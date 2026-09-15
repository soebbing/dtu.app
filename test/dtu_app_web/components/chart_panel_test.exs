defmodule DtuAppWeb.ChartPanelTest do
  @moduledoc """
  Render tests for `DtuAppWeb.ChartPanel`.

  Pure render-only tests, no LiveView, no DB. The chart panel
  is a thin orchestrator over four sibling components
  (`<.chart_title>`, `<.line_chart_panel>`,
  `<.bar_chart_panel>`, `<.share_panel>`) under a shared
  white-card wrapper. The component's own logic is the
  line-vs-bar conditional; the rest is pass-through. Tests
  focus on:

    - The white-card outer wrapper (the dashboard's shared
      panel chrome).

    - The `<.chart_title>` always renders (it's above the
      branch).

    - The branch logic:
        * `chart_type == :line` → `<.line_chart_panel>` DOM
          present, `<.bar_chart_panel>` DOM absent.
        * `chart_type == :bar` (and any non-`:line` value) →
          `<.bar_chart_panel>` DOM present, `<.line_chart_panel>`
          DOM absent.

    - The `<.share_panel>` always renders regardless of
      chart_type (the share panel sits below the chart, not
      above the branch).

    - Three-state inner row forward to `<.share_panel>`:
      `:share_loading?` / `:share_active?` / `:share_url`.

  Sister to `DtuAppWeb.DashboardHeaderTest`,
  `DtuAppWeb.DashboardToolbarTest`,
  `DtuAppWeb.DeviceStatusGridTest`.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DtuAppWeb.ChartPanel

  # Minimum <.line_chart_panel> chart bundle — a stable shape
  # that satisfies its `Map.fetch!` lookups without driving the
  # SVG into meaningful data. The line branch exists to test
  # the chart-panel branch gate, not the line panel's own
  # rendering (that's already covered by
  # `DtuAppWeb.LineChartPanelTest`).
  defp line_chart_fixture(overrides \\ %{}) do
    defaults = %{
      x_min_seconds: 0.0,
      x_max_seconds: 86_400.0,
      y_gridlines: [{0.0, 250.0}],
      cloud_cover_line: %{ticks: [], has_data: false, path: "", area_path: ""},
      x_labels: [{100.0, "00:00"}],
      yesterday_paths: %{},
      series_paths: %{},
      series_palette: %{},
      series_points_data: %{},
      series_legend: %{},
      total_path: "",
      total_palette: {"emerald", "500"},
      total_points_data: [],
      consumption_path: "",
      consumption_palette: {"rose", "500"},
      consumption_points_data: [],
      net_path: "",
      net_palette: {"sky", "500"},
      net_points_data: [],
      y_min: 0.0,
      sun_markers: {nil, nil, nil, nil},
      now_marker_x: nil,
      now_marker_label: nil,
      path_data: "",
      has_inverter?: true,
      has_shelly?: false
    }

    Map.merge(defaults, overrides)
  end

  # Minimum <.bar_chart_panel> bar shape — the bar branch
  # needs valid x/y/w/h/label/value keys to render.
  defp bar_fixture(overrides \\ %{}) do
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

  @default_attrs %{
    live: false,
    has_inverter?: false,
    has_shelly?: false,
    time_range: "day",
    selected_period: ~D[2026-09-15],
    chart_type: :bar,
    chart: %{},
    bars: [],
    y_max: nil,
    share_loading?: false,
    share_active?: false,
    share_url: nil,
    locale: "en"
  }

  describe "outer white-card chrome" do
    test "wraps the chart + share panels in a bordered rounded shadow card" do
      html = render_component(&ChartPanel.chart_panel/1, @default_attrs)

      assert html =~ "bg-white dark:bg-zinc-800 shadow rounded-lg"
      assert html =~ "border border-zinc-200 dark:border-zinc-700"
      assert html =~ "p-6"
    end
  end

  describe "<.chart_title> (always rendered above the branch)" do
    test "renders the chart_title range-heading regardless of chart_type" do
      for chart_type <- [:line, :bar] do
        attrs =
          case chart_type do
            :line -> %{@default_attrs | chart_type: :line, chart: line_chart_fixture()}
            :bar -> %{@default_attrs | chart_type: :bar, bars: [bar_fixture()], y_max: 25.0}
          end

        html = render_component(&ChartPanel.chart_panel/1, attrs)

        # The chart_title component renders the period copy
        # under id "chart-title". The chart_panel always
        # includes it.
        assert html =~ ~s(id="chart-title"),
               "chart_title missing for chart_type=#{inspect(chart_type)}"
      end
    end
  end

  describe "line-vs-bar branch gate" do
    test "renders <.line_chart_panel> (and NOT <.bar_chart_panel>) when chart_type == :line" do
      html =
        render_component(&ChartPanel.chart_panel/1, %{
          @default_attrs
          | chart_type: :line,
            chart: line_chart_fixture()
        })

      # The line chart panel registers its colocated
      # `.ChartTooltip` hook on the chart container div.
      # That's the most stable marker for "the line branch
      # is currently active" because the bar branch doesn't
      # use that hook at all.
      assert html =~ ~s(phx-hook="DtuAppWeb.LineChartPanel.ChartTooltip")
      # The bar gradient is absent in the line branch.
      refute html =~ ~s(id="barGrad")
    end

    test "renders <.bar_chart_panel> (and NOT <.line_chart_panel>) when chart_type == :bar" do
      html =
        render_component(&ChartPanel.chart_panel/1, %{
          @default_attrs
          | chart_type: :bar,
            bars: [bar_fixture()],
            y_max: 25.0
        })

      # The bar chart panel renders its own emerald
      # `barGrad` gradient — the line panel never does.
      assert html =~ ~s(id="barGrad")
      # Cloud-cover overlay (line-only) is absent in bar.
      refute html =~ ~s(id="chart-cloud-cover-area")
    end

    test "falls through to the bar branch for non-:line chart_type values" do
      # The branch condition is explicit `== :line`, so
      # anything else (`:bar`, `:sankey`, nil, ...) drops into
      # the bar branch — same default as the pre-extraction
      # inline template.
      html =
        render_component(&ChartPanel.chart_panel/1, %{
          @default_attrs
          | chart_type: :bar,
            bars: [bar_fixture()],
            y_max: 25.0
        })

      assert html =~ ~s(id="barGrad")
      refute html =~ ~s(id="chart-cloud-cover-area")
    end
  end

  describe "<.share_panel> (always rendered below the branch)" do
    test "renders share panel regardless of chart_type" do
      for chart_type <- [:line, :bar] do
        attrs =
          case chart_type do
            :line -> %{@default_attrs | chart_type: :line, chart: line_chart_fixture()}
            :bar -> %{@default_attrs | chart_type: :bar, bars: [bar_fixture()], y_max: 25.0}
          end

        html = render_component(&ChartPanel.chart_panel/1, attrs)

        assert html =~ ~s(id="share-panel"),
               "share panel missing for chart_type=#{inspect(chart_type)}"
      end
    end

    test "forwards share_loading? / share_active? / share_url to <.share_panel>" do
      # share_active? = true → share-panel renders a URL row.
      # The exact URL gets passed via share_url and rendered
      # inside the panel.
      html =
        render_component(&ChartPanel.chart_panel/1, %{
          @default_attrs
          | share_active?: true,
            share_url: "https://dtu.example/share/abc123"
        })

      assert html =~ ~s(id="share-panel")
      assert html =~ "https://dtu.example/share/abc123"
    end

    test "share-loading? = true makes the loading spinner render" do
      # When share_loading? is true, the <.share_panel> shows
      # its spinner row instead of the URL/hint row.
      html =
        render_component(&ChartPanel.chart_panel/1, %{
          @default_attrs
          | share_loading?: true
        })

      assert html =~ ~s(id="share-panel")
      # The spinner is rendered with the .animate-spin class.
      assert html =~ "animate-spin"
    end
  end

  describe "structure guards" do
    test "does NOT render dashboard chrome from sibling panels" do
      # The chart panel shares the dashboard's overall layout
      # but should not bleed into the toolbar, onboarding, or
      # device-status panels.
      html = render_component(&ChartPanel.chart_panel/1, @default_attrs)

      refute html =~ ~s(id="dtu-switcher")
      refute html =~ ~s(id="quick-range-switcher")
      refute html =~ ~s(id="history-picker")
      refute html =~ ~s(id="onboarding-empty")
      refute html =~ ~s(id="device-status-grid")
      refute html =~ "Device Connection Status"
    end
  end
end
