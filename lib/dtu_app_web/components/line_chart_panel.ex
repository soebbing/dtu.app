defmodule DtuAppWeb.LineChartPanel do
  @moduledoc """
  The primary `<svg>` chart panel rendered when the dashboard
  resolves `@chart_type == :line` (the production / consumption /
  net-flow line chart used by the today view and the historical
  day / week / month / year views).

  The chart owns:

    * The 800×280 SVG with `viewBox="-30 0 860 280"`, the
      cloud-area gradient, the cloud-cover band + line overlay,
      the y-axis watt ticks (per-500W via `@y_gridlines`), the
      right-axis `%` ticks, the cloud-cover / power axis titles,
      the X-axis time labels, the per-inverter (yesterday ghost
      and today) `<path>` series, the Total / Consumption /
      Net-flow overlay lines, the cursor guide, the sunrise /
      sunset vertical markers, and the now-marker pill.
    * The legend strip with one `<button class="legend-toggle">`
      per series — Total, Consumption, Net flow, the "Yesterday"
      dashed-swatch hint, and one row per (inverter, MPPT)
      series. The `ChartTooltip` colocated hook reads the
      buttons' `data-legend-key` to toggle the matching
      `<path>`'s `display:none`.
    * The empty-state copy ("No power readings logged for this
      day.") shown below the chart when `@path_data` is empty —
      the SVG above stays fully rendered so the cloud-cover band,
      axes, gridlines, sun markers, and now marker remain
      visible. Same `id="empty-chart"` the bar chart uses.
    * The `<script :type={Phoenix.LiveView.ColocatedHook}
      name=".ChartTooltip">` block — the tooltip guide line,
      floating foreignObject, nearest-bucket lookup, and
      now-marker live tick. The hook's FQN resolves to
      `DtuAppWeb.LineChartPanel.ChartTooltip` because of the
      dot-prefix colocated-hook convention (see
      `Phoenix.LiveView.ColocatedHook` docs); no external consumer
      references the old FQN.

  `@chart` is a single map that bundles every line-chart-specific
  assign produced by
  `DtuAppWeb.DashboardLive.LineChartData.assign_line_chart_data/6`
  (the production paths, points, palettes, legend, sun markers,
  now marker, cloud-cover line, axis grids, etc.). `@locale` is
  threaded separately because the chart also uses
  `Devices.format_number/3` + `gettext/1` for the y-axis ticks.

  Was the inline `<%= if @chart_type == :line do %> ... <% end %>`
  block in `DtuAppWeb.DashboardLive.html.heex` (formerly lines
  342-1466). Extracted so the dashboard template keeps the
  chart-type switch but the line chart — and its 300-line
  colocated JS hook — have their own render surface, their own
  id / palette / legend details, and their own focused test
  file.

  Sister to `DtuAppWeb.BarChartPanel` (PR #278) and the
  earlier-extracted dashboard components (PRs #273-#277).
  """

  use DtuAppWeb, :html

  alias DtuApp.Devices
  alias DtuAppWeb.DashboardLive.ChartPalette

  attr :chart, :map,
    required: true,
    doc: """
    Bundle of line-chart-specific assigns from
    `DtuAppWeb.DashboardLive.LineChartData.assign_line_chart_data/6`.
    Keys: `:x_min_seconds`, `:x_max_seconds`, `:y_gridlines`,
    `:cloud_cover_line`, `:x_labels`, `:yesterday_paths` (map),
    `:series_paths`, `:series_palette`, `:series_points_data`,
    `:total_path`, `:total_palette`, `:total_points_data`,
    `:consumption_path`, `:consumption_palette`,
    `:consumption_points_data`, `:net_path`, `:net_palette`,
    `:net_points_data`, `:y_min`, `:sun_markers`,
    `:now_marker_x`, `:now_marker_label`, `:path_data`,
    `:series_legend`, `:has_inverter?`, `:has_shelly?`.
    """

  attr :locale, :string,
    default: "en",
    doc: """
    BCP-47 locale used by `Devices.format_number/3` for the
    y-axis watt tick labels and by `gettext/1` for the axis
    titles / legend entries.
    """

  def line_chart_panel(assigns) do
    ~H"""
    <div
      class="relative w-full overflow-hidden"
      id="solar-chart-container"
      phx-hook=".ChartTooltip"
    >
      <!-- Chart SVG -->
      <svg
        viewBox="-30 0 860 280"
        class="w-full h-auto overflow-visible"
        id="solar-chart-svg"
        data-x-min-seconds={@chart.x_min_seconds}
        data-x-max-seconds={@chart.x_max_seconds}
      >
        <!-- Cloud-cover area fill. Anchored in user-space
                 to chart y=20 (top) → y=250 (bottom) so the
                 gradient reads as a soft sky haze regardless
                 of where the line sits: dense grey near the
                 line, fading to a still-visible tint at the
                 chart baseline. userSpaceOnUse is required —
                 with objectBoundingBox the gradient would
                 warp with the line's height (a low-coverage
                 day would render the line area as solid
                 grey instead of nearly clear). The opacity
                 range (0.18 → 0.06) is the fourth step down
                 from the bar overlay's original (0.55 → 0.15):
                 the post-#236 bump to (0.75 → 0.35) made the
                 dotted-green yesterday-power curve barely
                 legible through the haze; the (0.50 → 0.20)
                 midpoint (#238) only partially recovered it;
                 (0.30 → 0.10, #239) made it readable but the
                 haze still drew the eye; 0.18 → 0.06 keeps
                 enough coverage to read as a cloud-cue
                 without competing with the power curve. -->
        <defs>
          <linearGradient
            id="cloud-area-gradient"
            gradientUnits="userSpaceOnUse"
            x1="0"
            y1="20"
            x2="0"
            y2="250"
          >
            <stop offset="0%" stop-color="rgb(120 120 120)" stop-opacity="0.18" />
            <stop offset="100%" stop-color="rgb(120 120 120)" stop-opacity="0.06" />
          </linearGradient>
        </defs>
        <!-- Grid Lines + Y-Axis Labels. The chart renders one
                   horizontal gridline + tick label per 500 W step
                   (`@y_gridlines`, computed by `chart_y_gridlines/5`).
                   The list covers `[y_min, y_max]` aligned to the 500 W
                   grid — DTU-only users (y_min = 0) get ticks at 0,
                   500, 1000, …, y_max; paired users (y_min < 0) get
                   a symmetric ladder through zero. The 0 W tick is
                   rendered with a dashed stroke as the reference
                   line, and its label sits just below the gridline
                   (matching the previous label-tick alignment).

                   The chart's bottom edge (y = 250) is rendered as a
                   heavier baseline. For DTU-only users the 0 W tick
                   coincides with this baseline (since zero_y = 250),
                   and the 0 W label sits just below the chart. -->
        {chart_grid_bottom = 250.0}
        <%= for {watts, y_pixel} <- @chart.y_gridlines do %>
          <% is_zero = watts == 0.0 %>
          <line
            x1="0"
            y1={y_pixel}
            x2="800"
            y2={y_pixel}
            stroke="#f4f4f5"
            class="dark:stroke-zinc-700"
            stroke-width="1"
            stroke-dasharray={if is_zero, do: "4", else: nil}
          />
          <text
            x="5"
            y={y_pixel + 12}
            class="text-[10px] font-medium fill-zinc-400"
          >
            {Devices.format_number(watts, 0, @locale)} W
          </text>
        <% end %>

        <%!-- Left Y-axis title. Rotated -90° so it reads
                   bottom-to-top, sitting in the 30 px of padding
                   the SVG's viewBox reserves on the left
                   (viewBox="-30 0 860 280"). `text-anchor="middle"`
                   + `dominant-baseline="central"` centers the
                   label on the chart's vertical mid-line
                   (y=135) so it visually anchors the axis.
                   Uppercase + tracking-wider is one notch more
                   prominent than the per-tick `W` numbers, so it
                   reads as the *title* of the scale, not as
                   another tick. --%>
        <text
          x="-15"
          y="135"
          transform="rotate(-90, -15, 135)"
          text-anchor="middle"
          dominant-baseline="central"
          class="text-[10px] font-medium fill-zinc-400 uppercase tracking-wider"
          data-testid="power-axis-title"
        >
          {gettext("Power (W)")}
        </text>
        <line
          x1="0"
          y1={chart_grid_bottom}
          x2="800"
          y2={chart_grid_bottom}
          stroke="#e4e4e7"
          class="dark:stroke-zinc-600"
          stroke-width="1.5"
        />

        <%!-- Right-side Y-Axis Labels for the cloud-cover
                   line. Same 800×230 plot area as the power
                   curves, but mapped onto 0–100% coverage.
                   The y-position for each tick is computed as
                   `250 - pct/100 * 230`, so 0% sits on the
                   chart baseline (y=250) and 100% on the top
                   (y=20). Labels are right-anchored at x=795 so
                   they hug the chart's right edge; muted
                   zinc-400 fill matches the left-axis "W"
                   labels. The line itself (when present) sits
                   at the same y-pixel, so the labels double as
                   coverage readouts. --%>
        <%= for pct <- @chart.cloud_cover_line.ticks do %>
          <% tick_y = 250.0 - pct / 100.0 * 230.0 %>
          <text
            x="795"
            y={tick_y + 3}
            class="text-[10px] font-medium fill-zinc-400"
            text-anchor="end"
            data-testid={"cloud-cover-axis-tick-#{pct}"}
          >
            {pct}%
          </text>
        <% end %>

        <%!-- Right Y-axis title (cloud cover, %). Mirror
                   of the left title: rotated -90° in the 30 px
                   of padding the SVG's viewBox reserves on
                   the right (x=815 sits in the -30..860 window).
                   Same style as the left title so the two
                   axes read as a matched pair, with the
                   units (`(W)` vs `(%)`) disambiguating which
                   is which. --%>
        <text
          x="815"
          y="135"
          transform="rotate(-90, 815, 135)"
          text-anchor="middle"
          dominant-baseline="central"
          class="text-[10px] font-medium fill-zinc-400 uppercase tracking-wider"
          data-testid="cloud-cover-axis-title"
        >
          {gettext("Cloud cover (%)")}
        </text>

        <!-- X-Axis Labels (Time slots). Dynamically positioned to
                   fit the chart's X-axis range — full day (00:00–
                   24:00) when no data, or zoomed to data when
                   present (see `chart_time_range/1`). -->
        <%= for {{x, label}, edge} <- Enum.with_index(@chart.x_labels) do %>
          <% anchor =
            cond do
              edge == 0 -> "start"
              edge == length(@chart.x_labels) - 1 -> "end"
              true -> "middle"
            end %>
          <text
            x={x}
            y="270"
            class="text-[10px] font-medium fill-zinc-400"
            text-anchor={anchor}
          >
            {label}
          </text>
        <% end %>

        <%!-- Cloud-cover line overlay. Renders cloud-cover the
                   same way the inverter power curves do — one
                   thin grey polyline traversing the chart, with
                   `y` mapped onto the 0–100% coverage scale
                   (chart top = 100% overcast, chart bottom = 0%
                   clear sky). The `d` attribute comes from
                   `cloud_cover_line/6` and is sorted by X, so
                   the line connects each hour's coverage in
                   chronological order. Stroke is slate-500 on
                   light backgrounds, slate-400 in dark mode —
                   the same muted grey used by the cloud icon
                   so it reads as "weather metadata" rather
                   than competing with the power curves for
                   attention. Drawn AFTER the inverter paths
                   (so it sits on top) but with `pointer-events=
                   "none"` so it doesn't block cursor hit-tests
                   on the underlying power series. Hidden
                   entirely when `@chart.cloud_cover_line.has_data ==
                   false` (nil coords, no readings in window, or
                   upstream failure).

                   Why a line and not the previous bar/rect
                   overlay: a stack of grey rects going back
                   from a high past hour (e.g. 97%) fills the
                   whole chart even when the *current* hour is
                   3% — visually indistinguishable from "near-
                   full overcast right now". A thin line on
                   its own axis lets a user see "clearing right
                   now" as a real slope, the same way the
                   power curves show generation shape. The
                   right-side `0/25/50/75/100%` axis labels
                   make the scale explicit so the values
                   aren't ambiguous next to the watt labels on
                   the left.

                   Two paths are emitted: `area_path` (closed
                   shape from the smoothed line down to the
                   chart bottom, filled with the cloud-area
                   gradient so dense cloud reads as a soft
                   "sky haze" below the curve) and `path`
                   (the line itself). The area renders first so
                   the stroke sits cleanly on top of its own
                   fill. --%>
        <%= if @chart.cloud_cover_line.has_data do %>
          <path
            d={@chart.cloud_cover_line.area_path}
            fill="url(#cloud-area-gradient)"
            stroke="none"
            pointer-events="none"
            aria-hidden="true"
            data-testid="cloud-cover-area"
            id="chart-cloud-cover-area"
          />
          <path
            d={@chart.cloud_cover_line.path}
            fill="none"
            stroke="#64748b"
            class="dark:stroke-zinc-400"
            stroke-width="1.5"
            stroke-linecap="round"
            stroke-linejoin="round"
            pointer-events="none"
            data-testid="cloud-cover-line"
            id="chart-cloud-cover-line"
          />
        <% end %>

        <!-- Yesterday ghost overlay (1D / live view only):
                   translucent, dashed per-inverter paths that sit
                   BEHIND today's solid curves so the day-over-day
                   comparison reads at a glance. Rendered first
                   (before @series_paths below) so today's line
                   paints on top. Hidden on historical day/week/
                   month/year views, where the selected period's
                   own curve is the comparison the user asked for. -->
        <%= for {series, path} <- @chart.yesterday_paths do %>
          <% {ybase, yshade} = Map.get(@chart.series_palette, series, {"zinc", "400"}) %>
          <% ystroke_hex = ChartPalette.tooltip_to_hex(ybase, yshade) %>
          <path
            d={path}
            fill="none"
            stroke={ystroke_hex}
            stroke-width="1.5"
            stroke-opacity="0.35"
            stroke-dasharray="4 3"
            stroke-linecap="round"
            stroke-linejoin="round"
            data-ghost="true"
            data-legend-key={"yesterday:#{elem(series, 0)}:#{elem(series, 1)}:#{elem(series, 2)}"}
          />
        <% end %>

        <!-- One SVG path per inverter. Each path carries its
                   (time, power) data points as a JSON data attribute
                   so the ChartTooltip hook can look up the cursor-
                   time value without parsing the SVG `d=` string.
                   The Total line is rendered last so it sits on top
                   of every per-inverter path — it's the headline
                   curve. -->
        <%= for {series, path} <- @chart.series_paths do %>
          <% {base, shade} = Map.get(@chart.series_palette, series) %>
          <% stroke_hex = ChartPalette.tooltip_to_hex(base, shade) %>
          <% series_json =
            Jason.encode!(%{
              dtu_id: elem(series, 0),
              serial: elem(series, 1),
              mppt_index: elem(series, 2),
              name: elem(series, 3)
            }) %>
          <% points_json = Jason.encode!(Map.get(@chart.series_points_data, series, [])) %>
          <% legend_key =
            "series:#{elem(series, 0)}:#{elem(series, 1)}:#{elem(series, 2)}" %>
          <path
            d={path}
            fill="none"
            stroke={stroke_hex}
            stroke-width="2.5"
            stroke-linecap="round"
            stroke-linejoin="round"
            data-series={series_json}
            data-points={points_json}
            data-stroke={stroke_hex}
            data-legend-key={legend_key}
          />
        <% end %>
        <%= if @chart.total_path != "" do %>
          <% total_json =
            Jason.encode!(%{
              is_total: true,
              name: gettext("Total"),
              serial: "",
              mppt_index: -1
            }) %>
          <% total_points_json = Jason.encode!(@chart.total_points_data) %>
          <% {tbase, tshade} = @chart.total_palette %>
          <% total_stroke_hex = ChartPalette.tooltip_to_hex(tbase, tshade) %>
          <path
            d={@chart.total_path}
            fill="none"
            stroke={total_stroke_hex}
            stroke-width="3"
            stroke-linecap="round"
            stroke-linejoin="round"
            data-series={total_json}
            data-points={total_points_json}
            data-stroke={total_stroke_hex}
            data-legend-key="total"
          />
        <% end %>

        <%!-- Consumption overlay (Shelly Plus 3EM household draw).
                   Drawn after the Total so it sits on top — it's a
                   separate metric, not another inverter. Rendered
                   with a dashed stroke so it's visually distinct
                   from the solid Total line. Hidden when the user
                   has no Shelly device or no consumption data yet. --%>
        <%= if @chart.consumption_path != "" do %>
          <% consumption_json =
            Jason.encode!(%{
              is_consumption: true,
              name: gettext("Consumption"),
              serial: "",
              mppt_index: -2
            }) %>
          <% consumption_points_json = Jason.encode!(@chart.consumption_points_data) %>
          <% {cbase, cshade} = @chart.consumption_palette %>
          <% consumption_stroke_hex = ChartPalette.tooltip_to_hex(cbase, cshade) %>
          <path
            d={@chart.consumption_path}
            fill="none"
            stroke={consumption_stroke_hex}
            stroke-width="2.5"
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-dasharray="6,4"
            data-series={consumption_json}
            data-points={consumption_points_json}
            data-stroke={consumption_stroke_hex}
            data-legend-key="consumption"
          />
        <% end %>

        <%!-- Net flow overlay (production minus consumption). Drawn
                   last so it sits on top of every other series. The
                   SVG's vertical center (y=135) is the zero line —
                   negative values (export) plot downward, positive
                   values (import) plot upward. Hidden when the
                   user hasn't paired both an inverter and a Shelly. --%>
        <%= if @chart.net_path != "" and @chart.has_inverter? and @chart.has_shelly? do %>
          <% net_json =
            Jason.encode!(%{
              is_net: true,
              name: gettext("Net flow"),
              serial: "",
              mppt_index: -3
            }) %>
          <% net_points_json = Jason.encode!(@chart.net_points_data) %>
          <% {nbase, nshade} = @chart.net_palette %>
          <% net_stroke_hex = ChartPalette.tooltip_to_hex(nbase, nshade) %>
          <path
            d={@chart.net_path}
            fill="none"
            stroke={net_stroke_hex}
            stroke-width="2.5"
            stroke-linecap="round"
            stroke-linejoin="round"
            data-series={net_json}
            data-points={net_points_json}
            data-stroke={net_stroke_hex}
            data-legend-key="net"
          />
          <%!-- Zero line for the net flow axis — the dashed
                     grid line at @zero_y already marks this
                     position when `y_min < 0`, so we only render
                     the dedicated (slightly darker) reference
                     line when the chart is positive-only (no net
                     flow below zero). The two would otherwise
                     stack on top of each other. --%>
          <%= if @chart.y_min >= 0.0 do %>
            <line
              x1="0"
              y1="135"
              x2="800"
              y2="135"
              stroke="#a1a1aa"
              class="dark:stroke-zinc-500"
              stroke-width="1"
              stroke-dasharray="2,2"
              pointer-events="none"
            />
          <% end %>
        <% end %>

        <!-- Vertical guide line drawn at the cursor's X
                   position. Hidden by default; the ChartTooltip
                   hook shows it on hover/touch. Rendered LAST
                   (after every data path) so the SVG paint
                   order keeps it visually on top of the
                   curves — earlier in document order, the
                   strokes would paint over the dashed line
                   wherever the cursor sits near a series. -->
        <line
          x1="0"
          y1="20"
          x2="0"
          y2="250"
          stroke="#a1a1aa"
          class="dark:stroke-zinc-500"
          stroke-width="1"
          stroke-dasharray="2,2"
          pointer-events="none"
          style="display:none"
          id="chart-guide-line"
        />
        <%!-- Sunrise / sunset vertical guide lines. Drawn after
                   the cursor guide's source line above (but rendered
                   here, before the now marker) so the SVG paint order
                   keeps them visually underneath both the now marker
                   AND the live cursor. Both lines + their tiny
                   "HH:MM" labels are amber so they're visually
                   distinct from the indigo now-marker and the slate
                   cursor guide. `@sun_markers` is the 4-tuple
                   `{sr_x, ss_x, sr_label, ss_label}` from
                   `ChartHelpers.sun_markers/6`; each X and label
                   is nil together — the chart shows either both
                   or neither per event. --%>
        <%= case @chart.sun_markers do %>
          <% {sr_x, _, sr_label, _} when not is_nil(sr_x) -> %>
            <line
              x1={sr_x}
              y1="20"
              x2={sr_x}
              y2="250"
              stroke="#f59e0b"
              class="dark:stroke-amber-400"
              stroke-width="1"
              stroke-dasharray="3,3"
              opacity="0.55"
              pointer-events="none"
            />
            <g pointer-events="none">
              <text
                x={sr_x}
                y="14"
                text-anchor="middle"
                fill="#b45309"
                class="dark:fill-amber-300"
                font-size="9"
                font-weight="600"
                font-family="ui-sans-serif, system-ui, sans-serif"
              >
                ↑ {sr_label}
              </text>
            </g>
          <% _ -> %>
        <% end %>
        <%= case @chart.sun_markers do %>
          <% {_, ss_x, _, ss_label} when not is_nil(ss_x) -> %>
            <line
              x1={ss_x}
              y1="20"
              x2={ss_x}
              y2="250"
              stroke="#f59e0b"
              class="dark:stroke-amber-400"
              stroke-width="1"
              stroke-dasharray="3,3"
              opacity="0.55"
              pointer-events="none"
            />
            <g pointer-events="none">
              <text
                x={ss_x}
                y="14"
                text-anchor="middle"
                fill="#b45309"
                class="dark:fill-amber-300"
                font-size="9"
                font-weight="600"
                font-family="ui-sans-serif, system-ui, sans-serif"
              >
                ↓ {ss_label}
              </text>
            </g>
          <% _ -> %>
        <% end %>
        <%!-- Now marker - solid vertical line and label pill drawn
                   on top of the data curves but below the cursor guide.
                   Hidden on historical views (assign_line_chart_data/6
                   sets nil unless :live? is true). --%>

        <%= if @chart.now_marker_x do %>
          <g id="now-marker" pointer-events="none">
            <line
              id="now-marker-line"
              x1={@chart.now_marker_x}
              y1="24"
              x2={@chart.now_marker_x}
              y2="250"
              stroke="#6366f1"
              class="dark:stroke-indigo-400"
              stroke-width="1.5"
              opacity="0.65"
              pointer-events="none"
            />
            <rect
              id="now-marker-pill"
              x={@chart.now_marker_x - 18}
              y="6"
              width="36"
              height="14"
              rx="3"
              fill="#6366f1"
              class="dark:fill-indigo-400"
            />
            <text
              id="now-marker-text"
              x={@chart.now_marker_x}
              y="16"
              text-anchor="middle"
              fill="white"
              class="dark:fill-zinc-900"
              font-size="10"
              font-weight="600"
              font-family="ui-sans-serif, system-ui, sans-serif"
            >
              {@chart.now_marker_label || gettext("now")}
            </text>
          </g>
        <% end %>

        <!-- Floating tooltip overlay rendered by the
                   ChartTooltip hook. Hidden by default; positioned
                   via the foreignObject's x/y attributes as the
                   cursor moves. `pointer-events: none` so it
                   never blocks hover on the chart. Rendered LAST
                   (after every data path) so the SVG paint
                   order keeps it visually on top of the curves
                   — the foreignObject would otherwise be
                   painted under the data strokes wherever a
                   series crosses the tooltip box. -->
        <foreignObject
          x="0"
          y="0"
          width="200"
          height="160"
          pointer-events="none"
          style="display:none;overflow:visible"
          id="chart-tooltip"
        >
          <div
            xmlns="http://www.w3.org/1999/xhtml"
            class="rounded-md border border-zinc-200 bg-white/95 px-2.5 py-1.5 shadow-md backdrop-blur dark:border-zinc-700 dark:bg-zinc-900/95"
          >
            <div
              id="chart-tooltip-body"
              class="font-mono text-xs text-zinc-700 dark:text-zinc-200"
            >
            </div>
          </div>
        </foreignObject>
      </svg>

      <%!-- Legend: Total line first (the headline), then one entry
                 per (inverter, MPPT) series in the same order as the
                 paths above. Each entry is a real <button> so it's
                 keyboard- and screen-reader-accessible; the
                 ChartTooltip hook toggles the matching path's hidden
                 class on click. --%>
      <%= if map_size(@chart.series_legend) > 0 or @chart.total_path != "" or @chart.consumption_path != "" or map_size(@chart.yesterday_paths) > 0 do %>
        <div
          class="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1.5 text-xs"
          id="chart-legend"
        >
          <%= if @chart.total_path != "" do %>
            <% {tbase, tshade} = @chart.total_palette %>
            <button
              type="button"
              class="legend-toggle inline-flex items-center gap-1.5 cursor-pointer rounded px-1 py-0.5 hover:bg-zinc-100 dark:hover:bg-zinc-700/50"
              data-legend-key="total"
              aria-pressed="true"
            >
              <span
                class={"legend-swatch inline-block h-2.5 w-2.5 rounded-sm bg-#{tbase}-#{tshade}"}
                aria-hidden="true"
              />
              <span class="text-zinc-700 dark:text-zinc-300">
                {gettext("Total")}
              </span>
            </button>
          <% end %>
          <%= if @chart.consumption_path != "" do %>
            <% {cbase, cshade} = @chart.consumption_palette %>
            <button
              type="button"
              class="legend-toggle inline-flex items-center gap-1.5 cursor-pointer rounded px-1 py-0.5 hover:bg-zinc-100 dark:hover:bg-zinc-700/50"
              data-legend-key="consumption"
              aria-pressed="true"
            >
              <span
                class={"legend-swatch inline-block h-2.5 w-2.5 rounded-sm bg-#{cbase}-#{cshade}"}
                aria-hidden="true"
              />
              <span class="text-zinc-700 dark:text-zinc-300">
                {gettext("Consumption")}
              </span>
            </button>
          <% end %>
          <%= if @chart.net_path != "" and @chart.has_inverter? and @chart.has_shelly? do %>
            <% {nbase, nshade} = @chart.net_palette %>
            <button
              type="button"
              class="legend-toggle inline-flex items-center gap-1.5 cursor-pointer rounded px-1 py-0.5 hover:bg-zinc-100 dark:hover:bg-zinc-700/50"
              data-legend-key="net"
              aria-pressed="true"
            >
              <span
                class={"legend-swatch inline-block h-2.5 w-2.5 rounded-sm bg-#{nbase}-#{nshade}"}
                aria-hidden="true"
              />
              <span class="text-zinc-700 dark:text-zinc-300">
                {gettext("Net flow")}
              </span>
            </button>
          <% end %>
          <%= if map_size(@chart.yesterday_paths) > 0 do %>
            <span
              class="inline-flex items-center gap-1.5 rounded px-1 py-0.5 text-zinc-500 dark:text-zinc-400"
              aria-label={gettext("Yesterday (day-over-day comparison)")}
            >
              <span
                class="inline-block h-0.5 w-4 rounded border-t border-dashed border-zinc-400 dark:border-zinc-500"
                aria-hidden="true"
              />
              <span class="text-xs">
                {gettext("Yesterday")}
              </span>
            </span>
          <% end %>
          <%= for {series, label} <- @chart.series_legend do %>
            <% {base, shade} = Map.get(@chart.series_palette, series) %>
            <% legend_key =
              "series:#{elem(series, 0)}:#{elem(series, 1)}:#{elem(series, 2)}" %>
            <button
              type="button"
              class="legend-toggle inline-flex items-center gap-1.5 cursor-pointer rounded px-1 py-0.5 hover:bg-zinc-100 dark:hover:bg-zinc-700/50"
              data-legend-key={legend_key}
              aria-pressed="true"
            >
              <span
                class={"legend-swatch inline-block h-2.5 w-2.5 rounded-sm bg-#{base}-#{shade}"}
                aria-hidden="true"
              />
              <span class="text-zinc-700 dark:text-zinc-300">{label}</span>
            </button>
          <% end %>
        </div>
      <% end %>

      <%!-- Empty-state message: shown when there's no
                 production data for the day (e.g. at night, on
                 a fresh account, or before any data has been
                 logged). Sits BELOW the chart (and the legend,
                 if present) in normal document flow — the SVG
                 above stays fully visible so the cloud-cover
                 band, axes, gridlines, sun markers, and now
                 marker remain unobstructed. The earlier
                 absolute-positioned overlay (with a 70% opaque
                 card centred on top of the SVG) covered the
                 cloud band and made the dashboard look
                 chartless at night. --%>
      <%= if @chart.path_data == "" do %>
        <div
          class="mt-3 flex items-center gap-2 text-xs text-zinc-500 dark:text-zinc-400"
          id="empty-chart"
        >
          <.icon name="hero-presentation-chart-line" class="h-4 w-4" />
          <p>{gettext("No power readings logged for this day.")}</p>
        </div>
      <% end %>
    </div>

    <%!-- Colocated JS hook: shows a vertical guide line + a
             tooltip with the time and per-series power at the
             cursor's position. The tooltip body is rendered
             directly into the DOM (no LiveView round-trip) so
             it stays smooth on hover. Series data is read
             from the SVG's `data-series` / `data-points`
             attributes; the time range from `data-x-min-seconds`
             / `data-x-max-seconds`. --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ChartTooltip">
      export default {
        mounted() {
          // The chart X-axis labels and the bucket times
          // embedded in `data-points` are pre-shifted to
          // LOCAL time on the server (`assign_line_chart_data/5`
          // applies `tz_offset_seconds`). The chart range, the
          // tooltip body and the cursor math all use those
          // local values directly — no client-side timezone
          // conversion is needed here.
          this.svg = this.el.querySelector("#solar-chart-svg");
          this.guide = this.svg.querySelector("#chart-guide-line");
          this.tooltip = this.svg.querySelector("#chart-tooltip");
          this.body = this.svg.querySelector("#chart-tooltip-body");
          this.legend = this.el.querySelector("#chart-legend");

          this.xMin = parseFloat(this.svg.dataset.xMinSeconds);
          this.xMax = parseFloat(this.svg.dataset.xMaxSeconds);

          // Track which series the user has hidden via the
          // legend so the tooltip can skip them on the next
          // hover. Keys survive LiveView re-renders because
          // they're derived from the server template, not
          // from DOM node identity.
          this.hiddenKeys = new Set();

          this.series = Array.from(
            this.svg.querySelectorAll("path[data-series][data-points]")
          ).map((p) => ({
            meta: JSON.parse(p.dataset.series),
            points: JSON.parse(p.dataset.points),
            color: p.dataset.stroke,
            key: p.dataset.legendKey || null
          }));

          // Push the browser's UTC offset (in seconds,
          // positive east of UTC) so the LiveView can
          // re-render labels / chart range with the right
          // timezone. The very first render uses the default
          // offset of 0 (UTC) until this fires — see the
          // `set_timezone` handler in DashboardLive.
          const offsetMinutes = new Date().getTimezoneOffset();
          const offsetSeconds = -offsetMinutes * 60;
          this.pushEvent("set_timezone", {
            offset_seconds: String(offsetSeconds)
          });

          // Note: geolocation used to be auto-requested here
          // on every dashboard mount. The cloud-cover card
          // now owns that flow (see `.RequestLocation` in
          // the cloud-cover card slot) — the user clicks a
          // "Share location" button to opt in. Sun markers
          // still depend on captured coords; if the user
          // grants via the card, the next dashboard mount
          // (or a LiveView re-render after `set_location`)
          // will paint them.

          // Legend click -> toggle the matching path's
          // `display:none`. No LiveView round-trip needed;
          // the next hover rebuilds the tooltip rows from
          // `this.series` and skips anything in
          // `this.hiddenKeys`.
          this.legendClick = (e) => {
            const btn = e.target.closest("button.legend-toggle");
            if (!btn) return;
            const key = btn.dataset.legendKey;
            if (!key) return;
            // Re-query the SVG path on every click rather than
            // caching it in `pathsByKey`. LiveView re-renders
            // swap the path elements out for fresh ones, so a
            // cached reference would point at a detached node
            // that no longer affects what's on screen.
            const path = this.svg.querySelector(
              `path[data-legend-key="${CSS.escape(key)}"]`
            );
            if (!path) return;
            const nowHidden = !this.hiddenKeys.has(key);
            if (nowHidden) {
              this.hiddenKeys.add(key);
              path.style.display = "none";
              btn.setAttribute("aria-pressed", "false");
              btn.classList.add("opacity-40");
            } else {
              this.hiddenKeys.delete(key);
              path.style.display = "";
              btn.setAttribute("aria-pressed", "true");
              btn.classList.remove("opacity-40");
            }
          };
          // Listen on the hook container (`#solar-chart-container`)
          // rather than `#chart-legend` so the handler survives
          // LiveView re-renders that swap the legend strip out
          // for a fresh one — events from the new buttons still
          // bubble up to the container, and we re-query the
          // matching path on every click so we still operate on
          // the live DOM node.
          this.el.addEventListener("click", this.legendClick);

          this.handlers = {
            mousemove: (e) => this.move(e),
            mouseleave: () => this.hide(),
            touchstart: (e) => this.move(e),
            touchmove: (e) => this.move(e),
            touchend: () => this.hide(),
            touchcancel: () => this.hide(),
            resize: () => this.refRect()
          };

          for (const [event, handler] of Object.entries(this.handlers)) {
            if (event === "resize") {
              window.addEventListener(event, handler);
            } else {
              this.svg.addEventListener(event, handler, { passive: true });
            }
          }

          // Now-marker live tick. The server-rendered X
          // position + HH:MM label are correct at render
          // time but don't advance on their own — without
          // this tick the line drifts stale whenever the
          // tab is open longer than the next reading tick
          // (which can be minutes on a quiet inverter).
          // Refresh every 15 s: cheap (one render of four
          // attributes + a text content write) and small
          // enough that the line visibly tracks the
          // minute. The browser's `getHours/getMinutes`
          // already return LOCAL time, so no TZ math is
          // needed here — the chart's `xMin/xMax` are
          // server-computed in the user's local TZ too.
          this.refreshNowMarkerRefs();
          this.tickNowMarker();
          this.nowMarkerInterval = setInterval(
            () => this.tickNowMarker(),
            15000
          );
        },

        updated() {
          // LiveView patch re-rendered the SVG (e.g. user
          // switched time range, or a reading tick
          // re-ran `assign_line_chart_data/5`). The
          // server-side `data-x-min-seconds` /
          // `data-x-max-seconds` may have shifted, and the
          // now-marker nodes themselves may have been
          // swapped for fresh ones. Re-parse the range
          // and re-query the now-marker refs so the next
          // tick hits the live DOM.
          this.xMin = parseFloat(this.svg.dataset.xMinSeconds);
          this.xMax = parseFloat(this.svg.dataset.xMaxSeconds);
          this.refreshNowMarkerRefs();
        },

        destroyed() {
          for (const [event, handler] of Object.entries(this.handlers)) {
            if (event === "resize") {
              window.removeEventListener(event, handler);
            } else {
              this.svg.removeEventListener(event, handler);
            }
          }
          if (this.legendClick) {
            this.el.removeEventListener("click", this.legendClick);
          }
          if (this.nowMarkerInterval) {
            clearInterval(this.nowMarkerInterval);
            this.nowMarkerInterval = null;
          }
        },

        refreshNowMarkerRefs() {
          // Re-query the SVG + now-marker nodes on every
          // mount / update. LiveView's diffing keeps the
          // `phx-hook` container but may swap the inner
          // `<svg>` + `<g id="now-marker">` for fresh
          // nodes on a patch, so cached refs would point
          // at detached DOM the next tick. Returns nothing;
          // mutates `this.nowMarker{,Line,Pill,Text}` to
          // either real nodes or null (historical-day
          // views render no marker → all nulls).
          this.svg = this.el.querySelector("#solar-chart-svg");
          this.nowMarker = this.svg
            ? this.svg.querySelector("#now-marker")
            : null;
          this.nowMarkerLine = this.nowMarker
            ? this.nowMarker.querySelector("#now-marker-line")
            : null;
          this.nowMarkerPill = this.nowMarker
            ? this.nowMarker.querySelector("#now-marker-pill")
            : null;
          this.nowMarkerText = this.nowMarker
            ? this.nowMarker.querySelector("#now-marker-text")
            : null;
        },

        tickNowMarker() {
          if (
            !this.nowMarker ||
            !this.nowMarkerLine ||
            !this.nowMarkerPill ||
            !this.nowMarkerText
          ) {
            return;
          }

          const d = new Date();
          const seconds =
            d.getHours() * 3600 +
            d.getMinutes() * 60 +
            d.getSeconds();
          const span = this.xMax - this.xMin;

          // Out-of-range: local time falls outside the
          // chart's X window (e.g. 03:00 on a 06:00–22:00
          // historical-day view). Hide the marker rather
          // than draw it at a clamped edge — the same
          // behaviour as the server-side `now_marker_x`
          // returning nil.
          if (span <= 0 || seconds < this.xMin || seconds > this.xMax) {
            this.nowMarker.style.display = "none";
            return;
          }

          this.nowMarker.style.display = "";
          const x = ((seconds - this.xMin) / span) * 800;
          this.nowMarkerLine.setAttribute("x1", String(x));
          this.nowMarkerLine.setAttribute("x2", String(x));
          this.nowMarkerPill.setAttribute("x", String(x - 18));
          this.nowMarkerText.setAttribute("x", String(x));
          this.nowMarkerText.textContent =
            String(d.getHours()).padStart(2, "0") +
            ":" +
            String(d.getMinutes()).padStart(2, "0");
        },

        refRect() {
          this.rect = this.svg.getBoundingClientRect();
          // The SVG declares `viewBox="0 0 800 280"` and
          // stretches to the container's full width via
          // `class="w-full"`. When the container is wider
          // than 800 CSS px (desktop), one user unit maps
          // to (rect.width / 800) CSS px; when narrower
          // (mobile), one user unit maps to less. The
          // cursor's local `x` and the tooltip's flip
          // threshold live in CSS px, but the `<line x1
          // x2>` and `<foreignObject x>` attributes we
          // write are in user units — so we compute the
          // scale once per layout pass and convert at
          // write time. Falls back to 1:1 if the SVG
          // hasn't been laid out yet (rect.width = 0 →
          // divide-by-zero would otherwise blow up
          // later).
          this.scaleX = this.rect.width > 0 ? this.rect.width / 800 : 1;
        },

        move(e) {
          e.preventDefault();
          const touch = e.touches && e.touches[0];
          const clientX = touch ? touch.clientX : e.clientX;
          this.refRect();
          const x = clientX - this.rect.left;
          if (x < 0 || x > this.rect.width) {
            this.hide();
            return;
          }

          const span = this.xMax - this.xMin;
          const time = span > 0
            ? this.xMin + (x / this.rect.width) * span
            : this.xMin;

          // The guide line's x1/x2 attributes are in user
          // units; convert from the cursor's CSS-pixel
          // offset so the line sits at the cursor on
          // desktop (where rect.width > 800) and mobile
          // alike.
          const xUnits = x / this.scaleX;
          this.guide.setAttribute("x1", String(xUnits));
          this.guide.setAttribute("x2", String(xUnits));
          this.guide.style.display = "";

          // Drop rows whose legend entry was toggled off
          // before computing nearest-bucket lookup.
          const rows = this.series
            .filter((s) => s.points.length > 0)
            .filter((s) => !this.hiddenKeys.has(s.key))
            .map((s) => {
              const nearest = this.nearest(s.points, time);
              return { ...s, value: nearest ? nearest.power : null };
            })
            // Total, Consumption, and Net flow are headline
            // metrics — sort them above the per-inverter lines
            // so the first thing the reader sees in the tooltip
            // is generation, draw, and net flow (in that
            // order). Otherwise preserve server render order.
            .sort((a, b) => {
              const rank = (m) =>
                m.is_total ? 0 : m.is_consumption ? 1 : m.is_net ? 2 : 3;
              return rank(a.meta) - rank(b.meta);
            });

          this.body.innerHTML = this.renderRows(time, rows);

          // Position the tooltip just to the right of
          // the cursor (4 px gap so it hugs the guide
          // line without overlapping the data point);
          // flip to the left when there's no room. The
          // flip decision + the gap math are in CSS px
          // (measured against the cursor's local x) so
          // the visual feel is identical on desktop and
          // mobile — and `tooltipWidthCss` accounts for
          // the fact that the foreignObject's static
          // `width="200"` is in user units, so the box
          // actually renders at 200 * scaleX CSS px.
          const tooltipWidthCss = 200 * this.scaleX;
          const tooltipLeftCss =
            x > this.rect.width - tooltipWidthCss - 20
              ? Math.max(0, x - tooltipWidthCss - 10)
              : Math.min(this.rect.width - tooltipWidthCss, x + 4);
          // The foreignObject's `x` attribute is in user
          // units; convert from the CSS-pixel position
          // we just chose. Without this conversion the
          // tooltip lands at (x * scaleX) CSS px — i.e.
          // further from the cursor on every viewport
          // wider than 800 CSS px (desktop).
          this.tooltip.setAttribute(
            "x",
            String(tooltipLeftCss / this.scaleX)
          );
          this.tooltip.style.display = "";
        },

        hide() {
          if (this.guide) this.guide.style.display = "none";
          if (this.tooltip) this.tooltip.style.display = "none";
        },

        nearest(points, time) {
          // `points` is sorted ascending by time; binary search
          // for the closest entry to the cursor's time.
          let lo = 0;
          let hi = points.length - 1;
          while (lo < hi) {
            const mid = (lo + hi) >> 1;
            if (points[mid].time < time) lo = mid + 1;
            else hi = mid;
          }
          const a = points[lo - 1];
          const b = points[lo];
          if (!a) return b;
          if (!b) return a;
          return Math.abs(a.time - time) < Math.abs(b.time - time) ? a : b;
        },

        seriesLabel(meta) {
          // Per-MPPT lines were collapsed into the
          // inverter's AC row on the server (see the
          // `Enum.filter` in `assign_line_chart_data/5`),
          // so the tooltip only ever sees the Total /
          // Consumption / Net-flow pseudo-series or one
          // row per inverter. No `MPPT N` / `(AC)` suffix
          // is needed.
          if (meta.is_total) return meta.name || "Total";
          if (meta.is_consumption) return meta.name || "Consumption";
          if (meta.is_net) return meta.name || "Net flow";
          return meta.name || meta.serial || "";
        },

        renderRows(time, rows) {
          const hh = String(Math.floor(time / 3600)).padStart(2, "0");
          const mm = String(Math.floor((time % 3600) / 60)).padStart(2, "0");
          const header =
            '<div class="font-semibold mb-1 tabular-nums">' +
            hh + ":" + mm +
            "</div>";
          const body = rows
            .map((r) => {
              const val = r.value == null ? "—" : Math.round(r.value) + " W";
              const swatch =
                '<span class="inline-block h-2 w-2 rounded-sm mr-1.5" ' +
                'style="background-color:' + r.color + '"></span>';
              const rowClass = r.meta.is_total
                ? "flex items-center justify-between gap-3 font-semibold"
                : "flex items-center justify-between gap-3";
              return (
                '<div class="' + rowClass + '">' +
                '<span class="truncate">' + swatch + this.escape(this.seriesLabel(r.meta)) + "</span>" +
                '<span class="tabular-nums font-medium">' + val + "</span>" +
                "</div>"
              );
            })
            .join("");
          return header + body;
        },

        escape(s) {
          return String(s).replace(/[&<>"']/g, (c) => ({
            "&": "&amp;",
            "<": "&lt;",
            ">": "&gt;",
            '"': "&quot;",
            "'": "&#39;"
          })[c]);
        }
      }
    </script>
    """
  end
end
