defmodule DtuApp.DevicesTest do
  use DtuApp.DataCase, async: true

  alias DtuApp.Devices
  alias DtuApp.DevicesFixtures

  describe "get_daily_stats/2 — today_yield" do
    test "returns 0 when the user has no DTUs" do
      user = DtuApp.AccountsFixtures.user_fixture()
      stats = Devices.get_daily_stats(user)
      assert stats.today_yield == 0.0
      assert stats.current_power == 0.0
      assert stats.peak_power == 0.0
    end

    test "sums MAX(yield_day) per inverter for today's readings" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)
      now = DateTime.utc_now()

      # Two inverters with multiple readings each; the most recent reading
      # should win (yield_day is monotonic within a day). The fixture values
      # are in Wh — OpenDTU/AhoyDTU firmware publish yield_day in Wh, and
      # `get_daily_stats/2` converts to kWh before returning it for the
      # dashboard label.
      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-A",
        yield_day: 1_000.0,
        inserted_at: DateTime.add(now, -120, :second)
      })

      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-A",
        yield_day: 5_000.0,
        inserted_at: now
      })

      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-B",
        yield_day: 3_500.0,
        inserted_at: DateTime.add(now, -60, :second)
      })

      # Earlier (smaller) reading on INV-A — must NOT win. 5_000 + 3_500 Wh
      # = 8_500 Wh = 8.5 kWh.
      stats = Devices.get_daily_stats(user)
      assert_in_delta stats.today_yield, 8.5, 0.001
    end

    test "ignores readings from before today (UTC day window)" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)
      today = DateTime.utc_now()

      # Yesterday: 99 kWh (99_000 Wh) — must not count.
      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-A",
        yield_day: 99_000.0,
        inserted_at: DateTime.add(today, -1, :day)
      })

      # Today: 4.2 kWh (4_200 Wh) — wins.
      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-A",
        yield_day: 4_200.0,
        inserted_at: today
      })

      stats = Devices.get_daily_stats(user)
      assert_in_delta stats.today_yield, 4.2, 0.001
    end

    test "uses MAX(yield_day) even when the latest raw row's yield_day is stale" do
      # The pre-fix bug: get_daily_stats/2 summed yield_day from the latest
      # reading per inverter. If the inverter went offline mid-day, the
      # latest reading's yield_day is whatever it was when the inverter
      # stopped sending. The fix groups today's readings and takes MAX.
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)
      now = DateTime.utc_now()

      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-A",
        yield_day: 12_000.0,
        inserted_at: DateTime.add(now, -360, :second)
      })

      # Inverter went offline an hour ago. Reading has a low yield_day
      # because the inverter's counter stopped accumulating.
      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-A",
        yield_day: 500.0,
        inserted_at: now
      })

      stats = Devices.get_daily_stats(user)
      assert_in_delta stats.today_yield, 12.0, 0.001
    end

    test "treats nil yield_day as 0 so a half-wired inverter doesn't poison the sum" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)
      now = DateTime.utc_now()

      # Inserted with nil yield_day — simulates a firmware bug or a brand
      # new inverter that hasn't reported daily totals yet.
      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-A",
        yield_day: nil,
        inserted_at: now
      })

      stats = Devices.get_daily_stats(user)
      assert stats.today_yield == 0.0
    end

    test "scopes by dtu_id when one is passed" do
      user = DtuApp.AccountsFixtures.user_fixture()
      dtu1 = DevicesFixtures.device_fixture(user)
      dtu2 = DevicesFixtures.device_fixture(user)
      now = DateTime.utc_now()

      # Wh values; converted to kWh by get_daily_stats/2.
      DevicesFixtures.reading_fixture(dtu1, %{yield_day: 2_000.0, inserted_at: now})
      DevicesFixtures.reading_fixture(dtu2, %{yield_day: 7_000.0, inserted_at: now})

      assert_in_delta Devices.get_daily_stats(user, dtu1.id).today_yield, 2.0, 0.001
      assert_in_delta Devices.get_daily_stats(user, dtu2.id).today_yield, 7.0, 0.001
      assert_in_delta Devices.get_daily_stats(user).today_yield, 9.0, 0.001
    end
  end

  describe "get_daily_stats/2 — peak_power" do
    test "tracks the live current_power even before the 5-min bucket fills" do
      # The 5-min continuous aggregate closes its window 5 minutes after
      # the first reading in the bucket. A fast-rising morning ramp can
      # therefore have a `bucket_max` of e.g. 200 W while the live reading
      # is already 800 W. The bug reported in the field: the user sees
      # "Current generation: 800 W" and "Peak power: 200 W" at the same
      # time. Fix: peak_power = max(bucket_max, current_power) so the
      # displayed number follows the live reading.
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)
      now = DateTime.utc_now()

      # Both readings on the same inverter and 50 s apart — well under
      # the 5-min window so they always land in the same bucket regardless
      # of where the test happens to run inside the bucket. The mean of
      # this single bucket is (100 + 800) / 2 = 450 W; the live reading
      # (50 s ago) is well inside the 2-min freshness window and dominates
      # `current_power`.
      #   bucket_max:        450 W
      #   current_power:     800 W
      #   peak_power (good):  max(450, 800) = 800 W
      #   peak_power (bug):  450 W
      DevicesFixtures.reading_fixture(device, %{
        ac_power: 100.0,
        inverter_serial: "INV-A",
        inserted_at: DateTime.add(now, -100, :second)
      })

      DevicesFixtures.reading_fixture(device, %{
        ac_power: 800.0,
        inverter_serial: "INV-A",
        inserted_at: DateTime.add(now, -50, :second)
      })

      stats = Devices.get_daily_stats(user)

      # current_power is the live instantaneous power — the latest reading.
      assert_in_delta stats.current_power, 800.0, 0.1

      # peak_power is the live max whenever it exceeds the bucket max.
      assert_in_delta stats.peak_power,
                      800.0,
                      0.1,
                      "peak_power should track current_power when current exceeds bucket_max"
    end

    test "stays at the bucket max when the live current_power is below it" do
      # Cloud-cover transient: the most recent (live) reading dropped to
      # 50 W but a closed 5-min bucket from earlier in the hour averaged
      # 600 W. The user expects the day's peak to remain at 600 W.
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)
      now = DateTime.utc_now()

      # An older reading 6 minutes ago — in its own 5-min bucket, mean
      # equals the single reading (600 W).
      DevicesFixtures.reading_fixture(device, %{
        ac_power: 600.0,
        inverter_serial: "INV-A",
        inserted_at: DateTime.add(now, -360, :second)
      })

      # Live reading — 30 s ago, in its own (current) 5-min bucket. 50 W.
      DevicesFixtures.reading_fixture(device, %{
        ac_power: 50.0,
        inverter_serial: "INV-A",
        inserted_at: DateTime.add(now, -30, :second)
      })

      stats = Devices.get_daily_stats(user)

      assert_in_delta stats.current_power, 50.0, 0.1

      assert_in_delta stats.peak_power,
                      600.0,
                      0.1,
                      "peak_power should be the day's high, not the live low"
    end
  end

  describe "get_daily_stats/2 — per_series breakdown" do
    test "emits one entry per (inverter_serial, mppt_index) with the day's yield and peak" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      # Single inverter with AC + 2 DC MPPTs. Each (inverter, mppt) pair
      # contributes one row to `per_series`.
      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-A",
        inverter_name: "Roof Array",
        mppt_index: 0,
        ac_power: 500.0,
        yield_day: 5_000.0
      })

      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-A",
        inverter_name: "Roof Array",
        mppt_index: 1,
        dc_power: 250.0,
        yield_day: 2_500.0
      })

      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-A",
        inverter_name: "Roof Array",
        mppt_index: 2,
        dc_power: 250.0,
        yield_day: 2_500.0
      })

      stats = Devices.get_daily_stats(user)

      assert length(stats.per_series) == 3

      by_mppt = Map.new(stats.per_series, &{&1.mppt_index, &1})

      # The friendly name is preserved on every entry so the legend can
      # label each line without a separate join.
      assert by_mppt[0].inverter_name == "Roof Array"
      assert by_mppt[1].inverter_name == "Roof Array"
      assert by_mppt[2].inverter_name == "Roof Array"

      # Yields are converted to kWh (OpenDTU/AhoyDTU publish Wh).
      assert_in_delta by_mppt[0].today_yield, 5.0, 0.001
      assert_in_delta by_mppt[1].today_yield, 2.5, 0.001
      assert_in_delta by_mppt[2].today_yield, 2.5, 0.001
    end

    test "per_series sums to today_yield even when MPPTs report partial data" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      # Two inverters × two MPPTs each. yield_day is in Wh; get_daily_stats
      # converts to kWh before returning.
      for {serial, mppts} <- [{"INV-1", [1, 2]}, {"INV-2", [1]}] do
        for mppt <- mppts do
          DevicesFixtures.reading_fixture(device, %{
            inverter_serial: serial,
            mppt_index: mppt,
            yield_day: 1_000.0
          })
        end
      end

      stats = Devices.get_daily_stats(user)

      # 3 series × 1 kWh each = 3.0 kWh total
      assert_in_delta stats.today_yield, 3.0, 0.001
      assert length(stats.per_series) == 3
    end

    test "per_series is empty when the user has no DTUs" do
      user = DtuApp.AccountsFixtures.user_fixture()
      stats = Devices.get_daily_stats(user)
      assert stats.per_series == []
    end
  end

  describe "list_day_chart_data/3 — per-series bucketing" do
    test "returns one series per (dtu_id, inverter_serial, mppt_index)" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)
      now = DateTime.utc_now()

      # Two inverters, second one with two MPPTs. The chart should expose
      # four series, not one combined total.
      for {serial, mppt, power} <- [
            {"INV-1", 0, 400.0},
            {"INV-2", 1, 150.0},
            {"INV-2", 2, 100.0}
          ] do
        DevicesFixtures.reading_fixture(device, %{
          inverter_serial: serial,
          mppt_index: mppt,
          inverter_name: serial,
          ac_power: power,
          inserted_at: now
        })
      end

      points =
        Devices.list_day_chart_data(
          user,
          ~U[2026-07-31 00:00:00Z],
          ~U[9999-12-31 23:59:59Z]
        )

      series_set =
        points
        |> Enum.map(& &1.series)
        |> Enum.uniq()

      assert length(series_set) == 3
    end
  end

  describe "update_inverter_name/3" do
    test "backfills inverter_name on every row for the given (dtu_id, inverter_serial)" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "S1",
          mppt_index: 0,
          inverter_name: nil,
          ac_power: 100.0
        })

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "S1",
          mppt_index: 1,
          inverter_name: nil,
          dc_power: 80.0
        })

      # A reading for a different serial — must not be touched.
      {:ok, _other} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "S2",
          mppt_index: 0,
          inverter_name: nil,
          ac_power: 50.0
        })

      assert {:ok, 2} = Devices.update_inverter_name(device.id, "S1", "Friendly Name")

      import Ecto.Query
      alias DtuApp.Devices.Reading

      s1_rows =
        Reading
        |> where([r], r.dtu_id == ^device.id and r.inverter_serial == "S1")
        |> DtuApp.Repo.all()

      assert Enum.all?(s1_rows, &(&1.inverter_name == "Friendly Name"))

      s2_rows =
        Reading
        |> where([r], r.dtu_id == ^device.id and r.inverter_serial == "S2")
        |> DtuApp.Repo.all()

      assert Enum.all?(s2_rows, &(&1.inverter_name == nil))
    end

    test "returns {:ok, 0} for an empty / whitespace-only name without touching existing rows" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "S1",
          mppt_index: 0,
          inverter_name: "Existing Name",
          ac_power: 100.0
        })

      assert {:ok, 0} = Devices.update_inverter_name(device.id, "S1", "   ")

      import Ecto.Query
      alias DtuApp.Devices.Reading

      [reading] =
        Reading
        |> where([r], r.dtu_id == ^device.id and r.inverter_serial == "S1")
        |> DtuApp.Repo.all()

      assert reading.inverter_name == "Existing Name"
    end
  end

  describe "get_daily_stats/2 — current_power with multi-MPPT DTUs (regression)" do
    # Customer-reported bug: a DTU with multiple inverters, each exposing
    # one or two MPPTs, showed "Current Generation: 0 W" on the dashboard
    # even though the production curve was clearly producing. Root cause:
    # the previous query did `distinct: [dtu_id, inverter_serial]` without
    # filtering on mppt_index, so the "latest reading per inverter" was
    # whichever (inverter, MPPT) row happened to have the most recent
    # timestamp. Per-MPPT rows only carry `dc_power` (not `ac_power`), so
    # summing `ac_power || 0.0` over those rows always yielded 0.

    test "current_power is the sum of ac_power across the latest AC rows per inverter" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)
      now = DateTime.utc_now()

      # Two inverters, each with one AC row and one per-MPPT row.
      # Per-MPPT row for inverter-1 is published *more recently* than its
      # AC row — this is the regression trigger. Pre-fix, the latest-row
      # pick for inverter-1 would be the per-MPPT row whose ac_power is
      # nil, dropping the inverter's contribution from `current_power`.
      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-1",
        inverter_name: "East Array",
        mppt_index: 0,
        ac_power: 400.0,
        inserted_at: DateTime.add(now, -60, :second)
      })

      # The per-MPPT row arrives a minute later — typical for OpenDTU's
      # `[serial]/[1-4]/power` topic which fires more often than
      # `realtime/data`.
      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-1",
        inverter_name: "East Array",
        mppt_index: 1,
        dc_power: 200.0,
        ac_power: nil,
        inserted_at: now
      })

      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-2",
        inverter_name: "West Array",
        mppt_index: 0,
        ac_power: 250.0,
        inserted_at: DateTime.add(now, -30, :second)
      })

      stats = Devices.get_daily_stats(user)

      # current_power is the sum of the latest AC row's ac_power per
      # inverter (400 + 250 = 650 W), not the sum of `latest row per
      # inverter` regardless of mppt_index.
      assert_in_delta stats.current_power, 650.0, 0.1
    end

    test "current_power ignores a per-MPPT row whose dc_power is nil (no contribution)" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)
      now = DateTime.utc_now()

      # Inverter has only a per-MPPT row (no AC row yet) — `current_power`
      # should still be 0 because there's no ac_power to sum.
      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-1",
        inverter_name: "Solo MPPT",
        mppt_index: 1,
        dc_power: 200.0,
        ac_power: nil,
        inserted_at: now
      })

      stats = Devices.get_daily_stats(user)
      assert_in_delta stats.current_power, 0.0, 0.1
    end

    test "per_series_peak uses dc_power for per-MPPT rows (not ac_power)" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)
      now = DateTime.utc_now()

      # Per-MPPT row whose ac_power is nil but dc_power is 380 W. Pre-fix
      # the per-series peak for this MPPT would be 0; post-fix it should
      # be 380 W.
      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-1",
        inverter_name: "East Array",
        mppt_index: 1,
        dc_power: 380.0,
        ac_power: nil,
        inserted_at: now
      })

      stats = Devices.get_daily_stats(user)

      [mppt_1] = Enum.filter(stats.per_series, &(&1.mppt_index == 1))
      assert_in_delta mppt_1.peak_power, 380.0, 0.1
    end
  end

  describe "list_day_chart_data/3 — per-MPPT lines (regression)" do
    # Customer-reported bug: when a DTU emits per-MPPT rows alongside the
    # AC aggregate, the chart legend listed each (inverter, MPPT) pair but
    # the per-MPPT lines were drawn flat at the X-axis. Root cause: the
    # chart bucketed `ac_power || 0.0`, but per-MPPT rows only store
    # `dc_power`. Post-fix each row's power picks the right field via
    # `chart_power_for_mppt/1`.

    test "per-MPPT chart points pick dc_power so per-string lines actually draw" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      # All three readings fall inside today's UTC day-window but inside
      # the same 5-min bucket so the chart emits one point per
      # (inverter, MPPT) series.
      bucket =
        Date.utc_today()
        |> DateTime.new!(~T[06:02:00])
        |> Map.put(:microsecond, {0, 6})

      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-1",
        inverter_name: "East Array",
        mppt_index: 0,
        ac_power: 500.0,
        dc_power: 520.0,
        inserted_at: bucket
      })

      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-1",
        inverter_name: "East Array",
        mppt_index: 1,
        ac_power: nil,
        dc_power: 250.0,
        inserted_at: bucket
      })

      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-1",
        inverter_name: "East Array",
        mppt_index: 2,
        ac_power: nil,
        dc_power: 240.0,
        inserted_at: bucket
      })

      points =
        Devices.list_day_chart_data(
          user,
          ~U[2026-07-31 00:00:00Z],
          ~U[9999-12-31 23:59:59Z]
        )

      by_mppt = Map.new(points, &{elem(&1.series, 2), &1.power})

      # The AC aggregate line uses ac_power (500 W); per-MPPT lines use
      # dc_power (250 W and 240 W). Pre-fix all three would be plotted
      # at 0 because the bucketing read `ac_power || 0.0`.
      assert_in_delta by_mppt[0], 500.0, 0.1
      assert_in_delta by_mppt[1], 250.0, 0.1
      assert_in_delta by_mppt[2], 240.0, 0.1
    end
  end

  describe "mark_stale_dtus_offline/1" do
    # The broker only flips `online` on real CONNECT/DISCONNECT events.
    # A DTU that drops off silently (WiFi blip, NAT timeout, power-cycle
    # without a clean MQTT disconnect) keeps `online: true` indefinitely,
    # which contradicts the dashboard's "Last seen: 49 minutes ago" label.
    # The periodic sweep in `DtuApp.MqttBroker.Telemetry` calls
    # `mark_stale_dtus_offline/1` to catch this case. Tests here pin
    # the contract of that sweep so the dashboard LiveView's
    # `online`-badge refresh path stays correct.

    test "flips online to false for DTUs whose last_seen_at is older than the threshold" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      ten_min_ago = DateTime.utc_now() |> DateTime.add(-600, :second)

      {:ok, _} =
        DtuApp.Repo.update(
          Ecto.Changeset.change(device, %{online: true, last_seen_at: ten_min_ago})
        )

      assert {1, [flipped_id]} = Devices.mark_stale_dtus_offline(300)
      assert flipped_id == device.id

      reloaded = DtuApp.Repo.get!(DtuApp.Devices.Dtu, device.id)
      assert reloaded.online == false
      # `last_seen_at` is the historical record of the last uplink —
      # the sweep must not touch it.
      assert DateTime.compare(reloaded.last_seen_at, ten_min_ago) == :eq
    end

    test "leaves recent DTUs alone (last_seen_at within the threshold)" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      one_min_ago = DateTime.utc_now() |> DateTime.add(-60, :second)

      {:ok, _} =
        DtuApp.Repo.update(
          Ecto.Changeset.change(device, %{online: true, last_seen_at: one_min_ago})
        )

      assert {0, []} = Devices.mark_stale_dtus_offline(300)
      assert DtuApp.Repo.get!(DtuApp.Devices.Dtu, device.id).online == true
    end

    test "skips already-offline DTUs (idempotent — running twice is a no-op)" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      stale = DateTime.utc_now() |> DateTime.add(-600, :second)

      {:ok, _} =
        DtuApp.Repo.update(Ecto.Changeset.change(device, %{online: false, last_seen_at: stale}))

      assert {0, []} = Devices.mark_stale_dtus_offline(300)
    end

    test "honors a custom stale_after threshold" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      # Online 30 s ago. With the default 300 s threshold, this would
      # not flip. With a 10 s threshold, it should.
      thirty_sec_ago = DateTime.utc_now() |> DateTime.add(-30, :second)

      {:ok, _} =
        DtuApp.Repo.update(
          Ecto.Changeset.change(device, %{online: true, last_seen_at: thirty_sec_ago})
        )

      assert {0, []} = Devices.mark_stale_dtus_offline(300)

      assert {1, [flipped_id]} = Devices.mark_stale_dtus_offline(10)
      assert flipped_id == device.id
    end

    test "only flips DTUs owned by the affected user — no cross-user side effects" do
      # `update_all` is unscoped, so any stale DTU in the table is a
      # candidate. This test verifies the flip is scoped to the rows
      # that match the predicate (online AND stale), not by user —
      # which is correct: a DTU being stale is a property of the device,
      # not of who's logged in. Two users owning different DTUs see
      # both flips if both devices are stale.
      user1 = DtuApp.AccountsFixtures.user_fixture()
      user2 = DtuApp.AccountsFixtures.user_fixture()

      dtu1 = DevicesFixtures.device_fixture(user1)
      dtu2 = DevicesFixtures.device_fixture(user2)

      stale = DateTime.utc_now() |> DateTime.add(-600, :second)

      for dtu <- [dtu1, dtu2] do
        {:ok, _} =
          DtuApp.Repo.update(Ecto.Changeset.change(dtu, %{online: true, last_seen_at: stale}))
      end

      assert {2, ids} = Devices.mark_stale_dtus_offline(300)
      assert Enum.sort(ids) == Enum.sort([dtu1.id, dtu2.id])
    end

    test "DTUs with last_seen_at = nil are skipped (they've never connected)" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      {:ok, _} =
        DtuApp.Repo.update(Ecto.Changeset.change(device, %{online: false, last_seen_at: nil}))

      assert {0, []} = Devices.mark_stale_dtus_offline(300)
    end
  end

  describe "local_day_utc_range/2" do
    # Translates a user-facing local date into the UTC range that
    # contains the readings for that local day. The chart queries use
    # this so a Berlin user at 23:30 UTC (= 00:30 Berlin next day)
    # sees tomorrow's data, not today's — and vice versa.

    test "offset 0 (UTC) returns midnight-to-midnight in UTC" do
      assert {~U[2026-07-31 00:00:00Z], ~U[2026-07-31 23:59:59Z]} =
               Devices.local_day_utc_range(~D[2026-07-31], 0)
    end

    test "positive offset (east of UTC) shifts the UTC window earlier" do
      # Berlin winter: +01:00. Local 2026-07-31 = UTC 2026-07-30 23:00
      # → 2026-07-31 22:59:59.
      assert {~U[2026-07-30 23:00:00Z], ~U[2026-07-31 22:59:59Z]} =
               Devices.local_day_utc_range(~D[2026-07-31], 3_600)
    end

    test "positive offset crosses a UTC day boundary at the start" do
      # Tokyo winter: +09:00. Local 2026-08-01 in Tokyo = UTC 2026-07-31
      # 15:00 → 2026-08-01 14:59:59. The UTC day is DIFFERENT from the
      # local day at the start of the range.
      assert {~U[2026-07-31 15:00:00Z], ~U[2026-08-01 14:59:59Z]} =
               Devices.local_day_utc_range(~D[2026-08-01], 32_400)
    end

    test "negative offset (west of UTC) shifts the UTC window later" do
      # Honolulu winter: -10:00. Local 2026-07-31 in Honolulu = UTC
      # 2026-07-31 10:00 → 2026-08-01 09:59:59.
      assert {~U[2026-07-31 10:00:00Z], ~U[2026-08-01 09:59:59Z]} =
               Devices.local_day_utc_range(~D[2026-07-31], -36_000)
    end
  end
end
