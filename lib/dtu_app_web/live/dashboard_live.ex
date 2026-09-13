defmodule DtuAppWeb.DashboardLive do
  use DtuAppWeb, :live_view

  import Ecto.Query

  # Minimum visible time for the share-loading spinner, in ms. The
  # DB operations themselves complete in <10ms, so without this floor
  # the spinner would flash for a single frame and the user would
  # never see feedback. ~200ms is the lower bound for human-perceptible
  # motion (under 100ms feels instant, over 200ms feels "the system
  # is doing something"). Configurable so tests can skip the wait.
  @share_load_delay_ms Application.compile_env(:dtu_app, :share_load_delay_ms, 200)

  alias DtuApp.Devices
  alias DtuApp.Accounts
  alias DtuApp.MqttBroker.Telemetry
  alias DtuApp.MqttBroker.Broker
  alias DtuApp.Notifications
  alias DtuApp.PushSubscriptions

  # Chart math + colour helpers live in sibling modules under
  # `dashboard_live/` so this file stops growing past 4500 lines.
  # `ChartHelpers` owns the pure SVG coordinate math (X-axis range,
  # Y-axis gridlines, time-to-pixel mapping, "now" indicator X).
  # `ChartPalette` owns the per-series colour assignment + Tailwind
  # hex lookup used by the tooltip swatches. See the module docs on
  # each for the rationale.
  alias DtuAppWeb.DashboardLive.ChartPalette
  alias DtuAppWeb.DashboardLive.Components
  alias DtuAppWeb.DashboardLive.DashboardData
  alias DtuAppWeb.DashboardLive.DashboardMountCache
  alias DtuAppWeb.DashboardLive.DtuKinds
  alias DtuAppWeb.DashboardLive.MountTiming
  alias DtuAppWeb.DashboardLive.PeriodSelectable
  alias DtuAppWeb.DashboardLive.ShareLink
  alias DtuAppWeb.DashboardLive.TimeHelpers
  alias DtuAppWeb.DashboardLive.TodayDataCache
  alias DtuAppWeb.DashboardLive.Weather

  # Dashboard-specific function components (`<.dtu_switcher>`,
  # `<.quick_range_switcher>`, `<.historical_stepper>`,
  # `<.stat_card_row>`). Imported as bare names so the render
  # template stays close to plain HEEx.
  import Components

  require Logger

  @timezone_topic "dtu:timezone"

  # Per-LV-process debounce window for `{:reading, ...}` broadcasts.
  # A Shelly Plus 3EM publishes every ~30s, an OpenDTU inverter every
  # 5–10s, and a paired setup produces 2–6 broadcasts/sec sustained.
  # Collapsing the live-today refresh to at most one per second
  # eliminates the per-broadcast ~10 `Repo.all` round-trips that
  # exhausted the 10-slot DB pool (the 15s
  # `DBConnection.checkout_timeout`).
  @reading_refresh_debounce_ms 1_000

  # Per-LV-process debounce window for `{:dtu_seen, ...}` broadcasts
  # (analogous to the `:reading` debounce above). Every successful
  # MQTT uplink fires a `:dtu_seen`; a 6-inverter + 1 Shelly setup
  # produces ~1–4 per second sustained. Without this, each one was
  # running an uncached `list_devices/1` + `error_counts_by_dtu_id/1`
  # pair against `dtus` / `dtu_errors`, exhausting the 10-slot DB
  # pool alongside the reading-driven traffic. 1 s matches the
  # `:reading` debounce so the two refresh passes fit inside the
  # same checkout budget.
  @devices_refresh_debounce_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Telemetry.subscribe()
      Telemetry.subscribe_status()
      Broker.subscribe_presence()
      # Listen for the client-side timezone push (via PubSub from
      # `.ChartTooltip` or from tests).
      Phoenix.PubSub.subscribe(DtuApp.PubSub, @timezone_topic)
      # Subscribe to the per-user notification topic so this LiveView
      # receives `:notification` events fired by the server-side
      # producer GenServers (`DtuApp.Notifications.DtuConnection` and
      # `DtuApp.Notifications.SunDown`). The handle_info clause below
      # forwards each one to the page's `phx-hook="Notifications"`
      # sink via `push_event("notify", payload)`. Without this
      # subscribe, the dashboard would fire events that nobody
      # consumes — the user only saw notifications when they had the
      # `/notifications` page open, which is the opposite of the
      # intended behaviour.
      Notifications.subscribe(socket.assigns.current_scope.user.id)
    end

    user = socket.assigns.current_scope.user

    # Mount-stage timing probe — captures wall-clock of the two main
    # work blocks (`:mount_seed` + `:dashboard_data`) so a 6-inverter
    # cold-mount on prod can be diagnosed from a single log line. Off
    # by default; flip `DASHBOARD_MOUNT_TIMING_LOG=true` in the env to
    # enable. See `DtuAppWeb.DashboardLive.MountTiming` for the field
    # contract and why this isn't a telemetry event.
    mount_start = System.monotonic_time(:native)
    mount_stages = []

    # Tier 2 / Perf #15 — `mount_seed/2` wraps the four cacheable
    # mount-time fetches (`list_devices`, `error_counts_by_dtu_id`,
    # `PushSubscriptions.list_for_user`, `Accounts.get_shared_link`)
    # in a single `DashboardMountCache.fetch/4` closure. The HTTP
    # render and the WebSocket upgrade both call `mount/3` in
    # separate processes; without the cache, both processes
    # independently fire the same four queries — 8 round-trips per
    # page load against a 10-slot connection pool. The cache is a
    # lock-free `:ets` table with race-safe `:ets.insert_new/2`
    # (see `DtuAppWeb.DashboardLive.DashboardMountCache` for the
    # rationale); concurrent misses collapse to a single fetcher
    # run. `refresh_devices/2` (used by the `:dtu_seen` /
    # `:dtu_added` / `:dtu_removed` PubSub handlers) is unchanged —
    # those are single-process calls with no race to dedupe.
    {mount_stages, socket} =
      MountTiming.measure(:mount_seed, mount_stages, fn ->
        mount_seed(socket, user)
      end)

    socket =
      socket
      |> assign(:selected_dtu_id, nil)
      # `live` is true for the auto-refreshing Today view.
      # `granularity` drives the historical stepper (day/week/month/year).
      |> assign(:live, true)
      |> assign(:granularity, "day")
      # Perf #5 — `kickoff_weather_fetch/6` reads this to decide
      # between sync (initial mount) and async-on-WebSocket
      # (subsequent re-renders). Flipped to `false` at the end of
      # `assign_dashboard_data/5`'s line-chart branches so the
      # `handle_event` / `handle_info` re-render path gets the
      # latency win.
      |> assign(:initial_mount?, true)
      # Cloud-cover fingerprint — see `kickoff_weather_fetch/6`.
      # Seeded to `nil` so the very first fetch always takes the
      # "changed" branch; once populated, a steady-state PubSub
      # `:reading` broadcast (which doesn't shift coords, date, or
      # the visible X range) short-circuits and leaves the band
      # alone — no flicker.
      |> assign(:weather_input_fingerprint, nil)
      |> assign(:time_range, "today")
      # Top-level preset chosen in the toolbar: 1D (today, live) / 7D / 30D /
      # YTD / custom (delegates to the historical stepper). Defaults to 1D
      # so a fresh mount lands on the auto-refreshing view.
      |> assign(:range_preset, "1d")
      |> assign(:selected_period, nil)
      # Seed from the user's stored offset (`Accounts.update_user_tz_offset/2`
      # persists whatever the browser last reported) so the first render
      # already uses the correct tz — without this, the dashboard paints
      # with UTC, then jumps 1–2 hours to local time the moment the
      # `.SetTimezone` hook's PubSub message lands in `handle_info/2`
      # and triggers a second render. Sun-up / sun-down guide lines
      # and the now-marker visibly teleport in that gap.
      #
      # Brand-new users (`user.tz_offset_seconds == 0`) still fall
      # back to the JS push — there's no server-side way to know
      # the browser tz without their cooperation.
      |> assign(:user_tz_offset_seconds, user.tz_offset_seconds || 0)
      # `true` while a debounced `{:reading, ...}` refresh is in flight
      # (1s after the first broadcast, the actual refresh fires as
      # `:refresh_today`). Subsequent broadcasts in the same window
      # absorb into the existing timer instead of stacking new
      # refreshes. Set on the reading handler; cleared on the
      # `:refresh_today` handler. See `handle_info({:reading, ...})`
      # for the rationale (pool-exhaustion fix).
      |> assign(:dashboard_refresh_pending, false)
      # See `handle_info({:dtu_seen, ...})` for the rationale
      # (per-uplink `refresh_devices/2` exhausts the DB pool on a
      # paired Shelly + 6-inverter install). Set on the first
      # `:dtu_seen` in a window; cleared on the `:refresh_devices`
      # handler.
      |> assign(:devices_refresh_pending, false)
      # Locale for stat-card / chart-axis number formatting. Picked up by
      # `Devices.format_number/2` and `Devices.format_savings/1` so a
      # German user sees `1.234,5 kWh` and a French user sees
      # `1 234,5 kWh` instead of the locale-agnostic `1234.5 kWh`. Captured
      # once at mount; the user's locale doesn't change mid-session, so
      # the assign is read-only after this point.
      |> assign(:locale, Gettext.get_locale(DtuAppWeb.Gettext))
      # Cloud-cover-card geolocation state. `:granted` when the user
      # has captured lat/lon (the card renders the data); `:not_asked`
      # when the user has none (the card renders a "Share location"
      # button). `:loading` and `:denied` are set by the
      # `location_loading` / `location_denied` handlers below and
      # stay sticky through subsequent `assign_dashboard_data` calls
      # (the helper deliberately doesn't touch this assign). On a
      # full page reload the assign re-initialises from the user's
      # persisted coords, so a denied-then-granted user recovers
      # naturally on the next mount.
      |> assign(
        :geolocation_state,
        if(DtuApp.Accounts.user_has_geolocation?(user),
          do: :granted,
          else: :not_asked
        )
      )
      # Energy rate for the "Saved today" card. The user sets this on
      # `/users/settings`; if it's nil the savings card is hidden. Read
      # from the user schema here so the LiveView re-render on every
      # reading picks up the same value without a re-read.
      |> assign(:cents_per_kwh, user.cents_per_kwh)
      # `:consumption_stats` / `:net_flow_stats` start as
      # zero-placeholders. `assign_dashboard_data/5` below overwrites
      # them with the real numbers (today's kWh, peak, net flow) on
      # the today branch; the placeholders only matter for any path
      # that returns the render before `assign_dashboard_data/5`
      # completes, which in practice never happens (the call is
      # synchronous in `mount/3`).
      |> assign(:consumption_stats, %{
        current_consumption: 0.0,
        today_consumption: 0.0,
        peak_consumption: 0.0
      })
      |> assign(:net_flow_stats, %{
        current_net_flow: 0.0,
        today_net_export: 0.0,
        today_net_import: 0.0,
        peak_export: 0.0,
        peak_import: 0.0
      })
      |> PeriodSelectable.assign_selectable_periods(user, nil)

    # Main per-branch work: today's chart points, consumption/net stats,
    # line-chart SVG, peak computations. The dominant cost on a
    # 6-inverter cold mount (where the cache doesn't fully absorb
    # because the Shelly's reading-side queries aren't all cached).
    {mount_stages, socket} =
      MountTiming.measure(:dashboard_data, mount_stages, fn ->
        DashboardData.assign_dashboard_data(socket, user, nil, "today", nil)
      end)

    MountTiming.emit(mount_start, mount_stages, user_id: user.id)

    {:ok, socket}
  end

  # Weather cluster (`assign_weather_placeholders/1`,
  # `kickoff_weather_fetch/6`, `fetch_weather_snapshot/5`,
  # `apply_weather_snapshot/2`, `build_cloud_cover_band/5`,
  # `weather_current_condition/1`, `weather_current_pct/1`,
  # `most_recent_pct/2`, `weather_fingerprint/5`) lives in
  # `DtuAppWeb.DashboardLive.Weather` — see that module's @moduledoc
  # for the HTTP-vs-WebSocket split rationale and the
  # failure-handling contract.
  # weather-fetch cluster (`kickoff_weather_fetch/6`,
  # `fetch_weather_snapshot/5`, `apply_weather_snapshot/2`,
  # `assign_weather_placeholders/1`, `build_cloud_cover_band/5`,
  # `weather_current_condition/1`, `weather_current_pct/1`,
  # `most_recent_pct/2`) live in `DtuAppWeb.DashboardLive.Weather` —
  # see that module's @moduledoc for the HTTP-vs-WebSocket split
  # rationale and the failure-handling contract.

  # `phx-push` path: the JS hook's `this.pushEvent("set_timezone", ...)`
  # arrives here and is forwarded to `handle_info({:set_timezone, ...})`
  # (grouped with the other `handle_info/2` clauses further down). Tests
  # use `Phoenix.PubSub.broadcast/2` directly, hitting the same handler.
  @impl true
  def handle_event("set_timezone", %{"offset_seconds" => raw}, socket)
      when is_binary(raw) do
    handle_info({:set_timezone, String.to_integer(raw)}, socket)
  end

  def handle_event("set_timezone", _payload, socket), do: {:noreply, socket}

  # `phx-push` path: the JS hook's `this.pushEvent("set_location", ...)`
  # arrives here when the browser's `navigator.geolocation` resolves
  # positively. Mirrors the `set_timezone` flow above — the colocated
  # hook only pushes when both coords are finite numbers (denial /
  # unavailable / timeout all silently fall through), so the guard
  # here is a defence in depth against a corrupted payload.
  @impl true
  def handle_event("set_location", %{"latitude" => lat, "longitude" => lon}, socket)
      when is_number(lat) and is_number(lon) do
    handle_info({:set_location, {lat, lon}}, socket)
  end

  def handle_event("set_location", _payload, socket), do: {:noreply, socket}

  # Cloud-cover card geolocation state transitions. The button in
  # the card slot is wired to `.RequestLocation` (a colocated JS
  # hook); on click the hook calls `navigator.geolocation
  # .getCurrentPosition` and pushes one of:
  #
  #   * `location_loading` — the prompt is up; flip the card to
  #     the loading state (button disabled, "Requesting…" label)
  #     so the user gets immediate visual feedback.
  #   * `set_location` — handled above; success path.
  #   * `location_denied` — PERMISSION_DENIED / POSITION_UNAVAILABLE
  #     / TIMEOUT. We treat all three as "hide the card" per the
  #     product decision: a denied user has no in-app retry path,
  #     the browser's site settings is the recovery surface, and
  #     on the next page mount the button comes back.
  @impl true
  def handle_event("location_loading", _payload, socket) do
    {:noreply, assign(socket, :geolocation_state, :loading)}
  end

  def handle_event("location_denied", _payload, socket) do
    {:noreply, assign(socket, :geolocation_state, :denied)}
  end

  @impl true
  def handle_event("select_dtu", %{"id" => id_str}, socket) do
    selected_id = if id_str == "total", do: nil, else: String.to_integer(id_str)
    user = socket.assigns.current_scope.user

    socket = PeriodSelectable.assign_selectable_periods(socket, user, selected_id)

    # Drop the previous-dtu today-branch cache (same reasoning as
    # `set_timezone` above — the new `dtu_id` produces a new cache
    # key, but the stale entry would sit in ETS until TTL).
    TodayDataCache.invalidate(user.id)

    socket =
      socket
      |> assign(:selected_dtu_id, selected_id)
      |> DashboardData.reapply_current_view(user, selected_id)

    {:noreply, socket}
  end

  # Top-level preset toolbar dispatch. Each preset picks a different
  # branch in `assign_dashboard_data/5`; the `range` value IS the
  # `time_range` value used downstream (so existing `today` / `day` /
  # `week` / `month` / `year` branches keep working) plus the new
  # `7d` / `30d` / `ytd` values for the trailing-N-days presets.
  #
  # `1d` keeps the legacy "today" branch (live, auto-refreshing). The
  # `custom` preset stays on whatever granularity + period the user had
  # previously selected — the stepper's prev/next/calendar events
  # already mutate those assigns, so we just need to flip `range_preset`
  # and let `assign_dashboard_data/5` re-render for the current state.
  @impl true
  def handle_event("select_quick_range", %{"range" => range}, socket)
      when range in ~w(1d 7d 30d ytd custom) do
    user = socket.assigns.current_scope.user
    dtu_id = socket.assigns.selected_dtu_id

    socket =
      case range do
        "1d" ->
          socket
          |> assign(:range_preset, "1d")
          |> assign(:live, true)
          |> assign(:time_range, "today")
          |> assign(:selected_period, nil)
          |> DashboardData.assign_dashboard_data(user, dtu_id, "today", nil)

        "7d" ->
          socket
          |> assign(:range_preset, "7d")
          |> assign(:live, false)
          |> assign(:time_range, "7d")
          |> assign(:selected_period, nil)
          |> DashboardData.assign_dashboard_data(user, dtu_id, "7d", nil)

        "30d" ->
          socket
          |> assign(:range_preset, "30d")
          |> assign(:live, false)
          |> assign(:time_range, "30d")
          |> assign(:selected_period, nil)
          |> DashboardData.assign_dashboard_data(user, dtu_id, "30d", nil)

        "ytd" ->
          socket
          |> assign(:range_preset, "ytd")
          |> assign(:live, false)
          |> assign(:time_range, "ytd")
          |> assign(:selected_period, nil)
          |> DashboardData.assign_dashboard_data(user, dtu_id, "ytd", nil)

        "custom" ->
          # Keep the existing granularity + period; the stepper already
          # drives `selected_period` / `granularity`. If neither has
          # ever been set (e.g. user clicks Custom on a fresh mount),
          # fall back to Day granularity on the most recent period.
          granularity = socket.assigns.granularity || "day"
          period = socket.assigns.selected_period || Date.utc_today()

          socket
          |> assign(:range_preset, "custom")
          |> assign(:live, false)
          |> assign(:time_range, granularity)
          |> DashboardData.assign_dashboard_data(user, dtu_id, granularity, period)
      end

    {:noreply, socket}
  end

  # Back-compat: a stray `range=today` value (the original single
  # button's payload) maps to the `1d` preset. Once the template is
  # updated to emit `1d`, this clause can be removed.
  @impl true
  def handle_event("select_quick_range", %{"range" => "today"}, socket) do
    handle_event("select_quick_range", %{"range" => "1d"}, socket)
  end

  # Granularity dropdown in the historical stepper (day/week/month/year).
  @impl true
  def handle_event("set_granularity", %{"granularity" => granularity}, socket) do
    user = socket.assigns.current_scope.user
    dtu_id = socket.assigns.selected_dtu_id

    # Start the new granularity on the most recent period with data (or today).
    selectable = selectable_periods_for(socket.assigns, granularity)
    period = first_period(selectable, granularity)

    {:noreply,
     socket
     |> assign(:live, false)
     |> assign(:granularity, granularity)
     |> assign(:time_range, granularity)
     |> DashboardData.assign_dashboard_data(user, dtu_id, granularity, period)}
  end

  # Stepper: move one granularity step backward/forward.
  @impl true
  def handle_event("navigate_period", %{"dir" => dir}, socket) do
    user = socket.assigns.current_scope.user
    dtu_id = socket.assigns.selected_dtu_id
    granularity = socket.assigns.granularity

    current =
      socket.assigns.selected_period ||
        TimeHelpers.local_today(socket.assigns.user_tz_offset_seconds)

    period = shift_period(current, granularity, dir)

    {:noreply,
     socket
     |> assign(:live, false)
     |> assign(:time_range, granularity)
     |> DashboardData.assign_dashboard_data(user, dtu_id, granularity, period)}
  end

  # Calendar: native <input type=date> picks the anchor date for the granularity.
  @impl true
  def handle_event("set_date", %{"date" => date_str}, socket) do
    user = socket.assigns.current_scope.user
    dtu_id = socket.assigns.selected_dtu_id
    granularity = socket.assigns.granularity

    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        period = anchor_period(date, granularity)

        {:noreply,
         socket
         |> assign(:live, false)
         |> assign(:time_range, granularity)
         |> DashboardData.assign_dashboard_data(user, dtu_id, granularity, period)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  # Network status event handler from the NetworkStatus hook
  @impl true
  def handle_event("network_status_changed", payload, socket) do
    # Handle network status changes
    # You can update UI elements, show notifications, or adjust data fetching
    socket =
      socket
      |> assign(:network_online, payload["online"])
      |> assign(:network_connection_type, payload["connection_type"])
      |> assign(:network_last_update, payload["timestamp"])

    {:noreply, socket}
  end

  # The `PushSubscribe` JS hook (mounted on the dashboard layout, see
  # `render/1` below) sends this event after a successful POST to
  # `/push/subscribe`. We only flip `@has_push_subscriptions` to true
  # — never back to false — because the hook only POSTs when it has
  # a fresh subscription. A re-render mid-session shouldn't drop the
  # "Native push is on" badge until the next page load.
  @impl true
  def handle_event("push_subscribed", %{"endpoint" => _endpoint}, socket) do
    {:noreply, assign(socket, :has_push_subscriptions, true)}
  end

  def handle_event("push_subscribed", _payload, socket) do
    # Defensive: tolerate an empty/malformed payload (the hook
    # shouldn't ever send one, but if it did we don't want to crash
    # the dashboard LiveView).
    {:noreply, socket}
  end

  # Share toggle. The toolbar switch sends `"enabled" => "true"|"false"`
  # (the JS hook serializes booleans that way).
  #
  # Both directions are split into two phases so the UI gets a chance
  # to render the loading spinner between the click and the result:
  #
  #   1. `toggle_share` flips `:share_loading?` true and schedules a
  #      delayed message (`Process.send_after/3`) for the actual DB
  #      work. The delay is `@share_load_delay_ms` (200ms in prod, 0
  #      in tests) so the spinner is actually visible — a sub-10ms
  #      DB delete would otherwise flash the spinner for a single
  #      frame and the user would see "the click did nothing".
  #   2. The delayed `handle_info` clause runs the DB work and emits
  #      a second render with the result + `:share_loading?` false.
  #
  # On disable, the URL input and copy button vanish INSTANTLY
  # (optimistic UI: `:share_active?` and `:share_url` are cleared
  # synchronously), and the spinner stays in their place until the
  # delayed revoke completes and the hint text reappears.
  #
  # Both modes are best-effort — a DB failure logs at warning and
  # leaves the UI in its prior state rather than crashing the
  # dashboard.
  @impl true
  def handle_event("toggle_share", %{"enabled" => "true"}, socket) do
    user = socket.assigns.current_scope.user
    Process.send_after(self(), {:mint_shared_link, user.id}, @share_load_delay_ms)
    {:noreply, assign(socket, :share_loading?, true)}
  end

  def handle_event("toggle_share", %{"enabled" => "false"}, socket) do
    user = socket.assigns.current_scope.user
    Process.send_after(self(), {:revoke_shared_link, user.id}, @share_load_delay_ms)

    {:noreply,
     socket
     # Optimistic: input + copy button vanish this render.
     |> assign(:share_active?, false)
     |> assign(:share_url, nil)
     |> assign(:share_loading?, true)}
  end

  def handle_event("toggle_share", _payload, socket), do: {:noreply, socket}

  # Share-link result handlers live in
  # `DtuAppWeb.DashboardLive.ShareLink` (`apply_result/2` and
  # `url_for_token/1`). See that module's moduledoc for the toggle
  # flow contract.

  # Phase 2 of the enable flow: the delayed `Process.send_after` from
  # `toggle_share` fired. Run the DB work synchronously on the LiveView
  # process (it's <10ms so it doesn't block anything user-perceptible)
  # and apply the result. Pin the user id so a stale message from a
  # previous session can't resurrect a deleted user's share row.
  @impl true
  def handle_info({:mint_shared_link, user_id}, socket) do
    current_user_id = socket.assigns.current_scope.user.id

    if user_id == current_user_id do
      user = socket.assigns.current_scope.user
      ShareLink.apply_result(socket, Accounts.create_shared_link(user))
    else
      {:noreply, socket}
    end
  end

  # Phase 2 of the disable flow: the delayed `Process.send_after` from
  # `toggle_share` fired. Run the revoke synchronously and clear the
  # loading flag so the hint text reappears. Pin the user id so a
  # stale message from a previous session can't dismiss a different
  # user's spinner.
  @impl true
  def handle_info({:revoke_shared_link, user_id}, socket) do
    current_user_id = socket.assigns.current_scope.user.id

    if user_id == current_user_id do
      user = socket.assigns.current_scope.user
      :ok = Accounts.revoke_shared_link(user)
      {:noreply, assign(socket, :share_loading?, false)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:reading, _client_id, _reading}, socket) do
    # A paired Shelly (every 30s) + an OpenDTU inverter (every 5–10s)
    # produces 2–6 PubSub `:reading` broadcasts per second sustained.
    # Each one used to trigger a full `assign_dashboard_data/5` today-
    # branch refresh — ~10 separate `Repo.all` round-trips per call,
    # which on a 10-slot DB pool starves the connection pool under any
    # moderate load and produces a 15 s `DBConnection.checkout_timeout`
    # (visible as `:prim_inet.recv0/3` blocking inside
    # `get_net_flow_stats/3`'s DISTINCT ON).
    #
    # Coalesce: at most one debounced refresh per debounce window per
    # LV process. 1 s is comfortably below human-perception latency
    # (Shelly's 30s cadence and OpenDTU's 5–10s cadence both sit
    # inside it), and the today-branch cache is invalidated immediately
    # so the debounced refresh re-fetches fresh data.
    #
    # If a refresh is already pending, the in-flight one absorbs this
    # broadcast — no new timer, no new invalidation (the existing
    # timer's :refresh_today will re-invalidate and re-fetch).
    if socket.assigns.dashboard_refresh_pending do
      {:noreply, socket}
    else
      user = socket.assigns.current_scope.user

      # Drop the cached today-window data immediately so the
      # debounced refresh re-runs the heavy `readings` scans —
      # without this, a freshly-arrived reading would be invisible
      # in the chart for up to 15 s. The cache layer (extended to
      # cover the whole today branch — see `TodayDataCache`) picks
      # this up on the next `fetch/2`.
      #
      # Use the narrow `invalidate_today/1` rather than the broad
      # `invalidate/1` so the historical branches (day / week /
      # month / year / 7d / 30d / ytd) keep their 15 s TTL across
      # a reading broadcast — under hot `:reading` traffic, the
      # broad wipe was re-fetching all 8 branches on every
      # broadcast even though only the today view changed.
      TodayDataCache.invalidate_today(user.id)

      Process.send_after(self(), :refresh_today, @reading_refresh_debounce_ms)

      {:noreply, assign(socket, :dashboard_refresh_pending, true)}
    end
  end

  # Fires `reading_refresh_debounce_ms` after the first
  # `{:reading, ...}` broadcast in a debounce window. The actual
  # refresh work — re-running the today branch — runs here, not in
  # the broadcast handler, so 10 readings in 1 s collapse to a
  # single refresh.
  @impl true
  def handle_info(:refresh_today, socket) do
    user = socket.assigns.current_scope.user
    selected_id = socket.assigns.selected_dtu_id

    socket = PeriodSelectable.assign_selectable_periods(socket, user, selected_id)

    # Note: we deliberately do NOT call `refresh_devices/2` here. The
    # device list itself doesn't change on a reading — only
    # `dtus.last_seen_at` does, and that's already reflected by the
    # `:dtu_seen` broadcast (`handle_info({:dtu_seen, ...})` below)
    # which keeps the online badge fresh. Re-listing devices on
    # every reading was an unconditional `SELECT ... FROM dtus WHERE
    # user_id = $1` round-trip that contributed to the pool-exhaust
    # path this fix targets.
    socket =
      socket
      |> assign(:dashboard_refresh_pending, false)
      |> DashboardData.maybe_reassign_dashboard_data(user, selected_id)

    {:noreply, socket}
  end

  # Fires `devices_refresh_debounce_ms` after the first
  # `{:dtu_seen, ...}` broadcast in a debounce window. The actual
  # refresh work — re-listing devices + their error counts — runs
  # here, not in the broadcast handler, so 10 uplinks in 1 s
  # collapse to a single `refresh_devices/2` call.
  #
  # Unlike `:refresh_today` above, this handler does NOT touch
  # `TodayDataCache.invalidate/1`: `:dtu_seen` only updates
  # `dtus.last_seen_at` (the online badge), not the chart's
  # today-window data.
  @impl true
  def handle_info(:refresh_devices, socket) do
    user = socket.assigns.current_scope.user

    socket =
      socket
      |> assign(:devices_refresh_pending, false)
      |> refresh_devices(user)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:dtu_connected, _client_id, _device_id}, socket) do
    # Connection-state *notifications* are fired by
    # `DtuApp.Notifications.DtuConnection` (a server-side GenServer
    # subscribed to `dtu:presence`), so the producer runs even when
    # this LV process isn't alive. The LV's job here is only to
    # refresh the online badge — the same `dtu_seen` / CONNECT event
    # already triggered `last_seen_at` updates in `Telemetry`, but
    # re-reading the device list is what flips the badge on the
    # next render without waiting for the next reading.
    {:noreply, refresh_devices(socket, socket.assigns.current_scope.user)}
  end

  @impl true
  def handle_info({:dtu_disconnected, _client_id, _device_id}, socket) do
    # Same as `:dtu_connected` above — the notification producer lives
    # in `DtuApp.Notifications.DtuConnection`. We only refresh the
    # online badge here.
    {:noreply, refresh_devices(socket, socket.assigns.current_scope.user)}
  end

  # Every MQTT uplink (and every CONNECT / DISCONNECT) broadcasts a
  # `:dtu_seen` on `dtu:status` after touching `last_seen_at`. Re-read
  # the device list so the badge flips on the next render. The
  # historical-view path is left alone — only the live view's stats
  # chart is refreshed on every reading.
  #
  # Coalesce: at most one debounced refresh per debounce window per
  # LV process. Mirrors the `:reading` debounce above — the per-
  # uplink `refresh_devices/2` (uncached `list_devices/1` +
  # `error_counts_by_dtu_id/1`) was the second-largest contributor
  # to the 10-slot DB-pool exhaustion documented in
  # `docs/PERF_FINDINGS_2026-09-08.md` finding #4.
  @impl true
  def handle_info({:dtu_seen, _device_id}, socket) do
    if socket.assigns.devices_refresh_pending do
      {:noreply, socket}
    else
      Process.send_after(self(), :refresh_devices, @devices_refresh_debounce_ms)

      {:noreply, assign(socket, :devices_refresh_pending, true)}
    end
  end

  # `:dtu_error` is broadcast by `Telemetry.record_dtu_error/2` whenever
  # the parser rejects an uplink or a DB insert fails. The condition is
  # already persisted on `dtus.last_error`; we re-read the device list
  # here so the bubble appears without waiting for the next uplink.
  @impl true
  def handle_info({:dtu_error, _device_id}, socket) do
    user = socket.assigns.current_scope.user
    {:noreply, refresh_devices(socket, user)}
  end

  @impl true
  def handle_info({:set_timezone, offset_seconds}, socket)
      when is_integer(offset_seconds) do
    # Persist to the user record so the server-side `SunUp` producer
    # (which has no LV attached) can compute "today" in the user's
    # local TZ. Best-effort: a failed write doesn't break the render.
    user = socket.assigns.current_scope.user

    if user.tz_offset_seconds != offset_seconds do
      _ = DtuApp.Accounts.update_user_tz_offset(user, offset_seconds)
    end

    # Drop the previous-tz today-branch cache so the new tz doesn't
    # have to wait for the 15s TTL. The cache key already changes
    # automatically on tz change, but the stale entry would sit in
    # ETS until the TTL expires — `invalidate/1` is a one-line
    # `match_delete` that clears every variant for this user.
    TodayDataCache.invalidate(user.id)

    {:noreply,
     socket
     |> assign(:user_tz_offset_seconds, offset_seconds)
     |> DashboardData.assign_dashboard_data(
       socket.assigns.current_scope.user,
       socket.assigns.selected_dtu_id,
       socket.assigns.time_range,
       socket.assigns.selected_period
     )}
  end

  def handle_info({:set_timezone, _other}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:set_location, {lat, lon}}, socket) when is_number(lat) and is_number(lon) do
    # Persist on the user record so the server-side chart render
    # (which has no LV's own state to read from) can compute
    # astronomical sunrise / sunset on subsequent refreshes —
    # not just this one. Best-effort: a failed write doesn't break
    # the render, the chart simply won't show sun markers this
    # round.
    user = socket.assigns.current_scope.user

    case DtuApp.Accounts.update_user_location(user, %{latitude: lat, longitude: lon}) do
      :ok ->
        # Re-read so the just-persisted coords are visible to the
        # upcoming `assign_dashboard_data` (the in-memory `user`
        # struct still has the OLD nil values). Without this, the
        # cloud-cover card would re-render the "Share location"
        # button even though coords are now saved.
        refreshed_user = DtuApp.Accounts.get_user!(user.id)

        {:noreply,
         socket
         |> assign(:geolocation_state, :granted)
         |> DashboardData.assign_dashboard_data(
           refreshed_user,
           socket.assigns.selected_dtu_id,
           socket.assigns.time_range,
           socket.assigns.selected_period
         )}

      {:error, _reason} ->
        # Write failed — treat as a denial from the user's POV so
        # the card hides rather than showing a stale "Requesting…"
        # forever. The next page mount re-prompts from scratch.
        {:noreply,
         socket
         |> assign(:geolocation_state, :denied)
         |> DashboardData.assign_dashboard_data(
           user,
           socket.assigns.selected_dtu_id,
           socket.assigns.time_range,
           socket.assigns.selected_period
         )}
    end
  end

  def handle_info({:set_location, _other}, socket), do: {:noreply, socket}

  # Forward per-user `:notification` PubSub events (fired by
  # `broadcast_dtu_connection/3` and the future sun-down scheduler)
  # to the page's `phx-hook="Notifications"` sink via `push_event/3`.
  # The Notifications JS hook in `assets/js/notifications.js` then fires
  # the actual `new Notification(...)` after dedup against localStorage.
  #
  # Without this clause the dashboard's subscription (added in
  # `mount/3`) would crash on the very first `:notification` message.
  @impl true
  def handle_info({:notification, payload}, socket) do
    {:noreply, push_event(socket, "notify", payload)}
  end

  # Perf #5: the `Task.start/1` spawned by `kickoff_weather_fetch/6`
  # on the WebSocket path delivers its result here. Applies the
  # three weather-driven assigns (`:cloud_cover_line`,
  # `:current_cloud_cover`, `:current_cloud_cover_pct`); the chart
  # itself is already rendered, so the only thing this re-render
  # changes is the cloud-cover line + current-condition card.
  #
  # If the Task crashed and never sent (which shouldn't happen — the
  # `Weather` facade returns `nil` on every failure path), the assigns
  # stay at their placeholder defaults (`[]` / `nil`) and the next
  # re-render cycle (e.g. a new reading broadcast) re-fires the kickoff.
  @impl true
  def handle_info({:weather_update, snapshot}, socket) do
    {:noreply, Weather.apply_weather_snapshot(socket, snapshot)}
  end

  # Catch-all for other messages
  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Re-fetch the user's devices and recompute the scenario flags
  # (`@has_inverter?`, `@has_shelly?`, `@has_ro_sink?`) that drive the
  # dashboard's conditional rendering — which stat-card rows appear,
  # whether the chart plots a production curve, and whether the
  # net-flow row is shown.
  #
  # Called from every handle_info/2 that already updated
  # `@devices` (a reading, a CONNECT / DISCONNECT, a status tick,
  # mount/3). Centralising the flag update keeps the four call
  # sites in sync — adding a new code path that touches
  # `@devices` only needs to call this helper, not duplicate the
  # kind-classification logic.
  #
  # The classification mirrors `DtuApp.Devices.Dtu`'s `@kinds`
  # (`:opendtu`, `:ahoydtu`, `:shelly3em`, `:mqtt_ro_sink`). New
  # kinds added to the schema should extend `inverter_kinds?/1` /
  # `shelly_kinds?/1` / `ro_sink_kind?/1` here — the dashboard's
  # scenario logic is the single consumer that needs to distinguish
  # them.
  defp refresh_devices(socket, user) do
    devices = Devices.list_devices(user)

    # Tier 2 / Perf #11: previously this invalidated
    # `UserDtuIdsCache` on every call. But `refresh_devices/2` runs
    # on every mount AND on every `:dtu_seen` PubSub broadcast
    # (one per MQTT uplink, so 2–6 Hz on a paired user). With a
    # 30 s TTL the eager invalidate defeated the cache entirely —
    # every refresh started with a cache miss. The fix is to leave
    # the cache alone here: this function reads the device list,
    # it doesn't mutate it. The mutation entry points
    # (`Devices.create_device/2`, `Devices.delete_device/1`) now
    # invalidate explicitly, so the cache stays correct without
    # paying the invalidate cost on every refresh.
    socket
    |> assign(:devices, devices)
    |> assign(:has_inverter?, Enum.any?(devices, &DtuKinds.inverter_kind?/1))
    |> assign(:has_shelly?, Enum.any?(devices, &DtuKinds.shelly_kind?/1))
    |> assign(:has_ro_sink?, Enum.any?(devices, &DtuKinds.ro_sink_kind?/1))
    |> assign(:error_counts, error_counts_by_dtu_id(devices))
  end

  # Per-device distinct-error-count map for the dashboard's edge
  # badge. One round-trip regardless of how many devices the user has,
  # so the refresh stays O(1) queries even for power users with
  # many DTUs. Devices without errors are absent from the map — the
  # badge conditional in the template uses `Map.get(@error_counts,
  # device.id, 0)` so a missing entry reads as 0.
  defp error_counts_by_dtu_id(devices) do
    dtu_ids = Enum.map(devices, & &1.id)

    if dtu_ids == [] do
      %{}
    else
      # Filter on `inserted_at >= cutoff` so a device whose last error
      # fired more than `dtu_error_recency_seconds` ago doesn't show
      # the badge. The cutoff is computed at the same `now()` the row's
      # `inserted_at` was written against (DB clock), so the comparison
      # is exact — see `DtuApp.Time.utc_now_usec/0` for why.
      cutoff = DtuApp.Devices.dtu_error_recency_cutoff()

      DtuApp.Repo.all(
        from e in DtuApp.Devices.DtuError,
          where: e.dtu_id in ^dtu_ids and e.inserted_at >= ^cutoff,
          group_by: e.dtu_id,
          select: %{dtu_id: e.dtu_id, distinct_count: count(e.message, :distinct)}
      )
      |> Map.new(fn %{dtu_id: id, distinct_count: n} -> {id, n} end)
    end
  end

  # DTU-kind predicates (`inverter_kind?/1`, `shelly_kind?/1`,
  # `ro_sink_kind?/1`) live in `DtuAppWeb.DashboardLive.DtuKinds`.
  # Used by `refresh_devices/2` and `mount_seed/2` below.

  # Tier 2 / Perf #15 — wrap the four cacheable mount-time fetches
  # in a single `DashboardMountCache.fetch/4` closure. The HTTP render
  # and the WebSocket upgrade both call `mount/3` in separate
  # processes; without the cache, both processes independently fire
  # the same four queries (`list_devices`, `error_counts_by_dtu_id`,
  # `PushSubscriptions.list_for_user`, `Accounts.get_shared_link`).
  # The cache dedupes the second call to a 0-query ETS lookup.
  #
  # The share-link mint timer stays per-process (it targets `self()`,
  # and `self()` is different on the HTTP-render vs WebSocket-upgrade
  # processes) — only the boolean `share_active?` is cached; the
  # scheduling happens after the cache read.
  defp mount_seed(socket, user) do
    tz_offset_seconds = user.tz_offset_seconds || 0

    seed =
      DashboardMountCache.fetch(user.id, nil, tz_offset_seconds, fn ->
        devices = Devices.list_devices(user)

        %{
          devices: devices,
          has_inverter?: Enum.any?(devices, &DtuKinds.inverter_kind?/1),
          has_shelly?: Enum.any?(devices, &DtuKinds.shelly_kind?/1),
          has_ro_sink?: Enum.any?(devices, &DtuKinds.ro_sink_kind?/1),
          error_counts: error_counts_by_dtu_id(devices),
          has_push_subscriptions: PushSubscriptions.list_for_user(user) != [],
          share_active?: Accounts.get_shared_link(user) != nil
        }
      end)

    socket =
      socket
      |> assign(:devices, seed.devices)
      |> assign(:has_inverter?, seed.has_inverter?)
      |> assign(:has_shelly?, seed.has_shelly?)
      |> assign(:has_ro_sink?, seed.has_ro_sink?)
      |> assign(:error_counts, seed.error_counts)
      |> assign(:has_push_subscriptions, seed.has_push_subscriptions)
      |> assign(:share_active?, seed.share_active?)
      |> assign(:share_url, nil)
      |> assign(:share_loading?, false)

    # When the share row already exists (returning user with sharing
    # on), schedule the delayed-mint flow that `toggle_share` uses —
    # ~200ms after mount the spinner resolves into the URL input +
    # copy button. This silently invalidates the prior row, which
    # matches the toggle-on behavior the user already accepts.
    if seed.share_active? do
      Process.send_after(self(), {:mint_shared_link, user.id}, @share_load_delay_ms)
      assign(socket, :share_loading?, true)
    else
      socket
    end
  end

  # Line + bar chart data orchestration (`assign_line_chart_data/6`,
  # `assign_bar_chart_data/2`, `hd_or_first_key/1`) lives in
  # `DtuAppWeb.DashboardLive.LineChartData` — see that module's
  # @moduledoc for the coordinate-system + range-preset rationale.
  # Pure chart math (projection, X labels, Y gridlines) lives in
  # `ChartHelpers`.

  # --- Time-picker helpers ----------------------------------------------------

  # Apply `assign_dashboard_data/5` only on the live view — historical
  # views (day / week / month / year) are static and don't refresh on
  # every reading. Kept as a helper so the reading handler above can
  # stay readable.

  # Map a granularity to the prebuilt selectable-period list from assigns.
  defp selectable_periods_for(assigns, "day"), do: assigns.selectable_days
  defp selectable_periods_for(assigns, "week"), do: assigns.selectable_weeks
  defp selectable_periods_for(assigns, "month"), do: assigns.selectable_months
  defp selectable_periods_for(assigns, "year"), do: assigns.selectable_years
  defp selectable_periods_for(_assigns, _), do: []

  # First selectable period for a granularity (most recent with data), else today.
  defp first_period([], "year"), do: Date.utc_today().year
  defp first_period([], _), do: Date.utc_today()
  defp first_period([{_label, value} | _], "year"), do: String.to_integer(value)
  defp first_period([{_label, value} | _], _), do: Date.from_iso8601!(value)

  # Shift a period by one granularity step. "prev"/"next" move backward/forward.
  defp shift_period(%Date{} = date, "day", dir),
    do: Date.add(date, if(dir == "next", do: 1, else: -1))

  defp shift_period(%Date{} = date, "week", dir),
    do: Date.add(date, if(dir == "next", do: 7, else: -7))

  defp shift_period(%Date{} = date, "month", dir) do
    months = if(dir == "next", do: 1, else: -1)
    add_months(date, months)
  end

  defp shift_period(%Date{} = date, "year", dir),
    do: Date.add(date, if(dir == "next", do: 365, else: -365))

  defp shift_period(year, "year", dir) when is_integer(year),
    do: year + if(dir == "next", do: 1, else: -1)

  defp shift_period(period, _granularity, _dir), do: period

  defp add_months(date, months) do
    total = date.year * 12 + (date.month - 1) + months
    year = div(total, 12)
    month = rem(total, 12) + 1
    last_day = Date.new!(year, month, 1) |> Date.end_of_month() |> Map.get(:day)
    Date.new!(year, month, min(date.day, last_day))
  end

  # Normalize an arbitrary picked date to the start of the current granularity
  # (week→Monday, month/year→first day).
  defp anchor_period(date, "week"),
    do: Date.add(date, -(Date.day_of_week(date) - 1))

  defp anchor_period(date, "month"), do: Date.new!(date.year, date.month, 1)
  defp anchor_period(date, "year"), do: Date.new!(date.year, 1, 1)
  defp anchor_period(date, _), do: date

  # Human-readable "X ago" label for a past `DateTime`. Falls back to an
  # absolute YYYY-MM-DD HH:MM string for points in time more than a week
  # back, since minute/hour counts get unwieldy beyond that. Clamps future
  # timestamps to "just now" rather than rendering negative values.
  defp relative_time_label(%DateTime{} = dt, now \\ DtuApp.Time.utc_now()) do
    diff = DateTime.diff(now, dt, :second) |> max(0)

    cond do
      diff < 60 ->
        gettext("just now")

      diff < 3_600 ->
        gettext("%{n} minutes ago", n: div(diff, 60))

      diff < 86_400 ->
        gettext("%{n} hours ago", n: div(diff, 3_600))

      diff < 604_800 ->
        gettext("%{n} days ago", n: div(diff, 86_400))

      true ->
        Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} class="max-w-7xl">
      <%!--
        Notifications-firing hook. Mounted here (and on the /notifications
        page) so the dashboard can fire `new Notification(...)` on `notify`
        events. The hook is invisible (`hidden`) and only acts as a
        `phx:notify` event sink. `Notifications.subscribe/1` runs in mount/3
        and `handle_info({:notification, ...})` forwards each server-side
        event into `push_event("notify", payload)`.
      --%>
      <div
        id="notifications-firing"
        phx-hook="Notifications"
        data-user-id={@current_scope.user.id}
        hidden
      >
      </div>
      <%!--
        Push-subscribe hook. Owns the PushManager lifecycle on this
        device — when the user has already granted `Notification`
        permission in a prior session, this hook auto-subscribes on
        next visit by POSTing the service worker's PushSubscription
        JSON to `/push/subscribe`. The dashboard is the highest-
        traffic authenticated page (it's where most users land after
        login), so mounting here makes "returning user auto-
        subscribed" the default behaviour with no extra click.

        `data-push="auto"` is what `assets/js/push_subscribe.js` reads
        on `mounted()` to enable auto-subscription without waiting for
        the `push:enable` window event that the notifications page
        uses. The `NotificationPermission` hook on `/notifications`
        dispatches `push:enable` after the user clicks "Enable"; on
        the dashboard there's no permission UI, so we go straight to
        the auto-subscribe path.

        Idempotency: the controller upserts by `endpoint`, so a
        returning user landing here fires one extra POST per session
        and the row count stays stable.
      --%>
      <div
        id="push-subscribe"
        phx-hook="PushSubscribe"
        data-user-id={@current_scope.user.id}
        data-push="auto"
        hidden
      >
      </div>
      <%!--
        Geolocation auto-resolve hook. On mount, checks whether the
        user has already granted browser-level geolocation
        permission (e.g. via site settings after a previous denial,
        or because they previously used the browser's "Allow this
        site to always see my location" flow without going through
        the in-app button). When `state === 'granted'` the hook
        silently calls `getCurrentPosition` — no browser prompt
        fires because permission is already granted — and pushes
        the coordinates back via `set_location`, which the server
        handler turns into `:granted` plus a DB write.

        The user explicitly opted out of an unconditional
        on-mount prompt; this hook is the strict superset of that
        decision: it only acts when permission is *already*
        granted, so first-time users still see the in-app button.

        The card slot is gated on `@geolocation_state` (server
        assigns), so this hook racing with the button click is
        harmless — both paths converge on `:loading` → `:granted`.
      --%>
      <div
        id="auto-fetch-location"
        phx-hook=".AutoFetchLocation"
        data-user-id={@current_scope.user.id}
        hidden
      >
      </div>
      <div class="space-y-6 py-4">
        <!-- Title & Action -->
        <div class="flex flex-col md:flex-row md:items-center md:justify-between space-y-4 md:space-y-0">
          <div>
            <h1 class="text-3xl font-extrabold tracking-tight text-zinc-900 dark:text-white">
              {gettext("PV Power Dashboard")}
            </h1>
            <p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
              {gettext("Real-time and historic generation stats for your solar converter system.")}
            </p>
          </div>
          <%= if @devices == [] do %>
            <%!-- Promoted in the burger menu once a device exists. The
                 dashboard's main "Manage Devices" CTA only renders in
                 the onboarding state, so it doesn't compete with the
                 device cards below or the burger menu's link. --%>
            <div>
              <.link
                navigate={~p"/devices"}
                id="btn-manage-devices"
                class={[
                  "inline-flex items-center px-4 py-2 border rounded-md shadow-sm text-sm font-medium transition",
                  "border-zinc-300 dark:border-zinc-700 text-zinc-700 dark:text-zinc-200 bg-white dark:bg-zinc-800",
                  "hover:bg-zinc-50 dark:hover:bg-zinc-700 focus:outline-none"
                ]}
              >
                <.icon name="hero-cog-6-tooth" class="-ml-1 mr-2 h-5 w-5 text-zinc-400" />
                {gettext("Manage Devices")}
              </.link>
            </div>
          <% end %>
        </div>

        <%= if @devices == [] do %>
          <!-- Onboarding: no DTUs yet. The whole stats/chart grid is meaningless
               without a device, so guide the user to create their first one. -->
          <div
            class="rounded-2xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-8 text-center"
            id="onboarding-empty"
          >
            <div class="mx-auto w-fit p-3 rounded-xl bg-emerald-50 dark:bg-emerald-950/30 text-emerald-600 dark:text-emerald-400">
              <.icon name="hero-bolt" class="h-8 w-8" />
            </div>
            <h2 class="mt-4 text-xl font-bold tracking-tight text-zinc-900 dark:text-white">
              {gettext("Welcome! Let's connect your first DTU")}
            </h2>
            <p class="mt-2 text-sm text-zinc-500 dark:text-zinc-400 max-w-md mx-auto">
              {gettext(
                "A DTU (Data Transfer Unit) reads your solar inverter and publishes live telemetry here over MQTT. Add yours to start seeing real-time generation — works with OpenDTU and AhoyDTU firmware."
              )}
            </p>
            <div class="mt-6">
              <.link
                navigate={~p"/devices/new"}
                id="btn-add-first-dtu"
                class="inline-flex items-center gap-1.5 rounded-lg bg-emerald-500 hover:bg-emerald-400 px-5 py-2.5 text-sm font-semibold text-zinc-950 shadow-sm transition"
              >
                <.icon name="hero-plus-mini" class="size-4" />
                {gettext("Add your first DTU")}
              </.link>
            </div>
          </div>

          <%!-- "How it works" rail: a quiet three-step promise below
               the welcome card. The welcome card's paragraph already
               explains MQTT and per-device credentials; the rail names
               the three beats without repeating the detail. Three
               numbered steps lay out in a single column on mobile and
               a three-up row on `md:` so the numbers + dividers read
               as a sequence instead of three isolated icons. --%>
          <div
            class="rounded-2xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-6 md:p-8"
            id="onboarding-how-it-works"
          >
            <h2 class="text-base font-semibold tracking-tight text-zinc-900 dark:text-white">
              {gettext("How it works")}
            </h2>
            <p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
              {gettext("Three steps from sign-up to a live chart. Each step takes about a minute.")}
            </p>
            <ol class="mt-5 grid grid-cols-1 gap-4 md:grid-cols-3 md:gap-0">
              <li class="flex md:flex-col items-start gap-3 md:gap-0 md:pr-6">
                <span
                  class="shrink-0 inline-flex items-center justify-center size-7 rounded-full bg-emerald-50 dark:bg-emerald-950/40 text-emerald-700 dark:text-emerald-300 text-sm font-semibold"
                  aria-hidden="true"
                >
                  1
                </span>
                <div class="md:mt-3">
                  <p class="text-sm font-semibold text-zinc-900 dark:text-white">
                    {gettext("Register")}
                  </p>
                  <p class="mt-1 text-xs text-zinc-500 dark:text-zinc-400">
                    {gettext("Add your DTU on the Devices page.")}
                  </p>
                </div>
              </li>
              <li class="flex md:flex-col items-start gap-3 md:gap-0 md:px-6 md:border-x md:border-zinc-200 md:dark:border-zinc-800">
                <span
                  class="shrink-0 inline-flex items-center justify-center size-7 rounded-full bg-emerald-50 dark:bg-emerald-950/40 text-emerald-700 dark:text-emerald-300 text-sm font-semibold"
                  aria-hidden="true"
                >
                  2
                </span>
                <div class="md:mt-3">
                  <p class="text-sm font-semibold text-zinc-900 dark:text-white">
                    {gettext("Connect")}
                  </p>
                  <p class="mt-1 text-xs text-zinc-500 dark:text-zinc-400">
                    {gettext("Point your DTU at our broker with the credentials we show you.")}
                  </p>
                </div>
              </li>
              <li class="flex md:flex-col items-start gap-3 md:gap-0 md:pl-6">
                <span
                  class="shrink-0 inline-flex items-center justify-center size-7 rounded-full bg-emerald-50 dark:bg-emerald-950/40 text-emerald-700 dark:text-emerald-300 text-sm font-semibold"
                  aria-hidden="true"
                >
                  3
                </span>
                <div class="md:mt-3">
                  <p class="text-sm font-semibold text-zinc-900 dark:text-white">
                    {gettext("See live data")}
                  </p>
                  <p class="mt-1 text-xs text-zinc-500 dark:text-zinc-400">
                    {gettext("Watch watts appear on this chart as soon as the sun is up.")}
                  </p>
                </div>
              </li>
            </ol>
          </div>
        <% else %>
          <!-- Toolbar: Switcher & Time Ranges -->
          <div class="flex flex-col gap-4">
            <!-- DTU Switcher -->
            <.dtu_switcher devices={@devices} selected_dtu_id={@selected_dtu_id} />

            <!-- Time Range Tab Selector -->
            <!-- "Today" button + historical stepper share the same row so
                 the toolbar reads as one toolbar instead of two stacked
                 controls. The wrapping <div> uses `flex flex-wrap
                 items-center gap-4` so the two clusters stay side by
                 side on desktop and wrap below each other on narrow
                 viewports. -->
            <div class="flex flex-wrap items-center gap-4">
              <!-- Quick ranges: 1D (live, auto-refreshing) / 7D / 30D / YTD /
                   Custom (delegates to the historical stepper below). The
                   active preset is the one matching @range_preset; the
                   `1d` preset mirrors @live so legacy tests/clicks still
                   highlight the first button. -->
              <.quick_range_switcher range_preset={@range_preset} />

              <!-- Historical stepper: ‹ [Granularity ▾] [Date ▾] › — only rendered
                   when the user picked the `Custom` preset; the
                   1D/7D/30D/YTD presets already encode their own
                   window and don't need the stepper UI. -->
              <%= if @range_preset == "custom" do %>
                <.historical_stepper
                  granularity={@granularity}
                  selected_period={@selected_period}
                  selectable_dates={@selectable_dates}
                  selectable_days={@selectable_days}
                  selectable_weeks={@selectable_weeks}
                  selectable_months={@selectable_months}
                  selectable_years={@selectable_years}
                  live={@live}
                />
              <% end %>
            </div>
          </div>

          <!-- Stats Grid -->
          <%!--
            Headline stat-card row: visible only when the user has at
            least one inverter-kind DTU (`kind in [:opendtu, :ahoydtu]`).
            A Shelly-only user has no production telemetry, so this row
            would render three "0 W / 0.0 kWh / 00:00" placeholders that
            confuse rather than inform. The consumption row beneath
            still shows their household draw, and the consumption
            overlay on the chart still plots.

            The row is period-driven — yield, peak watts, peak time, and
            self-consumption % all recompute on every preset change so
            the headline reflects whatever window the user picked. Card
            labels stay period-stable ("Yield", "Peak Power", "Peak
            Time") so the row's identity doesn't shift as the user
            clicks through presets; the period context lives in the
            card sub-label below the headline number.

            Cards (always rendered):
              1. Yield (kWh)            — period total
              2. Peak Power (W)         — highest 5-min bucket in window
              3. Peak Time              — when the peak happened, local HH:MM

            Conditional cards (rendered when their predicate holds):
              4. Current Power (W)      — 1D-only, > 0 W
              5. Saved this period (€)  — rate configured, non-nil
              6. Self-consumption (%)   — Shelly paired, helper returned a number
              7. Current Consumption (W) — Shelly paired, > 0 W

            The grid's `lg:` column count is computed from the same
            predicates (see `cols` / `cols_class` below) so a user
            without, say, savings doesn't see a 6-up grid with two
            empty columns.
          --%>
          <%= if @has_inverter? do %>
            <.stat_card_row
              stats={@stats}
              consumption_stats={@consumption_stats}
              savings={@savings}
              cents_per_kwh={@cents_per_kwh}
              range_preset={@range_preset}
              time_range={@time_range}
              user_tz_offset_seconds={@user_tz_offset_seconds}
              locale={@locale}
              cloud_cover={@current_cloud_cover}
              cloud_cover_pct={@current_cloud_cover_pct}
              geolocation_state={@geolocation_state}
              user_has_geolocation={@user_has_geolocation}
            />
          <% end %>

          <%!-- Power consumption row: mirrors the production row's three
               cards (current / today / peak) but populated from a paired
               Shelly Plus 3EM (Gen3+) energy meter. Only rendered when the
               user actually has consumption data — a user without a
               Shelly device sees nothing here, exactly the same as a user
               without an inverter (the production row renders empty too).
               Rose color scheme matches the existing Current/Today's
               Consumption cards above for visual consistency. --%>
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

                <%= if @live do %>
                  <%!-- Today's total consumption (kWh) — mirrors
                       "Today's Total Yield" on the production side. Live
                       view only. --%>
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
                                id="stat-today-consumption-period"
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
                <% else %>
                  <%!-- Week/Month/Year: show todays consumption within
                       the period only if its been a partial period, else
                       mirror the production-side avg slot. --%>
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
                                id="stat-today-consumption-period-historical"
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
                <% end %>

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

          <%!-- Net flow row: only visible when the user has BOTH an inverter
               (production) and a Shelly (consumption). Net flow = production
               minus consumption — positive means exporting to the grid,
               negative means importing. Mirrors the layout of the
               production and consumption rows above.
               Without an inverter the headline "Net flow" is meaningless
               (there's nothing to net against), and `list_net_chart_data/4`
               would otherwise produce a misleadingly-negative curve equal
               to `-consumption`. --%>
          <%= if @has_inverter? and @has_shelly? and
                 (@net_flow_stats.current_net_flow != 0.0 or
                    @net_flow_stats.today_net_export > 0.0 or
                    @net_flow_stats.today_net_import > 0.0) do %>
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
          <% end %>

          <!-- Chart Panel -->
          <div class="bg-white dark:bg-zinc-800 shadow rounded-lg border border-zinc-200 dark:border-zinc-700 p-6">
            <h2 class="text-lg font-medium text-zinc-900 dark:text-white mb-4" id="chart-title">
              <%= cond do %>
                <% not @has_inverter? and @has_shelly? and @live -> %>
                  {gettext("Today's Consumption Curve (Watts)")}
                <% not @has_inverter? and @has_shelly? and @time_range == "day" -> %>
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

            <%= if @chart_type == :line do %>
              <%!-- The chart container always renders — even when
                   there's no production data for the day (e.g. at
                   night, on a freshly-created account, or before any
                   data has been logged) — so the cloud-cover band,
                   axes, gridlines, sun markers, and now marker stay
                   visible. The "No power readings" empty-state sits
                   on top as a centred overlay when path_data is
                   empty. --%>
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
                  data-x-min-seconds={@x_min_seconds}
                  data-x-max-seconds={@x_max_seconds}
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
                  <%= for {watts, y_pixel} <- @y_gridlines do %>
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
                  <%= for pct <- @cloud_cover_line.ticks do %>
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
                         of padding the SVG's viewBox reserves on the
                         right (x=815 sits in the -30..860 window).
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
                  <%= for {{x, label}, edge} <- Enum.with_index(@x_labels) do %>
                    <% anchor =
                      cond do
                        edge == 0 -> "start"
                        edge == length(@x_labels) - 1 -> "end"
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
                         entirely when `@cloud_cover_line.has_data ==
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
                  <%= if @cloud_cover_line.has_data do %>
                    <path
                      d={@cloud_cover_line.area_path}
                      fill="url(#cloud-area-gradient)"
                      stroke="none"
                      pointer-events="none"
                      aria-hidden="true"
                      data-testid="cloud-cover-area"
                      id="chart-cloud-cover-area"
                    />
                    <path
                      d={@cloud_cover_line.path}
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
                  <%= for {series, path} <- @yesterday_paths do %>
                    <% {ybase, yshade} = Map.get(@series_palette, series, {"zinc", "400"}) %>
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
                  <%= for {series, path} <- @series_paths do %>
                    <% {base, shade} = Map.get(@series_palette, series) %>
                    <% stroke_hex = ChartPalette.tooltip_to_hex(base, shade) %>
                    <% series_json =
                      Jason.encode!(%{
                        dtu_id: elem(series, 0),
                        serial: elem(series, 1),
                        mppt_index: elem(series, 2),
                        name: elem(series, 3)
                      }) %>
                    <% points_json = Jason.encode!(Map.get(@series_points_data, series, [])) %>
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
                  <%= if @total_path != "" do %>
                    <% total_json =
                      Jason.encode!(%{
                        is_total: true,
                        name: gettext("Total"),
                        serial: "",
                        mppt_index: -1
                      }) %>
                    <% total_points_json = Jason.encode!(@total_points_data) %>
                    <% {tbase, tshade} = @total_palette %>
                    <% total_stroke_hex = ChartPalette.tooltip_to_hex(tbase, tshade) %>
                    <path
                      d={@total_path}
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
                  <%= if @consumption_path != "" do %>
                    <% consumption_json =
                      Jason.encode!(%{
                        is_consumption: true,
                        name: gettext("Consumption"),
                        serial: "",
                        mppt_index: -2
                      }) %>
                    <% consumption_points_json = Jason.encode!(@consumption_points_data) %>
                    <% {cbase, cshade} = @consumption_palette %>
                    <% consumption_stroke_hex = ChartPalette.tooltip_to_hex(cbase, cshade) %>
                    <path
                      d={@consumption_path}
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
                  <%= if @net_path != "" and @has_inverter? and @has_shelly? do %>
                    <% net_json =
                      Jason.encode!(%{
                        is_net: true,
                        name: gettext("Net flow"),
                        serial: "",
                        mppt_index: -3
                      }) %>
                    <% net_points_json = Jason.encode!(@net_points_data) %>
                    <% {nbase, nshade} = @net_palette %>
                    <% net_stroke_hex = ChartPalette.tooltip_to_hex(nbase, nshade) %>
                    <path
                      d={@net_path}
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
                    <%= if @y_min >= 0.0 do %>
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
                  <%= case @sun_markers do %>
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
                  <%= case @sun_markers do %>
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

                  <%= if @now_marker_x do %>
                    <g id="now-marker" pointer-events="none">
                      <line
                        id="now-marker-line"
                        x1={@now_marker_x}
                        y1="24"
                        x2={@now_marker_x}
                        y2="250"
                        stroke="#6366f1"
                        class="dark:stroke-indigo-400"
                        stroke-width="1.5"
                        opacity="0.65"
                        pointer-events="none"
                      />
                      <rect
                        id="now-marker-pill"
                        x={@now_marker_x - 18}
                        y="6"
                        width="36"
                        height="14"
                        rx="3"
                        fill="#6366f1"
                        class="dark:fill-indigo-400"
                      />
                      <text
                        id="now-marker-text"
                        x={@now_marker_x}
                        y="16"
                        text-anchor="middle"
                        fill="white"
                        class="dark:fill-zinc-900"
                        font-size="10"
                        font-weight="600"
                        font-family="ui-sans-serif, system-ui, sans-serif"
                      >
                        {@now_marker_label || gettext("now")}
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
                <%= if map_size(@series_legend) > 0 or @total_path != "" or @consumption_path != "" or map_size(@yesterday_paths) > 0 do %>
                  <div
                    class="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1.5 text-xs"
                    id="chart-legend"
                  >
                    <%= if @total_path != "" do %>
                      <% {tbase, tshade} = @total_palette %>
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
                    <%= if @consumption_path != "" do %>
                      <% {cbase, cshade} = @consumption_palette %>
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
                    <%= if @net_path != "" and @has_inverter? and @has_shelly? do %>
                      <% {nbase, nshade} = @net_palette %>
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
                    <%= if map_size(@yesterday_paths) > 0 do %>
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
                    <%= for {series, label} <- @series_legend do %>
                      <% {base, shade} = Map.get(@series_palette, series) %>
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
                <%= if @path_data == "" do %>
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
            <% else %>
              <!-- Bar Chart -->
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
            <% end %>

            <%!-- Share panel: anonymous current-day dashboard share.
               Lives below the chart rather than in the toolbar so
               the URL row never has to compete for horizontal
               space with the quick-range / period stepper. The
               three states share the same outer chrome and only
               swap their inner row (toggle, spinner, or URL row)
               so the layout doesn't jump when the toggle flips.
               `aria-live="polite"` on the dynamic inner row
               announces state changes to screen readers without
               stealing focus. --%>
            <div
              id="share-panel"
              class="mt-4 border-t border-zinc-200 dark:border-zinc-700 pt-4"
            >
              <label
                id="share-toggle-label"
                for="share-toggle"
                class={[
                  "flex items-center gap-3 select-none",
                  unless(@share_loading?, do: "cursor-pointer", else: "cursor-wait opacity-70")
                ]}
                title={gettext("Share today's dashboard read-only")}
              >
                <.icon name="hero-share" class="size-5 text-zinc-500 dark:text-zinc-400" />
                <span class="text-sm font-semibold text-zinc-700 dark:text-zinc-200">
                  {gettext("Share today's dashboard read-only")}
                </span>
                <%!-- The visible switch: a checkbox styled as a pill
                   with a sliding dot. `peer-checked:` Tailwind
                   variants flip the on-colors without a separate
                   state class. The pill itself goes translucent
                   while a server call is in flight so it's
                   visually clear the click has been registered. --%>
                <span class="relative inline-flex items-center">
                  <input
                    type="checkbox"
                    id="share-toggle"
                    phx-click="toggle_share"
                    phx-value-enabled={to_string(!@share_active?)}
                    checked={@share_active?}
                    disabled={@share_loading?}
                    class="peer sr-only"
                  />
                  <span class="w-9 h-5 rounded-full bg-zinc-300 dark:bg-zinc-600 peer-checked:bg-emerald-500 peer-disabled:opacity-50 transition-colors"></span>
                  <span class="absolute left-0.5 top-0.5 size-4 rounded-full bg-white shadow transition-transform peer-checked:translate-x-4"></span>
                </span>
              </label>

              <div
                id="share-row"
                class="mt-3 min-h-[2.25rem] flex items-center"
                aria-live="polite"
              >
                <%= cond do %>
                  <% @share_loading? -> %>
                    <%!-- Inline spinner shown while the token is
                       being minted (see `toggle_share` +
                       `handle_info({:share_link_minted, _, _}, _)`).
                       A pure-CSS border-spinner so it doesn't
                       depend on any icon glyph being available. --%>
                    <div
                      id="share-loading-row"
                      class="flex items-center gap-2 text-sm text-zinc-500 dark:text-zinc-400"
                      data-testid="share-loading"
                    >
                      <span
                        class="inline-block size-4 rounded-full border-2 border-emerald-500 border-t-transparent animate-spin"
                        aria-hidden="true"
                      ></span>
                      <span>{gettext("Generating link…")}</span>
                    </div>
                  <% @share_active? and @share_url -> %>
                    <div
                      id="share-url-row"
                      class="flex items-center gap-2 w-full"
                    >
                      <input
                        type="text"
                        id="share-url-input"
                        readonly
                        value={@share_url}
                        class="flex-1 min-w-0 px-3 py-2 text-sm font-mono rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-800 text-zinc-800 dark:text-zinc-100 focus:outline-none focus:ring-1 focus:ring-emerald-500"
                        data-value={@share_url}
                        phx-hook=".SelectOnFocus"
                        aria-label={gettext("Shareable URL")}
                        data-testid="share-url-input"
                      />
                      <button
                        type="button"
                        id="btn-share-copy"
                        title={gettext("Copy URL")}
                        aria-label={gettext("Copy URL")}
                        class="shrink-0 p-2 rounded-lg text-zinc-600 hover:text-zinc-900 dark:text-zinc-300 dark:hover:text-white hover:bg-zinc-200/50 dark:hover:bg-zinc-700/50 transition"
                        data-value={@share_url}
                        phx-hook=".CopyToClipboardWithHint"
                        data-testid="btn-share-copy"
                      >
                        <.icon name="hero-clipboard-document" class="size-5" />
                      </button>
                      <span
                        id="share-copy-hint"
                        class="text-sm font-semibold text-emerald-600 dark:text-emerald-400 opacity-0 transition-opacity"
                        aria-live="polite"
                        data-testid="share-copy-hint"
                      >
                        {gettext("Copied!")}
                      </span>
                    </div>
                  <% true -> %>
                    <p
                      id="share-hint-text"
                      class="text-xs text-zinc-500 dark:text-zinc-400"
                    >
                      {gettext(
                        "Anyone with this link can view today's dashboard. The link stays valid until you turn sharing off."
                      )}
                    </p>
                <% end %>
              </div>
            </div>
          </div>

          <!-- Devices / Inverters status -->
          <div class="bg-white dark:bg-zinc-800 shadow rounded-lg border border-zinc-200 dark:border-zinc-700 p-6">
            <h2 class="text-lg font-medium text-zinc-900 dark:text-white mb-4">
              {gettext("Device Connection Status")}
            </h2>

            <div class="grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3" id="device-status-grid">
              <%= for device <- @devices do %>
                <%!-- Three-state pill: `online + producing` (green dot,
                     AC readings with ac_power > 0 in the last 2 min),
                     `online + nighttime` (amber moon, MQTT alive but
                     no AC readings in the 5-min online window — the
                     inverter has stopped emitting power data, e.g.
                     after sunset for firmware that suppresses
                     telemetry at night), or `offline` (zinc, no MQTT
                     activity in 5 min). The MQTT-liveness signal
                     (`last_seen_at`) drives online/offline so a DTU
                     whose inverter goes quiet at night no longer
                     flips to "offline" while the broker is still
                     forwarding status frames.
                     `producing_power?/2` is still the source for the
                     current-power card's hide/show logic
                     (dashboard_data/4). --%>
                <% online? = DtuApp.Devices.Dtu.online?(device) %>
                <% nighttime? = DtuApp.Devices.Dtu.nighttime?(device) %>
                <% error_count = Map.get(@error_counts, device.id, 0) %>
                <div class="relative">
                  <.link
                    navigate={~p"/devices?expand=#{device.id}"}
                    aria-label={
                      if(error_count > 0,
                        do:
                          gettext("%{count} errors, view details",
                            count: error_count
                          ),
                        else: gettext("Manage device")
                      )
                    }
                    class={[
                      "block border rounded-lg p-5 h-full flex flex-col justify-between transition hover:shadow-md focus:outline-none focus:ring-2 focus:ring-emerald-500",
                      if(error_count > 0,
                        do: "border-rose-300 dark:border-rose-700",
                        else: "border-zinc-200 dark:border-zinc-700"
                      )
                    ]}
                    id={"device-card-#{device.id}"}
                  >
                    <div>
                      <div class="flex items-center justify-between gap-2">
                        <div class="flex items-center gap-2 min-w-0">
                          <h3 class="text-md font-semibold text-zinc-900 dark:text-white truncate">
                            {device.name}
                          </h3>
                          <%!-- Sink badge: identifies a `mqtt_ro_sink` device so
                               the user understands this card represents a passive
                               subscriber — it never publishes, so it never
                               contributes to the production / consumption / net
                               rows above. Rendered alongside the device name (not
                               next to the online/offline pill) so the two roles
                               read independently. The violet palette matches
                               nothing else on the dashboard — sinks are their own
                               kind, neither inverter nor consumption meter. --%>
                          <%= if DtuKinds.ro_sink_kind?(device) do %>
                            <span
                              class="inline-flex shrink-0 items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-semibold bg-violet-100 text-violet-800 dark:bg-violet-900/30 dark:text-violet-300"
                              id={"dtu-sink-badge-#{device.id}"}
                              title={
                                gettext(
                                  "Read-only MQTT sink — receives a real-time feed of this account's other devices"
                                )
                              }
                            >
                              <.icon name="hero-arrow-down-on-square-stack" class="size-3" />
                              {gettext("sink")}
                            </span>
                          <% end %>
                        </div>
                        <span
                          class={[
                            "inline-flex shrink-0 items-center px-2 py-0.5 rounded text-xs font-medium",
                            cond do
                              online? and not nighttime? ->
                                "bg-emerald-100 text-emerald-800 dark:bg-emerald-900/30 dark:text-emerald-400"

                              online? ->
                                "bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-300"

                              true ->
                                "bg-zinc-100 text-zinc-800 dark:bg-zinc-800 dark:text-zinc-400"
                            end
                          ]}
                          title={
                            cond do
                              online? and not nighttime? ->
                                gettext(
                                  "Online — this DTU has reported AC power within the last 2 minutes"
                                )

                              online? ->
                                gettext(
                                  "Nighttime — MQTT is alive but no AC power reading has arrived. The inverter has stopped emitting telemetry, e.g. after sunset."
                                )

                              true ->
                                gettext("Offline — no MQTT activity in the last 5 minutes")
                            end
                          }
                        >
                          {cond do
                            online? and not nighttime? -> gettext("online")
                            online? -> gettext("nighttime")
                            true -> gettext("offline")
                          end}
                        </span>
                      </div>
                      <div class="mt-2 space-y-1 text-sm text-zinc-550 dark:text-zinc-400">
                        <p>
                          <span class="font-medium text-zinc-700 dark:text-zinc-300">{gettext(
                            "Last seen:"
                          )}</span>
                          <span title={
                            case device.last_seen_at do
                              nil -> nil
                              dt -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
                            end
                          }>{case device.last_seen_at do
                            nil -> gettext("never")
                            dt -> relative_time_label(dt)
                          end}</span>
                        </p>
                      </div>
                    </div>
                  </.link>
                  <%!-- Error badge: a small red circle pinned to the card's
                       top-right corner. Shows the *distinct* error-message
                       count so a Shelly spamming the same `unknown_topic`
                       50× in a minute shows "1" rather than "50". The
                       link is the entire card — clicking anywhere on the
                       card surfaces the deep-link to /devices?expand=<id>.
                       Hidden when the device has zero errors. --%>
                  <%= if error_count > 0 do %>
                    <span
                      class={[
                        "absolute -top-2 -right-2 inline-flex items-center justify-center size-7 rounded-full bg-rose-500 text-white text-xs font-semibold shadow-md ring-2 ring-white dark:ring-zinc-800 pointer-events-none",
                        if(error_count > 99, do: "size-8 text-[10px]")
                      ]}
                      id={"dtu-error-edge-badge-#{device.id}"}
                      aria-label={gettext("%{count} distinct errors", count: error_count)}
                      title={
                        gettext(
                          "%{count} distinct error message — click to view",
                          count: error_count
                        )
                      }
                    >
                      {if error_count > 99, do: "99+", else: error_count}
                    </span>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- Colocated JS hook for the share-cluster copy button. The
           dashboard uses `CopyToClipboard` for the URL input (a small
           green flash on the icon is enough context) and
           `CopyToClipboardWithHint` for the dedicated copy button —
           the latter reveals a "Copied!" label next to the button for
           1.5 s so the affordance is visible without having to hover
           the icon. We don't extend the existing `CopyToClipboard`
           hook because the device-settings page intentionally keeps
           its own quieter visual feedback, and merging the two would
           force every other call-site to carry the label element. --%>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToClipboardWithHint">
        export default {
          mounted() {
            this.hint = document.getElementById("share-copy-hint")

            this.handler = (event) => {
              event.preventDefault()
              const text = this.el.dataset.value || ""

              // Show "Copied!" feedback *immediately* on click — the
              // user needs to know the click registered, even if the
              // clipboard write below takes a beat (or hangs, in
              // some headless / iframe / permission-denied setups).
              // If the write later turns out to have failed, we
              // downgrade the visual feedback to "Copy failed" so
              // the optimistic state doesn't lie to the user.
              this.showFeedback(true)

              // `navigator.clipboard.writeText` is only available in
              // secure contexts (HTTPS, or `localhost` on most
              // browsers). On plain-HTTP LAN IPs (e.g. staging on a
              // Raspberry Pi) it returns `undefined` — and even when
              // defined, it can throw on browsers that prompt for
              // permission and the user clicks "Block". Fall back to
              // the legacy `document.execCommand("copy")` path via a
              // temporary textarea so the copy still works in those
              // environments. The legacy path is deprecated but still
              // works on every browser we care about.
              const write = async () => {
                if (
                  typeof navigator !== "undefined" &&
                  navigator.clipboard &&
                  typeof navigator.clipboard.writeText === "function"
                ) {
                  try {
                    await navigator.clipboard.writeText(text)
                    return true
                  } catch (_err) {
                    // Fall through to the textarea path.
                  }
                }

                try {
                  const ta = document.createElement("textarea")
                  ta.value = text
                  ta.setAttribute("readonly", "")
                  ta.style.position = "fixed"
                  ta.style.top = "0"
                  ta.style.left = "0"
                  ta.style.opacity = "0"
                  document.body.appendChild(ta)
                  ta.focus()
                  ta.select()
                  const ok = document.execCommand && document.execCommand("copy")
                  document.body.removeChild(ta)
                  return !!ok
                } catch (_err) {
                  return false
                }
              }

              write().then((ok) => {
                if (!ok) {
                  console.error(
                    "CopyToClipboardWithHint hook: copy failed (both clipboard API and execCommand fallback returned false)"
                  )
                  // Downgrade the optimistic "Copied!" to "Copy
                  // failed" — same timer, just an amber tint so the
                  // user notices something went wrong.
                  if (this.hint) {
                    this.hint.textContent = "Copy failed"
                    this.hint.classList.add(
                      "text-amber-600",
                      "dark:text-amber-400"
                    )
                    this.hint.classList.remove(
                      "text-emerald-600",
                      "dark:text-emerald-400"
                    )
                  }
                }
              })
            }

            this.showFeedback = (success) => {
              if (this.hint) {
                this.hint.textContent = success ? "Copied!" : "Copy failed"
                this.hint.classList.add("opacity-100")
                this.hint.classList.remove("opacity-0")
                if (!success) {
                  this.hint.classList.add("text-amber-600", "dark:text-amber-400")
                  this.hint.classList.remove("text-emerald-600", "dark:text-emerald-400")
                }
              }

              this.el.classList.add("copied")
              const svg = this.el.querySelector("svg")

              if (svg) {
                svg.dataset.originalClass = svg.getAttribute("class") || ""
                svg.setAttribute(
                  "class",
                  success
                    ? "size-5 text-emerald-500"
                    : "size-5 text-amber-500"
                )
              }

              clearTimeout(this._resetTimer)
              this._resetTimer = setTimeout(() => {
                if (this.hint) {
                  this.hint.classList.add("opacity-0")
                  this.hint.classList.remove("opacity-100")
                  this.hint.classList.remove(
                    "text-amber-600",
                    "dark:text-amber-400"
                  )
                  this.hint.classList.add(
                    "text-emerald-600",
                    "dark:text-emerald-400"
                  )
                  this.hint.textContent = "Copied!"
                }

                this.el.classList.remove("copied")

                if (svg) {
                  svg.setAttribute("class", svg.dataset.originalClass || "")
                }
              }, 1500)
            }

            this.el.addEventListener("click", this.handler)
          },

          destroyed() {
            if (this.el && this.handler) {
              this.el.removeEventListener("click", this.handler)
            }

            clearTimeout(this._resetTimer)
          }
        }
      </script>

      <%!-- SelectOnFocus: selects the full URL on the first user
           gesture so Cmd-C / Ctrl-C copies it without an extra
           triple-click. We listen on three events:

             * `focus`    — desktop keyboard navigation (Tab into the
                            field)
             * `click`    — desktop mouse click into the field
             * `pointerdown` — mobile / touch tap (where the browser
                            may or may not fire `focus` reliably; some
                            WebKit builds don't focus on tap without
                            `touch-action: manipulation`)

           We deliberately don't use the inline `onfocus="this.select()"`
           attribute — it works on desktop clicks but tap-into-input on
           iOS Safari doesn't fire `focus` for readonly inputs in some
           builds, so the URL stays unselected. The hook guarantees the
           selection on every gesture.

           The select() call is deferred via `setTimeout(..., 0)`
           — a macrotask — so it runs AFTER both the click event
           listeners AND the browser's default-action cursor
           placement for the click. (Microtasks drain BEFORE the
           click default action in some Chrome builds, which lets
           the cursor land at the click position; a macrotask
           always fires after both, so our selection wins.) --%>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".SelectOnFocus">
        export default {
          mounted() {
            this.select = () => {
              // `setTimeout(..., 0)` schedules a macrotask —
              // these always run AFTER microtasks drain AND after
              // the browser's default-action cursor placement.
              // That's what we need to win over the click's
              // default.
              setTimeout(() => {
                if (typeof this.el.select === "function") {
                  this.el.focus({ preventScroll: true })
                  this.el.select()
                  if (typeof this.el.setSelectionRange === "function") {
                    try {
                      this.el.setSelectionRange(0, this.el.value.length)
                    } catch (_err) {
                      // Some input types (e.g. email) reject setSelectionRange.
                      // `select()` already covered the common case.
                    }
                  }
                }
              }, 0)
            }

            this.el.addEventListener("focus", this.select)
            this.el.addEventListener("click", this.select)
            this.el.addEventListener("pointerdown", this.select)
          },

          destroyed() {
            if (!this.el || !this.select) return
            this.el.removeEventListener("focus", this.select)
            this.el.removeEventListener("click", this.select)
            this.el.removeEventListener("pointerdown", this.select)
          }
        }
      </script>

      <%!--
        AutoFetchLocation: silently resolves an already-granted
        browser geolocation permission on mount. Used by the
        invisible `#auto-fetch-location` div so the dashboard picks
        up coords that the browser holds but our DB doesn't yet
        (typical after a user re-grants permission via site
        settings or moves the prompt away from the in-app button).

        The Permissions API is not supported in every browser —
        when `navigator.permissions.query` is missing we fall
        through and do nothing. Without `query` we cannot
        distinguish "prompt" from "granted" without actually
        triggering the browser prompt, which would violate the
        product's "no auto-prompt on mount" rule.
      --%>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".AutoFetchLocation">
        export default {
          mounted() {
            // Old browsers / insecure contexts: bail. The
            // `.RequestLocation` button still works for these
            // because it calls `getCurrentPosition` directly.
            if (
              !navigator.permissions ||
              !navigator.geolocation ||
              typeof navigator.permissions.query !== "function"
            ) {
              return;
            }

            navigator.permissions
              .query({ name: "geolocation" })
              .then((result) => {
                // "granted" → user already gave permission; calling
                // `getCurrentPosition` now shows NO prompt, just a
                // silent position read. Push coords back to the
                // server so the cloud-cover card flips from
                // `:not_asked` (button) to `:granted` (data card).
                //
                // "prompt" → first-visit users, no permission yet.
                // Do nothing; the in-app "Share location" button
                // is the only path they get to grant.
                //
                // "denied" → user has explicitly refused. The
                // server already drives the slot to `:denied`
                // based on the persisted DB coords, but the browser
                // state could differ (e.g. just-removed block).
                // Doing nothing here lets the user recover via the
                // site-settings path without us re-asking.
                if (result.state !== "granted") return;

                this.pushEvent("location_loading", {});

                navigator.geolocation.getCurrentPosition(
                  (pos) => {
                    this.pushEvent("set_location", {
                      latitude: pos.coords.latitude,
                      longitude: pos.coords.longitude
                    });
                  },
                  () => {
                    // A granted permission can still fail to
                    // resolve a fix (POSITION_UNAVAILABLE / TIMEOUT).
                    // Treat as a denial from the slot's POV — the
                    // `:denied` state hides the card, and on next
                    // mount the button comes back.
                    this.pushEvent("location_denied", {});
                  },
                  { timeout: 10_000, maximumAge: 0 }
                );
              })
              .catch(() => {
                // Permissions API can throw (e.g. Firefox without
                // `permissions.query` polyfill, or a user-gesture
                // gate on some browsers). Swallow — the user can
                // still grant via the button.
              });
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
