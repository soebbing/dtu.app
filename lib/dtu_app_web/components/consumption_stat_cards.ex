defmodule DtuAppWeb.ConsumptionStatCards do
  @moduledoc """
  The "Power consumption" stat-card row rendered between the
  production `<.stat_card_row>` and the chart panel.

  Mirrors the production row's three-card layout — Total /
  Today's / Peak — but populated from a paired Shelly Plus 3EM
  (Gen3+) energy meter. Rose colour scheme matches the existing
  consumption card above; the icon set swaps between
  `hero-bolt` (total), `hero-sun` (today), `hero-chart-bar`
  (peak), and `hero-fire` (peak-power-day on historical views).

  Only rendered when the user has consumption data — a user
  without a Shelly device sees nothing here, exactly the same as
  a user without an inverter (the production row renders empty
  too). The same `@consumption_period_stats.current_consumption
  > 0 or period_total_consumption > 0 or peak_consumption > 0`
  guard gates the whole `<div class="space-y-2 pt-2">` block so
  the empty case is one branch and the populated case is the
  three-card row.

  Card layout adapts to the current view:

    * Live / Day (`@live or @time_range == "day"`) — Today's
      Consumption (kWh) + Peak Power Consumed (W). The Total
      slot is omitted: on the live view the household's
      instantaneous wattage lives in the production row's
      "Current Generation" card; the Total placeholder would
      otherwise echo the day's number and waste a column.
    * Historical (week / month / year / 7d / 30d / ytd) —
      Total Consumption (kWh) + Today's Consumption (kWh) +
      Peak Power Day (W + optional "on %{date}" sub-label).

  Was an inline ~190-line `<%= if … %>` block in
  `DtuAppWeb.DashboardLive.html.heex` (formerly lines 300-492).
  Extracted so the dashboard template stays focused on
  page-level layout and so the per-card render branches have a
  stable unit-test surface (the conditional Total placeholder +
  Peak-power-day peak-date rendering were previously only
  reachable through full LiveView mounts).

  See `DtuAppWeb.DeviceStatusCard` (sibling) and
  `DtuAppWeb.DashboardLive.Components.StatCardRow` (the
  production-side analogue) for the established extraction
  pattern.
  """

  use DtuAppWeb, :html

  alias DtuApp.Devices

  attr :consumption_period_stats, :map,
    required: true,
    doc: """
    Map with the consumption period stats. Required keys:
    `:current_consumption` (W, float), `:today_consumption`
    (kWh, float), `:peak_consumption` (W, float),
    `:period_total_consumption` (kWh, float),
    `:period_peak_consumption` (W, float), `:peak_date`
    (Date.t() | nil).
    """

  attr :live, :boolean,
    default: false,
    doc: "Whether the dashboard is rendering the live / today view."

  attr :time_range, :string,
    default: "day",
    doc: "Active time range — one of day / week / month / year / 7d / 30d / ytd / custom."

  attr :selected_period, :any,
    default: nil,
    doc:
      "Currently selected period (Date.t() | %{month: ..., year: ...} | …). Unused by this component but kept for parity with the production stat_card_row."

  attr :locale, :string,
    default: "en",
    doc: "Locale string for number formatting (passed to `Devices.format_number/3`)."

  def consumption_stat_cards(assigns) do
    ~H"""
    <%= if @consumption_period_stats.current_consumption > 0
              or @consumption_period_stats.period_total_consumption > 0
              or @consumption_period_stats.peak_consumption > 0 do %>
      <div class="space-y-2 pt-2">
        <h2 class="text-sm font-semibold text-zinc-700 dark:text-zinc-300 uppercase tracking-wider">
          {gettext("Power consumption")}
        </h2>
        <div class="grid grid-cols-1 gap-5 sm:grid-cols-2 lg:grid-cols-4">
          <%= if not (@live or @time_range == "day") do %>
            <%!-- Total consumption placeholder: keeps the 3-column grid
                     layout aligned with the production row above on
                     historical views. Filled with the period total.
                     On the live / day view this slot is empty — the
                     household's instantaneous wattage now lives in the
                     production row's "Current Generation" card (the
                     net-flow chart and Net flow stat card still
                     surface the underlying consumption). --%>
            <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
              <div class="px-4 py-5 sm:p-6">
                <div class="flex items-center">
                  <div class="p-3 rounded-md bg-rose-50 dark:bg-rose-950/30 text-rose-600 dark:text-rose-400">
                    <.icon name="hero-bolt" class="h-6 w-6" />
                  </div>
                  <div class="ml-5 w-0 flex-1">
                    <dl>
                      <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                        {gettext("Total Consumption")}
                      </dt>
                      <dd class="flex items-baseline">
                        <div
                          class="text-3xl font-semibold text-zinc-900 dark:text-white"
                          id="stat-period-total-consumption"
                        >
                          {Devices.format_number(
                            @consumption_period_stats.period_total_consumption,
                            1,
                            @locale
                          )} kWh
                        </div>
                      </dd>
                    </dl>
                  </div>
                </div>
              </div>
            </div>
          <% end %>

          <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
            <div class="px-4 py-5 sm:p-6">
              <div class="flex items-center">
                <div class="p-3 rounded-md bg-rose-50 dark:bg-rose-950/30 text-rose-600 dark:text-rose-400">
                  <.icon name="hero-sun" class="h-6 w-6" />
                </div>
                <div class="ml-5 w-0 flex-1">
                  <dl>
                    <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                      {gettext("Today's Consumption")}
                    </dt>
                    <dd class="flex items-baseline">
                      <div
                        class="text-3xl font-semibold text-zinc-900 dark:text-white"
                        id={
                          if @live,
                            do: "stat-today-consumption-period",
                            else: "stat-today-consumption-period-historical"
                        }
                      >
                        {Devices.format_number(
                          @consumption_period_stats.today_consumption,
                          1,
                          @locale
                        )} kWh
                      </div>
                    </dd>
                  </dl>
                </div>
              </div>
            </div>
          </div>

          <%= if @live or @time_range == "day" do %>
            <%!-- Peak power consumed in the period (W) — mirrors
                     "Peak Power" on the production side. --%>
            <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
              <div class="px-4 py-5 sm:p-6">
                <div class="flex items-center">
                  <div class="p-3 rounded-md bg-rose-50 dark:bg-rose-950/30 text-rose-600 dark:text-rose-400">
                    <.icon name="hero-chart-bar" class="h-6 w-6" />
                  </div>
                  <div class="ml-5 w-0 flex-1">
                    <dl>
                      <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                        {gettext("Peak Power Consumed")}
                      </dt>
                      <dd class="flex items-baseline">
                        <div
                          class="text-3xl font-semibold text-zinc-900 dark:text-white"
                          id="stat-peak-consumption"
                        >
                          {Devices.format_number(
                            @consumption_period_stats.peak_consumption,
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
          <% else %>
            <%!-- Week/Month/Year: peak-power day. Mirrors the
                     production-side Peak Yield Day slot. --%>
            <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
              <div class="px-4 py-5 sm:p-6">
                <div class="flex items-center">
                  <div class="p-3 rounded-md bg-rose-50 dark:bg-rose-950/30 text-rose-600 dark:text-rose-400">
                    <.icon name="hero-fire" class="h-6 w-6" />
                  </div>
                  <div class="ml-5 w-0 flex-1">
                    <dl>
                      <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                        {gettext("Peak Power Day")}
                      </dt>
                      <dd class="flex flex-col">
                        <div
                          class="text-2xl font-semibold text-zinc-900 dark:text-white"
                          id="stat-peak-consumption-day"
                        >
                          {Devices.format_number(
                            @consumption_period_stats.period_peak_consumption,
                            0,
                            @locale
                          )} W
                        </div>
                        <%= if @consumption_period_stats.peak_date do %>
                          <div
                            class="text-xs text-zinc-400 dark:text-zinc-500 mt-0.5"
                            id="stat-peak-consumption-day-date"
                          >
                            {gettext("on %{date}", date: @consumption_period_stats.peak_date)}
                          </div>
                        <% end %>
                      </dd>
                    </dl>
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end
end
