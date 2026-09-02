defmodule DtuAppWeb.DashboardLive.ChartHelpersTest do
  @moduledoc """
  Unit tests for the pure-math helpers extracted from
  `DtuAppWeb.DashboardLive`. Every function in `ChartHelpers` is pure,
  so the tests pin coordinates / ranges / labels without spinning up
  a LiveView or seeding the DB.
  """

  use ExUnit.Case, async: true

  alias DtuAppWeb.DashboardLive.ChartHelpers

  # Helper to build a UTC `DateTime` for the injected `now` argument.
  # The `now_marker_x/4` + `now_marker_label/2` helpers only read
  # `hour/minute/second`, so the date is irrelevant — we pick
  # 1970-01-01 to make that explicit. Module-level so both describe
  # blocks can share it (an inner defp would shadow any earlier one).
  defp utc(hour, minute, second) do
    {:ok, dt} = DateTime.new(~D[1970-01-01], Time.new!(hour, minute, second))
    dt
  end

  # Same idea but pinned to *today*'s date — SunCalc's polar
  # detection reads the date component, so the sun-expansion tests
  # need a real calendar date rather than 1970-01-01. `utc/3` above
  # is left unchanged because the now-marker tests don't care.
  defp utc_at_today(hour, minute, second) do
    {:ok, dt} = DateTime.new(Date.utc_today(), Time.new!(hour, minute, second))
    dt
  end

  describe "now_marker_x/4" do
    test "mid-day on a 24-hour chart lands in the middle of the canvas" do
      # Range 00:00–24:00, now 12:00, no tz offset → 50% → x = 400.
      assert ChartHelpers.now_marker_x(0, 86_400, 0, utc(12, 0, 0)) == 400.0
    end

    test "half hour lands at 52.08% (formatted to 1 dp → 416.7)" do
      # Range 00:00–24:00, now 12:30 → 0.520833 → 416.666… rounded to 416.7.
      assert ChartHelpers.now_marker_x(0, 86_400, 0, utc(12, 30, 0)) == 416.7
    end

    test "tz offset inverts the position the user perceives as 'now'" do
      # A user at UTC+1: 12:00 UTC is 13:00 local → 13/24 = 0.5416…
      assert ChartHelpers.now_marker_x(0, 86_400, 3600, utc(12, 0, 0)) == 433.3
    end

    test "tz offset wraps midnight backwards so 23:30 UTC + 01:00 → 00:30 local" do
      # 23:30 UTC + 1h = 24:30 → mod 86400 = 30 minutes = 0.5 hours.
      # 0.5 / 24 = 0.0208… → x = 16.666… → 16.7
      assert ChartHelpers.now_marker_x(0, 86_400, 3600, utc(23, 30, 0)) == 16.7
    end

    test "now before the chart's left edge returns nil" do
      # Range 06:00–22:00, now 04:00 → out of range, no line drawn.
      assert ChartHelpers.now_marker_x(6 * 3600, 22 * 3600, 0, utc(4, 0, 0)) == nil
    end

    test "now after the chart's right edge returns nil" do
      # Range 06:00–22:00, now 23:30 → out of range, no line drawn.
      assert ChartHelpers.now_marker_x(6 * 3600, 22 * 3600, 0, utc(23, 30, 0)) == nil
    end

    test "now exactly at the left edge returns x=0" do
      # Range 06:00–24:00, now 06:00 → 0% → 0.0
      assert ChartHelpers.now_marker_x(6 * 3600, 24 * 3600, 0, utc(6, 0, 0)) == 0.0
    end

    test "now exactly at the right edge returns x=800" do
      # Range 00:00–24:00, now 23:59:59 → ~99.999… → ~800.0
      # We use exactly 24:00 for a clean 1.0 → 800.0
      # (24:00 is technically 24h which mod 86400 = 0, so we test 23:59:59)
      assert ChartHelpers.now_marker_x(0, 86_400, 0, utc(23, 59, 59)) == 800.0
    end

    test "zoomed chart (4h window) maps 2h in to 50%" do
      # Range 10:00–14:00, now 12:00 → 50% → 400.0
      assert ChartHelpers.now_marker_x(10 * 3600, 14 * 3600, 0, utc(12, 0, 0)) == 400.0
    end

    test "tz offset shifts now into range when raw UTC time is outside" do
      # Range 08:00–20:00 in user's local time, user is UTC+5.
      # now = 05:00 UTC = 10:00 local → 2h into a 12h window = 16.7%.
      # 2/12 = 0.1666… → 133.333… → 133.3
      assert ChartHelpers.now_marker_x(8 * 3600, 20 * 3600, 5 * 3600, utc(5, 0, 0)) == 133.3
    end
  end

  describe "now_marker_label/2" do
    test "mid-afternoon UTC renders as 24-hour HH:MM" do
      assert ChartHelpers.now_marker_label(0, utc(14, 32, 0)) == "14:32"
    end

    test "single-digit hour is zero-padded to 2 digits" do
      assert ChartHelpers.now_marker_label(0, utc(5, 7, 0)) == "05:07"
    end

    test "tz offset shifts the label to local time" do
      # 12:00 UTC + 1h = 13:00 local.
      assert ChartHelpers.now_marker_label(3600, utc(12, 0, 0)) == "13:00"
    end

    test "tz offset wrapping past midnight renders as the next-day local time" do
      # 23:30 UTC + 1h = 24:30 → mod 86400 = 0:30 next day → "00:30".
      assert ChartHelpers.now_marker_label(3600, utc(23, 30, 0)) == "00:30"
    end

    test "negative tz offset shifts the label earlier" do
      # 06:00 UTC + (-5h) = 01:00 local.
      assert ChartHelpers.now_marker_label(-5 * 3600, utc(6, 0, 0)) == "01:00"
    end

    test "exactly midnight renders as 00:00" do
      assert ChartHelpers.now_marker_label(0, utc(0, 0, 0)) == "00:00"
    end
  end

  describe "sun_markers/6" do
    # Berlin coords. We use the live `SunCalc` rather than fixed
    # times so this test doesn't go stale when the algorithm is
    # tweaked — the integration is what matters, not pinning the
    # more-than-minute-precision output of SunCalc itself (which
    # has its own test suite with ±10min tolerance).
    @berlin_lat 52.520_008
    @berlin_lon 13.404_954

    test "Berlin on the summer solstice (CEST = UTC+2)" do
      # Sunrise ≈ 04:43 local = 02:43 UTC, sunset ≈ 21:33 local = 19:33 UTC.
      # The helper operates in LOCAL seconds; with tz_offset = 7200
      # sunrise local is 4*3600 + 43*60 ≈ 16_980s, sunset local ≈ 77_580s.
      # On a full-day chart (00:00–24:00 in local seconds, span 86_400):
      # sunrise_x ≈ 16980/86400 * 800 ≈ 157.2
      # sunset_x  ≈ 77580/86400 * 800 ≈ 718.3
      assert {sr, ss, sr_label, ss_label} =
               ChartHelpers.sun_markers(@berlin_lat, @berlin_lon, ~D[2026-06-21], 0, 86_400, 7200)

      assert is_float(sr) and sr > 150.0 and sr < 170.0
      assert is_float(ss) and ss > 710.0 and ss < 730.0
      # Labels are local HH:MM strings — Berlin summer is CEST = UTC+2,
      # so sunrise local is 04:43, sunset local is 21:33.
      assert sr_label =~ ~r/^0[4-5]:\d\d$/
      assert ss_label =~ ~r/^2[1-2]:\d\d$/
    end

    test "Berlin on the winter solstice (CET = UTC+1)" do
      # Sunrise ≈ 08:15 local = 07:15 UTC, sunset ≈ 15:54 local = 14:54 UTC.
      # Local seconds (tz = 3600): sunrise 8*3600 + 15*60 ≈ 29_700s,
      # sunset 15*3600 + 54*60 ≈ 56_040s.
      # sunrise_x ≈ 29700/86400 * 800 ≈ 275.0
      # sunset_x  ≈ 56040/86400 * 800 ≈ 518.9
      assert {sr, ss, sr_label, ss_label} =
               ChartHelpers.sun_markers(@berlin_lat, @berlin_lon, ~D[2026-12-21], 0, 86_400, 3600)

      assert is_float(sr) and sr > 265.0 and sr < 285.0
      assert is_float(ss) and ss > 520.0 and ss < 540.0
      # Berlin winter is CET = UTC+1, so sunrise local is 08:15,
      # sunset local is 15:54.
      assert sr_label =~ ~r/^0[78]:\d\d$/
      assert ss_label =~ ~r/^15:\d\d$/
    end

    test "nil coords → all nils" do
      assert {nil, nil, nil, nil} =
               ChartHelpers.sun_markers(nil, 13.4, ~D[2026-06-21], 0, 86_400, 7200)

      assert {nil, nil, nil, nil} =
               ChartHelpers.sun_markers(52.5, nil, ~D[2026-06-21], 0, 86_400, 7200)
    end

    test "out-of-window marker returns nil for that event (X + label together)" do
      # Zoomed chart: 10:00–14:00 local. On the winter solstice in
      # Berlin, sunrise is ~08:15 (BEFORE 10:00, so sunrise_x = nil)
      # and sunset is ~15:54 (AFTER 14:00, so sunset_x = nil).
      assert {sr, ss, sr_label, ss_label} =
               ChartHelpers.sun_markers(
                 @berlin_lat,
                 @berlin_lon,
                 ~D[2026-12-21],
                 10 * 3600,
                 14 * 3600,
                 3600
               )

      assert sr == nil and ss == nil
      assert sr_label == nil and ss_label == nil
    end

    test "in-window marker at right edge of chart returns x≈800" do
      # Berlin winter sunset is 15:54 local; on a 06:00–16:00 chart
      # it's near the right edge. Sunset_local_seconds ≈ 57_240.
      # x ≈ (57240 - 21600) / 36000 * 800 ≈ 793.0
      assert {_sr, ss, _sr_label, _ss_label} =
               ChartHelpers.sun_markers(
                 @berlin_lat,
                 @berlin_lon,
                 ~D[2026-12-21],
                 6 * 3600,
                 16 * 3600,
                 3600
               )

      assert is_float(ss) and ss > 780.0 and ss < 810.0
    end
  end

  describe "chart_time_range/5" do
    # Two-arg backward-compat: existing callers (and tests that
    # haven't been updated to thread coords through) still get the
    # data-driven window. Pinning this prevents accidental
    # regressions of the contract every other dashboard test
    # depends on.
    test "two-arg form returns the data-driven window unchanged" do
      # One reading at 09:00, one at 18:30 — window rounds to
      # [09:00, 19:00] = [32400, 68400].
      points = [
        %{time: utc_at_today(9, 0, 0)},
        %{time: utc_at_today(18, 30, 0)}
      ]

      assert ChartHelpers.chart_time_range(points, 0) == {32_400, 68_400}
    end

    # The sun-expansion path is what the today-branch dashboard
    # relies on for showing both sunrise AND sunset markers even
    # when the data arc starts after sunrise (which is the common
    # case for a user whose first reading is at 08:00 local — the
    # 06:25 sunrise would otherwise fall outside the window and
    # the sunrise marker wouldn't render).
    test "with Berlin coords + date, window expands to cover sunrise + sunset" do
      # Berlin Sep 2: sunrise ≈ 04:25 UTC, sunset ≈ 18:53 UTC.
      # Data arc: 08:00 UTC → 19:00 UTC. Pre-fix data-driven window
      # is [08:00, 20:00] = [28800, 72000]. Post-fix with coords the
      # window widens to [sunrise - 30m, max(end, sunset + 1h)] =
      # [03:55, 20:00] = [14100, 72000].
      points = [
        %{time: utc_at_today(8, 0, 0)},
        %{time: utc_at_today(19, 0, 0)}
      ]

      {x_min, x_max} =
        ChartHelpers.chart_time_range(
          points,
          0,
          52.520_008,
          13.404_954,
          ~D[2026-09-02]
        )

      # xMin must shift earlier than 08:00 to cover sunrise.
      assert x_min < 28_800,
             "Window xMin (#{x_min}) must shift earlier than the data start (28_800) to include sunrise"

      # xMin must be at most 30 minutes before the actual sunrise.
      # Sunrise UTC ~04:25 → 4*3600 + 25*60 = 15_900. 30 min before
      # = 14_100. We allow a ±10 min SunCalc tolerance.
      assert x_min >= 12_600 and x_min <= 15_900,
             "Window xMin (#{x_min}) must sit within 30min-pre-sunrise window"

      # xMax stays at 20:00 because data end (19:00) is after
      # sunset (~18:53) — sunset + 1h ≈ 19:53 < 20:00, so the
      # data-driven window is already wide enough.
      assert x_max == 72_000
    end

    test "with coords but nil date_local, window is NOT expanded" do
      # Defensive: nil date → can't compute sun events → fall back
      # to the data-driven window unchanged. (In production the
      # dashboard always threads `local_date` through, so this
      # branch only fires in tests that construct the args manually.)
      points = [
        %{time: utc_at_today(8, 0, 0)},
        %{time: utc_at_today(19, 0, 0)}
      ]

      assert ChartHelpers.chart_time_range(points, 0, 52.52, 13.41, nil) ==
               {28_800, 72_000}
    end

    test "with nil latitude (user hasn't granted location), window is NOT expanded" do
      points = [
        %{time: utc_at_today(8, 0, 0)},
        %{time: utc_at_today(19, 0, 0)}
      ]

      assert ChartHelpers.chart_time_range(points, 0, nil, 13.41, ~D[2026-09-02]) ==
               {28_800, 72_000}
    end

    test "with nil longitude, window is NOT expanded" do
      points = [
        %{time: utc_at_today(8, 0, 0)},
        %{time: utc_at_today(19, 0, 0)}
      ]

      assert ChartHelpers.chart_time_range(points, 0, 52.52, nil, ~D[2026-09-02]) ==
               {28_800, 72_000}
    end

    test "polar night (sun never rises) does not expand xMin" do
      # South Pole on Jun 21: SunCalc returns {nil, ~U[2026-06-21 00:00:00Z]}
      # (nil sunrise = "sun never rises", sunset sentinel =
      # "previous day midnight UTC"). Sunset at midnight UTC maps
      # to local_seconds = 0 → xMax = max(72_000, min(0 + 3600,
      # 86_400)) = 72_000 (unchanged). xMin stays at the data start
      # because sunrise is nil.
      #
      # This pins the contract that a nil SunCalc event must NOT
      # shift the corresponding edge — SunCalc's polar logic has
      # its own tests, so we only verify OUR wrapper's robustness
      # to nil, not the exact lat threshold.
      points = [
        %{time: utc_at_today(8, 0, 0)},
        %{time: utc_at_today(19, 0, 0)}
      ]

      assert ChartHelpers.chart_time_range(points, 0, -89.9, 0.0, ~D[2026-06-21]) ==
               {28_800, 72_000}
    end

    test "empty points with coords still returns full day" do
      # The early-return clause must run BEFORE the sun expansion —
      # otherwise we'd waste a SunCalc round-trip just to return
      # the same {0, 86400} the original code already returned.
      assert ChartHelpers.chart_time_range([], 0, 52.52, 13.41, ~D[2026-09-02]) ==
               {0, 86_400}
    end
  end
end
