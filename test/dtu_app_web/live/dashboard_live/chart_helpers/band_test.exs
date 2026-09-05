defmodule DtuAppWeb.Live.DashboardLive.ChartHelpers.BandTest do
  @moduledoc """
  Pins the contract for `ChartHelpers.cloud_cover_band/6` — the
  pure function that prepares per-hour cloud-cover data for the
  dashboard chart's shaded band overlay.

  Contract:

    * `readings == nil` → `[]` (the same "nil-through = no UI"
      convention `sun_markers/6` uses for users who haven't granted
      geolocation).
    * `readings == []` → `[]`.
    * When `local_date` is a `Date`, only readings whose local
      date matches are kept. This is what stops the Open-Meteo
      `past_days: 30` payload from stacking 31 translucent rects
      on top of each other at every hour on the 1D today view —
      see PR #208 follow-up.
    * Readings whose shifted local-seconds fall outside the chart's
      `[x_min_seconds, x_max_seconds]` window are dropped.
    * Each retained reading maps to a
      `%{x: float(), pct: integer(), width: float(), y: float(),
      height: float()}`: `x` is the pixel position on the 800-wide
      chart, `pct` is the cloud-cover value, `width` is the per-hour
      bucket width scaled to the chart's actual span, and `y` /
      `height` are the rect geometry mapped onto the cloud-cover
      percentage (top of chart = 100% overcast, baseline = 0% clear).
  """

  use ExUnit.Case, async: true

  alias DtuAppWeb.DashboardLive.ChartHelpers

  # Build a DateTime at a specific UTC hour, useful for fixtures.
  defp at(date, hour) do
    {:ok, naive} = NaiveDateTime.new(date, Time.new!(hour, 0, 0))
    {:ok, dt} = DateTime.from_naive(naive, "Etc/UTC")
    dt
  end

  describe "cloud_cover_band/6" do
    test "nil readings returns []" do
      assert ChartHelpers.cloud_cover_band(nil, nil, 0, 86_400, 0, 800) == []
    end

    test "empty readings returns []" do
      assert ChartHelpers.cloud_cover_band([], nil, 0, 86_400, 0, 800) == []
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

      assert [%{pct: 70}] =
               ChartHelpers.cloud_cover_band(readings, nil, x_min, x_max, 0, 800)
    end

    test "preserves pct (no transformation) for in-window readings" do
      x_min = 0
      x_max = 86_400

      readings = [
        %{time: at(~D[2026-08-30], 12), pct: 0},
        %{time: at(~D[2026-08-30], 13), pct: 50},
        %{time: at(~D[2026-08-30], 14), pct: 100}
      ]

      result = ChartHelpers.cloud_cover_band(readings, nil, x_min, x_max, 0, 800)
      assert Enum.map(result, & &1.pct) == [0, 50, 100]
    end

    test "shifts UTC times into the user's local timezone before placing them" do
      # Berlin is UTC+2. A 14:00 UTC reading shows up at 16:00
      # local, inside a 12:00–18:00 local-time window.
      x_min = 12 * 3600
      x_max = 18 * 3600

      readings = [%{time: at(~D[2026-08-30], 14), pct: 60}]

      result = ChartHelpers.cloud_cover_band(readings, nil, x_min, x_max, 2 * 3600, 800)
      assert [%{pct: 60, x: x}] = result
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

      result = ChartHelpers.cloud_cover_band(readings, nil, x_min, x_max, 0, 800)

      Enum.each(result, fn %{x: x} ->
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
      # (same hour, different date), which is exactly the
      # "huge black Blocks" stacking bug.
      readings = [
        %{time: at(~D[2026-08-30], 12), pct: 80},
        %{time: at(~D[2026-08-31], 12), pct: 20}
      ]

      today = ~D[2026-08-31]

      filtered =
        ChartHelpers.cloud_cover_band(readings, today, x_min, x_max, 0, 800)

      assert [%{pct: 20}] = filtered
    end

    test "scales width to chart span (per-hour bucket width)" do
      x_min = 0
      x_max = 86_400

      readings = [
        %{time: at(~D[2026-08-30], 0), pct: 50},
        %{time: at(~D[2026-08-30], 12), pct: 50}
      ]

      # Full-day span: 24 hours → 800 / 24 ≈ 33.33 SVG units per hour.
      full_day =
        ChartHelpers.cloud_cover_band(readings, nil, x_min, x_max, 0, 800)

      assert Enum.all?(full_day, &(&1.width == 800 * 3600.0 / 86_400))

      # 6-hour span: 800 / 6 ≈ 133.33 SVG units per hour — the band
      # must widen so it still fills the chart on narrower views.
      narrow =
        ChartHelpers.cloud_cover_band(readings, nil, 0, 6 * 3600, 0, 800)

      assert Enum.all?(narrow, &(&1.width == 800 * 3600.0 / (6 * 3600)))
    end

    test "maps cloud-cover pct to rect height (0% invisible, 100% full chart)" do
      # Cloud-cover band geometry: top of chart (y=20) = 100% overcast,
      # baseline (y=250) = 0% clear sky. Rect height grows upward from
      # the baseline in proportion to pct.
      x_min = 0
      x_max = 86_400

      readings = [
        %{time: at(~D[2026-08-30], 0), pct: 0},
        %{time: at(~D[2026-08-30], 6), pct: 25},
        %{time: at(~D[2026-08-30], 12), pct: 50},
        %{time: at(~D[2026-08-30], 18), pct: 100}
      ]

      result = ChartHelpers.cloud_cover_band(readings, nil, x_min, x_max, 0, 800)

      # Plot area height is 250 - 20 = 230 SVG units.
      assert Enum.map(result, & &1.pct) == [0, 25, 50, 100]

      assert [
               %{pct: 0, height: +0.0, y: 250.0},
               %{pct: 25, height: 57.5, y: 192.5},
               %{pct: 50, height: 115.0, y: 135.0},
               %{pct: 100, height: 230.0, y: 20.0}
             ] = result
    end

    test "y + height sums to 250 (chart baseline) for every rect" do
      # Invariant that pins the rect's bottom edge to the chart's
      # baseline regardless of pct — so the cloud band always sits
      # flush against the X axis even when partially overcast.
      x_min = 0
      x_max = 86_400

      readings = [
        %{time: at(~D[2026-08-30], 0), pct: 33},
        %{time: at(~D[2026-08-30], 12), pct: 67},
        %{time: at(~D[2026-08-30], 23), pct: 100}
      ]

      result = ChartHelpers.cloud_cover_band(readings, nil, x_min, x_max, 0, 800)

      assert Enum.all?(result, fn %{y: y, height: height} ->
               y + height == 250.0
             end)
    end
  end
end
