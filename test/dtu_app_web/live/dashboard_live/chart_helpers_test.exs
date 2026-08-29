defmodule DtuAppWeb.DashboardLive.ChartHelpersTest do
  @moduledoc """
  Unit tests for the pure-math helpers extracted from
  `DtuAppWeb.DashboardLive`. Every function in `ChartHelpers` is pure,
  so the tests pin coordinates / ranges / labels without spinning up
  a LiveView or seeding the DB.
  """

  use ExUnit.Case, async: true

  alias DtuAppWeb.DashboardLive.ChartHelpers

  describe "now_marker_x/4" do
    # Helper to build a UTC `DateTime` for the injected `now` argument.
    # The function only reads `hour/minute/second`, so the date is
    # irrelevant — we pick 1970-01-01 to make that explicit.
    defp utc(hour, minute, second) do
      {:ok, dt} = DateTime.new(~D[1970-01-01], Time.new!(hour, minute, second))
      dt
    end

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
end
