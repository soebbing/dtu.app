defmodule DtuAppWeb.ChartTitle do
  @moduledoc """
  The `<h2>` heading rendered above the chart panel.

  Picks one of nine title strings based on the dashboard's current
  view state (`@live`, `@has_inverter?`, `@has_shelly?`,
  `@time_range`, `@selected_period`):

    * **Consumption-only, live** — "Today's Consumption Curve (Watts)"
    * **Consumption-only, day** — "Consumption Curve for %{period} (Watts)"
    * **Production, live** — "Today's Production Curve (Watts)"
    * **Production, day** — "Production Curve for %{period} (Watts)"
    * **Production, week** — "Daily Yields for Week starting %{period} (kWh)"
    * **Production, month** — "Daily Yields for month of %{month_year} (kWh)"
      where `month_year` is the localized month name (via
      `Gettext.gettext/2` on `Calendar.strftime(.., "%B")`) followed
      by the year.
    * **Production, year** — "Monthly Yields for %{year} (kWh)"
    * **Production, 7d / 30d** — "Daily Yields — Last 7/30 days (kWh)"
    * **Production, ytd** — "Monthly Yields — Year to date (kWh)"

  The German month-name path on the month branch is the only call
  site of explicit `Gettext.gettext/2` in the dashboard template
  (the rest go through the `gettext/1` macro on the Gettext backend,
  which is implicit via `use Gettext`). Pulling the whole title into
  a function component gives the German-only branch a stable
  unit-test surface — a render-only test can pin the locale without
  spinning up a full LiveView.

  Was an inline `<%= cond do %>` block in
  `DtuAppWeb.DashboardLive.html.heex` (formerly lines 334-360).
  Extracted so the dashboard template stays focused on page-level
  layout and so the nine-case decision tree has a stable
  unit-test surface.

  Sister to `DtuAppWeb.DeviceStatusCard` (PR #274),
  `DtuAppWeb.ConsumptionStatCards` (PR #275), and
  `DtuAppWeb.NetFlowStatCards` (PR #276).
  """

  use DtuAppWeb, :html

  attr :live, :boolean,
    default: false,
    doc: "Whether the dashboard is rendering the live / today view."

  attr :has_inverter, :boolean,
    default: false,
    doc: "Whether the account has at least one inverter-kind DTU."

  attr :has_shelly, :boolean,
    default: false,
    doc: "Whether the account has at least one Shelly-kind DTU."

  attr :time_range, :string,
    default: "day",
    doc: "Active time range — one of day / week / month / year / 7d / 30d / ytd / custom."

  attr :selected_period, :any,
    default: nil,
    doc: """
    Currently selected period. `Date.t()` for day / week / 7d / 30d,
    `%{month: 1..12, year: 2024..}` for month, `%{year: 2024..}`
    for year / ytd. Unused on the consumption-only branches and on
    7d / 30d / ytd.
    """

  def chart_title(assigns) do
    ~H"""
    <h2 class="text-lg font-medium text-zinc-900 dark:text-white mb-4" id="chart-title">
      <%= cond do %>
        <% not @has_inverter and @has_shelly and @live -> %>
          {gettext("Today's Consumption Curve (Watts)")}
        <% not @has_inverter and @has_shelly and @time_range == "day" -> %>
          {gettext("Consumption Curve for %{period} (Watts)", period: @selected_period)}
        <% @live -> %>
          {gettext("Today's Production Curve (Watts)")}
        <% @time_range == "day" -> %>
          {gettext("Production Curve for %{period} (Watts)", period: @selected_period)}
        <% @time_range == "week" -> %>
          {gettext("Daily Yields for Week starting %{period} (kWh)", period: @selected_period)}
        <% @time_range == "month" -> %>
          {gettext("Daily Yields for month of %{month_year} (kWh)",
            month_year:
              "#{Gettext.gettext(DtuAppWeb.Gettext, Calendar.strftime(@selected_period, "%B"))} #{@selected_period.year}"
          )}
        <% @time_range == "year" -> %>
          {gettext("Monthly Yields for %{year} (kWh)", year: @selected_period.year)}
        <% @time_range == "7d" -> %>
          {gettext("Daily Yields — Last 7 days (kWh)")}
        <% @time_range == "30d" -> %>
          {gettext("Daily Yields — Last 30 days (kWh)")}
        <% @time_range == "ytd" -> %>
          {gettext("Monthly Yields — Year to date (kWh)")}
      <% end %>
    </h2>
    """
  end
end
