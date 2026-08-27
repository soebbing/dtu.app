defmodule DtuAppWeb.SharedDashboardLive do
  @moduledoc """
  Public, unauthenticated, read-only view of a user's current-day
  dashboard. Mounted by the anonymous `/s/:token` route — there is
  **no** `live_session :current_scope` wrapping this view, no
  `on_mount :mount_current_scope` hook, and no `require_authenticated_user`
  plug. Authentication is the possession of a valid share token.

  What we show:

    * The "Total — all DTUs" combined yield/power for today
      (`dtu_id: nil` in every `Devices` call).
    * The user's local day window, derived from their persisted
      `tz_offset_seconds`.
    * Stat-card row: today's yield (kWh), current power (W), peak
      power (W).
    * Live power curve (SVG, same coordinate conventions as the
      authenticated dashboard).

  What we deliberately do NOT show:

    * The DTU switcher (the share is always the combined view).
    * The historical ranges (1D/7D/30D/YTD/custom) — this view is
      current-day only.
    * Anything tied to the user's account: their email, devices,
      MQTT credentials, notification settings.
    * The standard app navbar — replaced by `Layouts.public` (see
      `task #169`).

  Real-time updates: subscribes to the global `dtu:reading` PubSub
  topic via `Telemetry.subscribe/0` and re-runs the data fetch on
  every reading. Any reading for the user's fleet triggers a
  re-render; readings from other tenants' devices are ignored
  (the query itself filters by `user_id`).

  Privacy: token resolution happens by SHA-256 hash (see
  `Accounts.get_user_by_share_token/1`) so the URL plaintext is
  not stored server-side. If the token doesn't match, we mount
  `{:error, ...}` and render the public layout's "link invalid"
  fallback instead of the dashboard.
  """

  use DtuAppWeb, :live_view

  alias DtuApp.Accounts
  alias DtuApp.Devices
  alias DtuApp.MqttBroker.Telemetry

  require Logger

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case Accounts.get_user_by_share_token(token) do
      nil ->
        # Token doesn't match any active share. Render the public
        # layout with an "invalid link" notice so the visitor gets a
        # meaningful response instead of a stack trace. The page
        # is server-rendered (no `:connected?` checks needed for
        # the failure path). `:share_state` rather than `:layout`
        # because `:layout` is a reserved Phoenix assign (taken by
        # the layout resolution pipeline — see
        # `Phoenix.Controller.prepare_assigns/4`).
        {:ok,
         socket
         |> assign(:share_state, :invalid)
         |> put_flash(:error, gettext("This share link is invalid or has been revoked."))}

      %{} = user ->
        # Subscribe to the global readings topic so we re-render on
        # every uplink. The data fetch itself filters by `user_id`,
        # so cross-tenant noise is harmless.
        if connected?(socket), do: Telemetry.subscribe()

        {:ok, assign_shared_data(socket, user)}
    end
  end

  # On every MQTT uplink for any of the user's devices, refresh
  # the data. Identical shape to the initial assign in mount/3 so
  # the SSRed HTML and the post-tick HTML match.
  @impl true
  def handle_info({:reading, _client_id, _reading}, socket) do
    user = socket.assigns.user
    {:noreply, assign_shared_data(socket, user)}
  end

  # Swallow the other telemetry / status messages so the public
  # LiveView doesn't crash on the first `:dtu_connected` etc.
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Read today's stat-card values + chart points for the given user
  # and thread them into socket assigns. `tz_offset_seconds` is
  # persisted on the user schema (the dashboard's `set_timezone`
  # JS hook pushes it; if no dashboard session ever ran for this
  # user we fall back to UTC). `dtu_id: nil` is the "Total — all
  # DTUs" combined view, matching the share's privacy design.
  defp assign_shared_data(socket, user) do
    tz_offset_seconds = user.tz_offset_seconds || 0
    today_local = local_today(tz_offset_seconds)
    {utc_start, utc_end} = Devices.local_day_utc_range(today_local, tz_offset_seconds)

    stats = Devices.get_daily_stats(user, nil, Date.utc_today())

    chart_points =
      Devices.list_day_chart_data_for_dashboard(user, utc_start, utc_end, nil)

    socket
    |> assign(:share_state, :ok)
    |> assign(:user, user)
    |> assign(:today_local, today_local)
    |> assign(:tz_offset_seconds, tz_offset_seconds)
    |> assign(:stats, stats)
    |> assign(:chart_points, chart_points)
    |> assign(:chart_type, :line)
    # Use the visitor's `Accept-Language` locale (set by `Plugs.Locale`
    # earlier in the `:public_browser` pipeline), NOT the share owner's
    # persisted `user.locale`. Visitors want the page in their own
    # browser language regardless of where the link came from.
    |> assign(:locale, Gettext.get_locale(DtuAppWeb.Gettext))
  end

  # Resolve "today" in the user's local timezone. Mirrors the
  # helper of the same name in `DashboardLive`; duplicated here
  # rather than exported so the two views stay independent
  # (changes to one shouldn't accidentally reshape the other).
  defp local_today(tz_offset_seconds) do
    DateTime.utc_now()
    |> DateTime.add(tz_offset_seconds, :second)
    |> DateTime.to_date()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.public flash={@flash}>
      <%= case @share_state do %>
        <% :invalid -> %>
          <div
            id="shared-invalid"
            class="rounded-2xl border border-amber-300 dark:border-amber-700/60 bg-amber-50 dark:bg-amber-950/30 p-8 text-center"
          >
            <.icon name="hero-exclamation-triangle" class="mx-auto size-10 text-amber-500" />
            <h1 class="mt-3 text-xl font-bold text-zinc-900 dark:text-white">
              {gettext("Share link unavailable")}
            </h1>
            <p class="mt-2 text-sm text-zinc-600 dark:text-zinc-300">
              {gettext(
                "This link has been revoked, expired, or never existed. Ask the owner to generate a new one."
              )}
            </p>
          </div>
        <% :ok -> %>
          <header class="flex items-center justify-between">
            <h1 class="text-2xl font-extrabold tracking-tight text-zinc-900 dark:text-white">
              {date_label(@today_local)}
            </h1>
            <span
              id="shared-live-badge"
              class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-semibold bg-emerald-100 dark:bg-emerald-900/40 text-emerald-700 dark:text-emerald-300"
            >
              <span class="size-2 rounded-full bg-emerald-500 animate-pulse"></span>
              {gettext("Live")}
            </span>
          </header>

          <%!-- Minimal 3-card stat row. We deliberately do not
               replicate the full dashboard's 5-up grid here:
               the shared view's promise is "current-day snapshot",
               not "interactive exploration". --%>
          <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <.shared_stat_card
              id="shared-stat-yield"
              icon="hero-bolt"
              label={gettext("Yield today")}
              value={format_kwh(@stats.today_yield)}
              hint={gettext("since midnight local")}
            />
            <.shared_stat_card
              id="shared-stat-current"
              icon="hero-sun"
              label={gettext("Current power")}
              value={format_watts(@stats.current_power)}
            />
            <.shared_stat_card
              id="shared-stat-peak"
              icon="hero-chart-bar"
              label={gettext("Peak power")}
              value={format_watts(@stats.peak_power)}
            />
          </div>

          <.shared_power_chart
            id="shared-power-chart"
            points={@chart_points}
            tz_offset_seconds={@tz_offset_seconds}
          />
      <% end %>
    </Layouts.public>
    """
  end

  # Single stat card. A 3-line function component, deliberately
  # simpler than the dashboard's stat cards (no period sub-label,
  # no multi-value layout) — the shared view's whole point is to
  # be readable at a glance.
  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :hint, :string, default: nil

  defp shared_stat_card(assigns) do
    ~H"""
    <div
      id={@id}
      class="rounded-2xl border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-800 p-5"
    >
      <div class="flex items-center gap-2 text-xs font-semibold text-zinc-500 dark:text-zinc-400 uppercase tracking-wide">
        <%!-- Icon sits in a coloured square so it reads as an icon,
           not as a glyph blended into the small-caps label. Matches
           the auth dashboard's badge style but kept compact (size-9
           box, size-5 glyph) because the shared view is denser. --%>
        <span class="inline-flex items-center justify-center size-9 rounded-lg bg-emerald-50 dark:bg-emerald-950/40 text-emerald-600 dark:text-emerald-400">
          <.icon name={@icon} class="size-5" />
        </span>
        {@label}
      </div>
      <div class="mt-2 text-3xl font-bold tracking-tight text-zinc-900 dark:text-white tabular-nums">
        {@value}
      </div>
      <%= if @hint do %>
        <div class="mt-1 text-xs text-zinc-500 dark:text-zinc-400">
          {@hint}
        </div>
      <% end %>
    </div>
    """
  end

  # Inline SVG power curve. A simplified render of the dashboard's
  # chart: same coordinate conventions (x = seconds-into-local-day,
  # y = watts), but no consumption overlay, no tooltip, no zoom —
  # the shared view is fire-and-forget. The single polyline is
  # enough to convey "today's generation curve".
  attr :id, :string, required: true
  attr :points, :list, required: true
  attr :tz_offset_seconds, :integer, default: 0

  defp shared_power_chart(assigns) do
    ~H"""
    <div
      id={@id}
      class="rounded-2xl border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-800 p-5"
    >
      <div class="text-xs font-semibold text-zinc-500 dark:text-zinc-400 uppercase tracking-wide mb-3">
        {gettext("Today's power")}
      </div>
      <%= if @points == [] do %>
        <div class="h-48 flex items-center justify-center text-sm text-zinc-500 dark:text-zinc-400">
          {gettext("No data yet — check back in a few minutes.")}
        </div>
      <% else %>
        {polyline_points = build_polyline(@points, @tz_offset_seconds)}
        <%!-- Static SVG chart: viewBox 0 0 864 200; x maps to
             seconds-into-local-day (0-86399), y inverts watts
             (0 W at y=190, 200 W or more at y=10). Two axis
             labels at the bottom show midnight + noon. --%>
        <svg viewBox="0 0 864 200" class="w-full h-48" preserveAspectRatio="none">
          <line
            x1="0"
            y1="190"
            x2="864"
            y2="190"
            class="stroke-zinc-200 dark:stroke-zinc-700"
            stroke-width="1"
          />
          <line
            x1="432"
            y1="190"
            x2="432"
            y2="10"
            class="stroke-zinc-200 dark:stroke-zinc-700"
            stroke-width="1"
            stroke-dasharray="3 3"
          />
          <polyline
            points={polyline_points}
            class="fill-none stroke-emerald-500"
            stroke-width="2"
            stroke-linejoin="round"
            stroke-linecap="round"
          />
          <text x="2" y="200" class="fill-zinc-400 text-[10px]">
            {gettext("00:00")}
          </text>
          <text x="430" y="200" class="fill-zinc-400 text-[10px]">
            {gettext("12:00")}
          </text>
        </svg>
      <% end %>
    </div>
    """
  end

  # Build the polyline `points` attribute from the per-bucket
  # data returned by `list_day_chart_data_for_dashboard/4`. Each
  # bucket is a 5-minute window and the query returns one point per
  # `(inverter, MPPT)` series per bucket — for the combined ("Total")
  # view we sum those into a single per-bucket value so the share
  # page renders ONE polyline (matching its "combined snapshot"
  # promise). Field names follow the `chart_point()` contract in
  # `DtuApp.Devices`: `:time` (UTC DateTime) and `:power` (watts).
  # An earlier draft used `:utc_start` / `:power_w` and crashed with
  # KeyError on the first non-empty mount — see #175.
  defp build_polyline(points, tz_offset_seconds) do
    # Compute per-bucket watts once so we can derive both the Y-scale and
    # the polyline points from the same numbers. Without this two-pass,
    # `watts_to_y/2` had to pick a hard-coded 200 W ceiling, which clamped
    # every realistic solar day (>200 W peak) into a 10 px band at the
    # top of the chart (see task #221).
    bucketed =
      points
      |> Enum.group_by(& &1.time)
      |> Enum.map(fn {time, pts} ->
        watts =
          pts
          |> Enum.map(&(&1.power || 0.0))
          |> Enum.sum()
          |> clamp(0.0, 5000.0)

        {time, watts}
      end)
      |> Enum.sort()

    y_max = y_axis_max(bucketed)

    bucketed
    |> Enum.map(fn {time, watts} ->
      seconds = local_seconds(time, tz_offset_seconds)
      x = seconds / 100
      y = watts_to_y(watts, y_max)
      "#{Float.round(x, 1)},#{y}"
    end)
    |> Enum.join(" ")
  end

  defp local_seconds(%DateTime{} = utc, tz_offset_seconds) do
    shifted = DateTime.add(utc, tz_offset_seconds, :second)
    dt = shifted.hour * 3600 + shifted.minute * 60 + shifted.second
    dt
  end

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  # Pick the top of the Y-axis so a normal solar day actually fills the
  # chart instead of being squished into the top sliver. We round up to
  # the next 100 W step (50 W for small days) so the topmost data point
  # never lands exactly on the chart edge. Floor of 100 W keeps the axis
  # honest for tiny installations — a 30 W micro-inverter shouldn't claim
  # the same visual range as a 5 kW system.
  defp y_axis_max(bucketed) do
    peak =
      case bucketed do
        [] -> 0.0
        _ -> bucketed |> Enum.map(fn {_, w} -> w end) |> Enum.max()
      end

    cond do
      peak <= 0.0 -> 100.0
      peak <= 200.0 -> 200.0
      true -> Float.ceil(peak / 100.0) * 100.0
    end
  end

  # SVG y-coordinate for a given wattage, with `y_max` W mapping to y=10
  # (just below the top edge) and 0 W mapping to y=190 (just above the
  # bottom edge). The old hard-coded `y_max = 200` meant anything above
  # 200 W piled into the top 10 px, which is the bug the user spotted.
  defp watts_to_y(w, y_max) when y_max > 0.0 do
    Float.round(190.0 - w / y_max * 180.0, 1)
  end

  # Pretty-print a local date for the page header: "Wednesday,
  # 27 August 2026" style. We don't depend on `Gettext.dgettext/3`
  # here because date formatting in this codebase is done
  # server-side with the user's locale via `Calendar.strftime/3`.
  defp date_label(%Date{} = date) do
    Calendar.strftime(date, "%A, %d %B %Y")
  end

  defp format_kwh(v) when is_number(v) do
    :io_lib.format("~.2f kWh", [v / 1.0]) |> IO.iodata_to_binary()
  end

  defp format_kwh(_), do: "—"

  # `:io_lib.format/2` rejects precision 0 (`~.0f` is interpreted as
  # "precision = 0", which Erlang's format spec requires to be ≥ 1).
  # Round and stringify instead so 0 W renders as "0 W" rather than
  # crashing the page.
  defp format_watts(v) when is_number(v) do
    rounded = v |> Float.round(0) |> trunc()
    "#{rounded} W"
  end

  defp format_watts(_), do: "—"
end
