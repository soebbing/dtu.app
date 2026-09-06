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

    test "path is \"M x y C ... C ...\" — smoothed cubic-Bezier through every point" do
      x_min = 0
      x_max = 86_400

      readings = [
        %{time: at(~D[2026-08-30], 0), pct: 0},
        %{time: at(~D[2026-08-30], 12), pct: 50},
        %{time: at(~D[2026-08-30], 23), pct: 100}
      ]

      result = ChartHelpers.cloud_cover_line(readings, nil, x_min, x_max, 0, 800)

      assert result.has_data == true
      # SVG path shape: starts with M, then chained cubic-Bezier
      # segments. Three readings → one C segment per pair, so two
      # C segments (the curve from point 0→1 and 1→2). Each segment
      # has the form "C cp1x cp1y, cp2x cp2y, x y" — two control
      # points + the destination anchor.
      assert String.starts_with?(result.path, "M ")
      assert length(String.split(result.path, " C ")) == 3
      # Both segments end at one of our three input points: the
      # first segment's anchor is the middle reading's (x, y), the
      # second segment's anchor is the last reading's (x, y).
      [_, c1, c2] = String.split(result.path, " C ", parts: 3)

      assert String.ends_with?(
               c1,
               ", #{Enum.at(result.points, 1).x} #{Enum.at(result.points, 1).y}"
             )

      assert String.ends_with?(
               c2,
               ", #{Enum.at(result.points, 2).x} #{Enum.at(result.points, 2).y}"
             )
    end

    test "two-point path falls back to plain M…L segment (no smoothing math from two anchors alone)" do
      x_min = 0
      x_max = 86_400

      readings = [
        %{time: at(~D[2026-08-30], 6), pct: 25},
        %{time: at(~D[2026-08-30], 18), pct: 75}
      ]

      result = ChartHelpers.cloud_cover_line(readings, nil, x_min, x_max, 0, 800)

      assert result.has_data == true
      # Two points can't produce a Catmull-Rom curve (no neighbouring
      # anchors to derive control points from), so the helper falls
      # back to a single straight segment. Still useful visually.
      assert String.starts_with?(result.path, "M ")
      assert result.path =~ ~r/ L [\d.]+ [\d.]+$/
      refute result.path =~ ~r/ C /
    end

    test "area_path closes the smoothed line down to the chart bottom and back" do
      x_min = 0
      _x_max = 86_400

      readings = [
        %{time: at(~D[2026-08-30], 0), pct: 0},
        %{time: at(~D[2026-08-30], 12), pct: 50},
        %{time: at(~D[2026-08-30], 23), pct: 100}
      ]

      result = ChartHelpers.cloud_cover_line(readings, nil, x_min, 86_400, 0, 800)

      assert result.has_data == true

      first = List.first(result.points)
      last = List.last(result.points)

      # The area path starts with the same M anchor as the line, ends
      # with Z (closed shape), and contains two L commands that drop
      # down to the chart bottom (y=250) at the line's last/first X.
      assert String.starts_with?(result.area_path, "M ")
      assert String.ends_with?(result.area_path, " Z")

      # The closing segment must drop to y=250 at the line's last
      # point's X, then travel across to the line's first point's X,
      # then Z. Float formatting goes through `ChartHelpers.fmt/1`
      # (two-decimal fixed width) so the tail is stable.
      closing =
        " L #{:erlang.float_to_binary(last.x, decimals: 2)} 250.00 L #{:erlang.float_to_binary(first.x, decimals: 2)} 250.00 Z"

      assert String.ends_with?(result.area_path, closing)
    end

    test "area_path is empty when only one reading falls in window" do
      x_min = 0
      x_max = 86_400

      readings = [%{time: at(~D[2026-08-30], 12), pct: 50}]

      result = ChartHelpers.cloud_cover_line(readings, nil, x_min, x_max, 0, 800)

      # A 1-vertex "area" is a degenerate point — no fill region
      # exists. The line path is also empty (nothing to draw with
      # one anchor); has_data stays true so the placeholder doesn't
      # render and neither does the path/area fill.
      assert result.area_path == ""
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

    test "no control-point Y falls outside the chart's [20, 250] range" do
      # Regression for the Catmull-Rom overshoot: a 0% reading
      # followed by a 25% reading produces a control point whose
      # raw Y is below 250 (i.e. past the chart baseline, "negative
      # coverage"). The curve was visibly dipping under the chart
      # bottom edge on segments climbing out of 0%. The fix clamps
      # CP1.y and CP2.y to the segment's Y range — a cubic Bezier
      # lies within the convex hull of its 4 control points, so the
      # entire curve stays inside the chart.
      x_min = 0
      x_max = 86_400

      # Alternating 0/25/50/75/100 readings — the same shape the
      # Open-Meteo stub fixture uses in dashboard_live_test.exs.
      readings =
        Enum.map(0..23, fn hour ->
          pct = rem(hour, 4) * 25
          %{time: at(~D[2026-08-30], hour), pct: pct}
        end)

      result = ChartHelpers.cloud_cover_line(readings, nil, x_min, x_max, 0, 800)

      assert result.has_data == true
      assert length(result.points) == 24

      # Pull every Y from the rendered path string. Tokens are
      # `M x y` then `C x y x y x y` per segment, so the sequence
      # is X₀ Y₀ X₁ Y₁ X₂ Y₂ X₃ Y₃ … (alternating, with the
      # M/C command letters excluded by the split regex).
      ys =
        result.path
        |> String.split(~r/[\s,MC]+/, trim: true)
        |> Enum.drop_every(2)

      Enum.each(ys, fn y_str ->
        y = String.to_float(y_str)

        assert y >= 20.0 and y <= 250.0,
               "Control point or anchor Y (#{y}) must stay inside the chart's [20, 250] range — got path: #{result.path}"
      end)
    end
  end
end
