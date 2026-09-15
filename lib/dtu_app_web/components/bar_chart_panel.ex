defmodule DtuAppWeb.BarChartPanel do
  @moduledoc """
  The fallback `<svg>` chart panel rendered when the dashboard
  resolves `@chart_type` to a non-`:line` variant (the daily-yields
  bar chart used by the week / month / year / 7d / 30d / ytd views
  where the bar form is more legible than the line form).

  Branch behaviour:

    * **Empty** — every bar in `@bars` has `value == 0.0` (e.g. a
      freshly-created account, no readings yet for the selected
      period, or a period that genuinely produced no yield). Renders
      the dashed-border empty-state card with
      `id="empty-chart"` and the "No yield records logged for this
      period." copy. Same id as the line-chart empty-state — the
      dashboard test suite keys off `id="empty-chart"` regardless
      of which chart type is selected.
    * **Has bars** — renders the `<svg id="solar-chart-svg">` with
      three horizontal gridlines, three y-axis labels (top / mid /
      bottom in kWh, formatted via `Devices.format_number/3` with
      the `@locale` for de_DE grouping), and one `<g class="group">`
      per bar (rect + hover-value label + x-axis label). The rect
      uses an emerald linear gradient (`#barGrad`). Hover behaviour
      is pure CSS (`group-hover:opacity-100`).

  Was the inline `<% else %>` block in
  `DtuAppWeb.DashboardLive.html.heex` (formerly lines 1467-1567).
  Extracted so the dashboard template keeps the chart-type switch
  but the bar-chart fallback has its own render-only test surface
  and its own id / palette / hover details.

  Sister to `DtuAppWeb.DeviceStatusCard` (PR #274),
  `DtuAppWeb.ConsumptionStatCards` (PR #275),
  `DtuAppWeb.NetFlowStatCards` (PR #276),
  `DtuAppWeb.ChartTitle` (PR #277), and
  `DtuAppWeb.LineChartPanel` (PR #279).
  """

  use DtuAppWeb, :html

  alias DtuApp.Devices

  attr :bars, :list,
    default: [],
    doc: """
    List of bar descriptors. Each item is a map with
    `:x` / `:y` / `:w` / `:h` (pixel coordinates inside the
    800×250 SVG viewBox), `:label` (x-axis text), and `:value`
    (kWh, used in both the rect height and the hover label).
    Built by `DtuAppWeb.DashboardLive.LineChartData.assign_bar_chart_data/2`.
    """

  attr :y_max, :any,
    default: 0.0,
    doc: """
    Top y-axis tick value in kWh (already rounded to a clean
    5.0/10.0/ceil bucket — `DtuAppWeb.DashboardLive.LineChartData`
    picks the smallest bucket ≤ the period's actual max). Rendered
    in the top y-axis label and divided by 2 for the mid label.
    """

  attr :locale, :string,
    default: "en",
    doc: """
    BCP-47 locale used by `Devices.format_number/3` for the
    thousands separator / decimal mark on every y-axis label and
    every per-bar hover value.
    """

  def bar_chart_panel(assigns) do
    ~H"""
    <%= if Enum.all?(@bars, &(&1.value == 0.0)) do %>
      <div
        class="flex flex-col items-center justify-center h-64 border-2 border-dashed border-zinc-300 dark:border-zinc-700 rounded-lg"
        id="empty-chart"
      >
        <.icon name="hero-presentation-chart-bar" class="h-12 w-12 text-zinc-400 mb-2" />
        <p class="text-sm text-zinc-500 dark:text-zinc-400">
          {gettext("No yield records logged for this period.")}
        </p>
      </div>
    <% else %>
      <div class="relative w-full overflow-hidden" id="solar-chart-container">
        <svg
          viewBox="0 0 800 250"
          class="w-full h-auto overflow-visible"
          id="solar-chart-svg"
        >
          <defs>
            <linearGradient id="barGrad" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stop-color="#10b981" stop-opacity="0.85" />
              <stop offset="100%" stop-color="#047857" stop-opacity="0.95" />
            </linearGradient>
          </defs>

          <!-- Grid Lines -->
          <line
            x1="0"
            y1="20"
            x2="800"
            y2="20"
            stroke="#f4f4f5"
            class="dark:stroke-zinc-700"
            stroke-width="1"
          />
          <line
            x1="0"
            y1="120"
            x2="800"
            y2="120"
            stroke="#f4f4f5"
            class="dark:stroke-zinc-700"
            stroke-width="1"
            stroke-dasharray="4"
          />
          <line
            x1="0"
            y1="220"
            x2="800"
            y2="220"
            stroke="#e4e4e7"
            class="dark:stroke-zinc-600"
            stroke-width="1.5"
          />

          <!-- Y-Axis Labels -->
          <text x="5" y="32" class="text-[10px] font-medium fill-zinc-400">
            {Devices.format_number(@y_max, 1, @locale)} kWh
          </text>
          <text x="5" y="128" class="text-[10px] font-medium fill-zinc-400">
            {Devices.format_number(Float.round(@y_max / 2, 2), 1, @locale)} kWh
          </text>
          <text x="5" y="215" class="text-[10px] font-medium fill-zinc-400">0 kWh</text>

          <!-- Draw Bars -->
          <%= for bar <- @bars do %>
            <g class="group">
              <rect
                x={bar.x}
                y={bar.y}
                width={bar.w}
                height={bar.h}
                fill="url(#barGrad)"
                rx="4"
                class="transition-all duration-200 hover:fill-emerald-400 cursor-pointer"
              />
              <!-- Hover tooltip showing value -->
              <text
                x={bar.x + bar.w / 2}
                y={max(bar.y - 6.0, 15.0)}
                text-anchor="middle"
                class="text-[9px] font-bold fill-zinc-800 dark:fill-white opacity-0 group-hover:opacity-100 transition-opacity duration-150 pointer-events-none"
              >
                {Devices.format_number(bar.value, 1, @locale)}
              </text>
              <!-- X label -->
              <text
                x={bar.x + bar.w / 2}
                y="238"
                text-anchor="middle"
                class="text-[9px] font-semibold fill-zinc-550 dark:fill-zinc-400"
              >
                {bar.label}
              </text>
            </g>
          <% end %>
        </svg>
      </div>
    <% end %>
    """
  end
end
