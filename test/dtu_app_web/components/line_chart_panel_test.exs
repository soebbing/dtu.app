defmodule DtuAppWeb.LineChartPanelTest do
  @moduledoc """
  Render tests for `DtuAppWeb.LineChartPanel`.

  Pure render-only tests, no LiveView, no DB. We construct
  `@chart` maps by hand because the component reads only the keys
  listed in `attr :chart` and runs no domain logic; the values
  come straight from
  `DtuAppWeb.DashboardLive.LineChartData.assign_line_chart_data/6`
  that the dashboard regression suite covers.

  Coverage focuses on the render invariants a refactor must not
  break — the SVG ids the JS hook relies on, the data-attributes
  the tooltip parses, the legend buttons' `data-legend-key`s, the
  cloud-cover area+line ids, the empty-state id, the now-marker
  g element, the sunrise/sunset case match, and the colocated
  `.ChartTooltip` hook FQN. The hook's full event behavior is
  tested by the JS-side Playwright suite.

  Sister to `DtuAppWeb.BarChartPanelTest` and `DtuAppWeb.ChartTitleTest`.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DtuAppWeb.LineChartPanel

  defp base_chart(overrides \\ %{}) do
    defaults = %{
      x_min_seconds: 0.0,
      x_max_seconds: 86_400.0,
      y_gridlines: [{0.0, 250.0}, {500.0, 135.0}, {1000.0, 20.0}],
      cloud_cover_line: %{
        ticks: [0, 25, 50, 75, 100],
        has_data: false,
        path: "",
        area_path: ""
      },
      x_labels: [{100.0, "00:00"}, {400.0, "06:00"}, {700.0, "12:00"}],
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

  describe "container + svg" do
    test "renders the chart container with id and hook" do
      html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: base_chart(),
          locale: "en"
        })

      # Hook container the ChartTooltip colocated hook attaches to.
      assert html =~ "id=\"solar-chart-container\""
      # The `.ChartTooltip` colocated hook FQN resolves to
      # `DtuAppWeb.LineChartPanel.ChartTooltip` (Phoenix prepends the
      # module + dot-prefix convention). Assert the resolved form so a
      # future move-back-to-dashboard_live.ex stays caught.
      assert html =~ "phx-hook=\"DtuAppWeb.LineChartPanel.ChartTooltip\""
    end

    test "renders the chart SVG with the expected viewBox and data attributes" do
      html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: base_chart(%{x_min_seconds: 21_600.0, x_max_seconds: 75_600.0}),
          locale: "en"
        })

      assert html =~ "viewBox=\"-30 0 860 280\""
      assert html =~ "id=\"solar-chart-svg\""
      # The hook parses these on mount + update to map cursor X -> seconds.
      assert html =~ "data-x-min-seconds=\"2.16e4\""
      assert html =~ "data-x-max-seconds=\"7.56e4\""
    end
  end

  describe "axes" do
    test "renders a watt tick label per y_gridline entry" do
      html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: base_chart(),
          locale: "en"
        })

      assert html =~ "0 W"
      assert html =~ "500 W"
      assert html =~ "1,000 W"
    end

    test "renders the cloud-cover axis ticks as percentages" do
      html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: base_chart(),
          locale: "en"
        })

      assert html =~ "0%"
      assert html =~ "50%"
      assert html =~ "100%"
    end

    test "renders both axis titles (Power W and Cloud cover %)" do
      html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: base_chart(),
          locale: "en"
        })

      assert html =~ "data-testid=\"power-axis-title\""
      assert html =~ "Power (W)"
      assert html =~ "data-testid=\"cloud-cover-axis-title\""
      assert html =~ "Cloud cover (%)"
    end
  end

  describe "series overlays" do
    test "renders a path per series_paths entry with data-series + data-points" do
      series = {1, "serial-A", 0, "Inv A"}

      chart =
        base_chart(%{
          series_paths: %{series => "M 0 0 L 100 100"},
          series_palette: %{series => {"emerald", "500"}},
          series_points_data: %{series => [%{time: 0, power: 100.0}]},
          series_legend: %{series => "Inv A"}
        })

      html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: chart,
          locale: "en"
        })

      # JSON-encoded series meta (name + serial + mppt_index). Phoenix
      # entity-escapes the quotes inside attribute values, so we match
      # the `&quot;`-escaped form rather than the raw JSON.
      assert html =~ "data-series="
      assert html =~ ~s(&quot;name&quot;:&quot;Inv A&quot;)
      assert html =~ "data-points="
      assert html =~ "data-stroke="
      assert html =~ "data-legend-key=\"series:1:serial-A:0\""
    end

    test "renders the Total path only when total_path is non-empty" do
      empty_html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: base_chart(%{total_path: ""}),
          locale: "en"
        })

      refute empty_html =~ "data-legend-key=\"total\""

      filled_html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: base_chart(%{total_path: "M 0 0 L 100 100"}),
          locale: "en"
        })

      assert filled_html =~ "data-legend-key=\"total\""
      assert filled_html =~ ~s(&quot;is_total&quot;:true)
    end

    test "renders the consumption dashed overlay only when consumption_path is non-empty" do
      html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart:
            base_chart(%{
              consumption_path: "M 0 0 L 100 100",
              has_inverter?: true,
              has_shelly?: true
            }),
          locale: "en"
        })

      assert html =~ "data-legend-key=\"consumption\""
      assert html =~ ~s(&quot;is_consumption&quot;:true)
      # The dashed stroke is the visual tell that this is a separate metric.
      assert html =~ "stroke-dasharray=\"6,4\""
    end

    test "renders the net-flow overlay only when both inverter and shelly are present" do
      dtu_only_html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart:
            base_chart(%{
              net_path: "M 0 0 L 100 100",
              has_inverter?: true,
              has_shelly?: false
            }),
          locale: "en"
        })

      refute dtu_only_html =~ "data-legend-key=\"net\""

      paired_html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart:
            base_chart(%{
              net_path: "M 0 0 L 100 100",
              has_inverter?: true,
              has_shelly?: true
            }),
          locale: "en"
        })

      assert paired_html =~ "data-legend-key=\"net\""
      assert paired_html =~ ~s(&quot;is_net&quot;:true)
    end

    test "renders the cloud-cover line + area only when cloud_cover_line.has_data is true" do
      empty_html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: base_chart(),
          locale: "en"
        })

      refute empty_html =~ "id=\"chart-cloud-cover-area\""
      refute empty_html =~ "id=\"chart-cloud-cover-line\""

      cloud_chart =
        base_chart(%{
          cloud_cover_line: %{
            ticks: [0, 50, 100],
            has_data: true,
            path: "M 0 250 L 800 250",
            area_path: "M 0 250 L 800 250 Z"
          }
        })

      filled_html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: cloud_chart,
          locale: "en"
        })

      assert filled_html =~ "id=\"chart-cloud-cover-area\""
      assert filled_html =~ "id=\"chart-cloud-cover-line\""
    end
  end

  describe "legend" do
    test "renders one legend-toggle button per visible series" do
      series_a = {1, "serial-A", 0, "Inv A"}
      series_b = {2, "serial-B", 0, "Inv B"}

      chart =
        base_chart(%{
          series_paths: %{series_a => "...", series_b => "..."},
          series_palette: %{
            series_a => {"emerald", "500"},
            series_b => {"sky", "500"}
          },
          series_points_data: %{},
          series_legend: %{series_a => "Inv A", series_b => "Inv B"}
        })

      html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: chart,
          locale: "en"
        })

      assert html =~ "id=\"chart-legend\""
      assert html =~ "data-legend-key=\"series:1:serial-A:0\""
      assert html =~ "data-legend-key=\"series:2:serial-B:0\""
      # The buttons are real <button>s with aria-pressed so screen readers
      # announce their toggle state.
      assert html =~ "aria-pressed=\"true\""
    end

    test "renders the Yesterday swatch hint only when yesterday_paths is non-empty" do
      empty_html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: base_chart(),
          locale: "en"
        })

      refute empty_html =~ "Yesterday (day-over-day comparison)"

      series = {1, "serial-A", 0, "Inv A"}

      chart =
        base_chart(%{
          yesterday_paths: %{series => "M 0 0"},
          series_palette: %{series => {"emerald", "500"}}
        })

      filled_html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: chart,
          locale: "en"
        })

      assert filled_html =~ "Yesterday (day-over-day comparison)"
      assert filled_html =~ "data-legend-key=\"yesterday:1:serial-A:0\""
    end

    test "hides the entire legend strip when there are no series and no overlays" do
      html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: base_chart(),
          locale: "en"
        })

      refute html =~ "id=\"chart-legend\""
    end
  end

  describe "empty-state" do
    test "renders the empty-state id when path_data is empty" do
      html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: base_chart(%{path_data: ""}),
          locale: "en"
        })

      # Same id="empty-chart" the bar chart uses.
      assert html =~ "id=\"empty-chart\""
      assert html =~ "hero-presentation-chart-line"
      assert html =~ "No power readings logged for this day."
    end

    test "hides the empty-state when path_data is non-empty" do
      html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: base_chart(%{path_data: "M 0 0 L 100 100"}),
          locale: "en"
        })

      refute html =~ "id=\"empty-chart\""
    end
  end

  describe "now marker" do
    test "renders the now-marker group only when now_marker_x is set" do
      html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: base_chart(%{now_marker_x: 420.0, now_marker_label: "12:30"}),
          locale: "en"
        })

      assert html =~ "id=\"now-marker\""
      assert html =~ "id=\"now-marker-line\""
      assert html =~ "id=\"now-marker-pill\""
      assert html =~ "id=\"now-marker-text\""
      assert html =~ "12:30"
    end

    test "hides the now-marker group when now_marker_x is nil" do
      html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: base_chart(%{now_marker_x: nil}),
          locale: "en"
        })

      refute html =~ "id=\"now-marker\""
    end
  end

  describe "sun markers" do
    test "renders both sunrise + sunset lines and labels when both are present" do
      chart = base_chart(%{sun_markers: {21_600.0, 75_600.0, "06:00", "21:00"}})

      html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: chart,
          locale: "en"
        })

      # Amber stroke is the visual tell (also `data-` is none; this is
      # just a marker line). Labels are "↑" for sunrise, "↓" for sunset.
      assert html =~ "06:00"
      assert html =~ "21:00"
      assert html =~ "↑"
      assert html =~ "↓"
    end

    test "renders neither sunrise nor sunset when both X coords are nil" do
      html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: base_chart(%{sun_markers: {nil, nil, nil, nil}}),
          locale: "en"
        })

      refute html =~ "↑"
      refute html =~ "↓"
    end
  end

  describe "localization" do
    test "renders the watt tick suffix in English by default" do
      html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: base_chart(),
          locale: "en"
        })

      assert html =~ "0 W"
      assert html =~ "1,000 W"
    end

    test "renders the watt tick suffix localized to German under locale=de" do
      html =
        Gettext.with_locale(DtuAppWeb.Gettext, "de", fn ->
          render_component(&LineChartPanel.line_chart_panel/1, %{
            chart: base_chart(),
            locale: "de"
          })
        end)

      # DE uses "." as the thousands separator — "1.000 W" rather
      # than the EN "1,000 W". The `W` symbol is the SI unit and
      # stays identical across locales.
      assert html =~ "1.000 W"
      refute html =~ "1,000 W"
    end

    test "renders the watt tick suffix localized to French under locale=fr" do
      html =
        Gettext.with_locale(DtuAppWeb.Gettext, "fr", fn ->
          render_component(&LineChartPanel.line_chart_panel/1, %{
            chart: base_chart(),
            locale: "fr"
          })
        end)

      # FR uses NBSP (U+00A0) as the thousands separator — written
      # as the literal NBSP character so the assertion matches
      # the exact bytes the formatter emits. A regular ASCII
      # space would also pass `=~` but would silently accept a
      # future regression that swaps NBSP for a breaking space.
      assert html =~ "1 000 W"
    end

    test "exposes the localized watt unit to the colocated JS hook via a data attribute" do
      html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: base_chart(),
          locale: "en"
        })

      # The chart tooltip (rendered client-side by the colocated
      # hook) appends the unit to every value; the server now
      # passes the localized form so the JS doesn't need its own
      # i18n catalog. The default gettext msgid is the SI symbol
      # `W`, identical across EN/DE/FR — the attribute is still
      # wired so future locale-specific unit changes land in one
      # place.
      assert html =~ ~s(data-watts-unit="W")
    end
  end

  describe "colocated hook" do
    test "the chart container binds the colocated hook FQN resolved to the component module" do
      # The full colocated hook body (`export default { ... }`) only
      # reaches the page through `Phoenix.LiveView.ColocatedHook`'s
      # asset pipeline, which `render_component/2` bypasses — so we
      # can't assert on the JS source from a render-only test. We
      # CAN assert that the container's `phx-hook` attribute points
      # at the FQN Phoenix derives from the `<script>`'s `name=".X"`
      # attribute (dot-prefix + surrounding module), which is the
      # same resolution the runtime applies.
      html =
        render_component(&LineChartPanel.line_chart_panel/1, %{
          chart: base_chart(),
          locale: "en"
        })

      assert html =~ "phx-hook=\"DtuAppWeb.LineChartPanel.ChartTooltip\""
    end
  end
end
