defmodule DtuAppWeb.DashboardLive.Components do
  @moduledoc """
  Dashboard-specific HEEx function components.

  Extracted from `DtuAppWeb.DashboardLive`'s `render/1` so the
  LiveView's template stays focused on its render-flow concerns
  (the chart, the SVG, the toolbar glue) and the four most
  self-contained template blocks live as named, reusable pieces.

  Sister modules under `dashboard_live/`:
    * `ChartHelpers` — pure SVG math (X-axis range, gridlines,
      time-to-pixel, sun markers, "now" indicator)
    * `ChartPalette` — per-series colour assignment + Tailwind
      hex lookup
    * `TimeHelpers` — pure date/time math (`local_today/1`,
      `format_peak_time/2`, …)
    * `PeriodSelectable` — selectable-period builders +
      calendar-input helpers

  This module owns the function components consumed by the
  dashboard's render:
    * `<.dtu_switcher>`           — toolbar DTU picker
    * `<.quick_range_switcher>`   — toolbar preset buttons (1D/7D/30D/YTD/Custom)
    * `<.quick_range_btn>`        — single preset button (used inside the switcher)
    * `<.historical_stepper>`     — toolbar period stepper (when preset == "custom")
    * `<.stat_card_row>`          — the 3-7-up stats grid
  """

  use Phoenix.Component
  use Gettext, backend: DtuAppWeb.Gettext

  import DtuAppWeb.CoreComponents, only: [icon: 1]

  import DtuAppWeb.DashboardLive.PeriodSelectable,
    only: [
      date_input_value: 1,
      date_min_bound: 1,
      date_max_bound: 1,
      historical_empty?: 5
    ]

  # `stepper_label/2` lives here because it's only used by the
  # historical stepper template; the LiveView no longer needs it.
  defp stepper_label(%Date{} = date, "day"), do: Calendar.strftime(date, "%a %b %-d, %Y")

  defp stepper_label(%Date{} = date, "week"),
    do: gettext("Week of %{date}", date: Calendar.strftime(date, "%b %-d, %Y"))

  defp stepper_label(%Date{} = date, "month"), do: Calendar.strftime(date, "%B %Y")
  defp stepper_label(%Date{} = date, "year"), do: to_string(date.year)
  defp stepper_label(year, _), do: to_string(year)

  # ------------------------------------------------------------------
  # <.dtu_switcher>
  # ------------------------------------------------------------------

  @doc """
  Toolbar DTU picker: a row of buttons — first "Total (All DTUs)",
  then one per device. The active button (the one matching
  `selected_dtu_id`, or the "Total" one when `selected_dtu_id` is
  `nil`) is highlighted with the project's emerald accent; the
  rest are quiet. Clicking posts a `select_dtu` event to the
  LiveView.

  Renders nothing when the user has zero or one device — a
  single-device user doesn't need a switcher, and a zero-device
  user can't switch to anything.

  ## Assigns

    * `:devices`          — list of `%Device{id, name, …}` structs
                            (empty / single-element lists render nothing)
    * `:selected_dtu_id`  — currently selected device id, or `nil`
                            for the "Total (All DTUs)" pseudo-button
  """
  attr :devices, :list, required: true
  attr :selected_dtu_id, :any, default: nil

  def dtu_switcher(assigns) do
    ~H"""
    <%= if length(@devices) > 1 do %>
      <div
        class="flex flex-wrap items-center gap-2 border border-zinc-200 dark:border-zinc-700 bg-zinc-50/80 dark:bg-zinc-800/40 p-1.5 rounded-xl max-w-max"
        id="dtu-switcher"
      >
        <button
          phx-click="select_dtu"
          phx-value-id="total"
          id="btn-select-total"
          class={[
            "px-3.5 py-1.5 text-xs font-semibold rounded-lg transition-all duration-250",
            is_nil(@selected_dtu_id) &&
              "bg-emerald-500 text-zinc-950 shadow-md shadow-emerald-500/10",
            !is_nil(@selected_dtu_id) &&
              "text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100 hover:bg-zinc-250/50 dark:hover:bg-zinc-700/50"
          ]}
        >
          {gettext("Total (All DTUs)")}
        </button>
        <%= for device <- @devices do %>
          <button
            phx-click="select_dtu"
            phx-value-id={device.id}
            id={"btn-select-dtu-#{device.id}"}
            class={[
              "px-3.5 py-1.5 text-xs font-semibold rounded-lg transition-all duration-250",
              @selected_dtu_id == device.id &&
                "bg-emerald-500 text-zinc-950 shadow-md shadow-emerald-500/10",
              @selected_dtu_id != device.id &&
                "text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100 hover:bg-zinc-250/50 dark:hover:bg-zinc-700/50"
            ]}
          >
            {device.name}
          </button>
        <% end %>
      </div>
    <% end %>
    """
  end

  # ------------------------------------------------------------------
  # <.quick_range_switcher> + <.quick_range_btn>
  # ------------------------------------------------------------------

  @doc """
  Toolbar preset row: 1D / 7D / 30D / YTD / Custom. The active
  preset (matching `range_preset`) is highlighted; the rest are
  quiet. Clicking posts a `select_quick_range` event to the
  LiveView.

  The five presets are fixed — the dashboard always offers the
  same five options, so they're encoded as a constant rather than
  passed in. Adding a new preset means editing this component.

  ## Assigns

    * `:range_preset` — currently active preset, one of `"1d"`,
                       `"7d"`, `"30d"`, `"ytd"`, `"custom"`
  """
  attr :range_preset, :string, required: true

  def quick_range_switcher(assigns) do
    ~H"""
    <div
      class="flex flex-wrap items-center gap-2 border border-zinc-200 dark:border-zinc-700 bg-zinc-50/80 dark:bg-zinc-800/40 p-1.5 rounded-xl max-w-max"
      id="quick-range-switcher"
    >
      <.quick_range_btn
        id="btn-range-1d"
        range="1d"
        active={@range_preset == "1d"}
      >
        {gettext("1D")}
      </.quick_range_btn>
      <.quick_range_btn
        id="btn-range-7d"
        range="7d"
        active={@range_preset == "7d"}
      >
        {gettext("7D")}
      </.quick_range_btn>
      <.quick_range_btn
        id="btn-range-30d"
        range="30d"
        active={@range_preset == "30d"}
      >
        {gettext("30D")}
      </.quick_range_btn>
      <.quick_range_btn
        id="btn-range-ytd"
        range="ytd"
        active={@range_preset == "ytd"}
      >
        {gettext("YTD")}
      </.quick_range_btn>
      <.quick_range_btn
        id="btn-range-custom"
        range="custom"
        active={@range_preset == "custom"}
      >
        {gettext("Custom")}
      </.quick_range_btn>
    </div>
    """
  end

  @doc """
  Single preset button inside `<.quick_range_switcher>`. Posts a
  `select_quick_range` event with the `range` value.

  The label/spinner toggle is driven by LiveView's
  `phx-click-loading` class — the project declares
  `@custom-variant phx-click-loading` in `assets/css/app.css` so
  the label hides and the spinner shows exactly for the duration
  of the click round-trip. We can't use `phx-disable-with` here
  because LiveView sets its value via `el.textContent`, which
  renders any embedded HTML markup as visible text instead of
  parsed HTML — that was the "literal <svg>…</svg> on the page"
  bug. Keeping both elements in the DOM and toggling them via
  the LiveView-managed class also handles rapid clicks: the
  class is added on click and removed when the response arrives,
  so no leftover text accumulates.

  ## Assigns

    * `:id`     — DOM id for the button (used by E2E tests)
    * `:range`  — value posted with `phx-click` (e.g. `"1d"`)
    * `:active` — whether this preset is currently active
    * `:inner_block` — slot for the button label content
  """
  attr :id, :string, required: true
  attr :range, :string, required: true
  attr :active, :boolean, required: true
  slot :inner_block, required: true

  def quick_range_btn(assigns) do
    ~H"""
    <button
      phx-click="select_quick_range"
      phx-value-range={@range}
      id={@id}
      class={[
        "px-3.5 py-1.5 text-xs font-semibold rounded-lg transition-all duration-250 cursor-pointer disabled:cursor-wait disabled:opacity-80 inline-flex items-center justify-center",
        @active &&
          "bg-emerald-500 text-zinc-950 shadow-md shadow-emerald-500/10",
        !@active &&
          "text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100 hover:bg-zinc-250/50 dark:hover:bg-zinc-700/50"
      ]}
    >
      <span class="phx-click-loading:hidden">
        {render_slot(@inner_block)}
      </span>
      <span
        class="hidden phx-click-loading:inline-flex items-center justify-center"
        aria-hidden="true"
      >
        <.icon name="hero-arrow-path" class="h-4 w-4 animate-spin" />
      </span>
    </button>
    """
  end

  # ------------------------------------------------------------------
  # <.historical_stepper>
  # ------------------------------------------------------------------

  @doc """
  Historical period stepper: ‹ [Granularity ▾] [Date ▾] › with
  an optional "No historical data for this period." sub-caption
  when the active granularity has no data to show.

  Renders nothing when the user picked a non-`custom` preset
  (1D/7D/30D/YTD) — those presets encode their own window and
  don't need the stepper UI. The LiveView checks `@range_preset`
  before calling this component.

  ## Assigns

    * `:granularity`        — current granularity, one of
                               `"day"`, `"week"`, `"month"`, `"year"`
    * `:selected_period`    — current period anchor (`Date` for
                               day/week/month, `integer` year for
                               year granularity)
    * `:selectable_dates`   — full list of dates with data
    * `:selectable_days`    — pre-bucketed day list (output of
                               `PeriodSelectable.build_selectable_days/1`)
    * `:selectable_weeks`   — pre-bucketed week list
    * `:selectable_months`  — pre-bucketed month list
    * `:selectable_years`   — pre-bucketed year list
    * `:live?`              — true when the current view is live
                               (live view hides the "No data" caption)
  """
  attr :granularity, :string, required: true
  attr :selected_period, :any, required: true
  attr :selectable_dates, :list, required: true
  attr :selectable_days, :list, required: true
  attr :selectable_weeks, :list, required: true
  attr :selectable_months, :list, required: true
  attr :selectable_years, :list, required: true
  attr :live, :boolean, default: false

  def historical_stepper(assigns) do
    ~H"""
    <div
      class="flex flex-wrap items-center gap-1.5 border border-zinc-200 dark:border-zinc-700 bg-zinc-50/80 dark:bg-zinc-800/40 p-1.5 rounded-xl"
      id="history-picker"
    >
      <button
        phx-click="navigate_period"
        phx-value-dir="prev"
        id="btn-history-prev"
        aria-label={gettext("Previous period")}
        class="px-2.5 py-1.5 text-sm font-semibold rounded-lg text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100 hover:bg-zinc-250/50 dark:hover:bg-zinc-700/50 transition"
      >
        <.icon name="hero-chevron-left" class="size-4" />
      </button>

      <form phx-change="set_granularity" id="form-granularity" class="inline-block">
        <select
          name="granularity"
          id="select-granularity"
          class="bg-white dark:bg-zinc-800 text-zinc-900 dark:text-white border border-zinc-300 dark:border-zinc-700 rounded-lg text-sm px-2.5 py-1.5 focus:ring-emerald-500 focus:border-emerald-500"
        >
          <%= for {label, value} <- [
            {gettext("Day"), "day"},
            {gettext("Week"), "week"},
            {gettext("Month"), "month"},
            {gettext("Year"), "year"}
          ] do %>
            <option value={value} selected={value == @granularity}>
              {label}
            </option>
          <% end %>
        </select>
      </form>

      <label
        class="relative inline-flex items-center rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-800 px-2.5 py-1.5 text-sm font-semibold text-zinc-700 dark:text-zinc-200 cursor-pointer hover:bg-zinc-50 dark:hover:bg-zinc-700 transition"
        title={gettext("Choose date")}
      >
        <span id="history-label">{stepper_label(@selected_period, @granularity)}</span>
        <.icon name="hero-calendar-days-mini" class="ml-1.5 size-4 text-zinc-400" />
        <input
          type="date"
          phx-change="set_date"
          id="history-date-input"
          value={date_input_value(@selected_period)}
          min={date_min_bound(@selectable_dates)}
          max={date_max_bound(@selectable_dates)}
          class="absolute inset-0 opacity-0 cursor-pointer"
        />
      </label>

      <button
        phx-click="navigate_period"
        phx-value-dir="next"
        id="btn-history-next"
        aria-label={gettext("Next period")}
        class="px-2.5 py-1.5 text-sm font-semibold rounded-lg text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100 hover:bg-zinc-250/50 dark:hover:bg-zinc-700/50 transition"
      >
        <.icon name="hero-chevron-right" class="size-4" />
      </button>

      <%= if @live == false and historical_empty?(@granularity, @selectable_days, @selectable_weeks, @selectable_months, @selectable_years) do %>
        <span class="ml-2 text-sm text-zinc-450 dark:text-zinc-500 italic">
          {gettext("No historical data for this period.")}
        </span>
      <% end %>
    </div>
    """
  end

  # ------------------------------------------------------------------
  # <.stat_card_row>
  # ------------------------------------------------------------------

  @doc """
  Headline stat-card row, rendered when the user has at least
  one inverter-kind DTU. A Shelly-only user has no production
  telemetry, so this row would render three "0 W / 0.0 kWh /
  00:00" placeholders that confuse rather than inform. The
  consumption row beneath the chart still shows their household
  draw.

  Cards (always rendered when row is rendered):
    1. Yield (kWh)            — period total
    2. Peak Power (W)         — highest 5-min bucket in window
    3. Peak Time              — when the peak happened, local HH:MM

  Conditional cards (rendered when their predicate holds):
    4. Current Power (W)       — 1D-only, > 0 W
    5. Saved this period (€)   — rate configured, non-nil
    6. Self-consumption (%)    — Shelly paired, helper returned a number
    7. Current Consumption (W) — Shelly paired, > 0 W

  The grid's `lg:` column count is computed from the same
  predicates so a user without, say, savings doesn't see a 6-up
  grid with two empty columns. Tailwind v4's source-based JIT
  doesn't detect interpolated class strings, so the `cols`
  → `cols_class` mapping is a literal `cond` over the seven
  possible widths.

  ## Assigns

    * `:stats`                 — map with `current_power`, `total_yield`,
                                  `peak_power`, `peak_time`,
                                  `self_consumption_pct`
    * `:consumption_stats`     — map with `current_consumption`
    * `:savings`               — euro-cents integer or `nil`
    * `:cents_per_kwh`         — configured rate (cents/kWh) or `nil`
    * `:range_preset`          — current preset (gates 1D-only "Current Power" card)
    * `:user_tz_offset_seconds` — user's tz offset (formats peak time)
    * `:locale`                — for number formatting (`Devices.format_number/3`)
  """
  attr :stats, :map, required: true
  attr :consumption_stats, :map, required: true
  attr :savings, :any, default: nil
  attr :cents_per_kwh, :any, default: nil
  attr :range_preset, :string, required: true
  attr :time_range, :string, required: true
  attr :user_tz_offset_seconds, :integer, required: true
  attr :locale, :string, required: true

  def stat_card_row(assigns) do
    ~H"""
    <% cols =
      3 +
        if(@range_preset == "1d" and @stats.current_power > 0,
          do: 1,
          else: 0
        ) +
        if(@savings, do: 1, else: 0) +
        if(@consumption_stats.current_consumption > 0, do: 1, else: 0) +
        if(
          is_number(@stats[:self_consumption_pct]) and
            @consumption_stats.current_consumption > 0,
          do: 1,
          else: 0
        ) %>
    <% cols_class =
      cond do
        cols <= 3 -> "lg:grid-cols-3"
        cols == 4 -> "lg:grid-cols-4"
        cols == 5 -> "lg:grid-cols-5"
        cols == 6 -> "lg:grid-cols-6"
        true -> "lg:grid-cols-7"
      end %>
    <div class={[
      "grid grid-cols-1 gap-5 sm:grid-cols-2",
      cols_class
    ]}>
      <%!-- Card 0: Current Power (W). 1D-only — a live "what's the
         inverter producing right now" signal that doesn't make sense
         for historical periods (7D, 30D, YTD, Custom). Hidden when
         the seeded value is 0 so a quiet inverter doesn't pollute
         the row. Sits at the start of the grid so the live signal
         is the first thing the user reads on the today view. --%>
      <%= if @range_preset == "1d" and @stats.current_power > 0 do %>
        <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
          <div class="px-4 py-5 sm:p-6">
            <div class="flex items-center">
              <div class="p-3 rounded-md bg-amber-50 dark:bg-amber-950/30 text-amber-600 dark:text-amber-400">
                <.icon name="hero-bolt" class="h-6 w-6" />
              </div>
              <div class="ml-5 w-0 flex-1">
                <dl>
                  <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                    {gettext("Current Power")}
                  </dt>
                  <dd class="flex items-baseline">
                    <div
                      class="text-3xl font-semibold text-zinc-900 dark:text-white"
                      id="stat-current-power"
                    >
                      {DtuApp.Devices.format_number(@stats.current_power, 0, @locale)} W
                    </div>
                  </dd>
                </dl>
              </div>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- Card 1: Yield (kWh). The headline number stays the same
         shape — `total_yield` rounded to one decimal — whether the
         period is today, a week, a month, or a year. The sub-label
         below the headline names the period ("Today", "Last 7
         days", etc.) so the user knows what window the kWh figure
         covers. --%>
      <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
        <div class="px-4 py-5 sm:p-6">
          <div class="flex items-center">
            <div class="p-3 rounded-md bg-emerald-50 dark:bg-emerald-950/30 text-emerald-600 dark:text-emerald-400">
              <.icon name="hero-bolt" class="h-6 w-6" />
            </div>
            <div class="ml-5 w-0 flex-1">
              <dl>
                <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                  {gettext("Yield")}
                </dt>
                <dd class="flex flex-col">
                  <div
                    class="text-3xl font-semibold text-zinc-900 dark:text-white"
                    id="stat-yield-kwh"
                  >
                    {DtuApp.Devices.format_number(@stats.total_yield, 1, @locale)} kWh
                  </div>
                  <div class="text-xs text-zinc-400 dark:text-zinc-500 mt-0.5">
                    {period_label(@range_preset, @time_range)}
                  </div>
                </dd>
              </dl>
            </div>
          </div>
        </div>
      </div>

      <%!-- Card 2: Peak Power (W). The same headline number across
         all presets — `stats.peak_power` — but the underlying query
         changes (today's `bucket_max` vs the range-wide peak via
         `compute_peak_watts_in_period/4`). A user on 7D sees the
         highest single bucket over the last 7 days, not the daily
         peak. --%>
      <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
        <div class="px-4 py-5 sm:p-6">
          <div class="flex items-center">
            <div class="p-3 rounded-md bg-blue-50 dark:bg-blue-950/30 text-blue-600 dark:text-blue-400">
              <.icon name="hero-chart-bar" class="h-6 w-6" />
            </div>
            <div class="ml-5 w-0 flex-1">
              <dl>
                <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                  {gettext("Peak Power")}
                </dt>
                <dd class="flex items-baseline">
                  <div
                    class="text-3xl font-semibold text-zinc-900 dark:text-white"
                    id="stat-peak-watts"
                  >
                    {DtuApp.Devices.format_number(@stats.peak_power, 0, @locale)} W
                  </div>
                </dd>
              </dl>
            </div>
          </div>
        </div>
      </div>

      <%!-- Card 3: Peak Time. The bucket time of the peak wattage
         above, formatted in the user's local timezone (the
         underlying DateTime is UTC; `format_peak_time/2` adds the
         tz offset and emits HH:MM). The card falls back to `—`
         when the window has no readings. --%>
      <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
        <div class="px-4 py-5 sm:p-6">
          <div class="flex items-center">
            <div class="p-3 rounded-md bg-violet-50 dark:bg-violet-950/30 text-violet-600 dark:text-violet-400">
              <.icon name="hero-clock" class="h-6 w-6" />
            </div>
            <div class="ml-5 w-0 flex-1">
              <dl>
                <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                  {gettext("Peak Time")}
                </dt>
                <dd class="flex items-baseline">
                  <div
                    class="text-3xl font-semibold text-zinc-900 dark:text-white"
                    id="stat-peak-time"
                  >
                    {DtuAppWeb.DashboardLive.TimeHelpers.format_peak_time(
                      @stats.peak_time,
                      @user_tz_offset_seconds
                    )}
                  </div>
                </dd>
              </dl>
            </div>
          </div>
        </div>
      </div>

      <%!-- Card 4: Self-consumption (%). Period-aware:
         `(production - exported) / production × 100`. Hidden when
         the user has no consumption devices (no Shelly paired) —
         `self_consumption_pct == nil` is the helper's "no scope"
         signal, the consumption card's `current_consumption > 0`
         is the dashboard-level guard. --%>
      <%= if is_number(@stats[:self_consumption_pct]) and @consumption_stats.current_consumption > 0 do %>
        <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
          <div class="px-4 py-5 sm:p-6">
            <div class="flex items-center">
              <div class="p-3 rounded-md bg-teal-50 dark:bg-teal-950/30 text-teal-600 dark:text-teal-400">
                <.icon name="hero-recycle" class="h-6 w-6" />
              </div>
              <div class="ml-5 w-0 flex-1">
                <dl>
                  <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                    {gettext("Self-consumption")}
                  </dt>
                  <dd class="flex items-baseline">
                    <div
                      class="text-3xl font-semibold text-zinc-900 dark:text-white"
                      id="stat-self-consumption"
                    >
                      {DtuApp.Devices.format_number(@stats.self_consumption_pct, 1, @locale)} %
                    </div>
                  </dd>
                </dl>
              </div>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- Card 5: Savings (€). Reads `@savings` (euro cents, an
         integer assigned by assign_dashboard_data/5 via
         `Devices.compute_savings/2`) and formats it as €X.XX.
         Hidden when nil so a brand-new user without a rate doesn't
         see a misleading "€0.00 saved" claim. --%>
      <%= if @savings do %>
        <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
          <div class="px-4 py-5 sm:p-6">
            <div class="flex items-center">
              <div class="p-3 rounded-md bg-emerald-50 dark:bg-emerald-950/30 text-emerald-600 dark:text-emerald-400">
                <.icon name="hero-banknotes" class="h-6 w-6" />
              </div>
              <div class="ml-5 w-0 flex-1">
                <dl>
                  <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                    {gettext("Saved this period")}
                  </dt>
                  <dd class="flex items-baseline">
                    <div
                      class="text-3xl font-semibold text-zinc-900 dark:text-white"
                      id="stat-saved"
                    >
                      {DtuApp.Devices.format_savings(@savings)}
                    </div>
                  </dd>
                </dl>
                <p class="mt-1 text-xs text-zinc-400 dark:text-zinc-500">
                  {gettext("at %{rate}",
                    rate:
                      if(is_integer(@cents_per_kwh),
                        do: DtuApp.Devices.format_savings(@cents_per_kwh),
                        else: "—"
                      )
                  )}
                </p>
              </div>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- Current Consumption card: only visible when the user has
         paired a Shelly Plus 3EM (Gen3+) energy meter. Sits in the
         same headline row because it's also a top-of-dashboard
         signal — a 5-up grid can absorb one conditional card
         cleanly on lg screens. --%>
      <%= if @consumption_stats.current_consumption > 0 do %>
        <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
          <div class="px-4 py-5 sm:p-6">
            <div class="flex items-center">
              <div class="p-3 rounded-md bg-rose-50 dark:bg-rose-950/30 text-rose-600 dark:text-rose-400">
                <.icon name="hero-bolt" class="h-6 w-6" />
              </div>
              <div class="ml-5 w-0 flex-1">
                <dl>
                  <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                    {gettext("Current Consumption")}
                  </dt>
                  <dd class="flex items-baseline">
                    <div
                      class="text-3xl font-semibold text-zinc-900 dark:text-white"
                      id="stat-current-consumption"
                    >
                      {DtuApp.Devices.format_number(
                        @consumption_stats.current_consumption,
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
      <% end %>
    </div>
    """
  end

  # `period_label/2` lives here because it's only used by the
  # stat-card row's yield sub-label. The full mapping mirrors the
  # chart-title copy in `chart_title/2` so the kWh sub-label and
  # the chart agree on what window the data covers.
  @spec period_label(String.t() | nil, String.t()) :: String.t()
  def period_label("1d", _time_range), do: gettext("Today")
  def period_label("7d", _time_range), do: gettext("Last 7 days")
  def period_label("30d", _time_range), do: gettext("Last 30 days")
  def period_label("ytd", _time_range), do: gettext("Year to date")
  def period_label("custom", "day"), do: gettext("Selected day")
  def period_label("custom", "week"), do: gettext("Selected week")
  def period_label("custom", "month"), do: gettext("Selected month")
  def period_label("custom", "year"), do: gettext("Selected year")

  def period_label(_other, time_range),
    do: Gettext.gettext(DtuAppWeb.Gettext, period_fallback(time_range))

  defp period_fallback("today"), do: "Today"
  defp period_fallback("day"), do: "Selected day"
  defp period_fallback("week"), do: "Selected week"
  defp period_fallback("month"), do: "Selected month"
  defp period_fallback("year"), do: "Selected year"
  defp period_fallback(_), do: "Selected period"
end
