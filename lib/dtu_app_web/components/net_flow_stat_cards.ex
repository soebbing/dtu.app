defmodule DtuAppWeb.NetFlowStatCards do
  @moduledoc """
  The "Net flow" stat-card row rendered between the consumption
  row and the chart panel.

  Net flow = production − consumption. Positive means exporting
  to the grid, negative means importing. The row only appears
  for paired-inverter-and-shelly users — without an inverter
  there's nothing to net against (a Shelly-only user would see a
  misleadingly-negative "Net flow = −consumption" curve).

  Four cards in a single row, each with its own colour cue:

    * **Current Net Flow** (W) — emerald when exporting (positive
      net flow), rose when importing (negative). The first card
      swaps label ("Net export" / "Net import") AND icon-container
      colour based on the sign of `current_net_flow`; the absolute
      value renders as a positive W magnitude.
    * **Exported today** (kWh, 2 decimals) — emerald. Arrow-up icon.
    * **Imported today** (kWh, 2 decimals) — rose. Arrow-down icon.
    * **Peak power** (W) — blue. Shows `max(peak_export,
      peak_import)` so a peak-export afternoon and a peak-import
      evening both surface on the same card.

  Was an inline ~185-line `<%= if … %>` block in
  `DtuAppWeb.DashboardLive.html.heex` (formerly lines 313-498).
  Extracted so the dashboard template stays focused on
  page-level layout and so the sign-aware "Current Net Flow"
  card (the only card whose label + colour + absolute-value
  branches off `current_net_flow >= 0`) has a stable unit-test
  surface. Mirrors `DtuAppWeb.ConsumptionStatCards` (PR #275,
  sibling) and `DtuAppWeb.DeviceStatusCard` (PR #274, sibling)
  in the established extraction pattern.

  The outer guard — `@has_inverter? and @has_shelly? and
  (current_net_flow != 0.0 or today_net_export > 0.0 or
  today_net_import > 0.0)` — stays in the dashboard template;
  this component only renders when the caller has decided the
  user should see the row. Pulling the guard inside would mean
  the component has to take `@has_inverter?` / `@has_shelly?`
  booleans it doesn't otherwise use.
  """

  use DtuAppWeb, :html

  alias DtuApp.Devices

  attr :net_flow_stats, :map,
    required: true,
    doc: """
    Map with the net-flow stats. Required keys:
    `:current_net_flow` (W, signed float — positive means
    exporting), `:today_net_export` (kWh, float),
    `:today_net_import` (kWh, float), `:peak_export` (W, float),
    `:peak_import` (W, float).
    """

  attr :locale, :string,
    default: "en",
    doc: "Locale string for number formatting (passed to `Devices.format_number/3`)."

  def net_flow_stat_cards(assigns) do
    ~H"""
    <div class="space-y-2 pt-2">
      <h2 class="text-sm font-semibold text-zinc-700 dark:text-zinc-300 uppercase tracking-wider">
        {gettext("Net flow")}
      </h2>
      <div class="grid grid-cols-1 gap-5 sm:grid-cols-2 lg:grid-cols-4">
        <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
          <div class="px-4 py-5 sm:p-6">
            <div class="flex items-center">
              <div class={
                    "p-3 rounded-md " <>
                      if @net_flow_stats.current_net_flow >= 0 do
                        "bg-emerald-50 dark:bg-emerald-950/30 text-emerald-600 dark:text-emerald-400"
                      else
                        "bg-rose-50 dark:bg-rose-950/30 text-rose-600 dark:text-rose-400"
                      end
                  }>
                <.icon name="hero-arrows-right-left" class="h-6 w-6" />
              </div>
              <div class="ml-5 w-0 flex-1">
                <dl>
                  <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                    {if @net_flow_stats.current_net_flow >= 0,
                      do: gettext("Net export"),
                      else: gettext("Net import")}
                  </dt>
                  <dd class="flex items-baseline">
                    <div
                      class="text-3xl font-semibold text-zinc-900 dark:text-white"
                      id="stat-net-flow"
                    >
                      {Devices.format_number(
                        abs(@net_flow_stats.current_net_flow),
                        0,
                        @locale
                      )} W
                    </div>
                  </dd>
                </dl>
              </div>
            </div>
          </div>
        </div>

        <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
          <div class="px-4 py-5 sm:p-6">
            <div class="flex items-center">
              <div class="p-3 rounded-md bg-emerald-50 dark:bg-emerald-950/30 text-emerald-600 dark:text-emerald-400">
                <.icon name="hero-arrow-up-right" class="h-6 w-6" />
              </div>
              <div class="ml-5 w-0 flex-1">
                <dl>
                  <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                    {gettext("Exported today")}
                  </dt>
                  <dd class="flex items-baseline">
                    <div
                      class="text-3xl font-semibold text-zinc-900 dark:text-white"
                      id="stat-net-export"
                    >
                      {Devices.format_number(
                        @net_flow_stats.today_net_export,
                        2,
                        @locale
                      )} kWh
                    </div>
                  </dd>
                </dl>
              </div>
            </div>
          </div>
        </div>

        <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
          <div class="px-4 py-5 sm:p-6">
            <div class="flex items-center">
              <div class="p-3 rounded-md bg-rose-50 dark:bg-rose-950/30 text-rose-600 dark:text-rose-400">
                <.icon name="hero-arrow-down-left" class="h-6 w-6" />
              </div>
              <div class="ml-5 w-0 flex-1">
                <dl>
                  <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                    {gettext("Imported today")}
                  </dt>
                  <dd class="flex items-baseline">
                    <div
                      class="text-3xl font-semibold text-zinc-900 dark:text-white"
                      id="stat-net-import"
                    >
                      {Devices.format_number(
                        @net_flow_stats.today_net_import,
                        2,
                        @locale
                      )} kWh
                    </div>
                  </dd>
                </dl>
              </div>
            </div>
          </div>
        </div>

        <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
          <div class="px-4 py-5 sm:p-6">
            <div class="flex items-center">
              <div class="p-3 rounded-md bg-blue-50 dark:bg-blue-950/30 text-blue-600 dark:text-blue-400">
                <.icon name="hero-chart-bar" class="h-6 w-6" />
              </div>
              <div class="ml-5 w-0 flex-1">
                <dl>
                  <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                    {gettext("Peak power")}
                  </dt>
                  <dd class="flex items-baseline">
                    <div
                      class="text-3xl font-semibold text-zinc-900 dark:text-white"
                      id="stat-net-peak"
                    >
                      {Devices.format_number(
                        max(
                          @net_flow_stats.peak_export,
                          @net_flow_stats.peak_import
                        ),
                        0,
                        @locale
                      )} W
                    </div>
                  </dd>
                </dl>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
