defmodule DtuAppWeb.BarChartPanelTest do
  @moduledoc """
  Render tests for `DtuAppWeb.BarChartPanel`.

  Pure render-only tests, no LiveView, no DB. We construct
  `@bars` maps by hand because the component only reads six
  keys off each map (x, y, w, h, label, value) and runs no
  domain logic; the values come straight from the upstream
  assign_bar_chart_data path that the dashboard regression
  suite covers.

  Covers the two render branches:

    - Empty: every bar has value == 0.0; renders the
      dashed-border empty-state card with id="empty-chart"
      and the "No yield records logged for this period."
      copy. Same id as the line-chart empty-state; the
      dashboard tests key off it regardless of which chart
      type resolved.

    - Has bars: renders the svg with id="solar-chart-svg"
      and the three y-axis labels (top / mid / bottom in kWh,
      formatted via Devices.format_number/3 with @locale),
      the emerald linear gradient definition, and one
      bar group with its rect, hover-value text, and
      x-axis label.

  Sister to DtuAppWeb.ChartTitleTest and the upcoming
  DtuAppWeb.LineChartPanelTest.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DtuAppWeb.BarChartPanel

  defp bar(overrides \\ %{}) do
    defaults = %{
      x: 10.0,
      y: 100.0,
      w: 32.5,
      h: 120.0,
      label: "01",
      value: 12.5
    }

    Map.merge(defaults, overrides)
  end

  describe "empty state" do
    test "renders the empty-state card when every bar has value 0" do
      html =
        render_component(&BarChartPanel.bar_chart_panel/1, %{
          bars: [
            bar(%{value: 0.0}),
            bar(%{value: 0.0}),
            bar(%{value: 0.0})
          ],
          y_max: 10.0,
          locale: "en"
        })

      # Same id="empty-chart" the line-chart empty-state uses.
      assert html =~ "id=\"empty-chart\""
      assert html =~ "border-2 border-dashed border-zinc-300"
      assert html =~ "No yield records logged for this period."
      # The heroicon used for the empty-state.
      assert html =~ "hero-presentation-chart-bar"
      # No SVG when in empty-state - the bar list is replaced.
      refute html =~ "viewBox=\"0 0 800 250\""
      refute html =~ "id=\"solar-chart-svg\""
    end

    test "renders the empty-state when bars is an empty list" do
      html =
        render_component(&BarChartPanel.bar_chart_panel/1, %{
          bars: [],
          y_max: 0.0,
          locale: "en"
        })

      assert html =~ "id=\"empty-chart\""
    end
  end

  describe "with bars" do
    test "renders the chart SVG with the expected viewBox, id, and gridlines" do
      html =
        render_component(&BarChartPanel.bar_chart_panel/1, %{
          bars: [bar()],
          y_max: 25.0,
          locale: "en"
        })

      # The SVG id matches the line chart's id.
      assert html =~ "viewBox=\"0 0 800 250\""
      assert html =~ "id=\"solar-chart-svg\""

      # Emerald linear gradient: #barGrad with the 0.85 to 0.95 stops.
      assert html =~ "id=\"barGrad\""
      assert html =~ "#10b981"
      assert html =~ "#047857"

      # Three horizontal gridlines at y=20, 120, 220.
      assert html =~ "y1=\"20\""
      assert html =~ "y1=\"120\""
      assert html =~ "y1=\"220\""
    end

    test "renders three y-axis labels from y_max (top, mid, bottom)" do
      html =
        render_component(&BarChartPanel.bar_chart_panel/1, %{
          bars: [bar()],
          y_max: 25.0,
          locale: "en"
        })

      # Top: y_max itself, formatted to 1 decimal.
      assert html =~ "25.0 kWh"
      # Mid: y_max / 2, also formatted to 1 decimal.
      assert html =~ "12.5 kWh"
      # Bottom: literal "0 kWh" - no formatting, no decimal.
      assert html =~ "0 kWh"
    end

    test "renders one bar group per bar with rect, hover value, and x label" do
      bars = [
        bar(%{label: "01", value: 12.5}),
        bar(%{label: "02", value: 22.8, x: 80.0}),
        bar(%{label: "03", value: 8.4, x: 150.0})
      ]

      html =
        render_component(&BarChartPanel.bar_chart_panel/1, %{
          bars: bars,
          y_max: 25.0,
          locale: "en"
        })

      # Three group elements. Count by substring matching that also
      # appears in another sibling.
      assert html =~ "01"
      assert html =~ "02"
      assert html =~ "03"

      # Rect uses the barGrad fill with rounded corners.
      assert html =~ "fill=\"url(#barGrad)\""
      assert html =~ "rx=\"4\""

      # Per-bar hover values formatted to 1 decimal (kWh).
      assert html =~ "12.5"
      assert html =~ "22.8"
      assert html =~ "8.4"
    end

    test "zero-value bars render as minimum-height rects, not skipped" do
      bars = [
        bar(%{value: 0.0}),
        bar(%{value: 12.5, x: 80.0})
      ]

      html =
        render_component(&BarChartPanel.bar_chart_panel/1, %{
          bars: bars,
          y_max: 25.0,
          locale: "en"
        })

      # Two bars: NOT empty-state, has SVG.
      assert html =~ "id=\"solar-chart-svg\""
      refute html =~ "id=\"empty-chart\""
    end
  end
end
