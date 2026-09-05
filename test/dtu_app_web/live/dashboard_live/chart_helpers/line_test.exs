defmodule DtuAppWeb.Live.DashboardLive.ChartHelpers.LineTest do
  @moduledoc """
  Pins the contract for `ChartHelpers.cloud_cover_line/6` — the
  pure function that produces the SVG path data for the dashboard
  chart's cloud-cover line overlay.

  Contract:

    * `readings == nil` → `%{path: "", has_data: false, points: [], ticks: [0, 25, 50, 75, 100]}`
      (the "nil-through = no UI" convention the chart's stat card
      uses for users who haven't granted geolocation).
    * `readings == []` → same shape as the nil case.
    * When `local_date` is a `Date`, only readings whose local
      date matches are kept. This is what stops the Open-Meteo
      `past_days: 30` payload from collapsing 31 days of hourly
      readings onto the same X for each hour on the 1D today view.
    * Readings whose shifted local-seconds fall outside the chart's
      `[x_min_seconds, x_max_seconds]` window are dropped.
    * Each retained reading produces a
      `%{x: float(), pct: integer(), y: float()}` where:
        - `x` is the pixel position on the 800-wide chart,
        - `pct` is the cloud-cover value (0–100),
        - `y = 250 - 230 * pct / 100` — chart top (y=20) = 100%
          overcast, baseline (y=250) = 0% clear sky.
    * `path` is `"M x y L x y …"` sorted by ascending X (the order
      the line draws in); empty string when there are no in-window
      points.
    * `ticks` is always `[0, 25, 50, 75, 100]` — the right-axis
      ladder the template renders as labels. The helper always
      returns them so the template can render the axis once and
      the line either on top or not at all.
  """

  use ExUnit.Case, async: true

  alias DtuAppWeb.DashboardLive.ChartHelpers

  # Build a DateTime at a specific UTC hour, useful for fixtures.
  defp at(date, hour) do
    {:ok, naive} = NaiveDateTime.new(date, Time.new!(hour, 0, 0))
    {:ok, dt} = DateTime.from_naive(naive, "Etc/UTC")
    dt
  end

  describe "cloud_cover_line/6" do
    test "nil readings returns has_data=false with empty path and default ticks" do
      result = ChartHelpers.cloud_cover_line(nil, nil, 0, 86_400, 0, 800)
      assert result.path == ""
      assert result.has_data == false
      assert result.points == []
      assert result.ticks == [0, 25, 50, 75, 100]
    end

    test "empty readings returns has_data=false with empty path" do
      result = ChartHelpers.cloud_cover_line([], nil, 0, 86_400, 0, 800)
      assert result.path == ""
      assert result.has_data == false
      assert result.points == []
    end

    test "always returns the right-axis tick ladder [0, 25, 50, 75, 100]" do
      # Invariant the template relies on: even when no readings
      # are in window, the right-axis labels still render. The
      # helper returns the same ticks whether or not the line has
      # data so the template can branch once on has_data.
      nil_result = ChartHelpers.cloud_cover_line(nil, nil, 0, 86_400, 0, 800)
      assert nil_result.ticks == [0, 25, 50, 75, 100]

      populated =
        ChartHelpers.cloud_cover_line(
          [%{time: at(~D[2026-08-30], 12), pct: 50}],
          nil,
          0,
          86_400,
          0,
          800
        )

      assert populated.ticks == [0, 25, 50, 75, 100]
    end

    test "drop readings whose local-seconds fall outside the chart window" do
      # x range is [06:00, 18:00] in seconds-from-midnight:
      x_min = 6 * 3600
      x_max = 18 * 3600

      readings = [
        # before window
        %{time: at(~D[2026-08-30], 3), pct: 50},
        # inside
        %{time: at(~D[2026-08-30], 12), pct: 70},
        # after window
        %{time: at(~D[2026-08-30], 21), pct: 90}
      ]

      result = ChartHelpers.cloud_cover_line(readings, nil, x_min, x_max, 0, 800)
      assert [%{pct: 70}] = result.points
    end

    test "preserves pct (no transformation) for in-window readings" do
      x_min = 0
      x_max = 86_400

      readings = [
        %{time: at(~D[2026-08-30], 12), pct: 0},
        %{time: at(~D[2026-08-30], 13), pct: 50},
        %{time: at(~D[2026-08-30], 14), pct: 100}
      ]

      result = ChartHelpers.cloud_cover_line(readings, nil, x_min, x_max, 0, 800)
      assert Enum.map(result.points, & &1.pct) == [0, 50, 100]
    end

    test "shifts UTC times into the user's local timezone before placing them" do
      # Berlin is UTC+2. A 14:00 UTC reading shows up at 16:00
      # local, inside a 12:00–18:00 local-time window.
      x_min = 12 * 3600
      x_max = 18 * 3600

      readings = [%{time: at(~D[2026-08-30], 14), pct: 60}]

      result =
        ChartHelpers.cloud_cover_line(readings, nil, x_min, x_max, 2 * 3600, 800)

      assert [%{pct: 60, x: x}] = result.points
      # 14:00 UTC + 2h = 16:00 local seconds = 57600. Window is
      # [43200, 64800] (span 21600). Pixel X = (57600 - 43200) /
      # 21600 * 800 = 533.3.
      assert x == 533.3
    end

    test "returns pixel X in [0, 800] for in-window readings" do
      x_min = 0
      x_max = 86_400

      readings = [
        %{time: at(~D[2026-08-30], 0), pct: 50},
        %{time: at(~D[2026-08-30], 12), pct: 50},
        %{time: at(~D[2026-08-30], 23), pct: 50}
      ]

      result = ChartHelpers.cloud_cover_line(readings, nil, x_min, x_max, 0, 800)

      Enum.each(result.points, fn %{x: x} ->
        assert is_float(x)
        assert x >= 0.0 and x <= 800.0
      end)
    end

    test "filters to local_date when supplied (no past_days stacking)" do
      x_min = 0
      x_max = 86_400

      # Two days' worth of the same 12:00 UTC reading. With
      # local_date scoping, only today's entry survives; without
      # the filter (local_date == nil) both project to x = 400
      # (same hour, different date), which would collapse the
      # line onto itself for past_days=30 payloads on the 1D view.
      readings = [
        %{time: at(~D[2026-08-30], 12), pct: 80},
        %{time: at(~D[2026-08-31], 12), pct: 20}
      ]

      today = ~D[2026-08-31]

      filtered =
        ChartHelpers.cloud_cover_line(readings, today, x_min, x_max, 0, 800)

      assert [%{pct: 20}] = filtered.points
    end

    test "maps cloud-cover pct to y in the 20..250 range" do
      # Y axis: chart top (y=20) = 100% overcast, baseline
      # (y=250) = 0% clear sky. y = 250 - 230 * pct/100.
      x_min = 0
      x_max = 86_400

      readings = [
        %{time: at(~D[2026-08-30], 0), pct: 0},
        %{time: at(~D[2026-08-30], 6), pct: 25},
        %{time: at(~D[2026-08-30], 12), pct: 50},
        %{time: at(~D[2026-08-30], 18), pct: 100}
      ]

      result = ChartHelpers.cloud_cover_line(readings, nil, x_min, x_max, 0, 800)

      assert Enum.map(result.points, & &1.pct) == [0, 25, 50, 100]

      assert [
               %{pct: 0, y: 250.0},
               %{pct: 25, y: 192.5},
               %{pct: 50, y: 135.0},
               %{pct: 100, y: 20.0}
             ] = result.points
    end

    test "points are sorted by ascending X (the order the path draws in)" do
      # Even when callers hand us readings out of order, the
      # line must connect them chronologically — otherwise the
      # SVG polyline would backtrack across the chart.
      x_min = 0
      x_max = 86_400

      readings = [
        %{time: at(~D[2026-08-30], 18), pct: 100},
        %{time: at(~D[2026-08-30], 6), pct: 25},
        %{time: at(~D[2026-08-30], 12), pct: 50}
      ]

      result = ChartHelpers.cloud_cover_line(readings, nil, x_min, x_max, 0, 800)

      xs = Enum.map(result.points, & &1.x)
      assert xs == Enum.sort(xs)
    end

    test "path is \"M x y L x y ...\" starting with M and chaining L commands" do
      x_min = 0
      x_max = 86_400

      readings = [
        %{time: at(~D[2026-08-30], 0), pct: 0},
        %{time: at(~D[2026-08-30], 12), pct: 50},
        %{time: at(~D[2026-08-30], 23), pct: 100}
      ]

      result = ChartHelpers.cloud_cover_line(readings, nil, x_min, x_max, 0, 800)

      assert result.has_data == true
      # SVG path shape: starts with M, then one or more L commands.
      assert String.starts_with?(result.path, "M ")
      assert length(String.split(result.path, " L ")) == 3
    end

    test "path is empty string when no readings fall in window" do
      # Narrow window: only 12:00–13:00 is visible. Both readings
      # sit at 06:00 and 21:00 UTC, so every project_x/6 call
      # returns nil and the for-comprehension drops them.
      x_min = 12 * 3600
      x_max = 13 * 3600

      readings = [
        %{time: at(~D[2026-08-30], 6), pct: 50},
        %{time: at(~D[2026-08-30], 21), pct: 50}
      ]

      result = ChartHelpers.cloud_cover_line(readings, nil, x_min, x_max, 0, 800)

      assert result.path == ""
      assert result.has_data == false
      assert result.points == []
    end
  end
end
