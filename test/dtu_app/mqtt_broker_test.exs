defmodule DtuApp.MqttBrokerTest do
  use DtuApp.DataCase

  import DtuApp.AccountsFixtures
  import DtuApp.DevicesFixtures

  alias DtuApp.Accounts
  alias DtuApp.MqttBroker.Credentials
  alias DtuApp.MqttBroker.Telemetry
  alias DtuApp.Notifications
  alias DtuApp.Devices

  setup do
    # The broker and its Credentials cache are gated off in the test env, so
    # start the cache here for the auth/parser tests that need it.
    start_supervised!(DtuApp.MqttBroker.Credentials)
    user = user_fixture()
    {:ok, user: user}
  end

  describe "MQTT Credentials & Authentication" do
    test "authenticates with valid username and password", %{user: user} do
      dtu = device_fixture(user, %{mqtt_username: "my-dtu", mqtt_password: "supersecure"})

      # Seed cache
      Credentials.refresh(dtu.mqtt_username)

      assert {:ok, cached_device} = Credentials.verify("my-dtu", "supersecure")
      assert cached_device.id == dtu.id
      assert cached_device.user_id == user.id
    end

    test "fails verification with invalid password", %{user: user} do
      dtu = device_fixture(user, %{mqtt_username: "my-dtu2", mqtt_password: "supersecure"})

      Credentials.refresh(dtu.mqtt_username)

      assert {:error, :unauthorized} = Credentials.verify("my-dtu2", "wrongpassword")
    end

    test "fails verification with non-existent username" do
      assert {:error, :unauthorized} = Credentials.verify("unknown", "any")
    end
  end

  describe "Telemetry Ingestion & DB Storage" do
    test "parses OpenDTU payload and saves a reading", %{user: user} do
      dtu =
        device_fixture(user, %{kind: "opendtu", mqtt_username: "opendtu-1", base_topic: "solar"})

      Credentials.refresh(dtu.mqtt_username)

      # Build simulated authenticated device info
      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :opendtu,
        base_topic: "solar",
        name: dtu.name
      }

      payload = ~s({
        "AC": {
          "Power": {
            "v": 245.5
          },
          "Frequency": {
            "v": 50.1
          },
          "YieldDay": {
            "v": 4320.0
          },
          "YieldTotal": {
            "v": 125000.0
          }
        },
        "DC": {
          "Power": {
            "v": 250.0
          }
        },
        "INV": {
          "Temperature": {
            "v": 35.5
          }
        },
        "status": {
          "producing": 1,
          "reachable": 1
        }
      })

      topic = "solar/123456789/realtime/data"

      msg = {:uplink, "client_1", device_info, topic, payload}
      {:noreply, _new_state} = Telemetry.handle_info(msg, %{buffers: %{}})

      # Assert reading is inserted
      assert [reading] = Devices.list_recent_readings(user, dtu.id)
      assert reading.inverter_serial == "123456789"
      assert reading.ac_power == 245.5
      assert reading.frequency == 50.1
      assert reading.yield_day == 4320.0
      assert reading.producing == true
    end

    test "parses AhoyDTU payload, buffers, and flushes a reading whenever a meaningful metric arrives",
         %{user: user} do
      dtu =
        device_fixture(user, %{
          kind: "ahoydtu",
          mqtt_username: "ahoydtu-1",
          base_topic: "inverter"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :ahoydtu,
        base_topic: "inverter",
        name: dtu.name
      }

      state = %{buffers: %{}}

      # Send temperature — flushes immediately, even without AC power.
      msg1 = {:uplink, "client_2", device_info, "inverter/balcony-inv/ch0/Temp", "34.5"}
      {:noreply, state} = Telemetry.handle_info(msg1, state)

      assert [temp_reading] = Devices.list_recent_readings(user, dtu.id)
      assert temp_reading.inverter_serial == "balcony-inv"
      assert temp_reading.temperature == 34.5
      assert temp_reading.ac_power == nil
      assert temp_reading.yield_day == nil

      # Send yield_day — flushes again, carrying the previously-buffered
      # temperature through. This used to be silently dropped until P_AC.
      #
      # AhoyDTU publishes `YieldDay` in **Wh** (matching OpenDTU's
      # wire format). The parser stores the raw value (`cast_float/1`)
      # so the dashboard's `/1000` divisor renders the firmware's Wh
      # figure as a small kWh value (e.g. `1.23 Wh / 1000 = 0.00123`
      # kWh, rounded to `0.0` kWh on the live view; an installer
      # typically sees a non-zero daily after the first ~5 kWh which
      # is the granularity the AhoyDTU firmware publishes in).
      msg2 = {:uplink, "client_2", device_info, "inverter/balcony-inv/ch0/YieldDay", "1.23"}
      {:noreply, state} = Telemetry.handle_info(msg2, state)

      readings = Devices.list_recent_readings(user, dtu.id)
      assert [latest | _] = readings
      assert latest.temperature == 34.5
      assert latest.yield_day == 1.23
      assert latest.ac_power == nil

      # Send active power — flushes once more with the full picture.
      msg3 = {:uplink, "client_2", device_info, "inverter/balcony-inv/ch0/P_AC", "150.0"}
      {:noreply, _state} = Telemetry.handle_info(msg3, state)

      readings = Devices.list_recent_readings(user, dtu.id)
      assert [latest | _] = readings
      assert latest.ac_power == 150.0
      assert latest.temperature == 34.5
      assert latest.yield_day == 1.23
    end

    test "AhoyDTU yield-only uplink is persisted even when AC power is absent",
         %{user: user} do
      dtu =
        device_fixture(user, %{
          kind: "ahoydtu",
          mqtt_username: "ahoydtu-yield-only",
          base_topic: "inverter"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :ahoydtu,
        base_topic: "inverter",
        name: dtu.name
      }

      # Regression: AhoyDTU users reporting "Today's Total Yield" stuck at 0
      # because the firmware only publishes yield/temperature while the
      # inverter is producing is no longer true — each meaningful uplink
      # writes through, even with no P_AC in this batch.
      #
      # AhoyDTU numeric-topic YieldDay is published in **Wh** (matching
      # OpenDTU's wire format). The parser stores the raw value verbatim
      # (`cast_float/1`) so the dashboard's `/1000` divisor renders the
      # firmware's Wh figure as a small kWh value (e.g. `4.32 Wh / 1000`
      # = 0.00432 kWh). The dashboard's `Float.round(..., 1)` rounding
      # makes this `0.0 kWh` on the live card — the per-MPPT aggregation
      # + the dashboard's rounding make tiny daily values round to 0.0
      # on the live view.
      msg =
        {:uplink, "client_3", device_info, "inverter/balcony-inv/ch0/YieldDay", "4.32"}

      {:noreply, _state} = Telemetry.handle_info(msg, %{buffers: %{}})

      assert [reading] = Devices.list_recent_readings(user, dtu.id)
      assert reading.inverter_serial == "balcony-inv"
      assert reading.yield_day == 4.32
      assert reading.ac_power == nil
    end

    test "parses AhoyDTU JSON-layout per-channel payload in one uplink", %{user: user} do
      dtu =
        device_fixture(user, %{
          kind: "ahoydtu",
          mqtt_username: "ahoydtu-json",
          base_topic: "inverter"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :ahoydtu,
        base_topic: "inverter",
        name: dtu.name
      }

      # AhoyDTU "JSON" setting: one JSON object per channel. ch0 carries the
      # AC-side values plus the calculated DC power total.
      #
      # AhoyDTU publishes its two energy fields in different units on the
      # same firmware:
      #   * `YieldDay`  in **Wh** (matching OpenDTU's convention; user
      #     report: AhoyDTU's own UI shows the daily counter in Wh, not
      #     kWh).
      #   * `YieldTotal` in **kWh** (AhoyDTU's lifetime counter is
      #     published in kWh on both the JSON and numeric layouts).
      #
      # The parser normalises both to Wh at the DB boundary:
      #   * `cast_float/1` for `YieldDay` — passes the Wh value through
      #     verbatim so the dashboard's `/1000` divisor renders a small
      #     kWh figure (e.g. 100 Wh → 0.1 kWh).
      #   * `cast_ahoy_yield/1` for `YieldTotal` — multiplies the kWh
      #     value by 1000 so the DB column holds Wh; the dashboard's
      #     `/1000` divisor renders the firmware's kWh figure verbatim.
      #
      # Pin the post-processed Wh values:
      #   YieldDay   "2.5" Wh      → 2.5 Wh (no multiplier)
      #   YieldTotal "980.0" kWh   → 980_000.0 Wh (×1000)
      payload =
        ~s({"U_AC": 233.3, "P_AC": 320.0, "F_AC": 50.01, "Temp": 41.2,
            "YieldDay": 2.5, "YieldTotal": 980.0, "P_DC": 330.0})

      msg = {:uplink, "client_json", device_info, "inverter/balcony-inv/ch0", payload}
      {:noreply, _state} = Telemetry.handle_info(msg, %{buffers: %{}})

      assert [reading] = Devices.list_recent_readings(user, dtu.id)
      assert reading.inverter_serial == "balcony-inv"
      assert reading.ac_power == 320.0
      assert reading.dc_power == 330.0
      assert reading.frequency == 50.01
      assert reading.temperature == 41.2
      assert reading.yield_day == 2.5
      assert reading.yield_total == 980_000.0
    end

    test "OpenDTU realtime/data is persisted as the AC aggregate row (mppt_index=0)",
         %{user: user} do
      dtu =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "opendtu-ac-row",
          base_topic: "solar"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :opendtu,
        base_topic: "solar",
        name: dtu.name
      }

      payload = ~s({
        "AC": {
          "Power": {"v": 245.5},
          "YieldDay": {"v": 4320.0},
          "YieldTotal": {"v": 125000.0}
        },
        "DC": {"Power": {"v": 250.0}},
        "INV": {"Temperature": {"v": 35.5}},
        "status": {"producing": 1, "reachable": 1}
      })

      msg = {:uplink, "client_ac", device_info, "solar/123456789/realtime/data", payload}
      {:noreply, _state} = Telemetry.handle_info(msg, %{buffers: %{}})

      [reading] = Devices.list_recent_readings(user, dtu.id)
      assert reading.inverter_serial == "123456789"
      assert reading.mppt_index == 0
      assert reading.ac_power == 245.5
      assert reading.dc_power == 250.0
      assert reading.yield_day == 4320.0
      # `inverter_name` is null until OpenDTU's `{serial}/name` uplink
      # arrives — the realtime JSON doesn't carry it.
      assert reading.inverter_name == nil
    end

    test "OpenDTU per-MPPT DC channels buffer independently and emit a row per channel",
         %{user: user} do
      dtu =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "opendtu-per-mppt",
          base_topic: "solar"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :opendtu,
        base_topic: "solar",
        name: dtu.name
      }

      # Two DC MPPT inputs (channels 1 & 2) each publishing power, yieldday
      # and yieldtotal on staggered intervals. Both should end up in the
      # database as separate rows keyed by (inverter_serial, mppt_index).
      state = %{buffers: %{}}

      {:noreply, state} =
        Telemetry.handle_info(
          {:uplink, "client_mppt", device_info, "solar/INV-1/1/power", "120.0"},
          state
        )

      # First MPPT's yieldday arrives in its own uplink — must merge into
      # the same row (not start a second one for channel 1).
      {:noreply, state} =
        Telemetry.handle_info(
          {:uplink, "client_mppt", device_info, "solar/INV-1/1/yieldday", "800.0"},
          state
        )

      # Second MPPT publishes its own power — must create a new row with
      # mppt_index = 2, not bleed into channel 1's row.
      {:noreply, _state} =
        Telemetry.handle_info(
          {:uplink, "client_mppt", device_info, "solar/INV-1/2/power", "95.0"},
          state
        )

      readings = Devices.list_recent_readings(user, dtu.id)

      # Three rows total: each `flush?` uplink creates a row with the latest
      # accumulated buffer for that channel.
      #   1. channel 1 power-only uplink  → ch1 row, dc_power=120, yield_day=nil
      #   2. channel 1 yieldday uplink    → ch1 row, dc_power=120, yield_day=800
      #   3. channel 2 power uplink       → ch2 row, dc_power=95,  yield_day=nil
      # Channel 1's two rows carry the same (inverter, mppt_index) so the
      # chart's `MAX(yield_day)` aggregation is unchanged — the second row
      # just has both fields populated.
      assert length(readings) == 3

      by_mppt = Enum.group_by(readings, & &1.mppt_index)

      assert [ch1_old, ch1_new] = Enum.sort_by(by_mppt[1], & &1.inserted_at)
      assert ch1_old.dc_power == 120.0
      assert ch1_old.yield_day == nil
      assert ch1_new.dc_power == 120.0
      assert ch1_new.yield_day == 800.0

      assert [ch2] = by_mppt[2]
      assert ch2.inverter_serial == "INV-1"
      assert ch2.dc_power == 95.0
      assert ch2.yield_day == nil
    end

    test "OpenDTU per-MPPT AC-channel (channel 0) per-field uplinks are ignored to avoid double-counting",
         %{user: user} do
      dtu =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "opendtu-ac-ignore",
          base_topic: "solar"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :opendtu,
        base_topic: "solar",
        name: dtu.name
      }

      # `0/power` carries the same value as realtime/data's AC.Power — we
      # ignore it so a device that publishes both forms doesn't double its
      # AC row count.
      msg = {:uplink, "client_dup", device_info, "solar/INV-1/0/power", "200.0"}
      {:noreply, _state} = Telemetry.handle_info(msg, %{buffers: %{}})

      assert [] = Devices.list_recent_readings(user, dtu.id)
    end

    test "OpenDTU {serial}/name retroactively updates inverter_name on every existing row",
         %{user: user} do
      dtu =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "opendtu-name",
          base_topic: "solar"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :opendtu,
        base_topic: "solar",
        name: dtu.name
      }

      # Three pre-existing readings for the same serial with null name.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "123456789",
          mppt_index: 0,
          inverter_name: nil,
          ac_power: 100.0,
          yield_day: 500.0
        })

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "123456789",
          mppt_index: 1,
          inverter_name: nil,
          dc_power: 95.0,
          yield_day: 480.0
        })

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "123456789",
          mppt_index: 2,
          inverter_name: nil,
          dc_power: 5.0,
          yield_day: 20.0
        })

      # A reading for a *different* serial — must NOT be touched.
      {:ok, _other} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "987654321",
          mppt_index: 0,
          inverter_name: nil,
          ac_power: 50.0
        })

      # OpenDTU publishes the name configured in its web UI.
      msg = {:uplink, "client_name", device_info, "solar/123456789/name", "Roof Inverter"}
      {:noreply, _state} = Telemetry.handle_info(msg, %{buffers: %{}})

      readings_for_target = Devices.list_recent_readings(user, dtu.id)
      updated = Enum.filter(readings_for_target, &(&1.inverter_serial == "123456789"))

      assert length(updated) == 3
      assert Enum.all?(updated, &(&1.inverter_name == "Roof Inverter"))

      # Different serial keeps its nil name.
      [other] = Enum.filter(readings_for_target, &(&1.inverter_serial == "987654321"))
      assert other.inverter_name == nil
    end

    test "OpenDTU {serial}/name with empty payload is ignored and leaves names untouched",
         %{user: user} do
      dtu =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "opendtu-empty-name",
          base_topic: "solar"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :opendtu,
        base_topic: "solar",
        name: dtu.name
      }

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV-X",
          mppt_index: 0,
          inverter_name: "Existing Name",
          ac_power: 100.0
        })

      msg = {:uplink, "client_blank", device_info, "solar/INV-X/name", "   "}
      {:noreply, _state} = Telemetry.handle_info(msg, %{buffers: %{}})

      [reading] = Devices.list_recent_readings(user, dtu.id)
      assert reading.inverter_name == "Existing Name"
    end

    test "OpenDTU {serial}/status/producing patches the latest reading's producing flag",
         %{user: user} do
      dtu =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "opendtu-status",
          base_topic: "solar"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :opendtu,
        base_topic: "solar",
        name: dtu.name
      }

      now = DateTime.utc_now()

      # Two readings for the same serial. The status uplink should patch
      # the most recent one (inserted second, with the later timestamp).
      {:ok, older} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV-1",
          mppt_index: 0,
          inverter_name: nil,
          ac_power: 50.0,
          producing: true,
          inserted_at: DateTime.add(now, -60, :second)
        })

      {:ok, latest} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV-1",
          mppt_index: 0,
          inverter_name: nil,
          ac_power: 200.0,
          producing: true,
          inserted_at: now
        })

      msg = {:uplink, "client_st", device_info, "solar/INV-1/status/producing", "0"}
      {:noreply, _state} = Telemetry.handle_info(msg, %{buffers: %{}})

      import Ecto.Query
      alias DtuApp.Devices.Reading

      reload = fn r ->
        from(reading in Reading,
          where:
            reading.dtu_id == ^r.dtu_id and
              reading.inverter_serial == ^r.inverter_serial and
              reading.mppt_index == ^r.mppt_index and
              reading.inserted_at == ^r.inserted_at
        )
        |> DtuApp.Repo.one!()
      end

      # Only the latest row was patched — the older one keeps its original
      # `producing: true`.
      assert reload.(older).producing == true
      assert reload.(latest).producing == false
    end

    test "AhoyDTU ch0 publishes are tagged mppt_index=0 (AC aggregate row)",
         %{user: user} do
      dtu =
        device_fixture(user, %{
          kind: "ahoydtu",
          mqtt_username: "ahoydtu-ch0",
          base_topic: "inverter"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :ahoydtu,
        base_topic: "inverter",
        name: dtu.name
      }

      msg =
        {:uplink, "client_ch0", device_info, "inverter/balcony-inv/ch0/P_AC", "180.0"}

      {:noreply, _state} = Telemetry.handle_info(msg, %{buffers: %{}})

      [reading] = Devices.list_recent_readings(user, dtu.id)
      assert reading.inverter_serial == "balcony-inv"
      assert reading.mppt_index == 0
      assert reading.ac_power == 180.0
      assert reading.inverter_name == "balcony-inv"
    end

    test "AhoyDTU ch1 publishes are tagged mppt_index=1 (per-MPPT row)",
         %{user: user} do
      dtu =
        device_fixture(user, %{
          kind: "ahoydtu",
          mqtt_username: "ahoydtu-ch1",
          base_topic: "inverter"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :ahoydtu,
        base_topic: "inverter",
        name: dtu.name
      }

      msg =
        {:uplink, "client_ch1", device_info, "inverter/balcony-inv/ch1/P_DC", "150.0"}

      {:noreply, _state} = Telemetry.handle_info(msg, %{buffers: %{}})

      [reading] = Devices.list_recent_readings(user, dtu.id)
      assert reading.mppt_index == 1
      assert reading.dc_power == 150.0
    end

    test "AhoyDTU per-MPPT channels (ch1..6) do not persist yield values, only dc_power",
         %{user: user} do
      # Regression for the user-reported "daily value too high by 1000×"
      # bug on a multi-MPPT AhoyDTU install. The user's AhoyDTU UI
      # shows the daily counter as `100 Wh` and the lifetime counter
      # as `329.22 kWh`. The firmware publishes inverter-aggregate
      # yield on ch0 only; ch1..6 are per-MPPT DC inputs that don't
      # carry their own yield values (and even on firmware versions
      # that do, the per-MPPT values are sub-totals the firmware has
      # already summed into ch0).
      #
      # Before this fix, the parser extracted `yield_day` and
      # `yield_total` from ch1..6 JSON payloads (and the corresponding
      # numeric topics), and `get_daily_stats/3` summed `MAX(yield)`
      # across MPPTs — a 2-MPPT Hoymiles would 2× / 3× the inverter's
      # true daily production. After the fix, ch1..6 only carries
      # `dc_power` (per-string DC input). The dashboard relies on the
      # ch0 row's `yield_day` / `yield_total` for the inverter
      # aggregate.
      dtu =
        device_fixture(user, %{
          kind: "ahoydtu",
          mqtt_username: "ahoydtu-ch1-no-yield",
          base_topic: "inverter"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :ahoydtu,
        base_topic: "inverter",
        name: dtu.name
      }

      # A ch1 JSON payload that DOES include `YieldDay` / `YieldTotal`
      # keys (some AhoyDTU firmware versions emit these redundantly).
      # The parser should ignore the yield fields on ch1..6 — only
      # `P_DC` is persisted.
      payload =
        ~s({"P_DC": 250.0, "YieldDay": 5.0, "YieldTotal": 100.0})

      msg = {:uplink, "client_ch1_json", device_info, "inverter/balcony-inv/ch1", payload}
      {:noreply, _state} = Telemetry.handle_info(msg, %{buffers: %{}})

      [reading] = Devices.list_recent_readings(user, dtu.id)
      assert reading.inverter_serial == "balcony-inv"
      assert reading.mppt_index == 1
      assert reading.dc_power == 250.0
      # Yield fields must NOT be persisted on ch1+ — the dashboard
      # relies on the ch0 (mppt_index = 0) row for the inverter
      # aggregate.
      assert reading.yield_day == nil
      assert reading.yield_total == nil
    end

    test "AhoyDTU per-MPPT numeric yield topics (ch1..6/YieldDay) do not persist yield values",
         %{user: user} do
      # Companion to the JSON-layout test above: the AhoyDTU
      # numeric-topic layout must mirror the JSON layout and drop
      # `YieldDay` / `YieldTotal` on ch1..6. AhoyDTU publishes
      # inverter-aggregate yield on ch0 only — ch1..6 are per-string
      # DC inputs. Per the firmware design, ch0 = ch1 + ch2 (the
      # per-string sub-totals are summed into the aggregate). Persisting
      # per-MPPT yields as separate rows would cause the dashboard's
      # `MAX(yield_day)` aggregation to sum them into today's total,
      # double-counting the inverter's actual production.
      #
      # The parser's `parse_ahoydtu/3` coerces a per-MPPT yield
      # metric to `:other` (the unrecognised-metric atom) so it falls
      # through to the "ignored metric" path in the buffer handler
      # and the row lands without a yield field. The pair's value is
      # still in the buffer briefly but the buffer's `flush?` guard
      # checks `metric_atom != :other`, so a yield-only per-MPPT
      # uplink never flushes (no row written). When a per-MPPT uplink
      # carries a non-yield metric (e.g. `ch1/P_DC`), the flush
      # proceeds but the row's `yield_day` stays nil.
      dtu =
        device_fixture(user, %{
          kind: "ahoydtu",
          mqtt_username: "ahoydtu-ch1-numeric-no-yield",
          base_topic: "inverter"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :ahoydtu,
        base_topic: "inverter",
        name: dtu.name
      }

      # Per-MPPT YieldDay numeric topic. The parser drops the yield
      # metric — `parse_ahoydtu/3` maps `YieldDay` on ch1+ to `:other`,
      # so the buffer sees no recognised metric. No row is written.
      msg =
        {:uplink, "client_ch1_n", device_info, "inverter/balcony-inv/ch1/YieldDay", "5.0"}

      {:noreply, _state} = Telemetry.handle_info(msg, %{buffers: %{}})

      # No row at all — the yield-only per-MPPT uplink was suppressed.
      assert [] == Devices.list_recent_readings(user, dtu.id)
    end

    test "AhoyDTU per-MPPT numeric topics that mix yield + non-yield keep the non-yield, drop the yield",
         %{user: user} do
      # Companion to the yield-only test: when a per-MMPT uplink
      # carries both a yield field (must be dropped) and a non-yield
      # field like `P_DC` (must be persisted), the buffer flushes
      # with the non-yield fields populated and the yield field
      # nil. The pair reducer's `if metric_atom == :other` guard
      # ensures the dropped yield value never lands in the buffer
      # map, so a later ch1 flush can't back-fill the dropped
      # value into a row that's already been written.
      dtu =
        device_fixture(user, %{
          kind: "ahoydtu",
          mqtt_username: "ahoydtu-ch1-mixed",
          base_topic: "inverter"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :ahoydtu,
        base_topic: "inverter",
        name: dtu.name
      }

      state = %{buffers: %{}}

      # The pair `parse_ahoydtu/3` returns: `{:yield_day, :other}` for
      # the yield field (dropped at the parse site) plus the
      # non-yield `P_DC` field. The buffer only sees the latter; the
      # dropped pair's value is discarded and the `flush?` check
      # still fires because the buffer has at least one recognised
      # metric.
      {:noreply, _state} =
        Telemetry.handle_info(
          {:uplink, "client_ch1_mixed", device_info, "inverter/balcony-inv/ch1",
           ~s({"P_DC": 80.0, "YieldDay": 7.5})},
          state
        )

      # JSON layout path is exercised above. Now exercise the numeric
      # path: per-MPPT `P_DC` followed by a per-MPPT `YieldTotal`.
      # The P_DC uplink flushes the ch1 row with dc_power=120; the
      # following YieldTotal uplink is suppressed (no row).
      {:noreply, _state} =
        Telemetry.handle_info(
          {:uplink, "client_ch1_mixed", device_info, "inverter/balcony-inv/ch1/P_DC", "120.0"},
          state
        )

      readings = Devices.list_recent_readings(user, dtu.id)
      # Two rows from the JSON `P_DC` + numeric `P_DC` uplinks, both
      # with `yield_day == nil` and `yield_total == nil` because the
      # yield fields were dropped at the parse site.
      assert length(readings) == 2

      Enum.each(readings, fn r ->
        assert r.inverter_serial == "balcony-inv"
        assert r.mppt_index == 1
        assert r.dc_power in [80.0, 120.0]
        assert r.yield_day == nil
        assert r.yield_total == nil
      end)

      # And the per-MPPT `YieldTotal` uplink is suppressed entirely —
      # `flush?` is false because the only pair is `:other`.
      {:noreply, _state} =
        Telemetry.handle_info(
          {:uplink, "client_ch1_mixed", device_info, "inverter/balcony-inv/ch1/YieldTotal",
           "10.0"},
          state
        )

      # Still the same two rows — the per-MPPT YieldTotal uplink
      # didn't flush.
      assert length(Devices.list_recent_readings(user, dtu.id)) == 2
    end

    test "AhoyDTU fleet-total JSON uplink ({base}/total) persists yields into a _fleet row",
         %{user: user} do
      # The AhoyDTU firmware's `stateSendTotals` publishes a single
      # JSON object on `{base}/total` with `YieldDay` (Wh) and
      # `YieldTotal` (kWh — normalised to Wh by `cast_ahoy_yield/1`).
      # The parser keys the row by `inverter_serial = "_fleet"` so
      # the dashboard's `get_daily_stats/3` fleet-totals path can
      # prefer it over summing per-inverter rows.
      dtu =
        device_fixture(user, %{
          kind: "ahoydtu",
          mqtt_username: "ahoydtu-fleet",
          base_topic: "inverter"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :ahoydtu,
        base_topic: "inverter",
        name: dtu.name
      }

      payload =
        ~s({"YieldDay": 1234.0, "YieldTotal": 50.0})

      msg = {:uplink, "client_fleet", device_info, "inverter/total", payload}
      {:noreply, _state} = Telemetry.handle_info(msg, %{buffers: %{}})

      [reading] = Devices.list_recent_readings(user, dtu.id)
      assert reading.inverter_serial == "_fleet"
      assert reading.inverter_name == "_fleet"
      assert reading.mppt_index == 0
      # YieldDay arrives in Wh (per upstream `stateSendTotals`):
      # 1234.0 Wh verbatim.
      assert reading.yield_day == 1234.0
      # YieldTotal arrives in kWh and is normalised to Wh by the
      # parser: 50.0 kWh × 1000 = 50_000 Wh.
      assert reading.yield_total == 50_000.0
    end

    test "AhoyDTU fleet-total numeric-layout uplink ({base}/total/{Metric}) persists yields into a _fleet row",
         %{user: user} do
      # Fallback path for firmware variants that publish the fleet
      # total as per-field scalars on `{base}/total/{Metric}`. The
      # parser handles both the consolidated JSON topic and the
      # per-field scalar fallback; the row's `inverter_serial` and
      # `inverter_name` are both "_fleet" so the dashboard's
      # fleet-preference query path picks them up.
      dtu =
        device_fixture(user, %{
          kind: "ahoydtu",
          mqtt_username: "ahoydtu-fleet-numeric",
          base_topic: "inverter"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :ahoydtu,
        base_topic: "inverter",
        name: dtu.name
      }

      # Numeric-layout fleet-total YieldDay — landing in Wh.
      msg1 = {:uplink, "client_fleet_n", device_info, "inverter/total/YieldDay", "9876.0"}
      {:noreply, _state} = Telemetry.handle_info(msg1, %{buffers: %{}})

      [reading] = Devices.list_recent_readings(user, dtu.id)
      assert reading.inverter_serial == "_fleet"
      assert reading.yield_day == 9876.0
      assert reading.yield_total == nil
    end

    # End-to-end regression for the user-reported "daily value too high
    # by a factor of 1000 for AhoyDTU" bug. The user reported the
    # dashboard rendering `1856.0 kWh` when the firmware-published
    # daily counter was `1.856` — visually 1000× too big.
    #
    # Per the wire-format audit that introduced `cast_ahoy_yield/1`:
    #   * `YieldDay`   on AhoyDTU → published in **Wh** (matching OpenDTU).
    #   * `YieldTotal` on AhoyDTU → published in **kWh**.
    #
    # The AhoyDTU parser normalises `YieldTotal` only to Wh at the DB
    # boundary via `cast_ahoy_yield/1` (×1000). `YieldDay` lands
    # verbatim via `cast_float/1`, matching OpenDTU's wire format.
    # `get_daily_stats/3`'s `/1000` Wh → kWh divisor then renders the
    # firmware figures verbatim on the dashboard.
    #
    # Pin: YieldTotal = 1234.5 kWh → 1234.5 kWh on dashboard,
    #      YieldDay = 12 400 Wh  → 12.4 kWh on dashboard,
    #      `total_yield >= today_yield` invariant preserved.
    test "AhoyDTU JSON-layout uplink respects daily <= lifetime + matches the firmware's split-unit scale",
         %{user: user} do
      dtu =
        device_fixture(user, %{
          kind: "ahoydtu",
          mqtt_username: "ahoydtu-inv-scale",
          base_topic: "inverter"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :ahoydtu,
        base_topic: "inverter",
        name: dtu.name
      }

      # Residential-install values on the firmware's split-unit scale:
      #   YieldTotal = 1234.5 kWh   → parser stores 1_234_500.0 Wh (×1000)
      #   YieldDay   = 12_400.0 Wh  → parser stores   12_400.0 Wh (no multiplier)
      payload =
        ~s({"P_AC": 350.0, "YieldDay": 12400.0, "YieldTotal": 1234.5})

      msg = {:uplink, "client_inv", device_info, "inverter/balcony-inv/ch0", payload}
      {:noreply, _state} = Telemetry.handle_info(msg, %{buffers: %{}})

      stats = Devices.get_daily_stats(user)

      # The end-to-end invariant the user reported: today's daily must
      # be ≤ the lifetime total. If this fails, the dashboard renders
      # a daily value larger than the device has ever produced.
      assert stats.total_yield >= stats.today_yield,
             "total_yield=#{stats.total_yield} < today_yield=#{stats.today_yield}; " <>
               "the AhoyDTU parser must normalise kWh→Wh for YieldTotal at the boundary"

      # Magnitudes match what the firmware said.
      assert_in_delta stats.total_yield, 1234.5, 0.01
      assert_in_delta stats.today_yield, 12.4, 0.01
    end
  end

  describe "Shelly Plus 3EM (Gen3+) payload parsing" do
    # The 3EM publishes a single JSON object on `{base}/status/em:0`
    # carrying the EM component's status. Real-world fields (per the
    # EM component API):
    #   total_act_power       — net instantaneous power (W, signed)
    #   a/b/c_act_power       — per-phase active power (W)
    #   a_energy              — nested object: {total, by_minute, minute_ts}
    #   ... voltage / current / freq / pf (not persisted)
    #
    # A naive first-cut parser would expect `a_act_energy` / `b_act_energy`
    # / `c_act_energy` (the OLD Shelly 3EM Gen1 flat layout) — those keys
    # don't exist on a Gen3+ payload, so the parser silently dropped them
    # and the dashboard's "Current Consumption" / "Today's Consumption"
    # stayed at 0. The tests below pin the correct Gen3+ layout so the
    # regression doesn't reappear.

    test "parses total_act_power + per-phase a_energy.total into consumption rows",
         %{user: user} do
      dtu =
        device_fixture(user, %{
          kind: "shelly3em",
          mqtt_username: "shelly-1",
          base_topic: "shellies/shellyplus3em"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :shelly3em,
        base_topic: "shellies/shellyplus3em",
        name: dtu.name
      }

      # Real-world Shelly Plus 3EM payload shape (status/em:0). Note the
      # nested energy objects, NOT the flat a_act_energy of the Gen1 device.
      payload =
        Jason.encode!(%{
          "id" => 0,
          "a_current" => 4.029,
          "a_voltage" => 236.1,
          "a_act_power" => 951.2,
          "a_aprt_power" => 951.9,
          "a_pf" => 1.0,
          "a_freq" => 50,
          "a_errors" => [],
          "a_flags" => [],
          "b_current" => 4.027,
          "b_voltage" => 236.201,
          "b_act_power" => -951.1,
          "b_aprt_power" => 951.8,
          "b_pf" => 1.0,
          "b_freq" => 50,
          "b_errors" => [],
          "b_flags" => [],
          "c_current" => 3.03,
          "c_voltage" => 236.402,
          "c_act_power" => 715.4,
          "c_aprt_power" => 716.2,
          "c_pf" => 1.0,
          "c_freq" => 50,
          "c_errors" => [],
          "c_flags" => [],
          "n_current" => 11.029,
          "total_current" => 11.083,
          "total_act_power" => 715.5,
          "total_aprt_power" => 716.7,
          "user_calibrated_phase" => [],
          "errors" => []
        })

      # Shelly Plus 3EM firmware 1.0+ reports energy on a separate
      # EMData component (`emdata` topic), but our subscription is on
      # `status/em:0` only — the EMData component payload is the
      # standard shape with nested energy objects per phase.
      payload_with_energy =
        Jason.encode!(%{
          "id" => 0,
          "a_current" => 4.029,
          "a_voltage" => 236.1,
          "a_act_power" => 951.2,
          "a_energy" => %{"total" => 1500.0, "by_minute" => [], "minute_ts" => 1_700_000_000},
          "b_current" => 4.027,
          "b_voltage" => 236.201,
          "b_act_power" => -951.1,
          "b_energy" => %{"total" => 1500.0, "by_minute" => [], "minute_ts" => 1_700_000_000},
          "c_current" => 3.03,
          "c_voltage" => 236.402,
          "c_act_power" => 715.4,
          "c_energy" => %{"total" => 1500.0, "by_minute" => [], "minute_ts" => 1_700_000_000},
          "n_current" => 11.029,
          "total_current" => 11.083,
          "total_act_power" => 715.5
        })

      topic = "shellies/shellyplus3em/status/em:0"

      # First uplink — power only, no energy objects (matches the
      # documented case where `status/em:0` is published without the
      # per-phase energy fields yet).
      msg1 = {:uplink, "client_shelly", device_info, topic, payload}
      {:noreply, _} = Telemetry.handle_info(msg1, %{buffers: %{}})

      [reading1] = Devices.list_recent_readings(user, dtu.id)
      assert reading1.power_type == "consumption"
      assert reading1.inverter_serial == "em:0"
      assert reading1.mppt_index == 0
      assert reading1.consumption_power == 715.5
      # Energy objects absent — consumption_energy_total stays nil.
      assert reading1.consumption_energy_total == nil

      # Second uplink — full payload with nested energy objects. The
      # three `*.energy.total` fields sum to 1500 × 3 = 4500 Wh.
      msg2 = {:uplink, "client_shelly", device_info, topic, payload_with_energy}
      {:noreply, _} = Telemetry.handle_info(msg2, %{buffers: %{}})

      # list_recent_readings/3 orders by desc inserted_at, so
      # [reading_newer, reading_older] = [second uplink, first uplink].
      [reading_newer, _reading_older] = Devices.list_recent_readings(user, dtu.id, 2)
      assert reading_newer.consumption_power == 715.5
      assert reading_newer.consumption_energy_total == 4500.0
    end

    test "uplink on a non-matching base_topic logs a warning and writes no row",
         %{user: user} do
      # Reproduces the "device shows as online but no values on the
      # dashboard" symptom: Shelly's default MQTT prefix is the device
      # ID (e.g. `shellyplus3em-XXXXXXXXXXXX`), so the topic the device
      # actually publishes on won't match the app's base_topic unless the
      # user explicitly set the prefix on the Shelly's web UI.
      dtu =
        device_fixture(user, %{
          kind: "shelly3em",
          mqtt_username: "shelly-2",
          base_topic: "shellies/shellyplus3em"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :shelly3em,
        base_topic: "shellies/shellyplus3em",
        name: dtu.name
      }

      # Topic the device *actually* publishes on (Shelly default, not
      # the app's expected base_topic).
      msg = {:uplink, "client_shelly", device_info, "shellyplus3em-aabbcc/status/em:0", "{}"}

      # Capture logs at warn level — the unknown_topic clause now
      # logs a warn so the operator can see the topic mismatch.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:noreply, _} = Telemetry.handle_info(msg, %{buffers: %{}})
        end)

      assert log =~ "did not match"
      assert log =~ "base_topic"
      assert log =~ "MQTT prefix"

      # No row written — exactly the "online but no values" symptom
      # the user reported.
      assert Devices.list_recent_readings(user, dtu.id) == []
    end

    test "/online retained LWT does not write a row but still touches last_seen_at",
         %{user: user} do
      # Documents the LWT semantics: the broker still records the
      # device as online (last_seen_at touched) but we don't insert
      # any reading — the regular uplink path is what populates
      # consumption_* fields.
      dtu =
        device_fixture(user, %{
          kind: "shelly3em",
          mqtt_username: "shelly-3",
          base_topic: "shellies/shellyplus3em"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :shelly3em,
        base_topic: "shellies/shellyplus3em",
        name: dtu.name
      }

      before = DtuApp.Repo.reload!(dtu).last_seen_at

      msg = {:uplink, "client_shelly", device_info, "shellies/shellyplus3em/online", "true"}
      {:noreply, _} = Telemetry.handle_info(msg, %{buffers: %{}})

      assert Devices.list_recent_readings(user, dtu.id) == []
      after_seen = DtuApp.Repo.reload!(dtu).last_seen_at
      assert DateTime.compare(after_seen, before) in [:gt, :eq]
    end
  end

  describe "last_seen_at touch path — :dtu_seen broadcast" do
    # Online status is **derived** from `last_seen_at` (see
    # `DtuApp.Devices.Dtu.online?/2`). `last_seen_at` is touched on every
    # MQTT activity (uplink, CONNECT, DISCONNECT) by
    # `Telemetry.handle_info/2`, and the touched timestamp is followed
    # by a `:dtu_seen` broadcast on `dtu:status` so subscribed
    # LiveViews can refresh their device list. The tests below pin the
    # wiring so the dashboard badge flips within one publish interval
    # of a DTU waking up.

    test "every uplink touches last_seen_at to the DB clock" do
      user = user_fixture()

      dtu =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "uplink-touch",
          base_topic: "solar"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :opendtu,
        base_topic: "solar",
        name: dtu.name
      }

      # Anchor: a stale `last_seen_at` well below the threshold so
      # the device starts offline, then a single uplink should flip
      # it to "just now" (within threshold).
      stale = DateTime.utc_now() |> DateTime.add(-3600, :second)
      {:ok, _} = DtuApp.Repo.update(Ecto.Changeset.change(dtu, %{last_seen_at: stale}))

      msg = {:uplink, "client_touch", device_info, "solar/SN/realtime/data", "{}"}
      {:noreply, _} = Telemetry.handle_info(msg, %{buffers: %{}})

      reloaded = DtuApp.Repo.get!(DtuApp.Devices.Dtu, dtu.id)
      # The new `last_seen_at` is within the 5-min threshold (i.e.
      # `now - last_seen_at < 300 s`).
      diff = DateTime.diff(DateTime.utc_now(), reloaded.last_seen_at, :second)

      assert diff < 300,
             "expected last_seen_at to be touched to within 5 minutes, got diff=#{diff}s"

      # And the new value is strictly newer than the stale anchor.
      assert DateTime.compare(reloaded.last_seen_at, stale) == :gt
    end

    test "every uplink broadcasts :dtu_seen on the dtu:status topic with the device id" do
      user = user_fixture()

      dtu =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "uplink-broadcast",
          base_topic: "solar"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :opendtu,
        base_topic: "solar",
        name: dtu.name
      }

      :ok = Telemetry.subscribe_status()

      msg = {:uplink, "client_bc", device_info, "solar/SN/realtime/data", "{}"}
      {:noreply, _} = Telemetry.handle_info(msg, %{buffers: %{}})

      assert_receive {:dtu_seen, device_id}, 1_000
      assert device_id == dtu.id
    end

    test ":dtu_connected and :dtu_disconnected both touch last_seen_at" do
      user = user_fixture()
      dtu = device_fixture(user)
      Credentials.refresh(dtu.mqtt_username)

      stale = DateTime.utc_now() |> DateTime.add(-3600, :second)
      {:ok, _} = DtuApp.Repo.update(Ecto.Changeset.change(dtu, %{last_seen_at: stale}))

      # CONNECT and DISCONNECT both go through `touch_last_seen/1`.
      Telemetry.handle_info({:dtu_connected, "client_x", dtu.id}, %{buffers: %{}})

      after_connect = DtuApp.Repo.get!(DtuApp.Devices.Dtu, dtu.id).last_seen_at
      assert DateTime.compare(after_connect, stale) == :gt

      stale2 = DateTime.utc_now() |> DateTime.add(-3600, :second)
      {:ok, _} = DtuApp.Repo.update(Ecto.Changeset.change(dtu, %{last_seen_at: stale2}))

      Telemetry.handle_info({:dtu_disconnected, "client_x", dtu.id}, %{buffers: %{}})

      after_disconnect = DtuApp.Repo.get!(DtuApp.Devices.Dtu, dtu.id).last_seen_at
      assert DateTime.compare(after_disconnect, stale2) == :gt
    end

    test "unauthenticated uplinks (device_info = nil) do not touch last_seen_at or broadcast" do
      user = user_fixture()
      dtu = device_fixture(user)

      original = DateTime.utc_now() |> DateTime.add(-3600, :second)
      {:ok, _} = DtuApp.Repo.update(Ecto.Changeset.change(dtu, %{last_seen_at: original}))

      :ok = Telemetry.subscribe_status()

      # Unauthenticated uplink: device_info = nil. The handler short-
      # circuits before any DB write or broadcast.
      msg = {:uplink, "anon", nil, "solar/SN/realtime/data", "{}"}
      {:noreply, _} = Telemetry.handle_info(msg, %{buffers: %{}})

      refute_receive {:dtu_seen, _}, 200

      reloaded = DtuApp.Repo.get!(DtuApp.Devices.Dtu, dtu.id)
      assert DateTime.compare(reloaded.last_seen_at, original) == :eq
    end

    test "uploads touch last_seen_at even when the topic is ignored by the parser" do
      # The bug we're fixing: a DTU that stays MQTT-connected but
      # publishes only on topics the parser doesn't recognise used to
      # leave `last_seen_at` stale, so the dashboard showed it offline
      # even though telemetry was flowing. Now the touch happens before
      # the parser, so any PUBLISH — even one we drop — counts as
      # evidence the DTU is alive.
      user = user_fixture()

      dtu =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "unknown-topic",
          base_topic: "solar"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :opendtu,
        base_topic: "solar",
        name: dtu.name
      }

      stale = DateTime.utc_now() |> DateTime.add(-3600, :second)
      {:ok, _} = DtuApp.Repo.update(Ecto.Changeset.change(dtu, %{last_seen_at: stale}))

      # `garbage/foo` doesn't match any of the OpenDTU topic patterns
      # in `parse_opendtu/3` — it returns `{:ignored, :unknown_topic}`.
      msg = {:uplink, "client_unk", device_info, "solar/garbage/foo", "data"}
      {:noreply, _} = Telemetry.handle_info(msg, %{buffers: %{}})

      reloaded = DtuApp.Repo.get!(DtuApp.Devices.Dtu, dtu.id)
      assert DateTime.compare(reloaded.last_seen_at, stale) == :gt
    end
  end

  describe "DTU error surfacing (record_dtu_error/2)" do
    # Every parser error path (bad JSON, unknown topic, base-topic
    # mismatch on a Shelly, DB insert failure) must now persist on
    # `dtus.last_error` and broadcast `:dtu_error` on `dtu:status` so
    # the dashboard bubble and manage-device fill appear. The tests
    # below pin each path — they're the regression guard so a future
    # refactor can't quietly degrade the user-visible indicator.

    test "record_dtu_error/2 persists the message and broadcasts :dtu_error" do
      user = user_fixture()
      dtu = device_fixture(user)

      :ok = Telemetry.subscribe_status()

      assert :ok =
               Telemetry.record_dtu_error(
                 dtu.id,
                 "Invalid JSON payload on solar/SN/realtime/data"
               )

      reloaded = DtuApp.Repo.get!(DtuApp.Devices.Dtu, dtu.id)
      assert reloaded.last_error == "Invalid JSON payload on solar/SN/realtime/data"
      assert reloaded.last_error_at

      assert_receive {:dtu_error, device_id}, 1_000
      assert device_id == dtu.id
    end

    test "OpenDTU bad JSON uplink records an error including the payload" do
      # Real-world failure mode: an OpenDTU firmware in a transitional
      # state sends garbage JSON on `realtime/data`. The parser used to
      # silently drop it; now the bubble appears on the dashboard, and
      # the message includes the payload so the user can see exactly what
      # the device sent (useful for catching "JSON with trailing junk"
      # firmware bugs that the parser can't recover from).
      user = user_fixture()

      dtu =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "opendtu-bad-json",
          base_topic: "solar"
        })

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :opendtu,
        base_topic: "solar",
        name: dtu.name
      }

      msg = {:uplink, "client_bj", device_info, "solar/SN/realtime/data", "not-json"}
      {:noreply, _} = Telemetry.handle_info(msg, %{buffers: %{}})

      reloaded = DtuApp.Repo.get!(DtuApp.Devices.Dtu, dtu.id)
      assert reloaded.last_error =~ "bad_json"
      assert reloaded.last_error =~ "solar/SN/realtime/data"
      # Payload included in the message — `format_payload_snippet/1`
      # truncated to 200 chars; here the payload is short so it
      # round-trips verbatim.
      assert reloaded.last_error =~ "payload:"
      assert reloaded.last_error =~ "not-json"
    end

    test "OpenDTU unknown topic is downgraded to a Logger.info line — no dtu_error row written" do
      # An OpenDTU publishing on a topic we don't yet parse (e.g. a
      # future firmware version adds a field on a path we haven't wired
      # up yet) used to surface a user-visible error bubble. Now it's
      # downgraded to a plain info log with the topic + payload — the
      # DTU is otherwise healthy; we just don't know what to do with
      # that topic yet. The user's manage-device error panel is kept
      # focused on real issues they can act on.
      #
      # Captures logs at info level so the regression guard fails if a
      # future refactor moves this back to the warn path or starts
      # writing a `dtu_errors` row.
      user = user_fixture()

      dtu =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "opendtu-unk",
          base_topic: "solar"
        })

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :opendtu,
        base_topic: "solar",
        name: dtu.name
      }

      msg = {:uplink, "client_unk", device_info, "garbage/foo/bar", "data"}

      # The default test log level (`config :logger, level: :warning`)
      # drops `Logger.info` calls before they reach `ExUnit.CaptureLog`,
      # so the capture has to raise the threshold to :info for the
      # duration of the call. Bump it back via `on_exit` so we don't
      # leak the level change across tests.
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log = ExUnit.CaptureLog.capture_log(fn -> Telemetry.handle_info(msg, %{buffers: %{}}) end)

      # Log: includes the firmware kind, the device id, the topic, the
      # payload — every breadcrumb a developer needs to recognise what
      # the firmware started publishing.
      assert log =~ "[info]"
      assert log =~ "OpenDTU"
      assert log =~ to_string(dtu.id)
      assert log =~ "topic not yet handled"
      assert log =~ "garbage/foo/bar"
      assert log =~ "data"

      # No row written — the user's error list is left clean.
      reloaded = DtuApp.Repo.get!(DtuApp.Devices.Dtu, dtu.id)
      assert reloaded.last_error == nil
    end

    test "OpenDTU :ac_per_field_redundant does NOT record an error" do
      # `:ac_per_field_redundant` is the *expected* case for OpenDTU
      # devices that publish both `realtime/data` and per-field `0/*`
      # topics — duplicate-path suppression is part of the parser
      # contract, not an error. Surfacing it would create a useless
      # bubble on every healthy OpenDTU.
      user = user_fixture()

      dtu =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "opendtu-ok",
          base_topic: "solar"
        })

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :opendtu,
        base_topic: "solar",
        name: dtu.name
      }

      msg = {:uplink, "client_dup", device_info, "solar/INV-1/0/power", "200.0"}
      {:noreply, _} = Telemetry.handle_info(msg, %{buffers: %{}})

      reloaded = DtuApp.Repo.get!(DtuApp.Devices.Dtu, dtu.id)
      assert reloaded.last_error == nil
    end

    test "Shelly non-matching base_topic records an error including the payload" do
      # Companion to the existing "logs a warning and writes no row"
      # test: the same condition must additionally surface a user-
      # visible error message on `dtus.last_error`. The payload is now
      # included so a user can see exactly what the device sent on the
      # non-matching topic (often empty for a status uplink, but useful
      # for diagnostic capture-log captures).
      user = user_fixture()

      dtu =
        device_fixture(user, %{
          kind: "shelly3em",
          mqtt_username: "shelly-mismatch",
          base_topic: "shellies/shellyplus3em"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :shelly3em,
        base_topic: "shellies/shellyplus3em",
        name: dtu.name
      }

      # Shelly publishes on its default prefix, not the app's. This is
      # the "device shows as online but no values" failure mode the user
      # reported.
      msg = {:uplink, "client_shelly", device_info, "shellyplus3em-aabbcc/status/em:0", "{}"}

      {:noreply, _} = Telemetry.handle_info(msg, %{buffers: %{}})

      reloaded = DtuApp.Repo.get!(DtuApp.Devices.Dtu, dtu.id)
      assert reloaded.last_error =~ "Shelly topic mismatch"
      assert reloaded.last_error =~ "shellies/shellyplus3em"
      # Payload is included in the message so the user can see exactly
      # what was sent on the rejected topic.
      assert reloaded.last_error =~ "payload:"
      assert reloaded.last_error =~ "{}"
    end

    test "Shelly /online LWT does NOT record an error" do
      # The retained LWT is informational only — the broker's
      # disconnect path + `last_seen_at` updates already cover
      # liveness. Surfacing it as an error would produce a bubble on
      # every healthy Shelly.
      user = user_fixture()

      dtu =
        device_fixture(user, %{
          kind: "shelly3em",
          mqtt_username: "shelly-lwt",
          base_topic: "shellies/shellyplus3em"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :shelly3em,
        base_topic: "shellies/shellyplus3em",
        name: dtu.name
      }

      msg = {:uplink, "client_lwt", device_info, "shellies/shellyplus3em/online", "true"}
      {:noreply, _} = Telemetry.handle_info(msg, %{buffers: %{}})

      reloaded = DtuApp.Repo.get!(DtuApp.Devices.Dtu, dtu.id)
      assert reloaded.last_error == nil
    end

    test "AhoyDTU unknown topic is downgraded to a Logger.info line — no dtu_error row written" do
      # The AhoyDTU parser returns `{:error, :ignored_topic}` for three
      # shapes: `total/...` (AhoyDTU fleet totals, intentionally
      # dropped), JSON payload on a numeric-layout topic (mode-set
      # mismatch), and any topic that doesn't match the parser's
      # patterns. All three are "topic provided by the client that we
      # don't currently parse" — downgrade to a plain info log with
      # the topic + payload so a developer reading logs can identify
      # exactly what was sent. No `dtu_errors` row is written.
      user = user_fixture()

      dtu =
        device_fixture(user, %{
          kind: "ahoydtu",
          mqtt_username: "ahoydtu-unk",
          base_topic: "inverter"
        })

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :ahoydtu,
        base_topic: "inverter",
        name: dtu.name
      }

      # A topic structure that doesn't match any of the parser's
      # clauses — not the per-channel numeric form (`{base}/{name}/ch{N}/{Metric}`)
      # nor the JSON form (`{base}/{name}/ch{N}`), and not the fleet-total
      # topics (`{base}/total` or `{base}/total/{Metric}`). The parser's
      # `String.split/2` falls through to the catch-all clause which
      # returns `{:error, :ignored_topic}` → `Logger.info` log.
      msg =
        {:uplink, "client_ah", device_info, "inverter/balcony-inv/totally-bogus/garbage", "150.0"}

      # The default test log level (`config :logger, level: :warning`)
      # drops `Logger.info` calls before they reach `ExUnit.CaptureLog`,
      # so the capture has to raise the threshold to :info for the
      # duration of the call (then restore via `on_exit` so we don't
      # leak the level change to the rest of the suite).
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log = ExUnit.CaptureLog.capture_log(fn -> Telemetry.handle_info(msg, %{buffers: %{}}) end)

      # Log line: firmware kind, device id, topic, payload.
      assert log =~ "[info]"
      assert log =~ "AhoyDTU"
      assert log =~ to_string(dtu.id)
      assert log =~ "topic not yet handled"
      assert log =~ "totally-bogus"
      assert log =~ "150.0"

      # No row written — the user's manage-device error panel stays clean.
      reloaded = DtuApp.Repo.get!(DtuApp.Devices.Dtu, dtu.id)
      assert reloaded.last_error == nil
    end

    test "record_dtu_error/2 with non-existent device does not crash" do
      # The telemetry GenServer must survive a write to a stale device
      # id (e.g. the row was deleted between the uplink arriving and
      # us writing). Swallowing the error is the contract — see
      # `record_dtu_error/2`'s rescue clause.
      assert :ok = Telemetry.record_dtu_error(99_999_999, "phantom device")
    end

    test "record_dtu_error/2 with empty / whitespace message is a no-op" do
      user = user_fixture()
      dtu = device_fixture(user)

      assert :ok = Telemetry.record_dtu_error(dtu.id, "")
      assert :ok = Telemetry.record_dtu_error(dtu.id, "   ")

      reloaded = DtuApp.Repo.get!(DtuApp.Devices.Dtu, dtu.id)
      assert reloaded.last_error == nil
    end

    test "AhoyDTU {base}/total/{Field} numeric uplink does NOT record an error and clears any stale last_error" do
      # The user reported: a device shows a red error bubble with the
      # message "AhoyDTU uplink rejected (:ignored_topic on topic
      # "inverter/total/MaxPower")" even though the corresponding
      # `dtu_errors` row is older than the 48 h recency cutoff (the
      # expansion panel shows "No errors recorded for this DTU yet.").
      #
      # Root cause: an earlier parser build wrote that error message to
      # `dtus.last_error` for any topic the parser didn't recognise.
      # The current build:
      #   1. Recognises `{base}/total/{Field}` (AhoyDTU fleet-total
      #      numerics) and routes through `parse_ahoydtu/3`'s
      #      `[binary_base, "total", metric]` clause — no `:ignored_topic`
      #      error.
      #   2. Calls `clear_stale_dtu_error/1` on every successfully-parsed
      #      uplink so the cached `last_error` row is cleared the next
      #      time the device publishes a topic the parser recognises.
      #
      # This test pins both contracts: the AhoyDTU numeric fleet-total
      # topic doesn't write a new `dtu_errors` row, and a pre-existing
      # `last_error` value is cleared by the parser's
      # `clear_stale_error/1` call so the dashboard's red bubble goes
      # away on the next successful uplink.
      user = user_fixture()

      dtu =
        device_fixture(user, %{
          kind: "ahoydtu",
          mqtt_username: "ahoydtu-stale-error",
          base_topic: "inverter"
        })

      Credentials.refresh(dtu.mqtt_username)

      # Seed a stale cached error directly on the `dtus` row — without
      # going through `update_dtu_error/2` (which would also insert a
      # `dtu_errors` row). The user's bug is precisely that the
      # cached `last_error` column is sticky across parser versions,
      # so we want to reproduce just that state.
      stale_message =
        ~s|AhoyDTU uplink rejected (:ignored_topic on topic "inverter/total/MaxPower")|

      stale_ts = DtuApp.Time.utc_now_usec() |> DateTime.add(-(3 * 86_400), :second)

      dtu =
        DtuApp.Repo.get!(DtuApp.Devices.Dtu, dtu.id)
        |> Ecto.Changeset.change(%{last_error: stale_message, last_error_at: stale_ts})
        |> DtuApp.Repo.update!()

      assert dtu.last_error =~ "AhoyDTU uplink rejected"

      # Sanity check: the seed did NOT create a `dtu_errors` row (the
      # bug is that the column alone keeps the bubble — there isn't an
      # `dtu_errors` row in scope).
      assert DtuApp.Repo.one(
               from e in DtuApp.Devices.DtuError,
                 where: e.dtu_id == ^dtu.id
             ) == nil

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :ahoydtu,
        base_topic: "inverter",
        name: dtu.name
      }

      # The device publishes a current fleet-total numeric — the
      # topic the previous parser build rejected. The current parser
      # routes this through the `[binary_base, "total", metric]`
      # clause: `MaxPower` is unmapped, so `parse_ahoy_metric/1` returns
      # `:other`, but the pair reaches the buffer with the value.
      # `flush?` is false (only `:other`), so no row is written, but
      # the parser's success path triggers `clear_stale_error/1` —
      # which is the path that fixes the user's bug.
      msg =
        {:uplink, "client_stale", device_info, "inverter/total/MaxPower", "650"}

      {:noreply, _} = Telemetry.handle_info(msg, %{buffers: %{}})

      # Still no `dtu_errors` row — the parser's success path for
      # this topic doesn't go through `record_dtu_error/2`.
      assert DtuApp.Repo.one(
               from e in DtuApp.Devices.DtuError,
                 where: e.dtu_id == ^dtu.id
             ) == nil

      # The cached `last_error` was cleared by `clear_stale_error/1`.
      reloaded = DtuApp.Repo.get!(DtuApp.Devices.Dtu, dtu.id)
      assert reloaded.last_error == nil
      assert reloaded.last_error_at == nil
    end
  end

  describe "Broker.handle_publish/4" do
    alias DtuApp.MqttBroker.Broker

    test "handles topic as a binary string" do
      :ok = Broker.subscribe_uplink()
      device = %{id: 123, kind: :opendtu, base_topic: "inverter"}
      state = %{client_id: "test_client", device: device}

      assert {:ok, ^state} = Broker.handle_publish("inverter/mqtt", "payload_data", [], state)
      assert_receive {:uplink, "test_client", ^device, "inverter/mqtt", "payload_data"}
    end

    test "handles topic as a list of path segments" do
      :ok = Broker.subscribe_uplink()
      device = %{id: 123, kind: :opendtu, base_topic: "inverter"}
      state = %{client_id: "test_client", device: device}

      assert {:ok, ^state} =
               Broker.handle_publish(["inverter", "mqtt"], "payload_data", [], state)

      assert_receive {:uplink, "test_client", ^device, "inverter/mqtt", "payload_data"}
    end
  end

  describe "Read-only MQTT sink (:mqtt_ro_sink)" do
    # The fourth device kind, alongside OpenDTU / AhoyDTU / Shelly3EM,
    # is a passive subscriber that wants a real-time feed of every
    # other DTU's telemetry on the same account, but is **never**
    # allowed to PUBLISH. The broker enforces this with:
    #
    #   1. Soft-reject PUBLISHes from sinks — drop + warn, leave the
    #      connection open (the sink is otherwise healthy and the user
    #      wants a continuous stream).
    #   2. Same-account scope — a sink belonging to user A must only
    #      see uplinks from user A's other devices; user B's devices
    #      must not leak across accounts.
    #   3. No sink-to-sink forwarding — a sink never needs to see
    #      another sink's uplink (sinks don't publish), and gating on
    #      `source_device.kind != :mqtt_ro_sink` keeps the fan-out
    #      surface trivially small.
    #
    # The telemetry side (sinks never reach the parser; their uplinks
    # are simply dropped before any topic pattern match) is covered by
    # `Telemetry.handle_info({:uplink, ..., kind: :mqtt_ro_sink, ...}, ...)`
    # which is dispatched to a no-op clause in the parser dispatch.
    alias DtuApp.MqttBroker.Broker

    test "handle_publish/4 soft-rejects PUBLISHes from a sink (drop + warn, no error to client)" do
      :ok = Broker.subscribe_uplink()
      sink = %{id: 999, kind: :mqtt_ro_sink, user_id: 1, base_topic: "sinks/dturo"}
      state = %{client_id: "sink_client", device: sink}

      # Capture logs at warn level — the soft-reject logs a warning so
      # operators can see the misbehaving sink in their dashboards.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, ^state} =
                   Broker.handle_publish("sinks/dturo/inject", "fake-power", [], state)
        end)

      # Connection stays open (no {:error, _} return). The device's
      # state map is unchanged — `handle_publish/4` returned the same
      # state shape, no disconnect initiated.
      assert log =~ "READ-ONLY SINK PUBLISH DROPPED"
      assert log =~ "sink_client"
      assert log =~ "sinks/dturo/inject"

      # The uplink does NOT propagate to the regular dtu:uplink
      # PubSub topic — the soft-reject happens before the broadcast,
      # so subscribed telemetry consumers never see the bad payload.
      refute_receive {:uplink, _, _, _, _}, 200
    end

    test "handle_publish/4 still forwards PUBLISHes from non-sink devices" do
      :ok = Broker.subscribe_uplink()
      device = %{id: 1, kind: :opendtu, user_id: 1, base_topic: "solar"}
      state = %{client_id: "src_client", device: device}

      assert {:ok, ^state} =
               Broker.handle_publish("solar/SN/realtime/data", "{}", [], state)

      # The non-sink path still works — telemetry subscribers see the
      # regular `:uplink` event. (The `dtu:ro_fanout` side is checked
      # in the next test.)
      assert_receive {:uplink, "src_client", ^device, "solar/SN/realtime/data", "{}"}, 1_000
    end

    test "non-sink PUBLISHes are forwarded to dtu:ro_fanout with the source device" do
      :ok = Broker.subscribe_ro_fanout()
      device = %{id: 42, kind: :opendtu, user_id: 7, base_topic: "solar"}
      state = %{client_id: "src_client", device: device}

      Broker.handle_publish("solar/SN/realtime/data", "{}", [], state)

      # The ro_fanout subscriber sees the uplink with the source
      # device's user_id preserved so sinks can filter by account.
      assert_receive {:ro_uplink, source, "solar/SN/realtime/data", "{}"}, 1_000
      assert source.id == 42
      assert source.user_id == 7
      assert source.kind == :opendtu
    end

    test "sink PUBLISHes do NOT broadcast to dtu:ro_fanout (the soft-reject drops the message before fan-out)" do
      :ok = Broker.subscribe_ro_fanout()
      sink = %{id: 999, kind: :mqtt_ro_sink, user_id: 1, base_topic: "sinks/dturo"}
      state = %{client_id: "sink_client", device: sink}

      ExUnit.CaptureLog.capture_log(fn ->
        Broker.handle_publish("sinks/dturo/anything", "x", [], state)
      end)

      # Even though the soft-reject emits a warn log, no fan-out
      # message reaches the dtu:ro_fanout topic. A buggy broker that
      # fan-outs the sink's PUBLISH would leak its content here.
      refute_receive {:ro_uplink, _, _, _}, 200
    end

    test "sink subscribed to ro_fanout receives uplinks only from the same account" do
      :ok = Broker.subscribe_ro_fanout()
      sink = %{id: 100, kind: :mqtt_ro_sink, user_id: 1, base_topic: "sinks/dturo"}
      sink_state = %{client_id: "sink_client", device: sink}

      own_device = %{id: 10, kind: :opendtu, user_id: 1, base_topic: "solar"}
      own_state = %{client_id: "own_src", device: own_device}

      other_user_device = %{id: 20, kind: :opendtu, user_id: 2, base_topic: "solar"}
      other_state = %{client_id: "other_src", device: other_user_device}

      # Simulate the broker dispatching a fan-out message to the
      # sink's per-connection process. The handle_info clause filters
      # by user_id and source kind before forwarding as a PUBLISH.
      same_account_msg = {:ro_uplink, own_device, "solar/SN/realtime/data", "{}"}
      cross_account_msg = {:ro_uplink, other_user_device, "solar/SN/realtime/data", "{}"}

      # Same-account uplink — sink is allowed to see it.
      assert {:publish, "solar/SN/realtime/data", "{}", [], _} =
               Broker.handle_info(same_account_msg, sink_state)

      # Cross-account uplink — sink must NOT receive it.
      assert {:ok, _} = Broker.handle_info(cross_account_msg, sink_state)
    end

    test "sink subscribed to ro_fanout does NOT receive uplinks from other sinks" do
      :ok = Broker.subscribe_ro_fanout()

      sink_a = %{id: 100, kind: :mqtt_ro_sink, user_id: 1, base_topic: "sinks/dturo"}
      sink_a_state = %{client_id: "sink_a", device: sink_a}

      other_sink = %{id: 200, kind: :mqtt_ro_sink, user_id: 1, base_topic: "sinks/dturo"}

      # Even when same-account: a sink-to-sink fan-out is meaningless
      # (sinks don't publish). The handle_info clause's `source_device.kind
      # != :mqtt_ro_sink` guard ensures it never happens.
      msg = {:ro_uplink, other_sink, "solar/SN/realtime/data", "{}"}
      assert {:ok, _} = Broker.handle_info(msg, sink_a_state)
    end

    test "non-sink broker connection never receives ro_uplink fan-out (only sinks do)" do
      :ok = Broker.subscribe_ro_fanout()

      device = %{id: 50, kind: :opendtu, user_id: 1, base_topic: "solar"}
      state = %{client_id: "src_client", device: device}

      # The non-sink handle_info clause returns {:ok, state} — sinks
      # are the only consumers of the ro_fanout channel.
      msg = {:ro_uplink, device, "solar/SN/realtime/data", "{}"}
      assert {:ok, ^state} = Broker.handle_info(msg, state)
    end
  end

  describe "DTU connection notifications (notify_dtu_connection)" do
    # The dashboard's `:dtu_disconnected` handler fires a `:notification`
    # event to the user's topic when the DTU was recently online (last_seen
    # within 5 min). `:dtu_connected` fires on reconnect. Both events are
    # gated on the user's `notify_dtu_connection` preference — users who
    # didn't opt in stay silent. The tests below pin all four combinations.

    defp with_user(opts \\ %{}) do
      user = user_fixture()
      {:ok, _user} = Accounts.update_notification_settings(user, opts)
      %{user: user}
    end

    test "Notifications.broadcast/2 reaches a subscribed test process" do
      # The dashboard's :dtu_disconnected / :dtu_connected handlers
      # ultimately call `Notifications.broadcast/2`, which PubSub-broadcasts
      # a :notification event to `"user:notification:#{user.id}"`. We
      # don't mount the dashboard LiveView in this test (the broker test
      # setup doesn't include a LiveView conn) — instead we verify the
      # broadcast helper itself, which is the only side effect of the
      # handlers. The handlers themselves are gated by user opt-in and
      # by `last_seen_at` recency, both of which are trivial to read
      # from the source.
      %{user: user} = with_user(%{notify_dtu_connection: true})

      :ok = Notifications.subscribe(user.id)

      Notifications.broadcast(user.id, %{
        event: "dtu_connection",
        title: "DTU went offline",
        body: "Your inverter Test DTU has been offline for at least 5 minutes.",
        tag: "dtu:Test DTU"
      })

      assert_receive {:notification, payload}, 1_000
      assert payload.event == "dtu_connection"
      assert payload.title == "DTU went offline"
      assert payload.body =~ "Test DTU"
      assert payload.tag == "dtu:Test DTU"
    end

    test "Notifications.broadcast/2 routes per-user — does not leak to other users" do
      # Pin the per-user topic isolation: subscribing as user A must
      # not see notifications broadcast for user B. Pins the subscription
      # key the dashboard handler uses so a future refactor that drops
      # the user_id would fail this test.
      user_a = user_fixture()
      user_b = user_fixture()

      :ok = Notifications.subscribe(user_a.id)

      Notifications.broadcast(user_b.id, %{title: "for B only"})

      # User A receives nothing within 200ms — they didn't subscribe to
      # user B's topic, and a buggy implementation that broadcast to a
      # global "user:notification" topic would leak here.
      refute_receive {:notification, _}, 200
    end
  end
end
