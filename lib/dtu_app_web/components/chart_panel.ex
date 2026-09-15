defmodule DtuAppWeb.ChartPanel do
  @moduledoc """
  The "Chart Panel" — the dashboard's main event card. It bundles
  three sibling components under a single white-card wrapper so the
  user reads them as one bordered panel:

      ┌──────────────────────────────────────────────┐
      │  <.chart_title>          ←  range heading    │
      │  <.line_chart_panel>     OR  <.bar_chart_panel>
      │  <.share_panel>          ←  share toggle row │
      └──────────────────────────────────────────────┘

  The white-card chrome matches every other dashboard panel
  (white-card + shadow + border + `p-6`). The chart_type
  conditional chooses between the live-line view and the
  historical-bar view — `<.line_chart_panel>` for `:line`,
  `<.bar_chart_panel>` for `:bar`. The `<.chart_title>` and
  `<.share_panel>` always render regardless of chart_type
  (the title shows the current period in both modes, and the
  share panel always offers the day-share toggle).

  ## Chart-type guard

  Pass `:chart_type` as `:line` or `:bar`. The component asserts
  on the branch internally — anything else falls through to the
  default `<.bar_chart_panel>` branch (the same default the
  dashboard's pre-extraction template had).

  ## Why one component (not three)

  The three sub-components share the white-card chrome and are
  visually one panel to the user. Splitting them across three
  sibling components would either repeat the chrome three times
  or introduce two extra cards the user sees — both are wrong.
  Keeping them under one component is the same trade-off
  `DtuAppWeb.DashboardToolbar` makes for its three pieces.

  Was the inline block in
  `DtuAppWeb.DashboardLive.html.heex` (formerly lines 188-251).
  Extracted so the dashboard template keeps just the outer
  spacing wrapper and the chart card's three sibling calls +
  the chart-type branch have a stable, render-only-testable
  boundary.

  Sister to `DtuAppWeb.DeviceStatusCard` (PR #274),
  `DtuAppWeb.ConsumptionStatCards` (PR #275),
  `DtuAppWeb.NetFlowStatCards` (#276),
  `DtuAppWeb.ChartTitle` (#277),
  `DtuAppWeb.BarChartPanel` (#278),
  `DtuAppWeb.LineChartPanel` (#279),
  `DtuAppWeb.SharePanel` (#280),
  `DtuAppWeb.OnboardingPanel` (#281),
  `DtuAppWeb.DashboardHeader` (#282),
  `DtuAppWeb.DashboardToolbar` (#283), and
  `DtuAppWeb.DeviceStatusGrid` (#284).
  """

  use DtuAppWeb, :html

  import DtuAppWeb.ChartTitle, only: [chart_title: 1]
  import DtuAppWeb.LineChartPanel, only: [line_chart_panel: 1]
  import DtuAppWeb.BarChartPanel, only: [bar_chart_panel: 1]
  import DtuAppWeb.SharePanel, only: [share_panel: 1]

  # ------------------------------------------------------------------
  # Title attrs (<.chart_title>)
  # ------------------------------------------------------------------

  attr :live, :boolean,
    default: false,
    doc: """
    True when the dashboard is in the live view. Forwarded to
    `<.chart_title>` so the range heading can switch its
    copy from "Today" to the historical-period wording.
    """

  attr :has_inverter?, :boolean,
    default: false,
    doc: """
    Whether the user has any inverter-kind DTU
    (`kind in [:opendtu, :ahoydtu]`). Forwarded to
    `<.chart_title>` — and also into the line-chart map —
    so the chart can decide whether to plot production
    overlays at all. Ignored by the bar branch.
    """

  attr :has_shelly?, :boolean,
    default: false,
    doc: """
    Whether the user has a Shelly energy monitor paired.
    Forwarded to `<.chart_title>` — and also into the
    line-chart map — so the chart can decide whether to
    show the consumption / net-flow overlays.
    """

  attr :time_range, :string,
    default: "1d",
    doc: """
    Period identifier (e.g. `"1d"`, `"7d"`, `"30d"`,
    `"ytd"`, `"custom"`). Forwarded to `<.chart_title>`
    for the heading copy.
    """

  attr :selected_period, :any,
    default: nil,
    doc: """
    Current period anchor (`Date` for day/week/month,
    integer year for year granularity). Forwarded to
    `<.chart_title>` so the heading can show the
    selected day / week / month when one is picked.
    """

  # ------------------------------------------------------------------
  # Branch gate (chart_type)
  # ------------------------------------------------------------------

  attr :chart_type, :atom,
    default: :bar,
    doc: """
    Which chart branch to render. `:line` renders
    `<.line_chart_panel>` (the live, auto-refreshing SVG);
    `:bar` (default — same default the dashboard had before
    extraction) renders `<.bar_chart_panel>` (the
    historical bars). Anything else falls through to the
    bar branch — same behaviour the pre-extraction inline
    template had when the dashboard rendered for a
    historical view by default.
    """

  # ------------------------------------------------------------------
  # Line-chart bundle (line branch only)
  # ------------------------------------------------------------------

  attr :chart, :map,
    default: %{},
    doc: """
    Bundle of line-chart-specific assigns forwarded straight
    to `<.line_chart_panel>`'s `chart` attr. See that
    component's doc for the full key list
    (`:x_min_seconds`, `:x_max_seconds`, `:y_gridlines`,
    `:cloud_cover_line`, `:x_labels`, `:yesterday_paths`,
    `:series_paths`, `:series_palette`,
    `:series_points_data`, `:series_legend`,
    `:total_path`, `:total_palette`, `:total_points_data`,
    `:consumption_path`, `:consumption_palette`,
    `:consumption_points_data`, `:net_path`,
    `:net_palette`, `:net_points_data`, `:y_min`,
    `:sun_markers`, `:now_marker_x`, `:now_marker_label`,
    `:path_data`, `:has_inverter?`, `:has_shelly?`).
    Empty by default because it's irrelevant when
    `chart_type == :bar`.
    """

  # ------------------------------------------------------------------
  # Bar-chart attrs (bar branch only)
  # ------------------------------------------------------------------

  attr :bars, :list,
    default: [],
    doc: """
    Pre-bucketed bars from `DtuAppWeb.DashboardLive.BarChartData`
    forwarded to `<.bar_chart_panel>`. Only consumed when
    `chart_type == :bar`.
    """

  attr :y_max, :any,
    default: nil,
    doc: """
    Upper bound for the bar chart's Y-axis. Only consumed
    when `chart_type == :bar`. May be `nil` — the bar
    component falls back to an auto-computed max when so.
    """

  # ------------------------------------------------------------------
  # Share panel attrs (<.share_panel>)
  # ------------------------------------------------------------------

  attr :share_loading?, :boolean,
    default: false,
    doc: """
    True while the share-link round-trip is in flight;
    makes `<.share_panel>` show its loading spinner instead
    of the URL row.
    """

  attr :share_active?, :boolean,
    default: false,
    doc: """
    True once a share link has been minted for this user;
    makes `<.share_panel>` render its URL-row + copy
    button instead of the static hint.
    """

  attr :share_url, :string,
    default: nil,
    doc: """
    The minted URL of the anonymous current-day dashboard
    share. Populated by the LiveView's
    `handle_info({:share_link_minted, _, _}, _)` callback.
    Only consumed when `share_active? == true`.
    """

  # ------------------------------------------------------------------
  # Locale (shared by all three chart-side components)
  # ------------------------------------------------------------------

  attr :locale, :string,
    default: "en",
    doc: """
    BCP-47 locale passed through to `<.line_chart_panel>`,
    `<.bar_chart_panel>`, and `<.share_panel>` for
    `gettext/1` calls and number formatting. Not used by
    `<.chart_title>` (the title is locale-stable).
    """

  def chart_panel(assigns) do
    ~H"""
    <div class="bg-white dark:bg-zinc-800 shadow rounded-lg border border-zinc-200 dark:border-zinc-700 p-6">
      <.chart_title
        live={@live}
        has_inverter={@has_inverter?}
        has_shelly={@has_shelly?}
        time_range={@time_range}
        selected_period={@selected_period}
      />

      <%= if @chart_type == :line do %>
        <.line_chart_panel locale={@locale} chart={@chart} />
      <% else %>
        <%!-- Bar Chart — historical fallback when the line
                 branch is not the active chart. --%>
        <.bar_chart_panel bars={@bars} y_max={@y_max} locale={@locale} />
      <% end %>

      <%!-- Share panel: anonymous current-day dashboard share.
               The component owns the toggle row, the three-state
               inner row (spinner / URL row + copy button / static
               hint), and the colocated `.CopyToClipboardWithHint` +
               `.SelectOnFocus` JS hooks — see
               `DtuAppWeb.SharePanel` (PR #280). The dashboard
               still owns the `toggle_share` event handler and the
               share-state assigns. --%>
      <.share_panel
        share_loading?={@share_loading?}
        share_active?={@share_active?}
        share_url={@share_url}
        locale={@locale}
      />
    </div>
    """
  end
end
