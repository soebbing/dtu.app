defmodule DtuAppWeb.DashboardLive.Components.StatCardRow do
  @moduledoc """
  The headline stat-card row extracted from
  `DtuAppWeb.DashboardLive.Components` so the components module
  doesn't carry ~485 lines (52% of its previous size) of one
  dominant component. The `Components.stat_card_row/1` forward
  delegate stays the public API — the dashboard's template still
  calls `<Components.stat_card_row ... />` and the LiveView
  doesn't change.
  """

  use Phoenix.Component
  use Gettext, backend: DtuAppWeb.Gettext

  # `<.icon>` is a HEEx component the template calls directly,
  # so the import has to live alongside the `use Phoenix.Component`
  # that defines the slot for `stat_card_row/1`. The same import
  # is in `DtuAppWeb.DashboardLive.Components`.

  import DtuAppWeb.CoreComponents, only: [icon: 1]

  @doc """
  Headline stat-card row, rendered when the user has at least
  one inverter-kind DTU. A Shelly-only user has no production
  telemetry, so this row would render three "0 W / 0.0 kWh /
  00:00" placeholders that confuse rather than inform. The
  consumption row beneath the chart still shows their household
  draw.

  The layout is two rows on `lg:` and wider so each card has
  more horizontal space than a single dense 5-up row would
  allow:

    Row 1 — headline + consumption. Always Peak Power and
            Peak Time, plus Current Power on 1D, plus
            Self-consumption and Current Consumption when a
            Shelly is paired. `lg:grid-cols-{3,4,5}` depending
            on which conditional cards render.
    Row 2 — period total + savings + ambient. Yield is
            always rendered; Savings joins it when a rate is
            configured; Cloud cover joins it when geolocation
            is not denied. `lg:grid-cols-{1,2,3}` depending on
            which conditional cards render.

  On `sm:` and narrower both grids collapse to `grid-cols-1`
  so every card stacks full-width on mobile.

  Tailwind v4's source-based JIT doesn't detect interpolated
  class strings, so each row's `lg:` column count is computed
  via a literal `cond` over the possible widths.

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
  attr :cloud_cover, :any, default: nil
  attr :cloud_cover_pct, :any, default: nil
  # `:granted | :not_asked | :loading | :denied` — drives which
  # sub-render the cloud-cover card slot produces (data card vs.
  # "Share location" prompt vs. loading spinner vs. nothing).
  # Set by the dashboard on mount (initial state derived from the
  # user's persisted lat/lon) and updated by the
  # `location_loading` / `location_denied` handlers.
  attr :geolocation_state, :atom,
    default: :not_asked,
    values: [:granted, :not_asked, :loading, :denied]

  # Mirrors the same condition the dashboard's
  # `DtuApp.Accounts.user_has_geolocation?/1` already computed —
  # passed through so the component can avoid re-deriving it (and
  # so the data card is rendered when upstream weather data is
  # present even if `@cloud_cover` happens to be nil for a
  # transient reason).
  attr :user_has_geolocation, :boolean, default: false

  def stat_card_row(assigns) do
    ~H"""
    <% # Two-row layout on lg+ viewports. Each row picks its own
    # `lg:` column count via a literal `cond` so Tailwind v4's
    # source-based JIT sees every `lg:grid-cols-N` class string.
    #
    # Row 1 (headline + consumption): Peak Power + Peak Time +
    # Current Power (1D only, > 0 W) + Self-consumption (Shelly
    # + scope) + Current Consumption (Shelly + > 0 W).
    #
    # Row 2 (period + ambient): Yield + Saved this period (if a
    # rate is configured) + Cloud cover slot (if the user hasn't
    # explicitly denied geolocation).
    #
    # Cloud cover no longer needs the old `show_cloud` promotion
    # logic — it lives on its own row, so `:not_asked` (CTA) and
    # `:loading` (spinner) always render alongside `:granted` (data
    # card), and `:denied` continues to render nothing.
    row1_count =
      2 +
        if(@range_preset == "1d" and @stats.current_power > 0,
          do: 1,
          else: 0
        ) +
        if(
          is_number(@stats[:self_consumption_pct]) and
            @consumption_stats.current_consumption > 0,
          do: 1,
          else: 0
        ) +
        if(@consumption_stats.current_consumption > 0, do: 1, else: 0)

    row1_cols_class =
      cond do
        row1_count <= 2 -> "lg:grid-cols-2"
        row1_count == 3 -> "lg:grid-cols-3"
        row1_count == 4 -> "lg:grid-cols-4"
        true -> "lg:grid-cols-5"
      end %>

    <% row2_count =
      1 +
        if(@savings, do: 1, else: 0) +
        if(@geolocation_state != :denied, do: 1, else: 0) %>

    <% row2_cols_class =
      cond do
        row2_count <= 1 -> "lg:grid-cols-1"
        row2_count == 2 -> "lg:grid-cols-2"
        true -> "lg:grid-cols-3"
      end %>

    <%!-- Row 1: peak wattage + peak time + (optional) live signal
         + (optional) Shelly consumption signals. --%>
    <div class={["grid grid-cols-1 gap-5 sm:grid-cols-2", row1_cols_class]}>
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

      <%!-- Card 1: Peak Power (W). The same headline number across
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

      <%!-- Card 2: Peak Time. The bucket time of the peak wattage
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

      <%!-- Card 3: Self-consumption (%). Period-aware:
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

      <%!-- Current Consumption card: only visible when the user has
         paired a Shelly Plus 3EM (Gen3+) energy meter. Sits in the
         same row 1 because it's a headline signal too — a
         top-of-dashboard "what's the household drawing right now"
         number that pairs with Peak Power and Current Power. --%>
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

    <%!-- Row 2: period total (Yield) + savings + cloud cover. The
         Yield card is always rendered; the other two are gated by
         their respective predicates. The cloud-cover slot renders
         nothing on `:denied`, so `@geolocation_state != :denied`
         already excludes it from `row2_count`. --%>
    <div class={["grid grid-cols-1 gap-5 sm:grid-cols-2 mt-5", row2_cols_class]}>
      <%!-- Card 0: Yield (kWh). The headline number stays the same
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

      <%!-- Card 1: Savings (€). Reads `@savings` (euro cents, an
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

      <%!-- Cloud-cover card slot. Renders one of four states:
             * `:granted` + `@cloud_cover` populated  → data card
               ("Cloud cover: 25% / clear").
             * `:granted` + `@cloud_cover` nil       → data card
               with "—" placeholder (coords are saved but the
               upstream Open-Meteo fetch failed / no data for today).
             * `:not_asked`                          → "Share location"
               prompt with explanation + button wired to
               `.RequestLocation` (the colocated JS hook that calls
               `navigator.geolocation.getCurrentPosition` and pushes
               the result back as `set_location` / `location_denied`).
             * `:loading`                            → the button shows
               a spinner + "Requesting…" while the browser permission
               prompt is up.
             * `:denied`                             → renders nothing
               and contributes 0 to `row2_count` — the explicit
               user choice that the card hide after a denial. --%>
      <%= case @geolocation_state do %>
        <% :granted -> %>
          <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
            <div class="px-4 py-5 sm:p-6">
              <div class="flex items-center">
                <div class="p-3 rounded-md bg-sky-50 dark:bg-sky-950/30 text-sky-600 dark:text-sky-400">
                  <.icon name="hero-cloud" class="h-6 w-6" />
                </div>
                <div class="ml-5 w-0 flex-1">
                  <dl>
                    <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                      {gettext("Cloud cover")}
                    </dt>
                    <dd class="flex items-baseline">
                      <div
                        class="text-3xl font-semibold text-zinc-900 dark:text-white"
                        id="stat-cloud-cover-pct"
                      >
                        {if @cloud_cover_pct, do: "#{@cloud_cover_pct}%", else: "—"}
                      </div>
                      <p class="ml-2 text-sm text-zinc-500 dark:text-zinc-400 truncate">
                        {if @cloud_cover,
                          do: cloud_cover_label(@cloud_cover),
                          else: gettext("no data")}
                      </p>
                    </dd>
                  </dl>
                </div>
              </div>
            </div>
          </div>
        <% :not_asked -> %>
          <div
            class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-dashed border-zinc-300 dark:border-zinc-700"
            id="cloud-cover-cta"
          >
            <div class="px-4 py-5 sm:p-6">
              <div class="flex items-start">
                <div class="p-3 rounded-md bg-sky-50 dark:bg-sky-950/30 text-sky-600 dark:text-sky-400">
                  <.icon name="hero-cloud" class="h-6 w-6" />
                </div>
                <div class="ml-5 w-0 flex-1">
                  <dt class="text-sm font-medium text-zinc-700 dark:text-zinc-200">
                    {gettext("Cloud cover")}
                  </dt>
                  <p class="mt-1 text-xs text-zinc-500 dark:text-zinc-400">
                    {gettext(
                      "Share your location to show local cloud cover on today's chart and as a stat card."
                    )}
                  </p>
                  <button
                    type="button"
                    id="request-location-btn"
                    phx-hook=".RequestLocation"
                    class="mt-2 inline-flex items-center gap-1.5 rounded-md bg-sky-600 px-2.5 py-1.5 text-xs font-medium text-white shadow-sm hover:bg-sky-500 focus:outline-none focus:ring-2 focus:ring-sky-500 focus:ring-offset-1 dark:focus:ring-offset-zinc-800"
                  >
                    <.icon name="hero-map-pin" class="h-4 w-4" />
                    {gettext("Share location")}
                  </button>
                </div>
              </div>
            </div>
          </div>
        <% :loading -> %>
          <div
            class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700"
            id="cloud-cover-loading"
          >
            <div class="px-4 py-5 sm:p-6">
              <div class="flex items-center">
                <div class="p-3 rounded-md bg-sky-50 dark:bg-sky-950/30 text-sky-600 dark:text-sky-400">
                  <.icon name="hero-cloud" class="h-6 w-6" />
                </div>
                <div class="ml-5 w-0 flex-1">
                  <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                    {gettext("Cloud cover")}
                  </dt>
                  <dd class="mt-1 flex items-center gap-2 text-sm text-zinc-500 dark:text-zinc-400">
                    <.icon name="hero-arrow-path" class="h-4 w-4 animate-spin" />
                    {gettext("Requesting…")}
                  </dd>
                </div>
              </div>
            </div>
          </div>
        <% :denied -> %>
      <% end %>
    </div>

    <%!-- Colocated hook bound to the "Share location" button
         inside the cloud-cover card slot. Triggers
         `navigator.geolocation.getCurrentPosition` and pushes
         the result back to the server so the dashboard re-renders
         with the captured lat/lon. See
         `handle_event("location_loading", ...)` and the existing
         `set_location` handler. Failure paths (PERMISSION_DENIED
         / POSITION_UNAVAILABLE / TIMEOUT) all push
         `location_denied`, which the server uses to flip the
         card to `:denied` (hidden). Lives here — colocated with
         the `stat_card_row/1` template that owns the button —
         because LiveView resolves `phx-hook=".X"` to the FQ
         module path of the calling template's module
         (`DtuAppWeb.DashboardLive.Components.X`). --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".RequestLocation">
      export default {
        mounted() {
          this.onClick = (event) => {
            // Browsers may have already disabled the button if a
            // previous click is in flight; bail rather than queue
            // a second prompt (the browser would still ignore the
            // second one, but the visual state on our side is
            // cleaner if we don't try).
            if (this.el.disabled) return;

            if (!navigator.geolocation) {
              // The browser doesn't expose geolocation at all
              // (very old browsers, insecure contexts). Treat
              // identically to a denial: the card hides, the user
              // can recover on a different device / context.
              this.pushEvent("location_denied", {});
              return;
            }

            // Disable + announce loading immediately so a rapid
            // double-click doesn't fire two prompts and so the
            // user sees the click registered even before the
            // browser shows its permission dialog. The server
            // flips the slot to the loading card via the
            // `location_loading` event we push below.
            this.el.disabled = true;
            this.pushEvent("location_loading", {});

            navigator.geolocation.getCurrentPosition(
              (pos) => {
                this.pushEvent("set_location", {
                  latitude: pos.coords.latitude,
                  longitude: pos.coords.longitude
                });
              },
              () => {
                // PERMISSION_DENIED (1) / POSITION_UNAVAILABLE (2)
                // / TIMEOUT (3) all collapse to "denied" from the
                // user's POV — the cloud-cover card hides until
                // the next page mount.
                this.pushEvent("location_denied", {});
              },
              // 10s is well above the typical 1–3s fix time but
              // well below the user's patience for a "loading"
              // state. `maximumAge: 0` forces a fresh read rather
              // than the cached 60s value the auto-prompt used.
              { timeout: 10_000, maximumAge: 0 }
            );
          };

          this.el.addEventListener("click", this.onClick);
        },

        destroyed() {
          if (this.el && this.onClick) {
            this.el.removeEventListener("click", this.onClick);
          }
        }
      }
    </script>
    """
  end

  # Maps the bucketed condition atom from `DtuApp.Weather.bucket_condition/1`
  # to the user-facing WMO-style label. Kept local to this module —
  # the bucket itself is the contract; the label is a presentation
  # detail that could be moved to gettext if we ever localise.
  defp cloud_cover_label(:clear), do: gettext("clear")
  defp cloud_cover_label(:partly_cloudy), do: gettext("partly cloudy")
  defp cloud_cover_label(:mostly_cloudy), do: gettext("mostly cloudy")
  defp cloud_cover_label(:overcast), do: gettext("overcast")
  defp cloud_cover_label(_), do: ""

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
