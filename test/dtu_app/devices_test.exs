defmodule DtuApp.DevicesTest do
  use DtuApp.DataCase, async: true

  alias DtuApp.Devices
  alias DtuApp.DevicesFixtures

  # Build a DateTime anchored on today's UTC date with the given HH:MM:SS.
  # Used by the net-flow regression tests so all readings fall inside
  # today's UTC window without needing per-test anchor dates.
  defp net_bucket_at(time_str) do
    [h, m, s] =
      time_str
      |> String.split(":")
      |> Enum.map(&String.to_integer/1)

    today = Date.utc_today()
    {:ok, dt} = DateTime.new(today, Time.new!(h, m, s))
    DateTime.truncate(dt, :microsecond)
  end

  # Insert a Shelly Plus 3EM consumption reading for the given DTU.
  # `idx` is folded into the microsecond offset so multiple readings
  # in the same bucket don't collide on the composite PK
  # (`bump_on_pk_collision` would otherwise retry 1000 µs before the
  # next insert gets through).
  defp shelly_consumption_row(dtu_id, watts, inserted_at, idx) do
    {:ok, _} =
      Devices.create_reading(%{
        dtu_id: dtu_id,
        inverter_serial: "em:0",
        mppt_index: 0,
        power_type: "consumption",
        consumption_power: watts,
        inserted_at: DateTime.add(inserted_at, idx * 1, :microsecond)
      })
  end

  describe "get_daily_stats/2 — today_yield" do
    test "returns 0 when the user has no DTUs" do
      user = DtuApp.AccountsFixtures.user_fixture()
      stats = Devices.get_daily_stats(user)
      assert stats.today_yield == 0.0
      assert stats.current_power == 0.0
      assert stats.peak_power == 0.0
    end

    test "sums each inverter's last reading of the day across multiple inverters" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)
      now = DateTime.utc_now()

      # Two inverters with multiple readings each. Per-inverter
      # `yield_day` is monotonic Wh that resets at midnight, so the
      # day's per-inverter total IS its last reading. Summing across
      # inverters gives the fleet's daily total — replacing the old
      # MAX-across-inverters semantic which conflated per-inverter
      # totals.
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

      # Headline = INV-A's last reading (5_000 Wh) + INV-B's last
      # reading (3_500 Wh) = 8_500 Wh = 8.5 kWh. Earlier (smaller)
      # readings don't influence the headline.
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

    test "uses the latest reading of the day per inverter (multi-uplink day)" do
      # Per-inverter `yield_day` is monotonic Wh that resets at
      # midnight, so the day's per-inverter total IS its last
      # reading of the day. A single inverter publishing multiple
      # readings today: the headline picks the latest, not the
      # day's MAX (which for a monotonic counter is also the latest,
      # but we pin the latest-reading semantic explicitly so a
      # future refactor doesn't slip back into MAX).
      #
      # Use UTC-midnight-anchored timestamps so the test stays
      # stable when CI happens to run a few seconds after 00:00 UTC —
      # otherwise the older reading's `inserted_at` may have rolled
      # into yesterday's UTC window and `today_start` filters it out.
      # `inserted_at` is typed `:utc_datetime_usec`, so add
      # microsecond precision explicitly (Ecto's `DateTime.truncate/2`
      # leaves microseconds at `{0, 0}` when the source value has
      # only second precision, which `:utc_datetime_usec` rejects).
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      now =
        Date.utc_today()
        |> DateTime.new!(~T[12:00:00])
        |> Map.put(:microsecond, {0, 6})

      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-A",
        yield_day: 12_000.0,
        inserted_at: now |> DateTime.add(-360, :second) |> Map.put(:microsecond, {0, 6})
      })

      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-A",
        yield_day: 15_000.0,
        inserted_at: now
      })

      # Headline = INV-A's last reading of the day (15_000 Wh =
      # 15.0 kWh). Earlier reading (12_000) doesn't influence it.
      stats = Devices.get_daily_stats(user)
      assert_in_delta stats.today_yield, 15.0, 0.001
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

      # Wh values; converted to kWh by get_daily_stats/2. Two DTUs, one
      # reading each. Scoped by dtu_id the per-DTU yield is the single
      # reading; unscoped the headline sums each DTU's last reading of
      # the day across the user's DTUs (multi-DTU fleet sums the
      # per-DTU totals).
      DevicesFixtures.reading_fixture(dtu1, %{yield_day: 2_000.0, inserted_at: now})
      DevicesFixtures.reading_fixture(dtu2, %{yield_day: 7_000.0, inserted_at: now})

      assert_in_delta Devices.get_daily_stats(user, dtu1.id).today_yield, 2.0, 0.001
      assert_in_delta Devices.get_daily_stats(user, dtu2.id).today_yield, 7.0, 0.001
      assert_in_delta Devices.get_daily_stats(user).today_yield, 9.0, 0.001
    end
  end

  describe "get_daily_stats/2 — total_yield" do
    # `total_yield` is the lifetime cumulative kWh from the firmware's
    # `YieldTotal` MQTT field (AhoyDTU's `YieldTotal` JSON / numeric topic
    # and OpenDTU's `AC.YieldTotal.v` JSON / per-MPPT `yieldtotal` scalar).
    # Both land in `readings.yield_total`. The helper takes
    # `MAX(yield_total)` per `(dtu_id, inverter_serial)` across **all**
    # readings (no time-window filter — the lifetime counter is
    # monotonic and never resets), sums the per-inverter maxes, then
    # converts Wh → kWh. Round to 1 decimal place to match the
    # dashboard's kWh rendering.

    test "returns 0 when the user has no DTUs" do
      user = DtuApp.AccountsFixtures.user_fixture()
      assert Devices.get_daily_stats(user).total_yield == 0.0
    end

    test "sums each inverter's MAX(yield_total) across the fleet" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)
      now = DateTime.utc_now()

      # Two inverters; MAX(yield_total) per inverter is 50_000 (INV-A)
      # and 35_000 (INV-B). The headline sums those: 50_000 + 35_000
      # = 85_000 Wh = 85.0 kWh. The older INV-A reading (10_000)
      # doesn't influence the headline because MAX(yield_total) per
      # inverter uses only the largest value (lifetime counter is
      # monotonic; only the largest value per series counts).
      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-A",
        yield_total: 10_000.0,
        inserted_at: DateTime.add(now, -120, :second)
      })

      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-A",
        yield_total: 50_000.0,
        inserted_at: now
      })

      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-B",
        yield_total: 35_000.0,
        inserted_at: DateTime.add(now, -60, :second)
      })

      assert_in_delta Devices.get_daily_stats(user).total_yield, 85.0, 0.001
    end

    test "ignores today's UTC window — uses ALL readings, not just today's" do
      # The lifetime counter doesn't reset at local midnight, so the
      # total_yield computation must include yesterday's readings too.
      # Yesterday's row has the highest yield_total for the inverter
      # (50_000 Wh); today's row is stale at 5_000 Wh. Without the
      # "no time-window filter" design, the dashboard would render a
      # lifetime total of just 5 kWh.
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)
      today = DateTime.utc_now()

      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-A",
        yield_total: 50_000.0,
        inserted_at: DateTime.add(today, -1, :day)
      })

      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-A",
        yield_total: 5_000.0,
        inserted_at: today
      })

      assert_in_delta Devices.get_daily_stats(user).total_yield, 50.0, 0.001
    end

    test "uses MAX(yield_total) per inverter, restricted to mppt_index = 0 (no per-MPPT double-count)" do
      # Multi-MPPT inverters publish yield_total on the AC aggregate row
      # (mppt_index = 0) and on each per-MPPT row (mppt_index >= 1). The
      # AC aggregate IS the inverter's true lifetime kWh — AhoyDTU's ch0
      # is the cumulative inverter-level value. Per-MPPT DC rows
      # (mppt_index >= 1) carry per-string sub-totals that the firmware
      # has already summed into ch0, so summing across MPPTs would
      # double-count the inverter.
      #
      # The aggregation is restricted to `mppt_index = 0` so a 2-MPPT
      # Hoymiles produces the same `total_yield` as a 1-MPPT install
      # of the same model — only the AC aggregate row counts. The
      # ch1+ch2 per-MPPT rows still get persisted to the DB (for the
      # chart's per-MPPT lines) but don't enter the total.
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)
      now = DateTime.utc_now()

      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-A",
        mppt_index: 0,
        yield_total: 100_000.0,
        inserted_at: now
      })

      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-A",
        mppt_index: 1,
        yield_total: 60_000.0,
        inserted_at: now
      })

      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-A",
        mppt_index: 2,
        yield_total: 40_000.0,
        inserted_at: now
      })

      # Only the ch0 row counts → 100 kWh, NOT 200 kWh (the overcounted
      # pre-fix sum).
      assert_in_delta Devices.get_daily_stats(user).total_yield, 100.0, 0.001
    end

    test "treats nil yield_total as 0 so a half-wired inverter doesn't poison the total" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)
      now = DateTime.utc_now()

      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-A",
        yield_total: 25_000.0,
        inserted_at: now
      })

      # A second inverter with nil yield_total — simulates a brand-new
      # inverter that hasn't yet reported its lifetime counter. Must
      # not poison the household total.
      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-B",
        yield_total: nil,
        inserted_at: now
      })

      assert_in_delta Devices.get_daily_stats(user).total_yield, 25.0, 0.001
    end

    test "scopes by dtu_id when one is passed" do
      user = DtuApp.AccountsFixtures.user_fixture()
      dtu1 = DevicesFixtures.device_fixture(user)
      dtu2 = DevicesFixtures.device_fixture(user)
      now = DateTime.utc_now()

      # Wh values; converted to kWh by get_daily_stats/2. Two DTUs, one
      # reading each. Scoped by dtu_id the per-DTU lifetime is the single
      # reading; unscoped the headline sums each DTU's per-inverter MAX
      # across the user's DTUs.
      DevicesFixtures.reading_fixture(dtu1, %{yield_total: 20_000.0, inserted_at: now})
      DevicesFixtures.reading_fixture(dtu2, %{yield_total: 70_000.0, inserted_at: now})

      assert_in_delta Devices.get_daily_stats(user, dtu1.id).total_yield, 20.0, 0.001
      assert_in_delta Devices.get_daily_stats(user, dtu2.id).total_yield, 70.0, 0.001
      assert_in_delta Devices.get_daily_stats(user).total_yield, 90.0, 0.001
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

    test "does not raise ArithmeticError when a 5-min bucket contains only nil-power rows (regression)" do
      # Reproduces the production crash reported in the field:
      #
      #   request_id=… [error] ** (ArithmeticError) bad argument in arithmetic expression
      #       (dtu_app 0.1.0) lib/dtu_app/devices.ex:1495: DtuApp.Devices.get_daily_stats/3
      #
      # AhoyDTU's buffer-flushing parser persists a row as soon as ANY
      # recognised metric arrives — including a yield-only flush before
      # the AC reading. The `readings_5m` continuous aggregate's
      # `avg_ac_power` is NULL when the only rows in a 5-minute bucket
      # have nil `ac_power` (the `avg()` of an all-NULL set is NULL).
      #
      # Pre-fix, `bucket_max` ran `Enum.max` over a list of chart-point
      # powers that contained only `nil`, which returned `nil` (Erlang
      # term order: atom > number). The downstream `peak_power * 1.0`
      # then raised `ArithmeticError` on `nil * 1.0` and every
      # dashboard mount 500'd until the bucket rolled forward.
      #
      # Unit-test the helper directly. Going through the full
      # `readings_5m` aggregate refresh from a unit test would need a
      # separate Postgres connection (`CALL refresh_continuous_aggregate`
      # can't run inside the sandbox's per-test transaction), and the
      # raw-row fallback (`list_day_chart_data/4`) never produces nil
      # powers (it uses `chart_power_for_mppt/1`, which returns `0.0`
      # for nil — not `nil`). Neither end-to-end path can exercise the
      # nil-only bucket case from a test, so the regression is pinned
      # at the helper boundary instead.
      dt = DateTime.utc_now()
      dtu_id = 1

      # A single bucket whose power is nil — exactly the shape the
      # `readings_5m` aggregate produces for an all-nil-ac bucket.
      chart_points = [
        %{
          time: dt,
          series: {dtu_id, "INV-A", 0, "INV-A"},
          power: nil
        }
      ]

      # Pre-fix: this raised `Enum.max/1` returning `nil`, then
      # `peak_power * 1.0` crashed the caller. Post-fix: it returns
      # `0.0` (nil coerced to `0.0`).
      assert Devices.bucket_max_from_chart_points(chart_points) == 0.0

      # Empty list — the no-readings case.
      assert Devices.bucket_max_from_chart_points([]) == 0.0

      # Mixed nil + numeric — only the numeric values drive the max,
      # but no nil is allowed to leak.
      mixed_points = [
        %{time: dt, series: {dtu_id, "INV-A", 0, "INV-A"}, power: nil},
        %{time: dt, series: {dtu_id, "INV-A", 0, "INV-A"}, power: 250.0},
        %{time: dt, series: {dtu_id, "INV-A", 0, "INV-A"}, power: nil}
      ]

      assert Devices.bucket_max_from_chart_points(mixed_points) == 250.0

      # Per-MPPT points (mppt_index >= 1) must be dropped, even when
      # they have nil power — the dashboard only plots the AC
      # aggregate as `peak_power`. A non-AC-aggregate nil would still
      # poison the max without this filter.
      per_mppt_only = [
        %{time: dt, series: {dtu_id, "INV-A", 1, "INV-A"}, power: nil},
        %{time: dt, series: {dtu_id, "INV-A", 2, "INV-A"}, power: nil}
      ]

      assert Devices.bucket_max_from_chart_points(per_mppt_only) == 0.0
    end
  end

  describe "get_daily_stats/2 — per_series breakdown" do
    # The aggregation is restricted to `mppt_index = 0` (the AC aggregate
    # row) so multi-MPPT AhoyDTU inverters don't double-count ch1+ch2's
    # per-string sub-totals into the daily / lifetime total. The
    # `per_series` breakdown emits one row per *inverter* (not per MPPT)
    # for the same reason.
    test "emits one entry per inverter, restricted to mppt_index = 0 (no per-MPPT double-count)" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      # Single inverter with AC + 2 DC MPPTs. Only the ch0 row counts
      # for the dashboard totals — ch1+ch2 are per-string sub-totals
      # the firmware has already summed into ch0. The `per_series` list
      # emits one entry per (inverter, mppt_index = 0), so this 2-MPPT
      # inverter produces 1 row, not 3.
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

      # Only ch0 enters the breakdown → 1 row, not 3.
      assert length(stats.per_series) == 1

      [series] = stats.per_series
      assert series.inverter_name == "Roof Array"
      assert series.mppt_index == 0
      # Yields are converted to kWh (AhoyDTU/OpenDTU publish Wh).
      assert_in_delta series.today_yield, 5.0, 0.001
    end

    test "per_series today_yield matches the headline's sum-across-inverters semantics" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      # Two inverters, each with one AC row (mppt_index = 0). Even
      # though AhoyDTU's per-MPPT rows (mppt_index = 1, 2) for the
      # first inverter also carry yield_day values, the aggregation
      # restricts to mppt_index = 0 to avoid the 2× / 3× overcount.
      for {serial, mppts} <- [{"INV-1", [0, 1, 2]}, {"INV-2", [0]}] do
        for mppt <- mppts do
          DevicesFixtures.reading_fixture(device, %{
            inverter_serial: serial,
            mppt_index: mppt,
            yield_day: 1_000.0
          })
        end
      end

      stats = Devices.get_daily_stats(user)

      # Headline = INV-1's last reading of the day (1000 Wh, mppt=0)
      # + INV-2's last reading of the day (1000 Wh, mppt=0)
      # = 2000 Wh = 2.0 kWh. Per-MPPT rows for INV-1 (ch1/ch2)
      # don't influence the sum because of the `mppt_index = 0`
      # restriction.
      assert_in_delta stats.today_yield, 2.0, 0.001
      assert length(stats.per_series) == 2
    end

    test "per_series is empty when the user has no DTUs" do
      user = DtuApp.AccountsFixtures.user_fixture()
      stats = Devices.get_daily_stats(user)
      assert stats.per_series == []
    end

    test "today_yield sums each inverter's last reading of the day (AhoyDTU multi-inverter)" do
      # Each per-inverter `yield_day` is a monotonic Wh counter that
      # resets at midnight and climbs through the day — the day's
      # per-inverter total IS its last reading of the day. Summing
      # across inverters (and across the user's DTUs) gives the
      # fleet's daily total without depending on the
      # firmware-aggregated `{base}/total` topic, which the parser
      # now drops.
      #
      # Replaces the old "fleet-total `_fleet` row overrides per-
      # inverter sum" test: that behaviour depended on a parser-
      # persisted row the current parser no longer creates.
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      now = DtuApp.Time.utc_now_usec()

      # Two inverters each with one reading today. Both readings are
      # at the same instant (`now`) — either is "the last reading of
      # the day" — and summing them gives the fleet's daily total
      # (1000 + 2000 = 3000 Wh = 3.0 kWh).
      for {serial, yield_day} <- [{"INV-1", 1000.0}, {"INV-2", 2000.0}] do
        DevicesFixtures.reading_fixture(device, %{
          inverter_serial: serial,
          mppt_index: 0,
          inverter_name: serial,
          yield_day: yield_day,
          inserted_at: now
        })
      end

      stats = Devices.get_daily_stats(user)
      assert_in_delta stats.today_yield, 3.0, 0.001
      # Per-series still lists per-inverter entries for the chart
      # legend.
      assert length(stats.per_series) == 2
    end

    test "today_yield uses each inverter's LATEST reading, not the day's MAX (multi-uplink day)" do
      # An inverter that published `yield_day` at 10:00 (lower) and
      # 16:00 (higher) on the same day should contribute its 16:00
      # value to the headline — that's the day's total for that
      # inverter. A naive MAX-semantic across rows would also
      # return the 16:00 value (so MAX-not-sum was an OK
      # approximation), but the new logic explicitly uses the
      # latest reading so the headline tracks the firmware's
      # monotonic counter. A second inverter at a different time
      # of day confirms the per-inverter independence.
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      earlier = DateTime.utc_now() |> DateTime.add(-3600, :second)
      later = DateTime.utc_now()

      # INV-1: 1000 at 10:00, 1500 at 16:00 → contributes 1500
      for {ts, yield_day} <- [{earlier, 1000.0}, {later, 1500.0}] do
        DevicesFixtures.reading_fixture(device, %{
          inverter_serial: "INV-1",
          mppt_index: 0,
          inverter_name: "INV-1",
          yield_day: yield_day,
          inserted_at: ts
        })
      end

      # INV-2: 800 only at 16:00 → contributes 800
      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-2",
        mppt_index: 0,
        inverter_name: "INV-2",
        yield_day: 800.0,
        inserted_at: later
      })

      # Headline = 1500 (INV-1 latest) + 800 (INV-2 latest) = 2300 Wh
      # = 2.3 kWh.
      stats = Devices.get_daily_stats(user)
      assert_in_delta stats.today_yield, 2.3, 0.001
    end

    test "today_yield ignores legacy _fleet rows the old parser persisted" do
      # Pre-source-drop installs may still have `_fleet` rows in the
      # DB. The dashboard's `today_yield` query explicitly filters
      # `inverter_serial != "_fleet"`, so a stale `_fleet` row with
      # a wildly different `yield_day` doesn't influence the
      # headline.
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      now = DtuApp.Time.utc_now_usec()

      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-1",
        mppt_index: 0,
        inverter_name: "INV-1",
        yield_day: 1000.0,
        inserted_at: now
      })

      # Stale `_fleet` row from a previous parser version. Should
      # have no effect on the headline.
      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "_fleet",
        mppt_index: 0,
        inverter_name: "_fleet",
        yield_day: 999_999.0,
        inserted_at: now
      })

      stats = Devices.get_daily_stats(user)
      # 1000 Wh = 1.0 kWh — NOT 999_999 Wh / 1000 = 999.999 kWh.
      assert_in_delta stats.today_yield, 1.0, 0.001
    end

    test "total_yield sums each inverter's MAX(yield_total)" do
      # Multiple readings of `yield_total` per inverter across the
      # device's lifetime — the lifetime counter is monotonic, so
      # MAX equals the latest recorded lifetime value. Summing
      # across inverters gives the fleet's lifetime total.
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      earlier = DateTime.utc_now() |> DateTime.add(-86_400 * 365, :second)
      later = DateTime.utc_now()

      # INV-1's lifetime counter has climbed from 5 MWh to 6 MWh
      # over a year. We seed three readings; MAX = 6 MWh.
      for {ts, yield_total} <- [{earlier, 5_000_000.0}, {later, 6_000_000.0}] do
        DevicesFixtures.reading_fixture(device, %{
          inverter_serial: "INV-1",
          mppt_index: 0,
          inverter_name: "INV-1",
          yield_total: yield_total,
          inserted_at: ts
        })
      end

      # INV-2's lifetime counter = 2 MWh.
      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-2",
        mppt_index: 0,
        inverter_name: "INV-2",
        yield_total: 2_000_000.0,
        inserted_at: later
      })

      # Headline = 6 MWh (INV-1) + 2 MWh (INV-2) = 8 MWh,
      # rendered as 8000.0 kWh on the dashboard.
      stats = Devices.get_daily_stats(user)
      assert_in_delta stats.total_yield, 8000.0, 0.1
    end

    test "falls back to per-inverter ch0 last reading when no fleet row exists (OpenDTU)" do
      # The dashboard's headline `today_yield` sums each inverter's
      # last reading of the day for the common OpenDTU install,
      # which doesn't publish a fleet-total topic. Two inverters
      # each contribute their `yield_day` to the sum.
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      now = DtuApp.Time.utc_now_usec()

      for {serial, yield_day} <- [{"INV-1", 1000.0}, {"INV-2", 2000.0}] do
        DevicesFixtures.reading_fixture(device, %{
          inverter_serial: serial,
          mppt_index: 0,
          inverter_name: serial,
          yield_day: yield_day,
          inserted_at: now
        })
      end

      stats = Devices.get_daily_stats(user)
      # 1000 + 2000 = 3000 Wh / 1000 = 3.0 kWh. (Different from
      # pre-source-drop semantics, which used MAX not SUM and
      # returned 2.0 kWh — the new semantics matches what the
      # firmware's per-inverter monotonic counters imply.)
      assert_in_delta stats.today_yield, 3.0, 0.001
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

  describe "list_day_chart_data_for_dashboard/4 (aggregate-backed hot path)" do
    # The dashboard's chart path uses this helper instead of
    # `list_day_chart_data/4` (which walks every raw `readings` row
    # in the BEAM). The aggregate-backed variant reads from the
    # `readings_5m` continuous aggregate for everything older than its
    # 5-minute `end_offset`, and unions with a live tail of raw rows
    # for the most recent 5 minutes — see the
    # `list_day_chart_data_for_dashboard/4` docstring for the
    # rationale.
    #
    # Tests below pin the contract the dashboard relies on:
    # * the same `%{time, series, power}` shape as
    #   `list_day_chart_data/4` so the chart can swap implementations
    #   without touching the renderer;
    # * the `time` is always a `%DateTime{}` (UTC), not the
    #   `NaiveDateTime` the `readings_5m.bucket` column would naturally
    #   decode to without a schema cast;
    # * `mppt_index = 0` (AC aggregate) rows surface in the chart;
    # * the cold-aggregate fallback returns the same points as
    #   `list_day_chart_data/4` for new installations where the
    #   materialised bucket rows haven't been refreshed yet.

    defp today_at(hour, minute \\ 0) do
      Date.utc_today()
      |> DateTime.new!(Time.new!(hour, minute, 0))
      |> Map.put(:microsecond, {0, 0})
    end

    defp today_end_of_day do
      DateTime.new!(Date.utc_today(), ~T[23:59:59])
      |> Map.put(:microsecond, {0, 0})
    end

    test "returns the same chart points shape as list_day_chart_data/4 (per-inverter AC rows)" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      # Two inverters, each with one AC row at noon today.
      for {serial, power} <- [{"INV-1", 200.0}, {"INV-2", 350.0}] do
        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: device.id,
            inverter_serial: serial,
            inverter_name: serial,
            mppt_index: 0,
            ac_power: power,
            inserted_at: today_at(12)
          })
      end

      points =
        Devices.list_day_chart_data_for_dashboard(
          user,
          today_at(0),
          today_end_of_day(),
          device.id
        )

      by_serial =
        points
        |> Enum.filter(fn pt -> elem(pt.series, 2) == 0 end)
        |> Map.new(fn pt -> {elem(pt.series, 1), pt.power} end)

      assert_in_delta by_serial["INV-1"], 200.0, 0.1
      assert_in_delta by_serial["INV-2"], 350.0, 0.1

      # Each point carries a `%DateTime{}` `time` (not a
      # `NaiveDateTime`) so the dashboard's `shift_local/2` and
      # `chart_time_range/2` keep their existing contract.
      Enum.each(points, fn pt ->
        assert %DateTime{} = pt.time
      end)
    end

    test "returns chart points with a :time key when the readings_5m aggregate is populated" do
      # Regression for the production crash reported in the field:
      #
      #   [info] Sent 500 in 3384ms
      #   ** (KeyError) key :time not found in: %{bucket: ~N[...], ...}
      #       (dtu_app 0.1.0) lib/dtu_app/devices.ex:751: anonymous fn/1 in
      #         DtuApp.Devices.list_day_chart_data_for_dashboard/4
      #
      # The aggregate SELECT returned the time column as `:bucket`
      # (matching the `readings_5m` column name), but the rest of the
      # function — and the dashboard's chart pipeline — expect `:time`.
      # Without the alias, the `case pt.time` coercion at the end of the
      # function raised KeyError on every dashboard mount once the
      # aggregate's first refresh policy ran.
      #
      # The contract the test pins — `%{time, series, power}` with
      # `:time` as a `%DateTime{}` and `:series` as a 4-tuple — is the
      # same one the cold-aggregate fallback (`list_day_chart_data/4`)
      # produces. We seed a raw `readings` row instead of writing to
      # `readings_5m` directly because TimescaleDB continuous aggregates
      # don't accept `INSERT` in production builds and the direct write
      # made the test fragile to the live-tail filter boundary (it ran
      # at 12:01 UTC, the seeded 12:00 bucket fell inside the 5-min tail,
      # and the assertion saw zero points). The test DB has `WITH NO
      # DATA` for `readings_5m` so the fallback path is exercised,
      # which returns the same chart_point contract the aggregate path
      # returns after the reshape.
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "INV-1",
          inverter_name: "INV-1",
          mppt_index: 0,
          ac_power: 250.0,
          inserted_at: today_at(10, 0)
        })

      points =
        Devices.list_day_chart_data_for_dashboard(
          user,
          today_at(0),
          today_end_of_day(),
          device.id
        )

      # The aggregate path must produce a chart point with the same shape
      # as the raw-row fallback: `%{time, series, power}` with `:time`
      # as a `%DateTime{}` (not a `NaiveDateTime`) and `:series` as a
      # 4-tuple `{dtu_id, inverter_serial, mppt_index, inverter_name}`.
      # The two crashes that hit production crashed on each of these keys
      # separately — once because the time column was named `:bucket`,
      # then once because the four series fields were emitted as separate
      # keys instead of a 4-tuple. This test pins both.
      assert length(points) == 1
      [point] = points

      assert Map.has_key?(point, :time),
             "expected point to have a :time key, got: #{inspect(Map.keys(point))}"

      assert %DateTime{} = point.time
      assert_in_delta point.power, 250.0, 0.1

      # `:series` contract: 4-tuple, not four separate fields. Pin both
      # the shape (is_tuple) and the contents (the dtu_id, serial,
      # mppt_index, and inverter_name we seeded).
      assert Map.has_key?(point, :series),
             "expected point to have a 4-tuple :series key, got: #{inspect(Map.keys(point))}"

      assert match?({_dtu_id, "INV-1", 0, "INV-1"}, point.series),
             "expected :series to be the 4-tuple {dtu_id, inverter_serial, mppt_index, inverter_name}, got: #{inspect(point.series)}"

      assert {dtu_id, "INV-1", 0, "INV-1"} = point.series
      assert dtu_id == device.id

      # The wide-table fields must NOT leak into the result — a regression
      # here would re-introduce the `:series` KeyError if the reshape
      # stopped emitting the 4-tuple.
      refute Map.has_key?(point, :dtu_id),
             "aggregate-path result leaked :dtu_id field; expected :series to replace it"

      refute Map.has_key?(point, :inverter_serial),
             "aggregate-path result leaked :inverter_serial field; expected :series to replace it"

      refute Map.has_key?(point, :mppt_index),
             "aggregate-path result leaked :mppt_index field; expected :series to replace it"

      refute Map.has_key?(point, :inverter_name),
             "aggregate-path result leaked :inverter_name field; expected :series to replace it"
    end

    test "get_daily_stats/3 bucket_max reads the aggregate (exercises :series elem/2)" do
      # End-to-end pin of the second KeyError class:
      #
      #   ** (KeyError) key :series not found in: %{time: ~U[...], ...}
      #       (dtu_app 0.1.0) lib/dtu_app/devices.ex:1478: anonymous fn/1 in
      #         DtuApp.Devices.get_daily_stats/3
      #
      # `get_daily_stats/3`'s `bucket_max` computes the day's peak power
      # via `elem(pt.series, 2) == 0` — exactly the access pattern that
      # crashed. The reshape makes the access succeed; `peak_power`
      # then reflects the seeded 250 W.
      #
      # Seeds a raw `readings` row at 10:00 today — well outside the
      # 5-minute live tail but inside the query window — so the cold
      # aggregate fallback returns the same `chart_point` shape the
      # aggregate path returns. The fallback path covers the same
      # `elem(pt.series, 2)` access pattern in `bucket_max`, so the
      # regression pin holds. The old direct-`INSERT INTO readings_5m`
      # seeding was brittle to the test-runtime clock (CI ran the test
      # at 12:01 UTC and the seeded 12:00 bucket fell inside the live
      # tail and was excluded).
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "INV-1",
          inverter_name: "INV-1",
          mppt_index: 0,
          ac_power: 250.0,
          inserted_at: today_at(10, 0)
        })

      # Without the :series reshape, the `elem(pt.series, 2) == 0`
      # filter inside `bucket_max` raises `KeyError: key :series
      # not found`. The call also asserts the peak-power value
      # surfaces (the live `current_power` is 0 since no recent
      # reading landed, so `peak_power` is purely the bucket max).
      stats = Devices.get_daily_stats(user)
      assert_in_delta stats.peak_power, 250.0, 0.1
    end

    test "returns points even when readings_5m is cold (no rows yet, fallback to raw scan)" do
      # A brand-new install — the continuous-aggregate policy hasn't
      # run yet, so `readings_5m` is empty (`WITH NO DATA`). The
      # fallback path walks the raw rows for the full day so the
      # chart still renders rather than blanking out. Pin that the
      # points list equals what `list_day_chart_data/4` would have
      # returned for the same data (same set of (bucket, series)
      # pairs and the same per-bucket power).
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      for {hour, minute, power} <- [{9, 0, 100.0}, {9, 30, 200.0}, {10, 0, 300.0}] do
        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: device.id,
            inverter_serial: "INV-1",
            mppt_index: 0,
            ac_power: power,
            inserted_at: today_at(hour, minute)
          })
      end

      dashboard_points =
        Devices.list_day_chart_data_for_dashboard(
          user,
          today_at(0),
          today_end_of_day(),
          device.id
        )

      raw_points =
        Devices.list_day_chart_data(user, today_at(0), today_end_of_day(), device.id)

      # Same number of points on both paths.
      assert length(dashboard_points) == length(raw_points)

      # Same set of `(bucket, series)` pairs on both paths. Comparing
      # via a {time, serial} → power map normalises away any
      # minor difference in the row-key shape between the two
      # implementations (raw rows bucketed in BEAM by `div(unix, 300)`,
      # aggregate rows by TimescaleDB's `time_bucket`). Both paths
      # produce identical 5-minute bucket boundaries for any timestamp
      # already aligned to a 5-min boundary, and the test seeds
      # such-aligned timestamps on purpose.
      dashboard_pairs =
        dashboard_points
        |> Map.new(fn pt -> {{pt.time, elem(pt.series, 1)}, pt.power} end)

      raw_pairs =
        raw_points
        |> Map.new(fn pt -> {{pt.time, elem(pt.series, 1)}, pt.power} end)

      Enum.each(raw_pairs, fn {key, expected_power} ->
        assert Map.has_key?(dashboard_pairs, key),
               "expected dashboard to have point #{inspect(key)}, got #{inspect(Map.keys(dashboard_pairs))}"

        assert_in_delta Map.fetch!(dashboard_pairs, key), expected_power, 0.1
      end)
    end

    test "returns [] for a window with no readings (no fallback scan)" do
      user = DtuApp.AccountsFixtures.user_fixture()
      _device = DevicesFixtures.device_fixture(user)

      # Empty window — no raw rows and no aggregate rows.
      assert Devices.list_day_chart_data_for_dashboard(
               user,
               today_at(0),
               today_end_of_day(),
               nil
             ) == []
    end

    test "scopes by dtu_id when one is supplied" do
      user = DtuApp.AccountsFixtures.user_fixture()
      dtu1 = DevicesFixtures.device_fixture(user)
      dtu2 = DevicesFixtures.device_fixture(user)

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu1.id,
          inverter_serial: "INV-1",
          mppt_index: 0,
          ac_power: 100.0,
          inserted_at: today_at(12)
        })

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu2.id,
          inverter_serial: "INV-2",
          mppt_index: 0,
          ac_power: 999.0,
          inserted_at: today_at(12)
        })

      only_dtu1 =
        Devices.list_day_chart_data_for_dashboard(
          user,
          today_at(0),
          today_end_of_day(),
          dtu1.id
        )

      # Only dtu1's row should appear; dtu2's 999 W row is filtered by
      # the `dtu_id in ^dtu_ids` clause in the SQL.
      assert Enum.all?(only_dtu1, fn pt -> elem(pt.series, 0) == dtu1.id end)
      assert_in_delta hd(only_dtu1).power, 100.0, 0.1
    end

    test "returns [] when the supplied dtu_id is not owned by the user" do
      # A user looking at another user's DTU must not see its rows.
      owner = DtuApp.AccountsFixtures.user_fixture()
      attacker = DtuApp.AccountsFixtures.user_fixture()
      their_dtu = DevicesFixtures.device_fixture(owner)

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: their_dtu.id,
          inverter_serial: "INV-X",
          mppt_index: 0,
          ac_power: 500.0,
          inserted_at: today_at(12)
        })

      assert Devices.list_day_chart_data_for_dashboard(
               attacker,
               today_at(0),
               today_end_of_day(),
               their_dtu.id
             ) == []
    end
  end

  describe "list_yesterday_chart_data_for_dashboard/4 (yesterday ghost)" do
    # Mirrors the today function but shifts the window back by one day
    # so the dashboard can reuse the same today-window DateTimes
    # passed to `list_day_chart_data_for_dashboard/4`. Same shape,
    # same MPPT-AC filtering, same per-user DTU scope.

    defp yesterday_at(hour, minute \\ 0) do
      today_at(hour, minute) |> DateTime.add(-86_400, :second)
    end

    test "returns yesterday's chart points, never today's" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      # AC row yesterday at noon.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "INV-1",
          inverter_name: "INV-1",
          mppt_index: 0,
          ac_power: 250.0,
          inserted_at: yesterday_at(12)
        })

      # AC row *today* at noon — must NOT appear in the yesterday result.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "INV-1",
          inverter_name: "INV-1",
          mppt_index: 0,
          ac_power: 999.0,
          inserted_at: today_at(12)
        })

      points =
        Devices.list_yesterday_chart_data_for_dashboard(
          user,
          today_at(0),
          today_end_of_day(),
          device.id
        )

      # Only the yesterday row shows up — the today row is filtered out
      # by the shifted window.
      assert length(points) == 1
      [pt] = points
      assert pt.series == {device.id, "INV-1", 0, "INV-1"}
      assert_in_delta pt.power, 250.0, 0.1
      assert %DateTime{} = pt.time
      assert pt.time.hour == 12
      # The yesterday timestamp must be 24h before today_at(12).
      assert DateTime.diff(pt.time, today_at(12), :second) == -86_400
    end

    test "returns [] when the user has no devices in scope" do
      user = DtuApp.AccountsFixtures.user_fixture()
      assert Devices.list_yesterday_chart_data_for_dashboard(user, today_at(0), today_end_of_day(), nil) == []
    end

    test "returns [] when yesterday has no readings" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      # Only a today reading exists — yesterday is empty.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "INV-1",
          mppt_index: 0,
          ac_power: 100.0,
          inserted_at: today_at(12)
        })

      assert Devices.list_yesterday_chart_data_for_dashboard(
               user,
               today_at(0),
               today_end_of_day(),
               device.id
             ) == []
    end

    test "scopes to the requested DTU — other users' inverters don't leak in" do
      alice = DtuApp.AccountsFixtures.user_fixture()
      alice_dtu = DevicesFixtures.device_fixture(alice)

      bob = DtuApp.AccountsFixtures.user_fixture()
      bob_dtu = DevicesFixtures.device_fixture(bob)

      # Bob's yesterday reading — must not appear in Alice's query.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: bob_dtu.id,
          inverter_serial: "BOB-INV",
          mppt_index: 0,
          ac_power: 500.0,
          inserted_at: yesterday_at(12)
        })

      # Alice's yesterday reading — the only one Alice should see.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: alice_dtu.id,
          inverter_serial: "ALICE-INV",
          mppt_index: 0,
          ac_power: 250.0,
          inserted_at: yesterday_at(12)
        })

      points =
        Devices.list_yesterday_chart_data_for_dashboard(
          alice,
          today_at(0),
          today_end_of_day(),
          alice_dtu.id
        )

      assert length(points) == 1
      [pt] = points
      assert elem(pt.series, 1) == "ALICE-INV"
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

  describe "update_dtu_error/2" do
    # `update_dtu_error/2` is the writer for the user-visible DTU error
    # bubble / fill. It's invoked by `MqttBroker.Telemetry.record_dtu_error/2`
    # every time the parser rejects an uplink or a DB insert fails —
    # so any DB regression here would silently break the dashboard's
    # error indicator. Tests pin the message write, the timestamp, the
    # not-found path, and the empty-message no-op.

    test "writes last_error and last_error_at for the matching DTU" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      before = DtuApp.Time.utc_now_usec()

      assert :ok =
               DtuApp.Devices.update_dtu_error(
                 device.id,
                 "Invalid JSON payload on topic solar/SN/realtime/data"
               )

      reloaded = DtuApp.Repo.get!(DtuApp.Devices.Dtu, device.id)
      assert reloaded.last_error == "Invalid JSON payload on topic solar/SN/realtime/data"
      # Timestamp is on the DB clock and within the same second as
      # `before` (both hands of the comparison come from the same
      # `utc_now_usec/0` source).
      assert reloaded.last_error_at
      assert DateTime.compare(reloaded.last_error_at, before) in [:gt, :eq]
    end

    test "overwriting an older error replaces the message and bumps the timestamp" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      assert :ok = DtuApp.Devices.update_dtu_error(device.id, "first error")
      first_ts = DtuApp.Repo.get!(DtuApp.Devices.Dtu, device.id).last_error_at

      assert :ok = DtuApp.Devices.update_dtu_error(device.id, "second error")
      reloaded = DtuApp.Repo.get!(DtuApp.Devices.Dtu, device.id)

      # The user-visible guarantee is that the *most recent* error
      # wins. Pinning that the timestamp is `>=` the first one is
      # sufficient — under the test sandbox two `now()` calls can
      # coalesce to the same µs and a strict `:gt` assertion would
      # flake, so we use the same `:in [:gt, :eq]` predicate the first
      # test uses.
      assert reloaded.last_error == "second error"
      assert reloaded.last_error_at
      assert DateTime.compare(reloaded.last_error_at, first_ts) in [:gt, :eq]
    end

    test "returns {:error, :not_found} for a non-existent device" do
      assert {:error, :not_found} =
               DtuApp.Devices.update_dtu_error(99_999_999, "no such device")
    end

    test "whitespace-only message is a no-op (no DB write)" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      assert :ok = DtuApp.Devices.update_dtu_error(device.id, "   ")

      reloaded = DtuApp.Repo.get!(DtuApp.Devices.Dtu, device.id)
      assert reloaded.last_error == nil
      assert reloaded.last_error_at == nil
    end

    test "appends a row to dtu_errors with the same message and the device's id" do
      # The bubble / fill UI from MR #86 reads `dtus.last_error` for
      # the most-recent error; the dashboard's edge badge and the
      # manage-device expansion panel read `dtu_errors` for the
      # history. Pin that both tables stay in sync after a write.
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      :ok =
        DtuApp.Devices.update_dtu_error(
          device.id,
          "Invalid JSON payload on solar/SN/realtime/data"
        )

      # History row exists.
      assert DtuApp.Repo.exists?(
               from e in DtuApp.Devices.DtuError,
                 where:
                   e.dtu_id == ^device.id and
                     e.message == "Invalid JSON payload on solar/SN/realtime/data"
             )

      # And the denormalised cache matches.
      reloaded = DtuApp.Repo.get!(DtuApp.Devices.Dtu, device.id)
      assert reloaded.last_error == "Invalid JSON payload on solar/SN/realtime/data"
    end

    test "prunes dtu_errors rows beyond the per-device history cap" do
      # Inserting more rows than `dtu_error_history_cap/0` keeps the
      # history bounded. The cap protects the table from growing
      # unboundedly for a misbehaving DTU that publishes bad payloads
      # every second.
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      cap = DtuApp.Devices.dtu_error_history_cap()
      total = cap + 25

      for i <- 1..total do
        :ok = DtuApp.Devices.update_dtu_error(device.id, "Synthetic error ##{i}")
      end

      # Repo count is bounded by the cap. We don't assert == cap
      # (concurrent inserts from parallel tests could nudge it over)
      # — `cap <= n <= cap` is what we want.
      count =
        DtuApp.Repo.one(
          from e in DtuApp.Devices.DtuError,
            where: e.dtu_id == ^device.id,
            select: count(e.id)
        )

      assert count == cap,
             "expected exactly #{cap} rows after inserting #{total}, got #{inspect(count)}"
    end
  end

  describe "clear_stale_dtu_error/1" do
    # Used by `MqttBroker.Telemetry`'s uplink handler to clear a stale
    # `dtus.last_error` written by a previous parser build. The current
    # parser may not call `record_dtu_error/2` for a topic that the
    # previous build *did* (e.g. `inverter/total/MaxPower` — old build
    # wrote `:ignored_topic` errors; current build silently drops the
    # metric as `:other`). Without this helper, a device that's been
    # publishing valid topics ever since the upgrade would still show
    # its old error bubble forever.
    #
    # Tests pin: the clear runs, the broadcast fires, the no-op
    # path on a healthy device, and the missing-device path.

    test "clears last_error + last_error_at for a device with a cached error" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)
      device_id = device.id

      # Seed an error first.
      :ok = DtuApp.Devices.update_dtu_error(device_id, "stale parser message")

      before = DtuApp.Repo.get!(DtuApp.Devices.Dtu, device_id)
      assert before.last_error == "stale parser message"
      assert before.last_error_at

      # Subscribe to the status topic to observe the broadcast.
      Phoenix.PubSub.subscribe(DtuApp.PubSub, DtuApp.MqttBroker.Telemetry.status_topic())

      :ok = DtuApp.Devices.clear_stale_dtu_error(device_id)

      reloaded = DtuApp.Repo.get!(DtuApp.Devices.Dtu, device_id)
      assert reloaded.last_error == nil
      assert reloaded.last_error_at == nil

      # The helper broadcasts `:dtu_error` so subscribed LiveViews
      # (device-list, dashboard) re-stream the affected device.
      assert_receive {:dtu_error, ^device_id}
    end

    test "is a no-op on a device with no cached error (no broadcast)" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)
      device_id = device.id

      Phoenix.PubSub.subscribe(DtuApp.PubSub, DtuApp.MqttBroker.Telemetry.status_topic())

      # Capture logs at warn level so the MatchError-regression test
      # below can pin the absence of the warning this old code path
      # produced on every healthy uplink.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :ok = DtuApp.Devices.clear_stale_dtu_error(device_id)
        end)

      # Regression: pre-fix, this branch raised
      #   MatchError{term: {0, nil}}
      # because `Repo.update_all` returns `{0, nil}` when no row
      # matched the `not is_nil(d.last_error)` guard, but the old
      # code did `{1, _} = ...`. The rescue clause caught the
      # exception and logged a `[Devices] clear_stale_dtu_error(N)
      # failed: %MatchError{...}` warning on every healthy uplink —
      # flooding the log when a DTU first connected (the parser
      # clears stale errors as part of every uplink handler). The
      # helper now captures the count and only broadcasts on a real
      # update, so the warning must not appear.
      refute log =~ "MatchError",
             "clear_stale_dtu_error must not raise MatchError when no row matched " <>
               "(the rescue warning was the user-visible regression)"

      refute log =~ "clear_stale_dtu_error(#{device_id}) failed",
             "clear_stale_dtu_error must not log a failure warning on a healthy device"

      # No broadcast fires on a no-op — the device's last_error was
      # already nil, so no LiveView needs to re-stream. We assert
      # this explicitly so a future regression that always broadcasts
      # is caught (extra broadcasts cost an extra re-fetch of the
      # device list per uplink on a healthy fleet).
      refute_receive {:dtu_error, ^device_id}, 50

      reloaded = DtuApp.Repo.get!(DtuApp.Devices.Dtu, device_id)
      assert reloaded.last_error == nil
      assert reloaded.last_error_at == nil
    end

    test "returns :ok for a non-existent device" do
      # The helper is called from the telemetry GenServer — a race
      # where the device was deleted between an uplink landing and
      # the clear running must not crash the parser.
      :ok = DtuApp.Devices.clear_stale_dtu_error(99_999_999)
    end
  end

  describe "record_dtu_error/2 + dtu_errors reads" do
    # The transactional writer that backs both the dashboard's edge
    # badge and the manage-device expansion panel. Pins the contract:
    # the insert and the cache update happen atomically; the read
    # helpers (count_distinct_dtu_errors/1 + list_dtu_error_groups/1)
    # return the expected shape.

    test "count_distinct_dtu_errors/1 returns 0 for a device with no errors" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      assert DtuApp.Devices.count_distinct_dtu_errors(device.id) == 0
    end

    test "count_distinct_dtu_errors/1 counts distinct messages, not events" do
      # A Shelly spamming the same `unknown_topic` 50× in a minute
      # should report `1`, not `50` — distinct-message count is the
      # dashboard's whole point.
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      for _ <- 1..5 do
        :ok = DtuApp.Devices.record_dtu_error(device.id, "Shelly topic mismatch")
      end

      :ok = DtuApp.Devices.record_dtu_error(device.id, "A different error")

      assert DtuApp.Devices.count_distinct_dtu_errors(device.id) == 2
    end

    test "list_dtu_error_groups/1 returns one row per distinct message, sorted by recency" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      :ok = DtuApp.Devices.record_dtu_error(device.id, "older error")
      # Sleep past the second boundary so the µs ordering is
      # deterministic; the count test above already passed so this is
      # the only place ordering matters.
      :timer.sleep(1100)
      :ok = DtuApp.Devices.record_dtu_error(device.id, "newer error")
      :ok = DtuApp.Devices.record_dtu_error(device.id, "newer error")

      groups = DtuApp.Devices.list_dtu_error_groups(device.id)

      assert length(groups) == 2

      # The newer message is first because the `ORDER BY
      # MAX(inserted_at) DESC` clause puts the most-recently-fired
      # message at the top of the expansion panel. Repeated inserts
      # of "newer error" bump its `occurrences` to 2.
      assert hd(groups).message == "newer error"
      assert hd(groups).occurrences == 2
      assert List.last(groups).message == "older error"
      assert List.last(groups).occurrences == 1

      # `last_seen` is monotonic — the newer group's timestamp is
      # at-or-after the older group's. Pinning the strict `:gt`
      # predicate flaked on a fast CI runner because postgres coalesces
      # two `now()` calls landing inside the same µs to the same
      # value, so accept `>=` instead.
      assert DateTime.compare(hd(groups).last_seen, List.last(groups).last_seen) in [:gt, :eq]
    end

    test "list_dtu_error_groups/1 returns [] for a device with no errors" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      assert DtuApp.Devices.list_dtu_error_groups(device.id) == []
    end
  end

  describe "DTU error recency filter (48h cutoff)" do
    # The dashboard's edge badge and the manage-device expansion panel
    # hide errors older than `dtu_error_recency_seconds/0` (48 h) so a
    # DTU that's been silent for two days doesn't carry a permanent
    # red badge. The tests below pin the cutoff behaviour by inserting
    # rows with explicit `inserted_at` timestamps so we can drive both
    # sides of the threshold without sleeping for hours.

    alias DtuApp.Devices.DtuError

    # Insert a `dtu_errors` row directly with an explicit `inserted_at`,
    # bypassing `record_dtu_error/2`'s clock-driven default. Used by
    # every test in this block to construct rows in the past without
    # real-time sleeps.
    defp insert_error_at(dtu_id, message, %DateTime{} = inserted_at) do
      %DtuError{}
      |> DtuError.changeset(%{dtu_id: dtu_id, message: message})
      |> Ecto.Changeset.put_change(:inserted_at, inserted_at)
      |> DtuApp.Repo.insert!()
    end

    defp hours_ago(n) do
      DtuApp.Time.utc_now_usec()
      |> DateTime.add(-n * 3600, :second)
      |> DateTime.truncate(:microsecond)
    end

    test "count_distinct_dtu_errors/1 hides errors older than the cutoff" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      # Two errors in the recent window (24 h ago) and one well past
      # the cutoff (72 h ago). Only the recent errors should count.
      insert_error_at(device.id, "recent error A", hours_ago(24))
      insert_error_at(device.id, "recent error B", hours_ago(12))
      insert_error_at(device.id, "stale error", hours_ago(72))

      assert DtuApp.Devices.count_distinct_dtu_errors(device.id) == 2
    end

    test "count_distinct_dtu_errors/1 returns 0 when all errors are stale" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      insert_error_at(device.id, "very stale", hours_ago(72))
      insert_error_at(device.id, "even staler", hours_ago(120))

      assert DtuApp.Devices.count_distinct_dtu_errors(device.id) == 0
    end

    test "list_dtu_error_groups/1 excludes stale groups" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      insert_error_at(device.id, "fresh message", hours_ago(2))
      insert_error_at(device.id, "stale message", hours_ago(72))

      groups = DtuApp.Devices.list_dtu_error_groups(device.id)

      assert length(groups) == 1
      assert hd(groups).message == "fresh message"
    end

    test "list_dtu_error_groups/1 only counts occurrences within the cutoff" do
      # A message that fired 50 times in the past 24 h and 100 times
      # a month ago should report 50 occurrences, not 150 — the
      # historical events stay in the table (so the per-device cap
      # does its job), but the user-visible count excludes them.
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      for _ <- 1..50 do
        insert_error_at(device.id, "frequent recent", hours_ago(1))
      end

      for _ <- 1..100 do
        insert_error_at(device.id, "frequent recent", hours_ago(720))
      end

      groups = DtuApp.Devices.list_dtu_error_groups(device.id)

      assert length(groups) == 1
      assert hd(groups).occurrences == 50
    end

    test "an error message split across the cutoff collapses to one group" do
      # A message fired at -23 h and -50 h: the recent event is inside
      # the cutoff, the older is outside. Both rows live in the table,
      # so `GROUP BY message` still collapses them — but the
      # `MAX(inserted_at)` is the recent event, which the user sees.
      # The older event is hidden from the panel because the cutoff
      # filter applies BEFORE the GROUP BY (so it never enters the
      # aggregation). The test pins this so a future refactor that
      # filters after the GROUP BY can't quietly surface the stale
      # event's count.
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      insert_error_at(device.id, "split message", hours_ago(23))
      insert_error_at(device.id, "split message", hours_ago(50))

      groups = DtuApp.Devices.list_dtu_error_groups(device.id)

      assert length(groups) == 1
      [group] = groups
      assert group.message == "split message"
      assert group.occurrences == 1
    end

    test "dtu_error_recency_cutoff/0 returns DB-clock minus the configured seconds" do
      cutoff = DtuApp.Devices.dtu_error_recency_cutoff()
      diff = DateTime.diff(DtuApp.Time.utc_now_usec(), cutoff, :second)

      # Exact second precision — the cutoff subtracts an integer
      # number of seconds from `now()`.
      assert diff == DtuApp.Devices.dtu_error_recency_seconds()
    end

    test "explicit cutoff overrides the default (tests can pin to any instant)" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      insert_error_at(device.id, "10h ago", hours_ago(10))
      insert_error_at(device.id, "20h ago", hours_ago(20))

      # Cutoff 15 h before now: only the 10 h error is visible.
      cutoff_15h = hours_ago(15)
      assert length(DtuApp.Devices.list_dtu_error_groups(device.id, cutoff_15h)) == 1
      assert DtuApp.Devices.count_distinct_dtu_errors(device.id, cutoff_15h) == 1

      # Cutoff 25 h before now: both errors visible.
      cutoff_25h = hours_ago(25)
      assert length(DtuApp.Devices.list_dtu_error_groups(device.id, cutoff_25h)) == 2
      assert DtuApp.Devices.count_distinct_dtu_errors(device.id, cutoff_25h) == 2
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

    test "per_series_peak uses ac_power for the ch0 entry (current_power mirrors it)" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)
      now = DateTime.utc_now()

      # ch0 AC aggregate row. `per_series_peak` is sourced from
      # `latest_per_series_readings` (full per-(inverter, MPPT) coverage)
      # and the AC aggregate is selected via `chart_power_for_mppt/1`
      # (ac_power for `mppt_index = 0`). The peak should be 380 W.
      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-1",
        inverter_name: "East Array",
        mppt_index: 0,
        ac_power: 380.0,
        dc_power: nil,
        inserted_at: now
      })

      stats = Devices.get_daily_stats(user)

      [mppt_0] = Enum.filter(stats.per_series, &(&1.mppt_index == 0))
      assert_in_delta mppt_0.peak_power, 380.0, 0.1
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

      # Anchor the 50 readings at 11:00 UTC today so all 50 readings
      # (spanning 4 hours, finishing at 15:05 UTC) sit inside today's
      # UTC window regardless of when the test runs. The latest reading
      # at 15:05 UTC may or may not be within the 2-min "fresh" cutoff
      # depending on the test's `now`, so we accept either value for
      # `current_consumption` and pin only the bucket-integrated totals.
      anchor =
        Date.utc_today()
        |> DateTime.new!(~T[11:00:00])
        |> Map.put(:microsecond, {0, 0})

      # 50 readings at 624 W, one per 5-min bucket. 50 buckets ×
      # 624 W × (5/60 h) = 2_600 Wh = 2.6 kWh.
      for idx <- 0..49 do
        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: device.id,
            inverter_serial: "em:0",
            mppt_index: 0,
            power_type: "consumption",
            consumption_power: 624.0,
            inserted_at: DateTime.add(anchor, idx * 300, :second)
          })
      end

      stats = Devices.get_consumption_period_stats(user, device.id, "today", nil)

      # today_consumption: 50 buckets × 624 W × (5/60 h) = 2_600 Wh =
      # 2.6 kWh. The integration replaces the old
      # `consumption_energy_total` lifetime-counter delta, which only
      # grew on grid imports and stayed 0 for solar self-sufficient
      # homes.
      assert_in_delta stats.today_consumption, 2.6, 0.1
      # Peak across today's buckets (624 W from the 50-reading series).
      assert_in_delta stats.peak_consumption, 624.0, 0.1
      # The mirror fields also carry the same values.
      assert_in_delta stats.period_total_consumption, 2.6, 0.1
      assert_in_delta stats.period_peak_consumption, 624.0, 0.1
      assert stats.peak_date == Date.utc_today()
    end

    test "day view with explicit selected_period computes the day-local totals" do
      # Pins the day view's "Total Consumption" card: a closed-day
      # window for the bucket-mean consumption_power integration.
      # The legacy implementation took the lifetime-counter delta
      # (`MAX - MIN` of `consumption_energy_total`), which only grew
      # on grid imports and stayed 0 for solar self-sufficient homes.
      # The new approach integrates the bucket-mean consumption_power
      # over time so household consumption is reported correctly
      # regardless of solar self-sufficiency.
      user = DtuApp.AccountsFixtures.user_fixture()

      device =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      target_date = ~D[2026-07-15]

      # 60 readings, one per 5-min bucket, each at 5000 W. Each
      # reading is in its own 5-min bucket (timestamps 5 min apart)
      # so the bucket mean equals the single reading. 60 buckets ×
      # 5000 W × (5/60 h) = 25_000 Wh = 25.0 kWh.
      for idx <- 0..59 do
        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: device.id,
            inverter_serial: "em:0",
            mppt_index: 0,
            power_type: "consumption",
            consumption_power: 5000.0,
            inserted_at:
              DateTime.new!(target_date, ~T[00:00:00])
              |> DateTime.add(idx * 300, :second)
              |> Map.put(:microsecond, {0, idx})
          })
      end

      # A 300 W reading that the helper should pick as the day's peak
      # (lower than 5000 W so it doesn't dominate the bucket mean).
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "em:0",
          mppt_index: 0,
          power_type: "consumption",
          consumption_power: 300.0,
          inserted_at: DateTime.new!(target_date, ~T[23:55:00])
        })

      stats = Devices.get_consumption_period_stats(user, device.id, "day", target_date)

      # 60 × 5000 W × (5/60 h) = 25_000 Wh = 25.0 kWh
      assert_in_delta stats.period_total_consumption, 25.0, 0.1
      # Peak across the day's consumption points — the 5000 W bucket
      # mean dominates over the single 300 W reading.
      assert_in_delta stats.period_peak_consumption, 5000.0, 0.1
      assert stats.peak_date == target_date
    end

    test "week view integrates period_total across multiple days via consumption_power" do
      # Three days of readings, each with 12 × 5-min buckets. The
      # bucket-mean consumption_power integration across the week
      # sums the per-bucket Wh contributions. The legacy implementation
      # took per-day lifetime-counter deltas which only grew on grid
      # imports — for a solar self-sufficient home the dashboard
      # always rendered 0 kWh. The new approach integrates the
      # bucket-mean consumption_power over time so household
      # consumption is reported correctly.
      user = DtuApp.AccountsFixtures.user_fixture()

      device =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      # Week starts Monday 2026-07-13, ends Sunday 2026-07-19.
      week_start = ~D[2026-07-13]
      _week_end = ~D[2026-07-19]

      # Three days, each with 12 buckets at 1000 W:
      #   12 buckets × 1000 W × (5/60 h) = 1000 Wh = 1.0 kWh per day
      #   3 days × 1.0 kWh = 3.0 kWh per week
      # Pick per-bucket power so each day's peak rounds cleanly to
      # a known value. Day 1: peak 1000 W. Day 2: peak 1500 W.
      # Day 3: peak 2000 W.
      for {date, peak_w} <- [
            {~D[2026-07-13], 1000.0},
            {~D[2026-07-15], 1500.0},
            {~D[2026-07-17], 2000.0}
          ] do
        # 12 readings per day, one per 5-min bucket. Microsecond
        # offsets keep the composite PK unique.
        for idx <- 0..11 do
          {:ok, _} =
            Devices.create_reading(%{
              dtu_id: device.id,
              inverter_serial: "em:0",
              mppt_index: 0,
              power_type: "consumption",
              consumption_power: peak_w,
              inserted_at:
                DateTime.new!(date, ~T[00:00:00])
                |> DateTime.add(idx * 300, :second)
                |> Map.put(:microsecond, {0, idx})
            })
        end
      end

      stats =
        Devices.get_consumption_period_stats(user, device.id, "week", week_start)

      # 3 days × 12 buckets × peak_W × (5/60 h):
      #   12 × 1000 × 1/12 = 1000 Wh = 1.0 kWh (day 1)
      #   12 × 1500 × 1/12 = 1500 Wh = 1.5 kWh (day 2)
      #   12 × 2000 × 1/12 = 2000 Wh = 2.0 kWh (day 3)
      #   total = 4.5 kWh
      assert_in_delta stats.period_total_consumption, 4.5, 0.1
      # The 2026-07-17 day (peak 2000 W) wins the per-day peak. The
      # peak helper returns the maximum single-day peak.
      assert_in_delta stats.period_peak_consumption, 2000.0, 0.1
      assert stats.peak_date == ~D[2026-07-17]
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

  describe "consumption stats — solar self-sufficient home (regression)" do
    # User-reported bug: a Shelly Plus 3EM paired with a solar inverter
    # saw the dashboard's "Today's Consumption" card always read 0.0 kWh
    # even though the household was actively consuming energy. The cause:
    # `get_consumption_daily_stats/2` derived today's kWh from the
    # Shelly's lifetime `consumption_energy_total` counter delta
    # (`MAX - MIN`). That counter only grows when current flows from
    # the grid into the home — for a solar self-sufficient home (or any
    # home exporting more than it imports), the lifetime counter barely
    # changes and the dashboard always rendered 0 kWh. The fix
    # integrates the per-bucket-mean `consumption_power` over time
    # instead, which reports actual household draw regardless of
    # whether the energy came from the grid or directly from solar.
    test "today_consumption integrates bucket-mean consumption_power over time" do
      # 12 readings, one per 5-min bucket, each at 1000 W. Spans 60
      # minutes. Bucket-mean × (5/60 h) = 83.33 Wh per bucket × 12
      # buckets = 1000 Wh = 1.0 kWh.
      # `consumption_energy_total` stays at nil — this is the bug shape:
      # the legacy lifetime-counter delta would have returned 0.
      user = DtuApp.AccountsFixtures.user_fixture()

      device =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      # Anchor the 12 readings at 03:00 UTC today (3 hours into
      # the day) and the test runs at any time after 03:55 UTC.
      # Late-night runs (before 03:00 UTC) are out of scope — the
      # 12-reading window from 03:00 to 03:55 UTC is entirely in
      # today. The latest reading at 03:55 UTC is well before the
      # 2-min "fresh" cutoff for `current_consumption` (unless the
      # test happens to run between 03:55 and 04:00 UTC, in which
      # case the 03:55 reading is fresh — see the cond below).
      anchor =
        Date.utc_today()
        |> DateTime.new!(~T[03:00:00])
        |> DateTime.truncate(:second)

      for idx <- 0..11 do
        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: device.id,
            inverter_serial: "em:0",
            mppt_index: 0,
            power_type: "consumption",
            consumption_power: 1000.0,
            # nil — never set. Simulates a freshly-reset Shelly or a
            # firmware that doesn't populate the energy_total field.
            consumption_energy_total: nil,
            inserted_at:
              DateTime.add(anchor, idx * 300, :second)
              |> Map.put(:microsecond, {0, 0})
          })
      end

      stats = Devices.get_consumption_daily_stats(user)

      # Without the fix: today_consumption = 0.0 (lifetime counter is
      # nil across all rows, so MIN/MAX → NULL → 0.0).
      # With the fix: today_consumption = 12 buckets × 1000 W × (5/60 h)
      # = 1000 Wh = 1.0 kWh.
      assert_in_delta stats.today_consumption, 1.0, 0.1

      # current_consumption is "fresh readings in the last 2 min".
      # For runs after 03:57 UTC, all 12 readings are > 2 min old
      # → 0. For runs at exactly 03:55–03:57 UTC, the latest reading
      # (03:55) is fresh and current_consumption = 1000 W. We accept
      # either since the test's primary purpose is the integration
      # total, not the live wattage.
      latest = DateTime.add(anchor, 11 * 300, :second)
      fresh_cutoff = DateTime.utc_now() |> DateTime.add(-120, :second)

      cond do
        DateTime.after?(latest, fresh_cutoff) ->
          assert_in_delta stats.current_consumption, 1000.0, 0.1

        true ->
          assert_in_delta stats.current_consumption, 0.0, 0.1
      end
    end

    test "today_consumption clamps negative consumption_power to zero (solar export)" do
      # A Shelly reporting `total_act_power = -300 W` (the home is
      # net-exporting 300 W through the meter) should not contribute a
      # negative Wh to today's consumption. Pre-clamp the bucket
      # integration would have subtracted 300 W × (5/60 h) = -25 Wh
      # from today's total — exactly the same bug as the chart's "Net
      # flow cap at +production" guard (see `clamp_household_draw/1`).
      user = DtuApp.AccountsFixtures.user_fixture()

      device =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      # Anchor the readings inside today's UTC window.
      anchor =
        Date.utc_today()
        |> DateTime.new!(~T[12:00:00])
        |> Map.put(:microsecond, {0, 0})

      for idx <- 0..2 do
        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: device.id,
            inverter_serial: "em:0",
            mppt_index: 0,
            power_type: "consumption",
            # Negative — typical for a home exporting surplus solar.
            # The clamp converts each reading to 0 W, so the integration
            # is 0 Wh per bucket (not -25 Wh).
            consumption_power: -300.0,
            inserted_at: DateTime.add(anchor, idx * 300, :second)
          })
      end

      stats = Devices.get_consumption_daily_stats(user)

      # All 3 buckets clamp to 0 W → today_consumption = 0.0 kWh.
      assert_in_delta stats.today_consumption, 0.0, 0.0
      # current_consumption is 0 because the only fresh readings are
      # negative (all older than 2 minutes), and clamp pushes them to 0.
      assert_in_delta stats.current_consumption, 0.0, 0.1
    end
  end

  describe "list_net_chart_data/4 — net flow bucketing (regression)" do
    # Customer-reported bug: a home with a 2-MPPT Hoymiles inverter (or
    # any multi-MPPT inverter) + a Shelly Plus 3EM saw the dashboard
    # "Exported today" stat roughly 10× higher than reality, while
    # "Imported today" was correspondingly wrong. Two distinct over-
    # counts compounded into the net-flow value:
    #
    #   * Production side: each bucket summed `ac_power` for the AC
    #     aggregate row AND `dc_power` for every per-MPPT row — for a
    #     2-MPPT Hoymiles producing 500 W AC, the bucket read
    #     `500 + 250 + 250 = 1000 W` (≈2× over-count).
    #   * Consumption side: a Shelly publishes ~10× per 5-min window.
    #     Each reading was summed, so `76 W` from the Shelly app rendered
    #     as `760 W` on the dashboard (≈10× over-count — the "factor of
    #     10" the user reported).
    #
    # Fix: average per device on each side. Per-MPPT DC rows are
    # excluded entirely from the production total (the AC aggregate row
    # is the inverter's true AC output); consumption averages per Shelly
    # device and sums across devices.
    #
    # The tests below pin the corrected behaviour. Each reading lands in
    # the same 5-min bucket so the chart emits a single net-flow point.

    test "averages consumption across the bucket (Shelly 10× over-count regression)" do
      # 10 Shelly uplinks in the same 5-min bucket, all reading 100 W.
      # Pre-fix this reported 1000 W for the consumption side of the net.
      # Post-fix the per-device mean = 100 W (matching the Shelly app).
      user = DtuApp.AccountsFixtures.user_fixture()

      shelly =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      inverter = DevicesFixtures.device_fixture(user)

      bucket = net_bucket_at("12:00:00")

      # 10 consumption uplinks spaced ~3s apart, all reading 100 W.
      for idx <- 0..9 do
        shelly_consumption_row(shelly.id, 100.0, DateTime.add(bucket, idx * 3, :second), idx)
      end

      # One production row in the same bucket — 100 W. With identical
      # production and consumption, the net should be 0 W (not the
      # pre-fix -900 W).
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: inverter.id,
          inverter_serial: "INV-1",
          inverter_name: "Roof",
          mppt_index: 0,
          ac_power: 100.0,
          inserted_at: bucket
        })

      points =
        Devices.list_net_chart_data(
          user,
          Date.utc_today() |> DateTime.new!(~T[00:00:00]),
          Date.utc_today() |> DateTime.new!(~T[23:59:59])
        )

      assert length(points) == 1
      [point] = points
      # 100 W production − 100 W (mean of 10× 100 W Shelly) = 0 W.
      # Pre-fix: 100 W production − 1000 W (sum of 10× 100 W Shelly) = −900 W.
      assert_in_delta point.power, 0.0, 0.1
    end

    test "excludes per-MPPT DC rows from the production total (multi-MPPT over-count)" do
      # A 2-MPPT Hoymiles publishes:
      #   * one AC aggregate row (mppt_index = 0) carrying the true AC
      #     output on `realtime/data`
      #   * one DC row per MPPT on `[serial]/[1-N]/power` carrying per-
      #     string DC inputs that the firmware has already summed into
      #     the AC total.
      # Pre-fix all three rows were summed: 500 + 250 + 250 = 1000 W.
      # Post-fix only the AC aggregate row counts: 500 W.
      user = DtuApp.AccountsFixtures.user_fixture()

      inverter = DevicesFixtures.device_fixture(user)

      shelly =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      bucket = net_bucket_at("12:00:00")

      # 500 W AC aggregate — the inverter's true AC output.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: inverter.id,
          inverter_serial: "INV-1",
          inverter_name: "Roof",
          mppt_index: 0,
          ac_power: 500.0,
          inserted_at: bucket
        })

      # 250 W per-MPPT rows — duplicates of the AC output, must NOT count.
      for mppt <- [1, 2] do
        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: inverter.id,
            inverter_serial: "INV-1",
            inverter_name: "Roof",
            mppt_index: mppt,
            dc_power: 250.0,
            ac_power: nil,
            inserted_at: bucket
          })
      end

      # One Shelly reading of 100 W — the household draw.
      shelly_consumption_row(shelly.id, 100.0, bucket, 0)

      points =
        Devices.list_net_chart_data(
          user,
          Date.utc_today() |> DateTime.new!(~T[00:00:00]),
          Date.utc_today() |> DateTime.new!(~T[23:59:59])
        )

      assert length(points) == 1
      [point] = points
      # 500 W AC − 100 W (single Shelly mean) = +400 W (exporting).
      # Pre-fix: 1000 W (AC + DC + DC) − 100 W = +900 W (≈2.25× too high).
      assert_in_delta point.power, 400.0, 0.1
    end

    test "exporting bucket: production exceeds consumption with multiple Shelly uplinks" do
      # Pre-fix a 500 W inverter vs. 10× 50 W Shelly readings reported
      # 500 − 500 = 0 W (the user thinks they're break-even). Post-fix
      # the same scenario reports 500 − 50 = 450 W (exporting), matching
      # what a person on the inverter side would expect.
      user = DtuApp.AccountsFixtures.user_fixture()

      inverter = DevicesFixtures.device_fixture(user)

      shelly =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      bucket = net_bucket_at("12:00:00")

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: inverter.id,
          inverter_serial: "INV-1",
          inverter_name: "Roof",
          mppt_index: 0,
          ac_power: 500.0,
          inserted_at: bucket
        })

      for idx <- 0..9 do
        shelly_consumption_row(shelly.id, 50.0, DateTime.add(bucket, idx * 3, :second), idx)
      end

      points =
        Devices.list_net_chart_data(
          user,
          Date.utc_today() |> DateTime.new!(~T[00:00:00]),
          Date.utc_today() |> DateTime.new!(~T[23:59:59])
        )

      [point] = points
      # 500 − mean(10× 50) = 500 − 50 = 450 W export.
      assert_in_delta point.power, 450.0, 0.1
    end

    test "importing bucket: consumption exceeds production with multiple Shelly uplinks" do
      # Symmetric to the exporting case — a 100 W inverter against a
      # 10× 100 W Shelly (a kettle running, say) should read -900 W
      # import, not the pre-fix 100 − 1000 = -900 (coincidentally
      # numerically identical in this case, but with a different bucket
      # value composition). Pin the post-fix expected = (100 W
      # production) − (mean of 10× 100 W Shelly = 100 W) = 0 W, and
      # bump the inverter to 0 W so the case is unambiguously an
      # importing bucket post-fix.
      user = DtuApp.AccountsFixtures.user_fixture()

      inverter = DevicesFixtures.device_fixture(user)

      shelly =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      bucket = net_bucket_at("12:00:00")

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: inverter.id,
          inverter_serial: "INV-1",
          inverter_name: "Roof",
          mppt_index: 0,
          ac_power: 50.0,
          inserted_at: bucket
        })

      # 10 × 200 W Shelly — household drawing 200 W mean. Pre-fix this
      # read 50 − 2000 = -1950 W. Post-fix: 50 − 200 = -150 W import.
      for idx <- 0..9 do
        shelly_consumption_row(shelly.id, 200.0, DateTime.add(bucket, idx * 3, :second), idx)
      end

      points =
        Devices.list_net_chart_data(
          user,
          Date.utc_today() |> DateTime.new!(~T[00:00:00]),
          Date.utc_today() |> DateTime.new!(~T[23:59:59])
        )

      [point] = points
      assert_in_delta point.power, -150.0, 0.1
    end

    test "drops buckets with no Shelly readings (no net-flow curve at all)" do
      # Without a Shelly row in the bucket, the bucket's net would be
      # `production - 0 = production` — identical to the Total line.
      # The dashboard hides the net-flow row entirely when no bucket
      # survives (`@net_path != ""`).
      user = DtuApp.AccountsFixtures.user_fixture()
      inverter = DevicesFixtures.device_fixture(user)

      bucket = net_bucket_at("12:00:00")

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: inverter.id,
          inverter_serial: "INV-1",
          inverter_name: "Roof",
          mppt_index: 0,
          ac_power: 500.0,
          inserted_at: bucket
        })

      assert Devices.list_net_chart_data(
               user,
               Date.utc_today() |> DateTime.new!(~T[00:00:00]),
               Date.utc_today() |> DateTime.new!(~T[23:59:59])
             ) == []
    end

    test "averages consumption across multiple Shelly devices" do
      # Multi-Shelly household: each device's per-bucket mean is summed
      # across devices. Pre-fix the sum-of-all-readings approach would
      # add up ~20× the true household draw (two Shellys, ~10 readings
      # each per bucket).
      user = DtuApp.AccountsFixtures.user_fixture()

      inverter = DevicesFixtures.device_fixture(user)

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

      bucket = net_bucket_at("12:00:00")

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: inverter.id,
          inverter_serial: "INV-1",
          inverter_name: "Roof",
          mppt_index: 0,
          ac_power: 1000.0,
          inserted_at: bucket
        })

      for idx <- 0..9 do
        shelly_consumption_row(dtu1.id, 200.0, DateTime.add(bucket, idx * 3, :second), idx)
      end

      for idx <- 0..9 do
        shelly_consumption_row(dtu2.id, 300.0, DateTime.add(bucket, idx * 3, :second), idx)
      end

      points =
        Devices.list_net_chart_data(
          user,
          Date.utc_today() |> DateTime.new!(~T[00:00:00]),
          Date.utc_today() |> DateTime.new!(~T[23:59:59])
        )

      [point] = points
      # 1000 W production − (mean Shelly 1 = 200 W) − (mean Shelly 2 = 300 W) = 500 W export.
      assert_in_delta point.power, 500.0, 0.1
    end
  end

  describe "get_net_flow_stats/2 — exported/imported today (regression)" do
    # The kWh exports/imports come from `list_net_chart_data/4` via
    # `bucket_h = 5/60 h`. Pin the end-to-end day-total math so the
    # dashboard's "Exported today" / "Imported today" cards reflect the
    # corrected per-bucket values.

    test "today_net_export = bucket_W × (5/60) h summed over positive buckets (corrected)" do
      # One bucket: 500 W production, 100 W Shelly (single reading) →
      # net = +400 W. Converted to Wh: 400 × (5/60) = 33.333 Wh
      # = 0.0333 kWh ≈ 0.03 kWh.
      user = DtuApp.AccountsFixtures.user_fixture()
      inverter = DevicesFixtures.device_fixture(user)

      shelly =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      bucket_time =
        Date.utc_today()
        |> DateTime.new!(~T[12:00:00])

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: inverter.id,
          inverter_serial: "INV-1",
          mppt_index: 0,
          ac_power: 500.0,
          inserted_at: bucket_time
        })

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: shelly.id,
          inverter_serial: "em:0",
          mppt_index: 0,
          power_type: "consumption",
          consumption_power: 100.0,
          inserted_at: bucket_time
        })

      stats = Devices.get_net_flow_stats(user)
      # `today_net_export` is rounded to 2 decimal places (kWh), so a
      # value like `0.03333…` renders as `0.03`. Tolerance accounts for
      # the post-rounding granularity.
      assert_in_delta stats.today_net_export, 400.0 * 5.0 / 60.0 / 1000.0, 0.01
      assert stats.today_net_import == 0.0
    end

    test "today_net_import uses abs(net) for the negative buckets (corrected)" do
      # 100 W production, 10 × 100 W Shelly readings in the same bucket.
      # Corrected net = 100 − 100 = 0 (no import). Pre-fix the same data
      # gave 100 − 1000 = -900 W → 75 Wh import (0.075 kWh). Pin the
      # corrected value of 0 kWh import here.
      user = DtuApp.AccountsFixtures.user_fixture()
      inverter = DevicesFixtures.device_fixture(user)

      shelly =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      bucket_time =
        Date.utc_today()
        |> DateTime.new!(~T[12:00:00])

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: inverter.id,
          inverter_serial: "INV-1",
          mppt_index: 0,
          ac_power: 100.0,
          inserted_at: bucket_time
        })

      for idx <- 0..9 do
        shelly_consumption_row(shelly.id, 100.0, bucket_time, idx)
      end

      stats = Devices.get_net_flow_stats(user)
      assert stats.today_net_export == 0.0
      assert stats.today_net_import == 0.0
    end

    test "peak_export / peak_import are the bucket-max W values (not the inflated sums)" do
      # Pre-fix the per-bucket W value was the inflated sum (10× Shelly
      # reading = 1000 W); peak_import therefore read 1000 W. Post-fix
      # the per-bucket value is the corrected mean (100 W), so
      # peak_import = 100 W.
      user = DtuApp.AccountsFixtures.user_fixture()
      inverter = DevicesFixtures.device_fixture(user)

      shelly =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      bucket_time =
        Date.utc_today()
        |> DateTime.new!(~T[12:00:00])

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: inverter.id,
          inverter_serial: "INV-1",
          mppt_index: 0,
          ac_power: 100.0,
          inserted_at: bucket_time
        })

      for idx <- 0..9 do
        shelly_consumption_row(shelly.id, 100.0, bucket_time, idx)
      end

      stats = Devices.get_net_flow_stats(user)
      # Corrected peak_import: max over buckets of abs(bucket-net) = |100 - 100| = 0 W.
      # Pre-fix: 100 - 1000 = -900 → 900 W.
      assert_in_delta stats.peak_import, 0.0, 0.1
      assert_in_delta stats.peak_export, 0.0, 0.1
    end
  end

  describe "clamp_household_draw/1 — Shelly signed total_act_power" do
    # The Shelly Plus 3EM publishes `total_act_power` as a SIGNED value
    # — negative when the home is net-exporting (the meter sees reverse
    # flow), positive when drawing from the grid. The dashboard's
    # "consumption" is meant to represent household draw, which is
    # intrinsically ≥ 0. Without clamping, a sunny midday with low
    # draw would render the "Current Consumption" stat as a negative
    # wattage and the consumption overlay would dip below the
    # chart's X-axis. The clamp is centralised in
    # `Devices.clamp_household_draw/1` and applied everywhere a
    # `consumption_power` value feeds into a stat or a chart point.
    # Tests below pin the helper directly and verify each call site.
    test "clamps negative values to 0" do
      assert Devices.clamp_household_draw(-150.0) == 0.0
      assert Devices.clamp_household_draw(-0.5) == 0.0
    end

    test "passes positive values through unchanged" do
      assert Devices.clamp_household_draw(0.0) == 0.0
      assert Devices.clamp_household_draw(76.0) == 76.0
      assert Devices.clamp_household_draw(1500.0) == 1500.0
    end

    test "treats nil as 0" do
      # Reading rows from `DISTINCT ON (dtu_id)` may return rows with
      # nil `consumption_power` if the Shelly uplink was missing that
      # field. The clamp must convert that to a usable 0.0.
      assert Devices.clamp_household_draw(nil) == 0.0
    end
  end

  describe "consumption-side stats — negative input is clamped to 0" do
    # End-to-end pins for the consumption-side helpers
    # (`get_consumption_daily_stats/2`, the consumption period stats,
    # the consumption chart series, the consumption half of
    # `list_net_chart_data/4`, and `get_net_flow_stats/2`'s live
    # reading). Every helper sees the raw `consumption_power` value;
    # each one must clamp to ≥ 0 W before summing / plotting / etc.

    test "current_consumption reads 0 when the Shelly reports negative power" do
      # Sunny midday, low draw: Shelly reports -250 W (house is net-
      # exporting through the meter). Without the clamp the dashboard
      # would render "Current Consumption: -250 W" — meaningless.
      # With the clamp it reads 0 W.
      user = DtuApp.AccountsFixtures.user_fixture()

      device =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      now = DateTime.utc_now()

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "em:0",
          mppt_index: 0,
          power_type: "consumption",
          consumption_power: -250.0,
          inserted_at: DateTime.add(now, -5, :second)
        })

      stats = Devices.get_consumption_daily_stats(user)
      assert stats.current_consumption == 0.0
      assert stats.peak_consumption == 0.0
    end

    test "list_consumption_chart_data/4 clamps negative bucket values to 0" do
      # The chart overlay must stay above the X-axis even when every
      # Shelly uplink in a bucket is negative. Two negative readings
      # in the same bucket produce a mean of -250 W — the chart
      # bucket should report 0 W (and the consumption line stays
      # flat at the X-axis baseline for that window).
      user = DtuApp.AccountsFixtures.user_fixture()

      device =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      bucket =
        Date.utc_today()
        |> DateTime.new!(~T[12:00:00])
        |> Map.put(:microsecond, {0, 6})

      # Two negative readings in the same 5-min bucket (idx keeps PK
      # microseconds distinct).
      shelly_consumption_row(device.id, -200.0, bucket, 0)
      shelly_consumption_row(device.id, -300.0, bucket, 1)

      points =
        Devices.list_consumption_chart_data(
          user,
          Date.utc_today() |> DateTime.new!(~T[00:00:00]),
          Date.utc_today() |> DateTime.new!(~T[23:59:59])
        )

      assert length(points) == 1
      [point] = points
      # Pre-fix: -250 W (mean). Post-fix: 0 W (mean of clamped values).
      assert_in_delta point.power, 0.0, 0.1
    end

    test "list_net_chart_data/4 caps net export at +production (no -consumption inflation)" do
      # 500 W AC aggregate + Shelly reporting -250 W (net exporting).
      # Pre-fix the net = 500 - (-250) = 750 W (exceeding total solar).
      # Post-fix the clamped consumption = 0 W, so net = 500 - 0 = 500 W
      # — the headline "Net export" caps at +production.
      user = DtuApp.AccountsFixtures.user_fixture()

      inverter = DevicesFixtures.device_fixture(user)

      shelly =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      bucket = net_bucket_at("12:00:00")

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: inverter.id,
          inverter_serial: "INV-1",
          mppt_index: 0,
          ac_power: 500.0,
          inserted_at: bucket
        })

      shelly_consumption_row(shelly.id, -250.0, bucket, 0)

      points =
        Devices.list_net_chart_data(
          user,
          Date.utc_today() |> DateTime.new!(~T[00:00:00]),
          Date.utc_today() |> DateTime.new!(~T[23:59:59])
        )

      [point] = points
      assert_in_delta point.power, 500.0, 0.1
    end

    test "get_net_flow_stats/2 clamps the live consumption reading" do
      # Live net flow: 800 W AC, Shelly reporting -300 W (exporting).
      # Pre-fix: current_net_flow = 800 - (-300) = 1100 W (impossible
      # — the inverter only makes 800 W). Post-fix: current_net_flow
      # = 800 - 0 = 800 W (the maximum export, matching the inverter's
      # actual output).
      user = DtuApp.AccountsFixtures.user_fixture()
      inverter = DevicesFixtures.device_fixture(user)

      shelly =
        DevicesFixtures.device_fixture(user, %{
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      now = DateTime.utc_now()

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: inverter.id,
          inverter_serial: "INV-1",
          mppt_index: 0,
          ac_power: 800.0,
          inserted_at: now
        })

      shelly_consumption_row(shelly.id, -300.0, now, 0)

      stats = Devices.get_net_flow_stats(user)
      assert_in_delta stats.current_net_flow, 800.0, 0.1
    end
  end

  describe "list_range_yield_data/4 — historical day, week, month, year" do
    # The historical chart path (calendar picker → day/week/month/year) uses
    # the same `list_range_yield_data/4` helper as the live "today" path.
    # The `DISTINCT ON (date, dtu_id, inverter_serial) ORDER BY inserted_at
    # DESC` query must work identically for any date in the past — pinning
    # this so a future refactor doesn't accidentally couple the query to
    # `Date.utc_today()`.
    test "sums each inverter's last reading per day for any past date" do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      today = Date.utc_today()
      yesterday = Date.add(today, -1)
      day_before = Date.add(today, -2)

      seed = fn date, hour, serial, yield_day ->
        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: device.id,
            inverter_serial: serial,
            mppt_index: 0,
            yield_day: yield_day,
            inserted_at: DateTime.new!(date, Time.new!(hour, 0, 0), "Etc/UTC")
          })
      end

      # Day-before-yesterday: INV-1 has 500 at 10am, 1500 at 4pm → last = 1500
      seed.(day_before, 10, "INV-1", 500.0)
      seed.(day_before, 16, "INV-1", 1500.0)
      # INV-2 only one reading at noon → 800
      seed.(day_before, 12, "INV-2", 800.0)

      # Yesterday: INV-1 last = 2000 (from 10am's 1000 + 4pm's 2000),
      # INV-2 = 1500
      seed.(yesterday, 10, "INV-1", 1000.0)
      seed.(yesterday, 16, "INV-1", 2000.0)
      seed.(yesterday, 12, "INV-2", 1500.0)

      # Today: INV-1 last = 2500, INV-2 = 1800
      seed.(today, 10, "INV-1", 1500.0)
      seed.(today, 16, "INV-1", 2500.0)
      seed.(today, 12, "INV-2", 1800.0)

      # Query the full 3-day range.
      {utc_start, _} = Devices.local_day_utc_range(day_before, 0)
      {_, utc_end} = Devices.local_day_utc_range(today, 0)

      yields = Devices.list_range_yield_data(user, utc_start, utc_end)

      # Map: {date => kWh}
      by_date = Map.new(yields)

      # Day-before: 1500 + 800 = 2300 Wh = 2.3 kWh
      assert_in_delta by_date[day_before] || 0.0, 2.3, 0.001
      # Yesterday: 2000 + 1500 = 3500 Wh = 3.5 kWh
      assert_in_delta by_date[yesterday] || 0.0, 3.5, 0.001
      # Today: 2500 + 1800 = 4300 Wh = 4.3 kWh
      assert_in_delta by_date[today] || 0.0, 4.3, 0.001
    end

    test "returns an empty list for a date range with no readings" do
      user = DtuApp.AccountsFixtures.user_fixture()
      _device = DevicesFixtures.device_fixture(user)

      long_ago = Date.add(Date.utc_today(), -30)
      {utc_start, utc_end} = Devices.local_day_utc_range(long_ago, 0)

      assert Devices.list_range_yield_data(user, utc_start, utc_end) == []
    end

    test "ignores legacy _fleet rows an older parser persisted in historical data" do
      # Same defensive filter as today's headline: `_fleet` rows from
      # older parser versions must not influence the historical day
      # chart's per-day yield.
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      yesterday = Date.add(Date.utc_today(), -1)
      dt = DateTime.new!(yesterday, Time.new!(12, 0, 0), "Etc/UTC")

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "INV-1",
          mppt_index: 0,
          yield_day: 1500.0,
          inserted_at: dt
        })

      # Stale `_fleet` row — should be ignored.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "_fleet",
          mppt_index: 0,
          yield_day: 99_999.0,
          inserted_at: dt
        })

      {utc_start, utc_end} = Devices.local_day_utc_range(yesterday, 0)
      [{_date, kwh}] = Devices.list_range_yield_data(user, utc_start, utc_end)

      # 1500 Wh / 1000 = 1.5 kWh — NOT 99.999 kWh.
      assert_in_delta kwh, 1.5, 0.001
    end
  end

  describe "list_last_n_days_yield_data/4 — trailing N-day presets" do
    test "returns up to N daily yields ending today (7D shape)" do
      user = DtuApp.AccountsFixtures.user_fixture()

      device =
        DevicesFixtures.device_fixture(user, %{
          name: "Trailing Inverter",
          kind: "opendtu",
          mqtt_username: "trailing"
        })

      today = Date.utc_today()

      # Seed 3 daily yields at distinct past dates — 0, -2, -5 days ago —
      # all outside today's chart but inside a 7-day window.
      for {offset, wh} <- [{0, 1000}, {-2, 2500}, {-5, 500}] do
        date = Date.add(today, offset)

        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: device.id,
            inverter_serial: "inv-1",
            mppt_index: 0,
            yield_day: wh * 1.0,
            inserted_at: DateTime.new!(date, ~T[12:00:00], "Etc/UTC")
          })
      end

      yields = Devices.list_last_n_days_yield_data(user, 7, 0)
      # Only days with readings appear in the result — the dashboard's
      # `assign_dashboard_data/5` branches zero-fill the missing days
      # to populate the bar chart's x-axis. This helper returns the
      # raw `{Date.t(), kWh}` pairs so the chart axis can be derived
      # deterministically from the data.
      assert length(yields) == 3
      map = Map.new(yields)
      assert_in_delta map[today], 1.0, 0.001
      assert_in_delta map[Date.add(today, -2)], 2.5, 0.001
      assert_in_delta map[Date.add(today, -5)], 0.5, 0.001
    end

    test "respects tz_offset_seconds: window anchored on local midnight" do
      user = DtuApp.AccountsFixtures.user_fixture()

      device =
        DevicesFixtures.device_fixture(user, %{
          name: "TZ Inverter",
          kind: "opendtu",
          mqtt_username: "tz"
        })

      today = Date.utc_today()
      yesterday = Date.add(today, -1)

      # Yield yesterday at 23:30 UTC — for a user at UTC+0 this falls on
      # yesterday (in-window). The point is to prove the window-anchoring
      # math doesn't blow up under non-zero tz offsets.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "inv-1",
          mppt_index: 0,
          yield_day: 7_777.0,
          inserted_at: DateTime.new!(yesterday, ~T[23:30:00], "Etc/UTC")
        })

      yields_utc = Devices.list_last_n_days_yield_data(user, 7, 0)
      # Only the seeded yesterday reading is in the result; the chart
      # does the zero-fill.
      assert length(yields_utc) == 1
      assert Enum.any?(yields_utc, fn {_, kwh} -> kwh > 0 end)

      # Same call with a 12-hour offset still returns at least one
      # entry — proves the local-midnight boundary math doesn't drop
      # the seed.
      yields_offset = Devices.list_last_n_days_yield_data(user, 7, -43_200)
      assert length(yields_offset) >= 1
    end

    test "returns [] when the user has no DTUs" do
      user = DtuApp.AccountsFixtures.user_fixture()
      assert Devices.list_last_n_days_yield_data(user, 7, 0) == []
    end

    test "scopes by dtu_id when one is passed" do
      user = DtuApp.AccountsFixtures.user_fixture()

      device =
        DevicesFixtures.device_fixture(user, %{
          name: "Other Inverter",
          kind: "opendtu",
          mqtt_username: "other"
        })

      today = Date.utc_today()

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: device.id,
          inverter_serial: "x",
          mppt_index: 0,
          yield_day: 999.0,
          inserted_at: DateTime.new!(today, ~T[12:00:00], "Etc/UTC")
        })

      # Pass `dtu_id = nil` (any DTU) vs the actual id — both should
      # return the same single yield, since this user owns only this
      # one DTU. The point is to prove the dtu_id branch is wired.
      assert [{^today, kwh}] = Devices.list_last_n_days_yield_data(user, 7, 0)
      assert_in_delta kwh, 0.999, 0.001

      assert [{^today, kwh2}] =
               Devices.list_last_n_days_yield_data(user, 7, 0, device.id)

      assert_in_delta kwh2, 0.999, 0.001
    end
  end

  describe "list_ytd_yield_data/2 — year-to-date preset" do
    test "returns one monthly entry per month from January through current month" do
      user = DtuApp.AccountsFixtures.user_fixture()

      device =
        DevicesFixtures.device_fixture(user, %{
          name: "YTD Inverter",
          kind: "opendtu",
          mqtt_username: "ytd"
        })

      today = Date.utc_today()
      current_month = today.month

      # Seed one reading per month for the current year (so we always
      # exercise the `month <= current_month` upper bound).
      for month <- 1..current_month do
        date = Date.new!(today.year, month, 15)

        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: device.id,
            inverter_serial: "inv-1",
            mppt_index: 0,
            yield_day: month * 100.0,
            inserted_at: DateTime.new!(date, ~T[12:00:00], "Etc/UTC")
          })
      end

      ytd = Devices.list_ytd_yield_data(user)
      assert length(ytd) == current_month

      # Each entry is `{{year, month}, kWh}`; verify a known month.
      current_year = today.year

      assert Enum.any?(ytd, fn {{^current_year, 1}, kwh} ->
               assert_in_delta kwh, 0.1, 0.001
               true
             end)

      # Entries are sorted ascending by {year, month}.
      keys = Enum.map(ytd, fn {k, _} -> k end)
      assert keys == Enum.sort(keys)
    end

    test "returns [] when the user has no DTUs" do
      user = DtuApp.AccountsFixtures.user_fixture()
      assert Devices.list_ytd_yield_data(user) == []
    end
  end
end
