defmodule DtuAppWeb.ConsumptionStatCardsTest do
  @moduledoc """
  Render tests for `DtuAppWeb.ConsumptionStatCards`.

  Pure render-only tests — no LiveView, no DB. The
  `consumption_period_stats` map is constructed by hand because the
  component only reads six numeric / date keys off it; we don't
  need the live `Devices.Stats.ConsumptionStats.compute_*` machinery
  to exercise the render branches.

  Covers the three layout shapes the component produces:

    * **Empty** — all three gating numbers are 0; the whole row is
      suppressed (matches "user without a Shelly device sees
      nothing here").
    * **Historical** — `live=false, time_range="week"`: Total +
      Today's + Peak Power Day (with optional `on %{date}`
      sub-label).
    * **Live / Day** — `live=true`: Today's + Peak Power Consumed
      (Total slot omitted to keep the grid aligned with the
      production row above).
    * **Historical no peak date** — peak_date is nil; the
      `on %{date}` sub-label is omitted.

  Plus the per-view `id` switching on the Today's card (live vs.
  historical) and the icon-name switch on the Peak card
  (hero-chart-bar for live/day, hero-fire for historical).
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DtuAppWeb.ConsumptionStatCards

  defp stats(overrides \\ %{}) do
    defaults = %{
      current_consumption: 1_250.0,
      today_consumption: 8.4,
      peak_consumption: 3_300.0,
      period_total_consumption: 124.6,
      period_peak_consumption: 2_750.0,
      peak_date: ~D[2026-09-14]
    }

    Map.merge(defaults, overrides)
  end

  describe "empty state" do
    test "renders nothing when all three gating numbers are 0" do
      empty =
        stats(%{current_consumption: 0.0, period_total_consumption: 0.0, peak_consumption: 0.0})

      html =
        render_component(&ConsumptionStatCards.consumption_stat_cards/1, %{
          consumption_period_stats: empty
        })

      refute html =~ "Power consumption"
      refute html =~ ~s(id="stat-period-total-consumption")
      refute html =~ ~s(id="stat-today-consumption-period")
      refute html =~ ~s(id="stat-peak-consumption")
    end

    test "renders when only one of the gating numbers is positive" do
      # period_total alone — user has a Shelly that has reported a
      # historical period but no fresh current reading yet.
      only_total = stats(%{current_consumption: 0.0, peak_consumption: 0.0})

      html =
        render_component(&ConsumptionStatCards.consumption_stat_cards/1, %{
          consumption_period_stats: only_total,
          time_range: "week"
        })

      assert html =~ "Power consumption"
    end
  end

  describe "historical view (live=false, time_range != 'day')" do
    test "renders Total + Today's + Peak Power Day" do
      html =
        render_component(&ConsumptionStatCards.consumption_stat_cards/1, %{
          consumption_period_stats: stats(),
          live: false,
          time_range: "week"
        })

      assert html =~ ~s(id="stat-period-total-consumption")
      assert html =~ "Total Consumption"

      # Today's card uses the historical id when not live.
      assert html =~ ~s(id="stat-today-consumption-period-historical")
      refute html =~ ~s(id="stat-today-consumption-period")

      # Peak-power-day slot (not the live/day Peak Power Consumed).
      assert html =~ ~s(id="stat-peak-consumption-day")
      refute html =~ ~s(id="stat-peak-consumption")
      assert html =~ "Peak Power Day"

      # Peak-power-day renders the `on %{date}` sub-label when
      # `peak_date` is set.
      assert html =~ ~s(id="stat-peak-consumption-day-date")
      assert html =~ "2026-09-14"

      # Icon set swaps to hero-fire on historical peak-power-day.
      # `<.icon name="hero-…">` renders as `<span class="hero-… …">`
      # so we match the class rather than a `name=` attribute.
      assert html =~ ~s(class="hero-fire )
      refute html =~ ~s(class="hero-chart-bar )
    end

    test "omits the 'on %{date}' sub-label when peak_date is nil" do
      no_date = stats(%{peak_date: nil})

      html =
        render_component(&ConsumptionStatCards.consumption_stat_cards/1, %{
          consumption_period_stats: no_date,
          live: false,
          time_range: "month"
        })

      assert html =~ ~s(id="stat-peak-consumption-day")
      refute html =~ ~s(id="stat-peak-consumption-day-date")
    end

    test "formats kWh with 1 decimal and W with 0 decimals" do
      # 124.6 kWh (Total) and 2750 W (Peak Power Day) — confirm
      # the precision choice is preserved through render. Devices
      # `.` thousands separator + `,` decimal in de_DE, plain in en.
      html =
        render_component(&ConsumptionStatCards.consumption_stat_cards/1, %{
          consumption_period_stats: stats(),
          live: false,
          time_range: "week",
          locale: "en"
        })

      assert html =~ "124.6 kWh"
      assert html =~ "2,750 W"
    end
  end

  describe "live / day view" do
    test "omits the Total slot when live=true" do
      html =
        render_component(&ConsumptionStatCards.consumption_stat_cards/1, %{
          consumption_period_stats: stats(),
          live: true,
          time_range: "day"
        })

      # Total card is the historical-only slot; on live/day it's
      # omitted so the grid aligns with the production row above.
      refute html =~ ~s(id="stat-period-total-consumption")
      refute html =~ "Total Consumption"

      # Today's card uses the live id.
      assert html =~ ~s(id="stat-today-consumption-period")
      refute html =~ ~s(id="stat-today-consumption-period-historical")

      # Peak Power Consumed (W), not Peak Power Day.
      assert html =~ ~s(id="stat-peak-consumption")
      refute html =~ ~s(id="stat-peak-consumption-day")
      assert html =~ "Peak Power Consumed"

      # Icon set swaps to hero-chart-bar on the live/day Peak card.
      assert html =~ ~s(class="hero-chart-bar )
      refute html =~ ~s(class="hero-fire )
    end

    test "omits the Total slot when live=false but time_range == 'day'" do
      # The Total placeholder is gated on `not (@live or @time_range == "day")`.
      # Day view with live=false (a user navigated back to day but
      # paused the live updates) still treats the day view the same.
      html =
        render_component(&ConsumptionStatCards.consumption_stat_cards/1, %{
          consumption_period_stats: stats(),
          live: false,
          time_range: "day"
        })

      refute html =~ ~s(id="stat-period-total-consumption")
      assert html =~ ~s(id="stat-peak-consumption")
    end
  end

  describe "rose colour scheme" do
    test "every card uses the rose icon container" do
      html =
        render_component(&ConsumptionStatCards.consumption_stat_cards/1, %{
          consumption_period_stats: stats(),
          live: false,
          time_range: "week"
        })

      # Rose icon container — bg-rose-50 + text-rose-600 + the dark
      # mode pair. Matches the existing consumption card above the
      # production row for visual consistency.
      assert html =~ "bg-rose-50 dark:bg-rose-950/30 text-rose-600 dark:text-rose-400"
    end
  end
end
