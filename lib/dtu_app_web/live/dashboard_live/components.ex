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

  `<.stat_card_row>` lives in
  `DtuAppWeb.DashboardLive.Components.StatCardRow` and is
  exposed here as a forward `defdelegate` so the dashboard
  template keeps calling `<Components.stat_card_row ... />`
  unchanged.
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

  # Extracted to `DtuAppWeb.DashboardLive.Components.StatCardRow`.
  # Public API unchanged: the dashboard template still calls
  # `<Components.stat_card_row ... />` and the LiveView
  # doesn't change. The defdelegate keeps the call site stable
  # while the ~485-line component body moves to its own sibling
  # module so this file doesn't carry 52% of its size in one
  # component.
  defdelegate stat_card_row(assigns), to: __MODULE__.StatCardRow
end
