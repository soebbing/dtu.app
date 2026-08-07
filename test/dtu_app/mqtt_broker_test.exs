defmodule DtuApp.MqttBrokerTest do
  use DtuApp.DataCase

  import DtuApp.AccountsFixtures
  import DtuApp.DevicesFixtures

  alias DtuApp.MqttBroker.Credentials
  alias DtuApp.MqttBroker.Telemetry
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
      assert reading.yield_total == 980.0
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
end
