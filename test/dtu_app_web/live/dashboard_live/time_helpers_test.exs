defmodule DtuAppWeb.DashboardLive.TimeHelpersTest do
  @moduledoc """
  Unit tests for the pure date/time helpers extracted from
  `DtuAppWeb.DashboardLive`. Every function in `TimeHelpers` is
  pure, so the tests pin their behaviour without spinning up a
  LiveView, seeding the DB, or mocking time.

  `local_today/1` uses `DtuApp.Time.utc_now/0`, so its output
  isn't deterministic. We exercise the time-shift math instead
  by constructing `DateTime`s directly (the function's logic
  is just `now + tz_offset → Date`, which the helper's spec
  documents).
  """

  use ExUnit.Case, async: true

  alias DtuAppWeb.DashboardLive.TimeHelpers

  # Helper to build a UTC `DateTime` for tests. We always use
  # 1970-01-01 as the base date — the helper only reads
  # `hour/minute/second` for the time-shift math.
  defp utc(hour, minute, second) do
    {:ok, dt} = DateTime.new(~D[1970-01-01], Time.new!(hour, minute, second))
    dt
  end

  describe "format_peak_time/2" do
    test "nil → em-dash placeholder" do
      assert TimeHelpers.format_peak_time(nil, 0) == "—"
      assert TimeHelpers.format_peak_time(nil, 7200) == "—"
    end

    test "no tz offset → UTC HH:MM" do
      assert TimeHelpers.format_peak_time(utc(13, 42, 0), 0) == "13:42"
      assert TimeHelpers.format_peak_time(utc(0, 5, 30), 0) == "00:05"
    end

    test "positive tz offset (east of UTC) shifts later" do
      # CEST = UTC+2: 13:42 UTC → 15:42 local.
      assert TimeHelpers.format_peak_time(utc(13, 42, 0), 7200) == "15:42"
    end

    test "negative tz offset (west of UTC) shifts earlier" do
      # EST = UTC-5: 13:42 UTC → 08:42 local.
      assert TimeHelpers.format_peak_time(utc(13, 42, 0), -18_000) == "08:42"
    end

    test "wrap-around past midnight forward (UTC+10: 23:30 UTC → 09:30 next day)" do
      # 23:30 + 10h = 33:30 → wraps to 09:30.
      assert TimeHelpers.format_peak_time(utc(23, 30, 0), 36_000) == "09:30"
    end

    test "wrap-around past midnight backward (UTC-10: 01:30 UTC → 15:30 prev day)" do
      # 01:30 - 10h = -08:30 → wraps to 15:30.
      assert TimeHelpers.format_peak_time(utc(1, 30, 0), -36_000) == "15:30"
    end

    test "single-digit hours pad to two digits" do
      # 09:05, not "9:5".
      assert TimeHelpers.format_peak_time(utc(9, 5, 0), 0) == "09:05"
    end
  end

  describe "format_time_hhmm/1" do
    test "two-digit pad for hour and minute" do
      assert TimeHelpers.format_time_hhmm(utc(7, 3, 0)) == "07:03"
      assert TimeHelpers.format_time_hhmm(utc(23, 59, 59)) == "23:59"
    end
  end

  describe "utc_day_range_for_local_date/2" do
    test "Berlin local day 2026-06-21 maps to the matching UTC window" do
      # Berlin = UTC+2 in summer. Local 00:00 → UTC 22:00 (prev day).
      # Local 23:59:59 → UTC 21:59:59 (same day).
      {start_utc, end_utc} =
        TimeHelpers.utc_day_range_for_local_date(~D[2026-06-21], 7200)

      assert start_utc == ~U[2026-06-20 22:00:00Z]
      assert end_utc == ~U[2026-06-21 21:59:59Z]
    end

    test "New York local day 2026-06-21 maps to the matching UTC window" do
      # New York = UTC-4 in summer. Local 00:00 → UTC 04:00 (same day).
      # Local 23:59:59 → UTC 03:59:59 (next day).
      {start_utc, end_utc} =
        TimeHelpers.utc_day_range_for_local_date(~D[2026-06-21], -14_400)

      assert start_utc == ~U[2026-06-21 04:00:00Z]
      assert end_utc == ~U[2026-06-22 03:59:59Z]
    end

    test "UTC local day maps identically (no shift)" do
      {start_utc, end_utc} =
        TimeHelpers.utc_day_range_for_local_date(~D[2026-06-21], 0)

      assert start_utc == ~U[2026-06-21 00:00:00Z]
      assert end_utc == ~U[2026-06-21 23:59:59Z]
    end
  end
end
