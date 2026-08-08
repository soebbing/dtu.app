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

  describe "Dtu.online?/2 — derived online status from last_seen_at" do
    # Online status is **derived**, not stored. A DTU is online iff
    # `now - last_seen_at < 300 s` (the `Dtu.online_threshold_seconds`
    # module attribute). The dashboard reads this directly so it
    # reflects real-time liveness rather than the last broker
    # CONNECT. Tests here pin the boundary contract so the badge
    # stays correct as we touch `last_seen_at` from every MQTT
    # activity path.

    alias DtuApp.Devices.Dtu

    test "DTU with last_seen_at = nil is offline (never seen)" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      assert Dtu.online?(device) == false
      # Even when `now` is far in the past, a DTU that's never been
      # seen is offline — the helper short-circuits on nil.
      assert Dtu.online?(device, DateTime.utc_now()) == false
    end

    test "DTU with last_seen_at within the threshold is online" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      # last_seen_at = now - 60 s → online
      one_min_ago = DateTime.utc_now() |> DateTime.add(-60, :second)

      {:ok, device} =
        DtuApp.Repo.update(Ecto.Changeset.change(device, %{last_seen_at: one_min_ago}))

      now = DateTime.utc_now()
      assert Dtu.online?(device, now) == true
    end

    test "DTU with last_seen_at at exactly the threshold is offline (<, not <=)" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      now = DateTime.utc_now()
      # 300 s exactly → NOT online (the comparison is strict <)
      five_min_ago = DateTime.add(now, -300, :second)

      {:ok, device} =
        DtuApp.Repo.update(Ecto.Changeset.change(device, %{last_seen_at: five_min_ago}))

      assert Dtu.online?(device, now) == false
    end

    test "DTU with last_seen_at older than the threshold is offline" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      ten_min_ago = DateTime.utc_now() |> DateTime.add(-600, :second)

      {:ok, device} =
        DtuApp.Repo.update(Ecto.Changeset.change(device, %{last_seen_at: ten_min_ago}))

      assert Dtu.online?(device) == false
    end

    test "online? accepts an explicit `now` argument for deterministic tests" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      # last_seen_at is typed `:utc_datetime_usec`, so the test value
      # needs microsecond precision to round-trip through Ecto. With
      # now = +60 s, online; with now = +600 s, offline.
      fixed_last_seen = ~U[2026-08-01 12:00:00.000000Z]

      {:ok, device} =
        DtuApp.Repo.update(Ecto.Changeset.change(device, %{last_seen_at: fixed_last_seen}))

      one_min_after = ~U[2026-08-01 12:01:00.000000Z]
      ten_min_after = ~U[2026-08-01 12:10:00.000000Z]

      assert Dtu.online?(device, one_min_after) == true
      assert Dtu.online?(device, ten_min_after) == false
    end
  end

  describe "compute_day_period_stats/2" do
    # Pure data shaping: takes the yields + chart points the LiveView already
    # fetched (both user-scoped upstream) and rolls them into the day-view
    # "stat cards" — {total_yield, peak_power, avg_power}, rounded to one
    # decimal. Lives in the Devices context so the LiveView can stay focused
    # on rendering. The tests here pin the corner cases that the inline
    # math in the LiveView used to handle.

    test "returns all-zero stats for an empty day" do
      stats = Devices.compute_day_period_stats([], [])

      assert stats == %{
               total_yield: 0.0,
               peak_power: 0.0,
               avg_power: 0.0
             }
    end

    test "extracts the single-element total_yield from the day's yields list" do
      # The day view's yields list comes from `list_range_yield_data/4` and
      # always has exactly one entry — the day being viewed. Anything
      # else (the `_ -> 0.0` branch) is defensive: an empty range, or a
      # date that doesn't match, falls back to zero.
      stats =
        Devices.compute_day_period_stats(
          [{~D[2026-07-31], 8.5}],
          []
        )

      assert stats.total_yield == 8.5
      assert stats.peak_power == 0.0
      assert stats.avg_power == 0.0
    end

    test "uses the max of points for peak_power" do
      # Three sampled points: 250 W, 800 W (peak), 320 W. The function
      # ignores the chronology and takes the simple max — `peak_power`
      # is "what was the highest sampled reading today".
      points = [
        %{time: ~U[2026-07-31 06:00:00Z], series: {1, "S1", 0, nil}, power: 250.0},
        %{time: ~U[2026-07-31 12:00:00Z], series: {1, "S1", 0, nil}, power: 800.0},
        %{time: ~U[2026-07-31 18:00:00Z], series: {1, "S1", 0, nil}, power: 320.0}
      ]

      stats = Devices.compute_day_period_stats([{~D[2026-07-31], 12.3}], points)

      assert stats.peak_power == 800.0
    end

    test "computes avg_power as the arithmetic mean of points" do
      points = [
        %{time: ~U[2026-07-31 06:00:00Z], series: {1, "S1", 0, nil}, power: 100.0},
        %{time: ~U[2026-07-31 07:00:00Z], series: {1, "S1", 0, nil}, power: 200.0},
        %{time: ~U[2026-07-31 08:00:00Z], series: {1, "S1", 0, nil}, power: 300.0}
      ]

      stats = Devices.compute_day_period_stats([{~D[2026-07-31], 5.0}], points)

      assert stats.avg_power == 200.0
    end

    test "rounds all three stats to one decimal place" do
      # Floating-point drift between the Wh→kWh division upstream and
      # the kWh stat here is round-to-one-decimal. Pre-fix this lived in
      # four `Float.round(..., 3)` calls in the LiveView; the refactor
      # centralised the precision in one place.
      points = [
        %{time: ~U[2026-07-31 06:00:00Z], series: {1, "S1", 0, nil}, power: 123.4567}
      ]

      stats = Devices.compute_day_period_stats([{~D[2026-07-31], 1.23456}], points)

      assert stats.total_yield == 1.2
      assert stats.peak_power == 123.5
      assert stats.avg_power == 123.5
    end
  end

  describe "compute_range_period_stats/2" do
    # Same idea, but for the week / month / year views. The shape is
    # {total_yield, avg_yield, peak_date, peak_val} — note `peak_date`
    # (calendar day of the best day) and `avg_yield` (per-day average
    # computed against the calendar span, not the data span).

    test "returns nil peak_date for an empty period" do
      stats = Devices.compute_range_period_stats([], 7)

      assert stats == %{
               total_yield: 0.0,
               avg_yield: 0.0,
               peak_date: nil,
               peak_val: 0.0
             }
    end

    test "sums yields and divides by the calendar divisor" do
      # Week: 7 days, even if only 3 yielded data. avg_yield is per-day
      # across the full calendar span, not the 3 days with data — so a
      # partial week still averages over 7 days. `avg_yield` is rounded
      # to one decimal by the function, so we compare against the rounded
      # result, not the pre-rounding exact division.
      yields = [
        {~D[2026-08-04], 2.0},
        {~D[2026-08-05], 4.0},
        {~D[2026-08-06], 6.0}
      ]

      stats = Devices.compute_range_period_stats(yields, 7)

      assert stats.total_yield == 12.0
      # 12.0 / 7 ≈ 1.7142… rounded to one decimal = 1.7
      assert stats.avg_yield == 1.7
    end

    test "picks the highest-yield day as peak_date / peak_val" do
      yields = [
        {~D[2026-08-01], 3.0},
        {~D[2026-08-02], 7.5},
        {~D[2026-08-03], 1.0}
      ]

      stats = Devices.compute_range_period_stats(yields, 3)

      assert stats.peak_date == ~D[2026-08-02]
      assert stats.peak_val == 7.5
    end

    test "month divisor: averages over days-in-month" do
      # Month view: divisor = days-in-month (28, 29, 30, or 31). The
      # caller passes the exact count from Date.diff(last, first) + 1
      # so partial months still work (e.g. 17/31 if reading started
      # mid-month).
      yields = [{~D[2026-08-01], 31.0}, {~D[2026-08-15], 0.0}]

      stats = Devices.compute_range_period_stats(yields, 31)

      assert stats.total_yield == 31.0
      assert stats.avg_yield == 31.0 / 31.0
    end

    test "year divisor: averages over 12 months" do
      # Each year's yields are monthly aggregates (from the bar chart),
      # not daily — but the function is shape-agnostic on its input.
      # Divisor = 12.
      yields = [
        {~D[2026-01-01], 10.0},
        {~D[2026-06-01], 20.0}
      ]

      stats = Devices.compute_range_period_stats(yields, 12)

      assert stats.total_yield == 30.0
      assert stats.avg_yield == 30.0 / 12.0
    end

    test "rejects divisor 0 or negative" do
      # The function guard rejects zero/negative divisors rather than
      # dividing by zero or returning a meaningless negative average.
      # 0 days-in-month shouldn't happen in practice (Date.end_of_month
      # always returns ≥28), but defending against it makes the contract
      # explicit.
      assert_raise FunctionClauseError, fn ->
        Devices.compute_range_period_stats([{~D[2026-08-01], 1.0}], 0)
      end

      assert_raise FunctionClauseError, fn ->
        Devices.compute_range_period_stats([{~D[2026-08-01], 1.0}], -1)
      end
    end

    test "rounds total_yield, avg_yield, and peak_val to one decimal place" do
      # Same precision contract as compute_day_period_stats — the
      # refactor pulled all the Float.round(..., 3) calls out of the
      # LiveView and into one place per function.
      yields = [
        {~D[2026-08-01], 1.23456},
        {~D[2026-08-02], 7.89012}
      ]

      stats = Devices.compute_range_period_stats(yields, 7)

      assert stats.total_yield == 9.1
      assert_in_delta stats.avg_yield, 1.3, 0.05
      assert stats.peak_val == 7.9
    end
  end

  describe "compute_savings/2 + format_savings/1" do
    # Pure data-shaping helpers behind the dashboard's "Saved this
    # period" card. `compute_savings/2` takes a yield in kWh and a
    # cents-per-kWh rate and returns integer euro cents; `format_savings/1`
    # then renders those cents as a `€X.XX` string for the dashboard.
    #
    # Regression: the original implementation divided `kwh * cents` by
    # 100 inside `compute_savings/2`, but `format_savings/1` *also*
    # divided by 100 (via `div(cents, 100)`), so every card value was
    # 100× too small. For typical residential yields (single-digit kWh
    # per day) the `round()` step then collapsed the result to 0 cents,
    # which the dashboard rendered as "€0.00" — the "always shows 0"
    # bug reported in the field. The tests below pin the correct units
    # across the realistic yield / rate combinations the dashboard will
    # actually see.
    #
    # Yield-vs-rate powers covered:
    #   * Tiny day    (1.5 kWh) @ typical German rate (32c)  → €0.48
    #   * Small day   (5 kWh)   @ typical German rate (32c)  → €1.60
    #   * Mid month   (250 kWh) @ typical German rate (32c)  → €80.00
    #   * Edge: zero yield                                       → €0.00
    #   * Industrial (1500 kWh)  @ typical German rate (32c)  → €480.00
    #   * Feed-in tariff  (10 kWh) @ low rate (8c)             → €0.80
    #   * Premium tariff (10 kWh) @ high rate (45c)            → €4.50
    #   * High yield    (100 kWh) @ premium rate (50c)         → €50.00

    test "returns nil when kwh is nil so the dashboard hides the card" do
      assert Devices.compute_savings(nil, 32) == nil
    end

    test "returns nil when cents is nil so the dashboard hides the card" do
      # User hasn't set a rate on /users/settings yet. The card must
      # not render a misleading "€0.00" claim — `nil` makes the
      # template's `<%= if @savings %>` guard hide the card entirely.
      assert Devices.compute_savings(5.0, nil) == nil
    end

    test "tiny day (1.5 kWh) at €0.32/kWh returns 48 cents (€0.48)" do
      # Pre-fix: round(1.5 * 32 / 100) = round(0.48) = 0 → "€0.00".
      # Post-fix: round(1.5 * 32) = 48 → "€0.48".
      assert Devices.compute_savings(1.5, 32) == 48
      assert Devices.format_savings(48, "en") == "0.48 €"
    end

    test "small day (5 kWh) at €0.32/kWh returns 160 cents (€1.60)" do
      # A typical cloudy-day residential yield. Pre-fix this rendered
      # as €0.02 (off by 100x); the user reported "always shows 0"
      # because the rounded figure was too small to see.
      assert Devices.compute_savings(5.0, 32) == 160
      assert Devices.format_savings(160, "en") == "1.60 €"
    end

    test "typical month (250 kWh) at €0.32/kWh returns 8000 cents (€80.00)" do
      # Pre-fix this rendered as "€0.80" (off by 100x) — exactly the
      # "always shows 0" symptom for any user with even modest monthly
      # generation.
      assert Devices.compute_savings(250.0, 32) == 8_000
      assert Devices.format_savings(8_000, "en") == "80.00 €"
    end

    test "zero yield returns 0 cents (€0.00)" do
      # Genuine zero — not a unit-bug round-down. The dashboard should
      # still show the card (0 is truthy) so the user sees the rate
      # caption ("at 0.32 €/kWh") even on a no-sun day.
      assert Devices.compute_savings(0.0, 32) == 0
      assert Devices.format_savings(0, "en") == "0.00 €"
    end

    test "industrial scale (1500 kWh) at €0.32/kWh returns 48000 cents (€480.00)" do
      # Higher-power residential / small-commercial installs.
      assert Devices.compute_savings(1500.0, 32) == 48_000
      assert Devices.format_savings(48_000, "en") == "480.00 €"
    end

    test "feed-in tariff (10 kWh at €0.08/kWh) returns 80 cents (€0.80)" do
      # The German Einspeisevergütung (feed-in tariff) is well under
      # the purchase rate. Pre-fix this rendered as "€0.01" — easy to
      # mistake for a free/zero card.
      assert Devices.compute_savings(10.0, 8) == 80
      assert Devices.format_savings(80, "en") == "0.80 €"
    end

    test "premium purchase tariff (10 kWh at €0.45/kWh) returns 450 cents (€4.50)" do
      assert Devices.compute_savings(10.0, 45) == 450
      assert Devices.format_savings(450, "en") == "4.50 €"
    end

    test "high yield at premium rate (100 kWh at €0.50/kWh) returns 5000 cents (€50.00)" do
      assert Devices.compute_savings(100.0, 50) == 5_000
      assert Devices.format_savings(5_000, "en") == "50.00 €"
    end

    test "rounds fractional cents to the nearest cent" do
      # 2.555 kWh × 32 c/kWh = 81.76 c → rounds to 82.
      assert Devices.compute_savings(2.555, 32) == 82
      # 2.554 kWh × 32 c/kWh = 81.728 c → rounds to 82.
      assert Devices.compute_savings(2.554, 32) == 82
      # 2.553 kWh × 32 c/kWh = 81.696 c → rounds to 82.
      assert Devices.compute_savings(2.553, 32) == 82
      # 2.5 kWh × 32 c/kWh = exactly 80 c (no rounding drift).
      assert Devices.compute_savings(2.5, 32) == 80
    end

    test "format_savings renders two-decimal strings in en (comma + dot)" do
      # Pin the en format so the dashboard cards stay stable. The
      # locale-aware format_savings/2 picks decimal point and thousands
      # separator by locale; en uses comma thousand, dot decimal, with
      # the euro symbol after the number per common European writing.
      assert Devices.format_savings(0, "en") == "0.00 €"
      assert Devices.format_savings(1, "en") == "0.01 €"
      assert Devices.format_savings(99, "en") == "0.99 €"
      assert Devices.format_savings(100, "en") == "1.00 €"
      assert Devices.format_savings(101, "en") == "1.01 €"
      assert Devices.format_savings(999, "en") == "9.99 €"
      # Four-digit euro values (100_000 c = €1000) — trigger
      # a separator (3 digits past thousands wouldn't need one).
      assert Devices.format_savings(100_000, "en") == "1,000.00 €"
      # Five-digit euro values (1_000_000 c = €10,000) — one separator.
      assert Devices.format_savings(1_000_000, "en") == "10,000.00 €"
      # Six-digit euro values (1_234_567 c = €12,345.67) — most
      # complete separator example.
      assert Devices.format_savings(1_234_567, "en") == "12,345.67 €"
    end

    test "format_savings renders de format with dot thousand + comma decimal + € after" do
      # German format: 1.234,56 €
      assert Devices.format_savings(0, "de") == "0,00 €"
      # 123_456 c = €1234.56 → "1.234,56 €"
      assert Devices.format_savings(123_456, "de") == "1.234,56 €"
      # 1_234_567 c = €12345.67 → "12.345,67 €"
      assert Devices.format_savings(1_234_567, "de") == "12.345,67 €"
    end

    test "format_savings renders fr format with non-breaking-space thousand + comma decimal + € after" do
      # French typography (DIN 5008 / AFNOR): non-breaking space (U+00A0) as
      # thousands separator, comma as decimal. The byte length of the result
      # would be longer than the visible character count by 1 per separator.
      # (nbsp = 0xC2 0xA0 = 2 bytes; visible = 1 grapheme.)
      thousand_sep = " "

      assert Devices.format_savings(0, "fr") == "0,00 €"
      # Verify NBSP (not regular space) is the separator.
      assert Devices.format_savings(123_456, "fr") == "1#{thousand_sep}234,56 €"
      assert Devices.format_savings(1_234_567, "fr") == "12#{thousand_sep}345,67 €"
    end

    test "format_savings/1 picks up the current Gettext locale (en by default)" do
      # `format_savings/1` is the dashboard-callable form; it reads the
      # current locale via `Gettext.get_locale/1` and uses the matching
      # number-formatting convention. The test locale is "en" by
      # default, so the comma/dot convention must be applied.
      # 1_234_567 cents = €12,345.67.
      assert Devices.format_savings(1_234_567) == "12,345.67 €"
    end

    test "format_savings returns 0.00 € placeholder for nil" do
      # The template's `<%= if @savings %>` guard already hides the card
      # when the assign is nil, so format_savings is only ever called
      # with an integer in practice. But the helper still accepts nil
      # and renders a stable placeholder so a future caller (e.g. an
      # admin tool that wants to show "no data") can rely on it.
      assert Devices.format_savings(nil) == "0.00 €"
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

  describe "format_number/3 — locale-aware unit-less number formatting" do
    # The dashboard's stat cards (`Current Power`, `Today's Total Yield`,
    # `Peak Power`, etc.) and chart Y-axis labels need a locale-aware
    # number without a trailing unit — `format_savings/1` doesn't fit
    # because it always appends ` €`. The convention is the same as
    # `format_savings/1`: en uses comma+dot, de uses dot+comma, fr
    # uses NBSP+comma. These tests pin the convention across the
    # values the dashboard will actually render, including the
    # integer-precision watts cards (`decimals: 0`) and the
    # one-decimal kWh cards.

    test "en: comma as thousands separator, dot as decimal, default 1 decimal" do
      # Zero with explicit decimals: the helper always emits the decimal
      # portion (the dashboard's "0.0 kWh" / "0,0 kWh" / "0,0 kWh"
      # values are stable across renders). The dashboard wraps these
      # in a <div>, not a math display, so trailing-zero precision is
      # intentional — it signals "we measured a real zero, not a
      # missing value" (which is rendered as "—" by the nil clause).
      assert Devices.format_number(0.0, 1, "en") == "0.0"
      assert Devices.format_number(12.3, 1, "en") == "12.3"
      # Thousands boundary.
      assert Devices.format_number(1234.5, 1, "en") == "1,234.5"
      assert Devices.format_number(1_234_567.89, 2, "en") == "1,234,567.89"
      # Small fractions round (half-up via Erlang's `round/1`).
      assert Devices.format_number(0.05, 1, "en") == "0.1"
      assert Devices.format_number(0.04, 1, "en") == "0.0"
    end

    test "en: 0 decimals produces an integer string with no trailing separator" do
      # The W (watts) stat cards use `decimals: 0` so a 800 W reading
      # renders as "800" rather than "800.0" — visual noise, not
      # information. The thousands separator is preserved.
      assert Devices.format_number(0, 0, "en") == "0"
      assert Devices.format_number(800, 0, "en") == "800"
      # Use 1234.4 (not 1234.5) to avoid the half-up rounding boundary
      # — Erlang's `round/1` rounds 0.5 away from zero, so 1234.5
      # becomes 1235, not 1234. 1234.4 stays at 1234.
      assert Devices.format_number(1234.4, 0, "en") == "1,234"
      assert Devices.format_number(12_345, 0, "en") == "12,345"
    end

    test "de: dot as thousands separator, comma as decimal" do
      # German format: 1.234,5
      assert Devices.format_number(0.0, 1, "de") == "0,0"
      assert Devices.format_number(12.3, 1, "de") == "12,3"
      assert Devices.format_number(1234.5, 1, "de") == "1.234,5"
      assert Devices.format_number(1_234_567.89, 2, "de") == "1.234.567,89"
    end

    test "de: 0 decimals uses dot separator, no decimal separator" do
      assert Devices.format_number(0, 0, "de") == "0"
      assert Devices.format_number(800, 0, "de") == "800"
      assert Devices.format_number(1234.4, 0, "de") == "1.234"
      assert Devices.format_number(12_345, 0, "de") == "12.345"
    end

    test "fr: non-breaking space (U+00A0) as thousands separator, comma as decimal" do
      # French typography (DIN 5008 / AFNOR): non-breaking space so
      # line breaks don't split the digits. Visible chars: 1 234,5.
      thousand_sep = "\u00A0"

      assert Devices.format_number(0.0, 1, "fr") == "0,0"
      assert Devices.format_number(12.3, 1, "fr") == "12,3"
      assert Devices.format_number(1234.5, 1, "fr") == "1#{thousand_sep}234,5"

      assert Devices.format_number(1_234_567.89, 2, "fr") ==
               "1#{thousand_sep}234#{thousand_sep}567,89"
    end

    test "fr: 0 decimals uses NBSP separator" do
      thousand_sep = "\u00A0"
      assert Devices.format_number(1234.4, 0, "fr") == "1#{thousand_sep}234"
      assert Devices.format_number(12_345, 0, "fr") == "12#{thousand_sep}345"
    end

    test "unknown locale falls back to en" do
      # A stale Gettext backend (e.g. a new language without a project-
      # side translation yet) must still produce a readable, machine-
      # parseable number rather than `?` or empty string.
      assert Devices.format_number(1234.5, 1, "es") == "1,234.5"
      assert Devices.format_number(1234.5, 1, "") == "1,234.5"
    end

    test "negative values render with a leading minus" do
      # Power is unsigned in practice, but the helper is generic over
      # `number()` so it must handle negatives. The minus goes BEFORE
      # the formatted whole (not after the sign of the decimal part),
      # which matches how every locale prints negative numbers. Use
      # -1234.7 (not -1234.5) so the half-up rounding boundary doesn't
      # tip the expected value.
      assert Devices.format_number(-12.3, 1, "en") == "-12.3"
      assert Devices.format_number(-1234.4, 1, "de") == "-1.234,4"
      assert Devices.format_number(-1234.4, 0, "fr") == "-1\u00A0234"
    end

    test "nil renders the em-dash placeholder" do
      # Stable placeholder so the template doesn't need a conditional.
      assert Devices.format_number(nil, 1, "en") == "—"
      assert Devices.format_number(nil, 0, "de") == "—"
    end

    test "format_number/1 reads the current Gettext locale (en by default)" do
      # The dashboard-callable form, mirroring `format_savings/1`.
      # The test process is set to en by default, so the comma/dot
      # convention must be applied.
      assert Devices.format_number(1234.5) == "1,234.5"
    end

    test "format_number/2 with explicit decimals reads the current Gettext locale" do
      # 1234.4 (not 1234.5) to avoid half-up rounding.
      assert Devices.format_number(1234.4, 0) == "1,234"
      assert Devices.format_number(1234.567, 2) == "1,234.57"
    end
  end

  describe "get_consumption_daily_stats/2 — current_consumption" do
    # `current_consumption` is the latest fresh reading's `consumption_power`
    # summed across the user's Shelly devices, freshness = 2 minutes.
    #
    # The early-cut used `distinct: true` (full-row dedup) instead of
    # `distinct: [r.dtu_id]` (DISTINCT ON dtu_id). Since every uplink
    # writes a row with a fresh `(consumption_power, inserted_at)` tuple,
    # no two rows were duplicates — the query returned every recent row,
    # and `Enum.sum/1` added them all up. A Shelly publishing every 5–10s
    # meant the dashboard rendered ~7× the true value (e.g. 530 W on the
    # dashboard vs 76 W on the Shelly app). The regression test below
    # pins the corrected behavior: exactly the latest reading per device.

    test "returns 0 when the user has no DTUs" do
      user = DtuApp.AccountsFixtures.user_fixture()
      stats = Devices.get_consumption_daily_stats(user)
      assert stats.current_consumption == 0.0
      assert stats.today_consumption == 0.0
      assert stats.peak_consumption == 0.0
    end

    test "current_consumption is the latest fresh reading per device (not the sum across uplinks)" do
      user = DtuApp.AccountsFixtures.user_fixture()

      device =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      now = DateTime.utc_now()

      # Seven uplinks spread across the last 70 s, all reading 100 W.
      # Pre-fix the dashboard summed all seven into `current_consumption: 700 W`.
      # Post-fix (distinct on dtu_id) the latest wins — 100 W.
      # We give each row a unique microsecond offset so the composite PK
      # doesn't collide with the bump_on_pk_collision retry budget.
      for {offset, idx} <- Enum.with_index([70, 60, 50, 40, 30, 20, 10]) do
        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: device.id,
            inverter_serial: "em:0",
            mppt_index: 0,
            power_type: "consumption",
            consumption_power: 100.0,
            # Distinct microsecond offsets per row — microseconds beyond
            # second-precision are guaranteed unique per idx.
            inserted_at: DateTime.add(now, -(offset * 1_000_000 + idx * 1), :microsecond)
          })
      end

      # Plus one fresher reading at 5 s with the real 76 W — this is
      # the one that should win.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "em:0",
          mppt_index: 0,
          power_type: "consumption",
          consumption_power: 76.0,
          inserted_at: DateTime.add(now, -5, :second)
        })

      stats = Devices.get_consumption_daily_stats(user)

      # Regression: would have been 76 + 100×7 = 776 W pre-fix.
      assert_in_delta stats.current_consumption, 76.0, 0.1
    end

    test "current_consumption sums across multiple Shelly devices" do
      user = DtuApp.AccountsFixtures.user_fixture()

      dtu1 =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em-1"
        })

      dtu2 =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em-2"
        })

      now = DateTime.utc_now()

      for {dtu, watts} <- [{dtu1, 200.0}, {dtu2, 350.0}] do
        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: dtu.id,
            inverter_serial: "em:0",
            mppt_index: 0,
            power_type: "consumption",
            consumption_power: watts,
            inserted_at: now
          })
      end

      stats = Devices.get_consumption_daily_stats(user)
      assert_in_delta stats.current_consumption, 550.0, 0.1
    end

    test "current_consumption only includes fresh readings (within 2 minutes)" do
      user = DtuApp.AccountsFixtures.user_fixture()

      device =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      now = DateTime.utc_now()

      # 800 W — too old (3 minutes), excluded from current_consumption.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "em:0",
          mppt_index: 0,
          power_type: "consumption",
          consumption_power: 800.0,
          inserted_at: DateTime.add(now, -180, :second)
        })

      # 100 W — fresh, should win.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "em:0",
          mppt_index: 0,
          power_type: "consumption",
          consumption_power: 100.0,
          inserted_at: DateTime.add(now, -30, :second)
        })

      stats = Devices.get_consumption_daily_stats(user)
      assert_in_delta stats.current_consumption, 100.0, 0.1
    end

    test "production rows are excluded from current_consumption" do
      # OpenDTU / AhoyDTU rows have power_type = "production" — they must
      # not contaminate the Shelly consumption sum. Pins the power_type
      # filter in the helper so a future schema change doesn't drop it.
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)
      now = DateTime.utc_now()

      # 999 W production row — must be filtered out.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "INV-1",
          mppt_index: 0,
          power_type: "production",
          ac_power: 999.0,
          inserted_at: now
        })

      # 42 W consumption row — should be the only contributor.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "em:0",
          mppt_index: 0,
          power_type: "consumption",
          consumption_power: 42.0,
          inserted_at: now
        })

      stats = Devices.get_consumption_daily_stats(user)
      assert_in_delta stats.current_consumption, 42.0, 0.1
    end
  end

  describe "get_consumption_period_stats/4 — period-aware consumption stats" do
    # Mirrors `compute_day_period_stats/2` and `compute_range_period_stats/2`
    # for the consumption side. The dashboard renders three new cards
    # (Current / Today's / Peak, or Total / Peak / Peak-day for historical
    # views) when a Shelly is paired. The shape is period-aware so the
    # same render function can pick the right field per view.
    #
    # Tests below pin the corner cases the LiveView cares about: the
    # today view derives everything from `get_consumption_daily_stats/2`,
    # the day view is a one-day window over consumption_energy_total
    # deltas, and the week/month/year views aggregate the daily deltas.

    test "returns all zeros when the user has no DTUs" do
      user = DtuApp.AccountsFixtures.user_fixture()
      stats = Devices.get_consumption_period_stats(user, nil, "today", nil)
      assert stats.current_consumption == 0.0
      assert stats.today_consumption == 0.0
      assert stats.peak_consumption == 0.0
      assert stats.period_total_consumption == 0.0
      assert stats.period_peak_consumption == 0.0
      assert stats.peak_date == nil
    end

    test "today view mirrors get_consumption_daily_stats/2 (current/today/peak)" do
      user = DtuApp.AccountsFixtures.user_fixture()

      device =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      now = DateTime.utc_now()

      # Fresh reading — wins current_consumption. We insert this FIRST
      # so the bumped-on-collision path isn't triggered; the older
      # reading below is then placed in a *different* 5-min bucket so
      # the bucket-max-vs-live-current comparison picks the older one.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "em:0",
          mppt_index: 0,
          power_type: "consumption",
          consumption_power: 76.0,
          consumption_energy_total: 1_234_567.0,
          inserted_at: now
        })

      # An older reading — 10 minutes back so it falls in its own
      # 5-min bucket from the fresh reading. This bucket's mean is just
      # 200 W (it's the only reading in that bucket), so the chart's
      # `bucket_max = 200`, exceeding the live `current_consumption = 76`.
      # `peak_consumption = max(76, 200) = 200`.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "em:0",
          mppt_index: 0,
          power_type: "consumption",
          consumption_power: 200.0,
          consumption_energy_total: 1_232_000.0,
          inserted_at: DateTime.add(now, -600, :second)
        })

      stats = Devices.get_consumption_period_stats(user, device.id, "today", nil)

      assert_in_delta stats.current_consumption, 76.0, 0.1

      # today_consumption: latest_total - earliest_total = 1_234_567 - 1_232_000 = 2567 Wh = 2.567 kWh ≈ 2.6 kWh
      assert_in_delta stats.today_consumption, 2.6, 0.1
      # Peak across today's buckets (200 W from the older reading).
      assert_in_delta stats.peak_consumption, 200.0, 0.1
      # The mirror fields also carry the same values.
      assert_in_delta stats.period_total_consumption, 2.6, 0.1
      assert_in_delta stats.period_peak_consumption, 200.0, 0.1
      assert stats.peak_date == Date.utc_today()
    end

    test "day view with explicit selected_period computes the day-local totals" do
      # Pins the day view's "Total Consumption" card: a closed-day window
      # for the lifetime-counter delta. Reading the counter at midnight
      # and again at 23:59 should produce ~24 kWh consumed.
      user = DtuApp.AccountsFixtures.user_fixture()

      device =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      target_date = ~D[2026-07-15]

      # 5 kWh consumed over the day: 12_345_678 Wh at start of day,
      # 12_370_678 Wh at end of day.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "em:0",
          mppt_index: 0,
          power_type: "consumption",
          consumption_power: 250.0,
          consumption_energy_total: 12_345_678.0,
          inserted_at: DateTime.new!(target_date, ~T[00:01:00])
        })

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "em:0",
          mppt_index: 0,
          power_type: "consumption",
          consumption_power: 300.0,
          consumption_energy_total: 12_370_678.0,
          inserted_at: DateTime.new!(target_date, ~T[23:30:00])
        })

      stats = Devices.get_consumption_period_stats(user, device.id, "day", target_date)

      # 12_370_678 - 12_345_678 = 25_000 Wh = 25.0 kWh
      assert_in_delta stats.period_total_consumption, 25.0, 0.1
      # Peak across the day's consumption points — both are fresh, so
      # the higher (300 W) wins.
      assert_in_delta stats.period_peak_consumption, 300.0, 0.1
      assert stats.peak_date == target_date
    end

    test "week view computes period_total across multiple days via lifetime-counter deltas" do
      # Three days of readings: each day has its own first/last
      # consumption_energy_total, and the period_total sums the
      # per-day deltas.
      user = DtuApp.AccountsFixtures.user_fixture()

      device =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      # Week starts Monday 2026-07-13, ends Sunday 2026-07-19.
      week_start = ~D[2026-07-13]
      week_end = ~D[2026-07-19]

      # Each day: morning reading (low counter) + evening reading
      # (higher counter). The deltas across the week sum to (3000 +
      # 4000 + 5000) Wh = 12.0 kWh.
      for {date, morning, evening} <- [
            {~D[2026-07-13], 1_000_000.0, 1_003_000.0},
            {~D[2026-07-15], 2_000_000.0, 2_004_000.0},
            {~D[2026-07-17], 3_000_000.0, 3_005_000.0}
          ] do
        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: device.id,
            inverter_serial: "em:0",
            mppt_index: 0,
            power_type: "consumption",
            consumption_power: 100.0,
            consumption_energy_total: morning,
            inserted_at: DateTime.new!(date, ~T[06:00:00])
          })

        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: device.id,
            inverter_serial: "em:0",
            mppt_index: 0,
            power_type: "consumption",
            consumption_power: 150.0,
            consumption_energy_total: evening,
            inserted_at: DateTime.new!(date, ~T[18:00:00])
          })
      end

      stats =
        Devices.get_consumption_period_stats(user, device.id, "week", week_start)

      # 3000 + 4000 + 5000 = 12_000 Wh = 12.0 kWh
      assert_in_delta stats.period_total_consumption, 12.0, 0.1
      # peak_per_day: 2026-07-15 was 150 W (highest single reading across
      # the week).
      assert_in_delta stats.period_peak_consumption, 150.0, 0.1
      assert stats.peak_date == ~D[2026-07-15]
    end

    test "production rows are excluded from the period totals" do
      # Even if a device's consumption logs are contaminated by a stray
      # production row (e.g. a Shelly publishing on the same topic as
      # an OpenDTU), the helper must filter to power_type = "consumption".
      user = DtuApp.AccountsFixtures.user_fixture()

      device =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      now = DateTime.utc_now()
      today = Date.utc_today()

      # 9999 W production row (a rogue emission that would skew the
      # current/today/peak sums by ~10× if not filtered). Distinct
      # microsecond offset so it doesn't collide with the next row's PK.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "em:0",
          mppt_index: 0,
          power_type: "production",
          ac_power: 9999.0,
          inserted_at: DateTime.add(now, -10, :second)
        })

      # 76 W consumption reading.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "em:0",
          mppt_index: 0,
          power_type: "consumption",
          consumption_power: 76.0,
          consumption_energy_total: 1_000.0,
          inserted_at: now
        })

      stats = Devices.get_consumption_period_stats(user, device.id, "today", nil)

      # 76 W (the production 9999 W is filtered out).
      assert_in_delta stats.current_consumption, 76.0, 0.1
      # Peak is also from the consumption row.
      assert_in_delta stats.peak_consumption, 76.0, 0.1
      # peak_date stays at today.
      assert stats.peak_date == today
    end
  end
end
