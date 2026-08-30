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
  alias DtuAppWeb.DashboardLive.ChartHelpers
  alias DtuAppWeb.DashboardLive.ChartPalette
  alias DtuAppWeb.DashboardLive.Components
  alias DtuAppWeb.DashboardLive.PeriodSelectable
  alias DtuAppWeb.DashboardLive.TimeHelpers

  # Dashboard-specific function components (`<.dtu_switcher>`,
  # `<.quick_range_switcher>`, `<.historical_stepper>`,
  # `<.stat_card_row>`). Imported as bare names so the render
  # template stays close to plain HEEx.
  import Components

  require Logger

  @timezone_topic "dtu:timezone"

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

    # True when this user has at least one row in `push_subscriptions`
    # — i.e. the `PushSubscribe` hook has already POSTed a
    # `PushSubscription` JSON to the server. Drives a small "Native
    # push is on" indicator on the page; we read it server-side at
    # mount rather than waiting for the JS hook to round-trip so the
    # badge appears immediately on page load (the hook still fires
    # `push_subscribed` afterwards, which is what the in-page badge
    # listens for in turn).
    has_push_subscriptions = PushSubscriptions.list_for_user(user) != []

    socket =
      socket
      |> refresh_devices(user)
      |> assign(:selected_dtu_id, nil)
      # `live` is true for the auto-refreshing Today view.
      # `granularity` drives the historical stepper (day/week/month/year).
      |> assign(:live, true)
      |> assign(:granularity, "day")
      |> assign(:time_range, "today")
      # Top-level preset chosen in the toolbar: 1D (today, live) / 7D / 30D /
      # YTD / custom (delegates to the historical stepper). Defaults to 1D
      # so a fresh mount lands on the auto-refreshing view.
      |> assign(:range_preset, "1d")
      |> assign(:selected_period, nil)
      |> assign(:has_push_subscriptions, has_push_subscriptions)
      # Default to UTC (offset 0). The client-side `.SetTimezone`
      # colocated hook pushes the real offset once the WebSocket is
      # connected, and `handle_info({:set_timezone, ...})` updates this
      # assign + re-renders.
      |> assign(:user_tz_offset_seconds, 0)
      # Locale for stat-card / chart-axis number formatting. Picked up by
      # `Devices.format_number/2` and `Devices.format_savings/1` so a
      # German user sees `1.234,5 kWh` and a French user sees
      # `1 234,5 kWh` instead of the locale-agnostic `1234.5 kWh`. Captured
      # once at mount; the user's locale doesn't change mid-session, so
      # the assign is read-only after this point.
      |> assign(:locale, Gettext.get_locale(DtuAppWeb.Gettext))
      # Energy rate for the "Saved today" card. The user sets this on
      # `/users/settings`; if it's nil the savings card is hidden. Read
      # from the user schema here so the LiveView re-render on every
      # reading picks up the same value without a re-read.
      |> assign(:cents_per_kwh, user.cents_per_kwh)
      # Anonymous share toggle for the current-day dashboard. The
      # plaintext URL token is never persisted, so a returning user
      # (page reload while sharing is on) would otherwise land on a
      # confusing "toggle on, no URL" state — the toggle is checked,
      # but the input below is empty and the only hint is the
      # generic "anyone with this link" copy.
      #
      # Pass `mint: true` so `assign_share_state/3` schedules the
      # same mint flow `toggle_share` uses; ~200ms after mount the
      # spinner resolves into the URL input + copy button. This
      # silently invalidates the prior row, which matches the
      # toggle-on behavior the user already accepts (the same flow
      # runs when they re-enable sharing).
      |> assign_share_state(user, mint: true)
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
      |> assign_dashboard_data(user, nil, "today", nil)

    {:ok, socket}
  end

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

  @impl true
  def handle_event("select_dtu", %{"id" => id_str}, socket) do
    selected_id = if id_str == "total", do: nil, else: String.to_integer(id_str)
    user = socket.assigns.current_scope.user

    socket = PeriodSelectable.assign_selectable_periods(socket, user, selected_id)

    socket =
      socket
      |> assign(:selected_dtu_id, selected_id)
      |> reapply_current_view(user, selected_id)

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
          |> assign_dashboard_data(user, dtu_id, "today", nil)

        "7d" ->
          socket
          |> assign(:range_preset, "7d")
          |> assign(:live, false)
          |> assign(:time_range, "7d")
          |> assign(:selected_period, nil)
          |> assign_dashboard_data(user, dtu_id, "7d", nil)

        "30d" ->
          socket
          |> assign(:range_preset, "30d")
          |> assign(:live, false)
          |> assign(:time_range, "30d")
          |> assign(:selected_period, nil)
          |> assign_dashboard_data(user, dtu_id, "30d", nil)

        "ytd" ->
          socket
          |> assign(:range_preset, "ytd")
          |> assign(:live, false)
          |> assign(:time_range, "ytd")
          |> assign(:selected_period, nil)
          |> assign_dashboard_data(user, dtu_id, "ytd", nil)

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
          |> assign_dashboard_data(user, dtu_id, granularity, period)
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
     |> assign_dashboard_data(user, dtu_id, granularity, period)}
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
     |> assign_dashboard_data(user, dtu_id, granularity, period)}
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
         |> assign_dashboard_data(user, dtu_id, granularity, period)}

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

  defp do_apply_share_link_result(socket, {:ok, {plaintext, _link}}) do
    {:noreply,
     socket
     |> assign(:share_active?, true)
     |> assign(:share_url, url_for_token(plaintext))
     |> assign(:share_loading?, false)}
  end

  defp do_apply_share_link_result(socket, {:error, reason}) do
    user = socket.assigns.current_scope.user

    Logger.warning(
      "[dashboard] create_shared_link failed user=#{user.id} reason=#{inspect(reason)}"
    )

    {:noreply,
     socket
     |> assign(:share_loading?, false)
     |> assign(:share_active?, false)
     |> assign(:share_url, nil)}
  end

  # Build the public share URL from a plaintext token. Uses the configured
  # PHX_HOST so the link points at the right deployment (dev / staging /
  # production) without a hard-coded hostname.
  defp url_for_token(token) do
    DtuAppWeb.Endpoint.url() <> "/s/" <> token
  end

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
      do_apply_share_link_result(socket, Accounts.create_shared_link(user))
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
    user = socket.assigns.current_scope.user
    selected_id = socket.assigns.selected_dtu_id

    socket = PeriodSelectable.assign_selectable_periods(socket, user, selected_id)

    # Every reading also touches the DTU's `last_seen_at` (see
    # `DtuApp.MqttBroker.Telemetry`), so re-read the device list here
    # to refresh the derived online badge — without this refresh the
    # badge would only update on a CONNECT / DISCONNECT, which means
    # a DTU that wakes up but stays MQTT-connected wouldn't flip from
    # offline to online until the next reconnect.
    socket =
      socket
      |> refresh_devices(user)
      |> maybe_reassign_dashboard_data(user, selected_id)

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
  @impl true
  def handle_info({:dtu_seen, _device_id}, socket) do
    user = socket.assigns.current_scope.user
    {:noreply, refresh_devices(socket, user)}
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

    {:noreply,
     socket
     |> assign(:user_tz_offset_seconds, offset_seconds)
     |> assign_dashboard_data(
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

    _ = DtuApp.Accounts.update_user_location(user, %{latitude: lat, longitude: lon})

    {:noreply,
     assign_dashboard_data(
       socket,
       user,
       socket.assigns.selected_dtu_id,
       socket.assigns.time_range,
       socket.assigns.selected_period
     )}
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

    socket
    |> assign(:devices, devices)
    |> assign(:has_inverter?, Enum.any?(devices, &inverter_kind?/1))
    |> assign(:has_shelly?, Enum.any?(devices, &shelly_kind?/1))
    |> assign(:has_ro_sink?, Enum.any?(devices, &ro_sink_kind?/1))
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

  # Inverter kinds: DTUs that report `ac_power` / `yield_day` and
  # contribute to the production stats and chart. Currently
  # OpenDTU and AhoyDTU.
  defp inverter_kind?(%Devices.Dtu{kind: kind}), do: kind in [:opendtu, :ahoydtu]
  defp inverter_kind?(_), do: false

  # Shelly kinds: DTUs that publish `consumption_power` from a
  # paired energy meter. Currently only the Plus 3EM Gen3+.
  defp shelly_kind?(%Devices.Dtu{kind: :shelly3em}), do: true
  defp shelly_kind?(_), do: false

  # Read-only MQTT sink: a passive subscriber that wants a real-time
  # feed of every other DTU's telemetry on the same account, but is
  # **never** allowed to PUBLISH. Sinks are not inverters and not
  # consumption meters — they show as a presence-only device card
  # with a "sink" badge so the user understands why this entry doesn't
  # contribute to the production/consumption/net rows above. The
  # broker enforces the publish-suppression contract
  # (`DtuApp.MqttBroker.Broker.handle_publish/4`); this predicate is
  # purely about the dashboard's presentation.
  defp ro_sink_kind?(%Devices.Dtu{kind: :mqtt_ro_sink}), do: true
  defp ro_sink_kind?(_), do: false

  # Read the user's existing share row (if any) and surface three
  # socket assigns:
  #   * `:share_active?` — toggle's on/off state (persisted row exists?)
  #   * `:share_url`     — the plaintext URL the UI displays (only set
  #     after a fresh `create_shared_link/1` call within this session)
  #   * `:share_loading?` — true while a token mint is in flight, so the
  #     toolbar can show a spinner instead of a stale (or empty) URL row.
  #
  # Options:
  #   * `:mint` (default `false`) — when the share row already exists,
  #     schedule the same delayed-mint flow `toggle_share` uses, so a
  #     returning user (page reload while sharing is on) lands on a
  #     populated URL field instead of the "toggle on, no URL" state.
  #     The mint invalidates the prior row (same behavior as toggling
  #     sharing off-and-on), and the 200ms loading-spinner render keeps
  #     the UI honest about the in-flight work.
  defp assign_share_state(socket, user, opts) do
    active? = Accounts.get_shared_link(user) != nil

    socket =
      socket
      |> assign(:share_active?, active?)
      |> assign(:share_url, nil)
      |> assign(:share_loading?, false)

    if active? and Keyword.get(opts, :mint, false) do
      Process.send_after(self(), {:mint_shared_link, user.id}, @share_load_delay_ms)
      assign(socket, :share_loading?, true)
    else
      socket
    end
  end

  # Helper to construct SVG line chart coordinates and range.
  # `local_date` is the user-facing date in the browser's timezone
  # (already converted from `selected_period` or `local_today/1`).
  # `tz_offset_seconds` shifts bucket times and labels so they read in
  # local time.
  defp assign_line_chart_data(
         socket,
         user,
         local_date,
         tz_offset_seconds,
         dtu_id,
         opts \\ []
       ) do
    # `:live?` flips on the yesterday-ghost overlay. Only the 1D (today)
    # preset shows it — historical day/week/month/year views keep the
    # chart scoped to their selected period. The historical-day caller
    # still gets a clean chart without a confusing ghost line.
    live? = Keyword.get(opts, :live?, socket.assigns[:live] == true)

    {utc_start, utc_end} = Devices.local_day_utc_range(local_date, tz_offset_seconds)
    # Read from the `readings_5m` continuous aggregate (older buckets)
    # unioned with a 5-minute live tail from raw rows; collapses the
    # per-row scan that `list_day_chart_data/4` did on every refresh.
    # See `DtuApp.Devices.list_day_chart_data_for_dashboard/4`.
    #
    # The dashboard thread pre-fetches the chart points once at the
    # top of `assign_dashboard_data/5`'s `:today` branch (where
    # `get_daily_stats/4` ALSO needs `bucket_max`). Re-using that
    # result here collapses two identical day-chart queries into one
    # on the noon mount path. Older callers (anything still passing
    # 5 args, including historical day/week/month branches and tests
    # via `select_quick_range`) fall through to the old fetch path.
    all_chart_points =
      case Keyword.get(opts, :chart_points) do
        nil -> Devices.list_day_chart_data_for_dashboard(user, utc_start, utc_end, dtu_id)
        pts -> pts
      end

    # The dashboard exposes one line per *inverter* (its AC aggregate,
    # mppt_index = 0). Per-MPPT DC rows are intentionally collapsed so
    # the chart stays readable when a fleet mixes single- and multi-
    # MPPT inverters; users can drill into a specific DTU on the
    # /devices page if they need MPPT-level detail.
    #
    # `inverter_serial != "_fleet"` is the matching defensive filter
    # against any legacy fleet-total rows an older parser version
    # persisted before the parser drop (see the matching comment in
    # `Devices.get_daily_stats/3`). The new parser no longer creates
    # these rows, but installs upgrading from a previous version still
    # have historical `_fleet` rows on disk — letting them through
    # would (a) render a phantom "Total" line in the legend and (b)
    # inflate the `show_total?` count, lighting up the headline Total
    # curve on single-inverter installs. Same defensive filter lives
    # at the data layer in `get_daily_stats/3` and `Devices.list_*` for
    # the same reason.
    chart_points =
      all_chart_points
      |> Enum.filter(fn pt ->
        pt.series |> elem(2) == 0 and pt.series |> elem(1) != "_fleet"
      end)
      # `readings_5m.avg_ac_power` is NULL for buckets whose only rows
      # had `ac_power: nil` (e.g. an AhoyDTU yield-only buffer flush
      # before the AC reading arrived — the same root cause as the
      # `bucket_max_from_chart_points/1` fix in PR #131). The aggregate
      # path exposes that NULL as a chart-point with `power: nil`.
      # Coalesce to `0.0` here, once, so every downstream consumer
      # (`Enum.max` over powers, `Enum.sum` per bucket, the per-point
      # `y = zero_y - power * pixels_per_watt_positive` calc) sees
      # numeric values only. Without the coalesce, `Float.ceil(nil, 0)`
      # at the `max_power` step raises `FunctionClauseError` and
      # `nil * pixels_per_watt_positive` at the per-point step raises
      # `ArithmeticError` — both crash the dashboard mount with a 500.
      |> Enum.map(fn pt -> %{pt | power: pt.power || 0.0} end)

    # Pull the consumption series upfront so `y_max` below can include
    # its peak — otherwise a heavy-load evening (Shelly reporting e.g.
    # 1500 W draw on a 600 W solar day) would clip the consumption line
    # off-screen above the chart.
    consumption_chart_points =
      Devices.list_today_consumption_chart_data(user, dtu_id)

    # Net-flow chart points (production minus consumption, sign-flipped
    # in the path below) — fetched up front so we can size the Y-axis
    # negative bound before computing the production/consumption paths.
    # Without this we'd render export peaks below the chart's bottom
    # edge, exactly the bug this fix targets.
    {net_utc_start, net_utc_end} = Devices.local_day_utc_range(local_date, tz_offset_seconds)
    net_chart_points = Devices.list_net_chart_data(user, net_utc_start, net_utc_end, dtu_id)

    max_power =
      chart_points
      |> Enum.map(& &1.power)
      |> Enum.max(fn -> 100.0 end)
      |> max(100.0)
      |> Float.ceil()

    # Fleet Total is the sum of every series at each bucket, which is
    # larger than any individual series power when more than one
    # inverter/MPPT is producing. The y-axis must cover the Total line
    # peak or it renders off-screen.
    total_max_power =
      chart_points
      |> Enum.group_by(& &1.time)
      |> Enum.map(fn {_time, pts} -> Enum.sum(Enum.map(pts, & &1.power)) end)
      |> Enum.max(fn -> 0.0 end)

    # Consumption peak — the highest bucket-mean household draw on
    # today/day. We compare against (max per-series production,
    # max Total production) so the Y-axis covers whatever's largest on
    # the chart. Without this, the consumption path renders off-screen
    # above the chart whenever the household draw exceeds solar peak
    # (common in winter / evenings).
    consumption_max_power =
      consumption_chart_points
      |> Enum.map(& &1.power)
      |> Enum.max(fn -> 0.0 end)

    # Scale max power to next multiple of 100, taking the larger of
    # the per-series peak, the Total peak, and the consumption peak so
    # the headline curve stays inside the chart area.
    y_max =
      [max_power, total_max_power, consumption_max_power]
      |> Enum.max()
      |> Float.ceil()
      |> Kernel./(100)
      |> Float.ceil()
      |> Kernel.*(100)
      |> max(100.0)

    # Negative Y-axis bound: the chart's lower edge should extend down
    # to the most-negative net-flow display value (i.e. -max_export),
    # rounded DOWN to the next multiple of 100 so the export peak
    # never sits flush against the chart's bottom edge. Without this
    # guard a 432 W export peak would clip to ~432 W below the zero
    # line on a chart whose lower bound is implicitly 0.
    #
    # `display_power` here is the *sign-flipped* net value (positive
    # for import, negative for export) — the same convention the path
    # uses below — so the most-negative display_power equals
    # -max_export. We only extend the axis when the user actually has
    # net data and a non-zero export peak; without that, the chart
    # stays positive-only (the previous behaviour).
    #
    # DTU-only users (no Shelly paired) have nothing to net against, so
    # the chart must NEVER extend below zero — there's no export peak to
    # show in the lower half and a negative axis would be visually
    # wrong (negative gridline labels on a production-only curve).
    # `list_net_chart_data/4` already returns [] for DTU-only users
    # (the bucket-drop guard requires a consumption row), but we clamp
    # at the chart layer too as defense-in-depth against any future
    # code path that might seed a net row without a paired Shelly.
    y_min =
      cond do
        not socket.assigns[:has_shelly?] ->
          0.0

        true ->
          case net_chart_points do
            [] ->
              0.0

            pts ->
              most_negative_display =
                pts
                |> Enum.map(fn p -> -p.power end)
                |> Enum.min(fn -> 0.0 end)

              # Round DOWN to the next lower 100. A -432 W peak → -500 W
              # (next lower multiple of 100). A -50 W peak → -100 W so
              # even small export dips stay inside the chart area.
              if most_negative_display < 0.0 do
                most_negative_display
                |> Float.floor()
                |> Kernel./(100)
                |> Float.floor()
                |> Kernel.*(100)
              else
                0.0
              end
          end
      end

    # Net path's Y mapping depends on the unified [y_min, y_max] range.
    # When y_min < 0 (paired user with export peak), the zero line
    # shifts UP proportionally to `y_max / (y_max + |y_min|)` of the
    # chart area, leaving room for the export peak in the lower half.
    # The net path is then plotted against this asymmetric two-sided
    # scale.
    #
    # When y_min == 0 (no export data), there is no positive-only
    # constraint on the lower half. DTU-only users (no Shelly paired)
    # have nothing to net against — the chart never extends below
    # zero, and pushing the zero line to the chart bottom (`zero_y =
    # chart_bottom_y`) gives the production curve the full chart
    # height. The previous mid-chart zero line (`zero_y_default =
    # 135`) wasted the lower half of the canvas for DTU-only users,
    # since no curve ever plots there.
    chart_top_y = 20.0
    chart_bottom_y = 250.0
    zero_y_default = 135.0

    {zero_y, lower_height} =
      cond do
        y_min < 0.0 ->
          total_range = y_max + abs(y_min)

          {chart_top_y + y_max / total_range * (chart_bottom_y - chart_top_y), abs(y_min)}

        socket.assigns[:has_shelly?] ->
          # Shelly-only / no-net-data case: the previous behaviour
          # (zero line at y=135) is preserved. Only paired inverters
          # + Shelly users flip the asymmetric layout on, so a Shelly-
          # only user keeps the historical layout for now.
          {zero_y_default, 0.0}

        true ->
          # DTU-only user: pin zero to the chart bottom so the
          # production curve fills the full chart height.
          {chart_bottom_y, 0.0}
      end

    # Pixel-per-watt scale factors for the unified Y-axis. Positive
    # values (production, consumption, total) use the upper-half
    # scale; the net path's negative display values use the lower-
    # half scale (only set when y_min < 0; defaults to 0 when the
    # chart stays positive-only).
    pixels_per_watt_positive = (zero_y - chart_top_y) / y_max
    pixels_per_watt_negative = (chart_bottom_y - zero_y) / max(lower_height, 1.0)

    # Chart dimensions: width 800, height 250 (with 20px top padding).
    # X range is dynamic: zoomed to data when present, full day (00:00–
    # 24:00) when empty. See `chart_time_range/2` below.
    {x_min_seconds, x_max_seconds} =
      ChartHelpers.chart_time_range(chart_points, tz_offset_seconds)

    x_span = x_max_seconds - x_min_seconds

    # Group points by series (one line per (inverter, MPPT) pair) and
    # translate each point into SVG coordinates within the dynamic X range.
    # We also capture the LOCAL bucket time (seconds-of-day, after applying
    # the user's timezone offset) per point so the ChartTooltip hook can
    # look up values by cursor time in the user's frame of reference
    # without round-tripping through the UTC values.
    series_points =
      chart_points
      |> Enum.group_by(& &1.series)
      |> Enum.map(fn {series, pts} ->
        coords =
          pts
          |> Enum.map(fn %{time: time, power: power} ->
            utc_seconds = time.hour * 3600 + time.minute * 60 + time.second
            local_seconds = utc_seconds + tz_offset_seconds
            local_seconds = rem(local_seconds + 86_400 * 4, 86_400)
            x = (local_seconds - x_min_seconds) / x_span * 800.0
            # Positive watts use the upper-half pixel-per-watt scale
            # (above the zero line). When `y_min` is 0 the zero line
            # sits at y=135 by default and this collapses to the
            # original `250 - power/y_max * 230` formula.
            y = zero_y - power * pixels_per_watt_positive
            {Float.round(x, 1), Float.round(y, 1), local_seconds}
          end)
          |> Enum.sort_by(&elem(&1, 0))

        {series, coords}
      end)
      |> Enum.sort_by(fn {{dtu_id, serial, mppt_index, _name}, _pts} ->
        {dtu_id, serial, mppt_index}
      end)

    # Build path data per series, plus an area fill for the first
    # series (the AC aggregate, mppt_index = 0) for the existing
    # "tinted under the curve" look.
    series_paths =
      Enum.map(series_points, fn {series, coords} ->
        path =
          case coords do
            [] ->
              ""

            [{first_x, first_y, _first_t} | rest] ->
              "M #{first_x} #{first_y} " <>
                (rest |> Enum.map_join(" ", fn {x, y, _t} -> "L #{x} #{y}" end))
          end

        {series, path}
      end)
      |> Map.new()

    # Yesterday's ghost overlay — only on the 1D (live) view. The
    # ghost reuses the same X/Y scale as today's chart so it sits on
    # the same baseline visually; same per-series grouping so the
    # ghost line picks up the same inverter colour (just rendered
    # translucent + dashed in the template). Empty when there's no
    # yesterday data — e.g. a brand-new install — so the template can
    # render nothing instead of a misleading zero line.
    yesterday_paths =
      if live? do
        yesterday_chart_points =
          user
          |> Devices.list_yesterday_chart_data_for_dashboard(utc_start, utc_end, dtu_id)
          |> Enum.filter(fn pt ->
            pt.series |> elem(2) == 0 and pt.series |> elem(1) != "_fleet"
          end)
          |> Enum.map(fn pt -> %{pt | power: pt.power || 0.0} end)

        yesterday_chart_points
        |> Enum.group_by(& &1.series)
        |> Enum.map(fn {series, pts} ->
          coords =
            pts
            |> Enum.map(fn %{time: time, power: power} ->
              utc_seconds = time.hour * 3600 + time.minute * 60 + time.second

              local_seconds =
                (utc_seconds + tz_offset_seconds)
                |> rem(86_400 * 4)
                |> rem(86_400)

              x = (local_seconds - x_min_seconds) / x_span * 800.0
              y = zero_y - power * pixels_per_watt_positive
              {Float.round(x, 1), Float.round(y, 1)}
            end)
            |> Enum.sort_by(&elem(&1, 0))

          path =
            case coords do
              [] ->
                ""

              [{fx, fy} | rest] ->
                "M #{fx} #{fy} " <>
                  Enum.map_join(rest, " ", fn {x, y} -> "L #{x} #{y}" end)
            end

          {series, path}
        end)
        |> Map.new()
      else
        %{}
      end

    # Color palette per series. Each series is now one line per
    # inverter (mppt_index = 0 only), so we just need the per-inverter
    # base hue. The shade is fixed at 400 because there's no second
    # MPPT line to differentiate against anymore — using a single
    # bright shade keeps each inverter's line clearly visible against
    # the tinted area fill.
    inverter_color = ChartPalette.inverte_order_to_color(series_points)

    series_palette =
      Enum.map(series_points, fn {series, _pts} ->
        dtu_id = elem(series, 0)
        serial = elem(series, 1)
        base = Map.get(inverter_color, {dtu_id, serial})
        {series, {base, "400"}}
      end)
      |> Map.new()

    # Friendly names for the legend. Prefer the user-set `inverter_name`,
    # fall back to the serial. Per-MPPT rows are collapsed into the
    # inverter's AC line (see the `Enum.filter` further up), so the
    # legend labels are simply the inverter's friendly name — no
    # `MPPT N` suffix needed.
    series_legend =
      Enum.map(series_points, fn {series, _pts} ->
        {dtu_id, serial, mppt_index, name} = series
        friendly = name || serial
        {{dtu_id, serial, mppt_index, name}, friendly}
      end)
      |> Map.new()

    # No tinted area under the curves. The decorative fill that used to
    # sit under the first inverter's line was misleading: in single-
    # inverter fleets the only inverter's line *is* the total, so users
    # reasonably read the tinted region as "Total" — but it wasn't.
    # The chart's lines, legend, and tooltip already convey all the
    # information; the fill was just visual noise.

    x_labels = ChartHelpers.chart_x_labels(x_min_seconds, x_max_seconds)

    # Time series per series for the tooltip hook. Encoded as JSON
    # strings (data-points="...") so the JS hook can look up the value
    # at the cursor's time without parsing the SVG path's `d=` string.
    # Each series entry is a list of {time, power} pairs in seconds /
    # watts, sorted by time. We use the bucket time captured alongside
    # each point in `series_points` (third tuple element) so we don't
    # lose precision reverse-mapping through the rounded X coord.
    series_points_data =
      Enum.map(series_points, fn {series, coords} ->
        {series,
         Enum.map(coords, fn {_x, y, seconds} ->
           %{time: seconds, power: ChartHelpers.power_at_from_unified_y(y, zero_y, y_max)}
         end)}
      end)
      |> Map.new()

    # Fleet-wide "Total" line: sum of every series' power at each
    # bucket. This is the headline curve a customer wants to see — it
    # answers "how much am I producing right now?" without having to
    # mentally add up per-inverter lines. Computed server-side from
    # `chart_points` (one entry per inverter per bucket) so the total
    # is exact, not interpolated.
    #
    # The Total is suppressed when there's only one inverter in scope
    # — in that case the per-inverter line *is* the total and adding
    # it again would be a redundant curve.
    distinct_inverters =
      chart_points
      |> Enum.map(fn pt -> {elem(pt.series, 0), elem(pt.series, 1)} end)
      |> Enum.uniq()

    show_total? = length(distinct_inverters) > 1

    {total_path, total_coords} =
      if show_total? do
        chart_points
        |> Enum.group_by(& &1.time)
        |> Enum.map(fn {time, pts} ->
          utc_seconds = time.hour * 3600 + time.minute * 60 + time.second
          local_seconds = rem(utc_seconds + tz_offset_seconds + 86_400 * 4, 86_400)
          x = (local_seconds - x_min_seconds) / x_span * 800.0
          total_power = pts |> Enum.map(& &1.power) |> Enum.sum()
          y = zero_y - total_power * pixels_per_watt_positive
          {Float.round(x, 1), Float.round(y, 1), local_seconds, total_power}
        end)
        |> Enum.sort_by(&elem(&1, 0))
        |> then(fn pts ->
          path =
            case pts do
              [] ->
                ""

              [{fx, fy, _, _} | rest] ->
                "M #{fx} #{fy} " <>
                  Enum.map_join(rest, " ", fn {x, y, _, _} -> "L #{x} #{y}" end)
            end

          coords = Enum.map(pts, fn {x, y, t, _} -> {x, y, t} end)
          {path, coords}
        end)
      else
        {"", []}
      end

    # Total-time -> power data for the tooltip, in the same shape as
    # `series_points_data` so the ChartTooltip hook can iterate over
    # both uniformly.
    total_points_data =
      Enum.map(total_coords, fn {_x, y, seconds} ->
        %{time: seconds, power: ChartHelpers.power_at_from_unified_y(y, zero_y, y_max)}
      end)

    # Consumption overlay: household draw (W) from a paired Shelly
    # Plus 3EM, plotted alongside the production lines. The consumption
    # chart points are bound earlier in this function (just below the
    # production points) so `y_max` can include the consumption peak
    # and the consumption path stays inside the chart area. Rendered
    # as a dashed rose-colored line so it reads as a separate metric,
    # not another inverter.
    {consumption_path, consumption_coords} =
      case consumption_chart_points do
        [] ->
          {"", []}

        pts ->
          path_coords =
            pts
            |> Enum.map(fn %{time: time, power: power} ->
              utc_seconds = time.hour * 3600 + time.minute * 60 + time.second
              local_seconds = utc_seconds + tz_offset_seconds
              local_seconds = rem(local_seconds + 86_400 * 4, 86_400)
              x = (local_seconds - x_min_seconds) / x_span * 800.0
              y = zero_y - power * pixels_per_watt_positive
              {Float.round(x, 1), Float.round(y, 1), local_seconds, power}
            end)
            |> Enum.sort_by(&elem(&1, 0))

          path =
            case path_coords do
              [] ->
                ""

              [{fx, fy, _, _} | rest] ->
                "M #{fx} #{fy} " <>
                  Enum.map_join(rest, " ", fn {x, y, _, _} -> "L #{x} #{y}" end)
            end

          coords = Enum.map(path_coords, fn {x, y, t, _} -> {x, y, t} end)
          {path, coords}
      end

    consumption_points_data =
      Enum.map(consumption_coords, fn {_x, y, seconds} ->
        %{time: seconds, power: ChartHelpers.power_at_from_unified_y(y, zero_y, y_max)}
      end)

    # Net flow overlay — production minus consumption, plotted on the
    # same axes. The user-facing sign convention flips the raw
    # `production - consumption` value: power LEAVING the home
    # (export, positive raw) is shown as a NEGATIVE value on the
    # graph and power ENTERING the home (import, negative raw) is
    # shown as POSITIVE. This matches the energy-flow perspective
    # "the home is exporting negative household consumption" and is
    # also the same convention the Shelly Plus 3EM uses for its
    # `total_act_power` field.
    #
    # Implementation:
    #   * `display_power = -power` — flips the sign for both the SVG
    #     Y coordinate and the JSON embedded in `data-points`. The
    #     tooltip's hover readout therefore shows the same number the
    #     user sees on the chart (-300 W for a 300 W export).
    #   * `y = 135 - display_power / y_max * 115.0` — same Y formula
    #     the production lines use (negative display_power increases
    #     y, plotting export below the zero line at y=135).
    #
    # The full SVG height is 230 (20px top padding, 250px bottom);
    # a centered zero line at y=135 lets the curve swing ±115. The
    # zero line itself is rendered as a separate <line> below the
    # net path so users see at a glance which side of zero a point
    # is on.
    #
    # `net_chart_points` is fetched up front (just below the production
    # chart_points binding) so the Y-axis scale can include the most-
    # negative export value before the per-series paths are computed.
    # `display_power = -power` flips the raw sign so export (positive
    # raw) becomes a negative display value below the zero line; the
    # Y mapping uses the unified [y_min, y_max] scale so the export
    # peak always sits inside the chart area, never clipping below
    # the bottom edge.
    {net_path, net_coords, net_points_data} =
      case net_chart_points do
        [] ->
          {"", [], []}

        pts ->
          path_coords =
            pts
            |> Enum.map(fn %{time: time, power: power} ->
              utc_seconds = time.hour * 3600 + time.minute * 60 + time.second
              local_seconds = utc_seconds + tz_offset_seconds
              local_seconds = rem(local_seconds + 86_400 * 4, 86_400)
              x = (local_seconds - x_min_seconds) / x_span * 800.0
              # Flip the sign: export (raw positive) becomes negative
              # for display, then plot below the zero line. See the
              # block comment above for the full sign-convention
              # rationale.
              display_power = -power
              # Use the unified [y_min, y_max] Y-axis: positive
              # display values (import) plot above `zero_y` against
              # the upper-half scale; negative display values (export)
              # plot below `zero_y` against the lower-half scale. The
              # export peak therefore sits inside the chart even when
              # the export magnitude is a fraction of the production
              # peak — the original centered-115-px formula clipped
              # export values that exceeded 50% of `y_max` past the
              # chart's bottom edge.
              y =
                cond do
                  display_power >= 0 ->
                    zero_y - display_power * pixels_per_watt_positive

                  true ->
                    zero_y + abs(display_power) * pixels_per_watt_negative
                end

              {Float.round(x, 1), Float.round(y, 1), local_seconds, display_power}
            end)
            |> Enum.sort_by(&elem(&1, 0))

          path =
            case path_coords do
              [] ->
                ""

              [{fx, fy, _, _} | rest] ->
                "M #{fx} #{fy} " <>
                  Enum.map_join(rest, " ", fn {x, y, _, _} -> "L #{x} #{y}" end)
            end

          coords = Enum.map(path_coords, fn {x, y, t, _} -> {x, y, t} end)

          points_data =
            Enum.map(path_coords, fn {_x, _y, seconds, display_power} ->
              %{time: seconds, power: display_power}
            end)

          {path, coords, points_data}
      end

    socket
    |> assign(:chart_points, chart_points)
    |> assign(:y_max, y_max)
    |> assign(:y_min, y_min)
    |> assign(:zero_y, zero_y)
    |> assign(
      :y_gridlines,
      ChartHelpers.chart_y_gridlines(y_min, y_max, zero_y, chart_bottom_y, lower_height)
    )
    |> assign(:series_paths, series_paths)
    |> assign(:yesterday_paths, yesterday_paths)
    |> assign(:series_palette, series_palette)
    |> assign(:series_legend, series_legend)
    |> assign(:path_data, Map.get(series_paths, hd_or_first_key(series_paths), ""))
    |> assign(:x_labels, x_labels)
    |> assign(:x_min_seconds, x_min_seconds)
    |> assign(:x_max_seconds, x_max_seconds)
    |> assign(:series_points_data, series_points_data)
    |> assign(:total_path, total_path)
    |> assign(:total_points_data, total_points_data)
    |> assign(:total_palette, {"emerald", "900"})
    |> assign(:consumption_path, consumption_path)
    |> assign(:consumption_points_data, consumption_points_data)
    |> assign(:consumption_palette, {"rose", "600"})
    |> assign(:net_path, net_path)
    |> assign(:net_coords, net_coords)
    |> assign(:net_points_data, net_points_data)
    |> assign(:net_palette, {"indigo", "500"})
    |> assign(
      :now_marker_x,
      if(opts[:live?],
        do: ChartHelpers.now_marker_x(x_min_seconds, x_max_seconds, tz_offset_seconds),
        else: nil
      )
    )
    # Sunrise / sunset guide-line X positions. Only computed when
    # the user has a captured geographic position (the JS hook
    # pushes it on every dashboard mount via `set_location`); the
    # helper returns `{nil, nil}` for nil coords so the template
    # renders nothing. We pass the chart's local date so the
    # "today" branch shows today's sunrise/sunset and the historical-
    # day branch shows that specific day's (slightly different) pair.
    |> assign(
      :sun_markers,
      ChartHelpers.sun_markers(
        user.latitude,
        user.longitude,
        local_date,
        x_min_seconds,
        x_max_seconds,
        tz_offset_seconds
      )
    )
  end

  # Chart math + Y-axis formatting helpers (`shift_local/2`,
  # `chart_time_range/2`, `chart_x_labels/2`, `chart_y_gridlines/5`,
  # `tick_range/3`, `format_hour_label/1`, `power_at_from_unified_y/3`,
  # `now_marker_x/4`) all live in `DtuAppWeb.DashboardLive.ChartHelpers`
  # now — see that module for the rationale and the per-function docs.

  # Today's date in the user's local timezone. `Date.utc_today()`
  # `local_today/1`, `utc_day_range_for_local_date/2`,
  # `format_peak_time/2`, and `format_time_hhmm/1` live in
  # `DtuAppWeb.DashboardLive.TimeHelpers` (extracted for testability
  # — see that module's @moduledoc).

  # Empty `series_paths` map is OK; we just need a default for the
  # `path_data` assign so the template always has a string.
  defp hd_or_first_key(map) when map_size(map) == 0, do: nil
  defp hd_or_first_key(map), do: map |> Enum.at(0) |> elem(0)

  # MPPT-specific shades were used when the chart plotted per-MPPT
  # lines (`mppt_index = 0` was the AC aggregate, 1+ were per-string
  # DC). Now that the dashboard exposes one line per inverter (the
  # `Enum.filter` in `assign_line_chart_data/5` collapses all MPPTs
  # into the inverter's AC row), there's nothing to shade-vary — see
  # `series_palette` for the fixed `"400"` shade.

  # Helper to construct SVG bar chart coordinates and range
  defp assign_bar_chart_data(socket, bar_data) do
    max_val =
      bar_data
      |> Enum.map(& &1.value)
      |> Enum.max(fn -> 1.0 end)
      |> max(1.0)

    y_max =
      cond do
        max_val <= 5.0 -> 5.0
        max_val <= 10.0 -> 10.0
        true -> Float.ceil(max_val)
      end

    count = length(bar_data)
    col_width = 800.0 / count
    bar_width = col_width * 0.65

    bars =
      bar_data
      |> Enum.with_index()
      |> Enum.map(fn {item, idx} ->
        height = item.value / y_max * 200.0
        x = idx * col_width + (col_width - bar_width) / 2.0
        y = 220.0 - height

        %{
          x: Float.round(x / 1.0, 1),
          y: Float.round(y / 1.0, 1),
          w: Float.round(bar_width / 1.0, 1),
          h: Float.round(max(height, 1.0) / 1.0, 1),
          label: item.label,
          value: Float.round(item.value / 1.0, 1)
        }
      end)

    socket
    |> assign(:y_max, y_max)
    |> assign(:bars, bars)
  end

  # --- Time-picker helpers ----------------------------------------------------

  # Apply `assign_dashboard_data/5` only on the live view — historical
  # views (day / week / month / year) are static and don't refresh on
  # every reading. Kept as a helper so the reading handler above can
  # stay readable.
  defp maybe_reassign_dashboard_data(socket, user, selected_id) do
    if socket.assigns.live do
      assign_dashboard_data(socket, user, selected_id, socket.assigns.time_range, nil)
    else
      socket
    end
  end

  # Re-run the dashboard for whichever view is active after a DTU switch.
  defp reapply_current_view(socket, user, dtu_id) do
    if socket.assigns.live do
      assign_dashboard_data(socket, user, dtu_id, socket.assigns.time_range, nil)
    else
      assign_dashboard_data(
        socket,
        user,
        dtu_id,
        socket.assigns.granularity,
        socket.assigns.selected_period
      )
    end
  end

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

  defp assign_dashboard_data(socket, user, dtu_id, time_range, selected_period) do
    tz_offset_seconds = socket.assigns.user_tz_offset_seconds
    # Energy rate for the "Saved" card. `cents_per_kwh` is set in
    # `mount/3` from `user.cents_per_kwh`; if the user hasn't set a
    # rate yet this is `nil` and `Devices.compute_savings/2`
    # short-circuits to `nil`, so the card is hidden by the
    # template (`<%= if @savings %>`).
    cents = socket.assigns.cents_per_kwh

    # Consumption stats from a paired Shelly Plus 3EM (Gen3+) energy
    # meter: current household draw (W), today's consumed energy
    # (kWh), and peak demand. Computed once per dashboard refresh and
    # shared across all branches since consumption is independent of
    # the production time_range/granularity.
    consumption_stats = Devices.get_consumption_daily_stats(user, dtu_id)

    # Period-aware consumption stats — same shape as `@stats` for the
    # production side: today/day views get current/today/peak, week/
    # month/year views get period total / period peak / peak date.
    # Drives the dedicated "Power consumption" stat-card row that
    # mirrors the production row when a Shelly is paired.
    #
    # We pass the already-fetched `consumption_stats` through so the
    # today / day branches don't re-fetch the same data. The
    # `get_consumption_period_stats/4` helper used to call
    # `get_consumption_daily_stats/2` again, doubling the per-day
    # consumption scan on every dashboard mount / reading refresh
    # (the dashboard pre-fetches the value just above for the
    # consumption stat cards). The 5th argument is `nil` by default
    # for older callers — see `DtuApp.Devices.get_consumption_period_stats/5`.
    consumption_period_stats =
      Devices.get_consumption_period_stats(
        user,
        dtu_id,
        time_range,
        selected_period,
        consumption_stats
      )

    # Net flow (production minus consumption) — the headline value
    # for a solar dashboard ("am I net-exporting or net-importing?").
    # Only meaningful when both an inverter AND a Shelly are paired;
    # otherwise the helper returns all-zeros and the dashboard's
    # `net_flow_active` guard hides the row.
    net_flow_stats = Devices.get_net_flow_stats(user, dtu_id)

    case time_range do
      "today" ->
        # Fetch the day-chart points once and thread them into both
        # `get_daily_stats/4`'s `bucket_max` (for the peak-power stat)
        # and `assign_line_chart_data/6` (for the SVG render). Without
        # threading each helper re-runs the exact same
        # `list_day_chart_data_for_dashboard/4` query in series, so a
        # noon-today mount had to eat two identical day-chart round
        # trips back-to-back. The `today_local` is computed from the
        # user's tz offset so the bucket boundaries line up with the
        # rest of the dashboard's local-day window.
        today_local = TimeHelpers.local_today(tz_offset_seconds)

        {today_utc_start, today_utc_end} =
          Devices.local_day_utc_range(today_local, tz_offset_seconds)

        today_chart_points =
          Devices.list_day_chart_data_for_dashboard(
            user,
            today_utc_start,
            today_utc_end,
            dtu_id
          )

        stats = Devices.get_daily_stats(user, dtu_id, Date.utc_today(), today_chart_points)

        # The 5-up stat-card row's "Yield" tile reads `@stats.total_yield`
        # uniformly across all 8 time_range branches. For the day / week
        # / month / year / 7d / 30d / ytd branches, `compute_day_period_stats/2`
        # and `compute_range_period_stats/2` already return
        # `:total_yield` as the period's kWh sum. But `get_daily_stats/4`
        # uses `:total_yield` for the **lifetime** cumulative yield
        # (firmware `yield_total`) and `:today_yield` for the day's
        # sum-of-latest-`yield_day`. Overwrite `:total_yield` here so
        # the 1D view matches the period semantics the other branches
        # use — otherwise the Yield card on 1D would show the lifetime
        # number instead of today's kWh.
        stats =
          Map.put(stats, :total_yield, stats.today_yield)

        # Self-consumption is a single-period value: today's export
        # divided by today's production. Compute alongside the rest
        # of the today branch so the stat card row's "self-consumption
        # %" tile renders without a second mount round-trip.
        today_self_consumption_pct =
          Devices.compute_self_consumption_pct(
            user,
            dtu_id,
            today_utc_start,
            today_utc_end
          )

        stats_with_self_consumption =
          Map.put(stats, :self_consumption_pct, today_self_consumption_pct)

        socket
        |> assign(:stats, stats_with_self_consumption)
        |> assign(:consumption_stats, consumption_stats)
        |> assign(:consumption_period_stats, consumption_period_stats)
        |> assign(:net_flow_stats, net_flow_stats)
        |> assign(:savings, Devices.compute_savings(stats.today_yield, cents))
        |> assign(:chart_type, :line)
        |> assign_line_chart_data(
          user,
          today_local,
          tz_offset_seconds,
          dtu_id,
          chart_points: today_chart_points
        )

      "day" ->
        date =
          case selected_period do
            %Date{} = d ->
              d

            _ ->
              selectable = socket.assigns.selectable_dates
              List.first(selectable) || TimeHelpers.local_today(tz_offset_seconds)
          end

        # Convert the user-facing local date to the UTC range that
        # contains the readings for that local day.
        {utc_start, utc_end} = Devices.local_day_utc_range(date, tz_offset_seconds)

        points = Devices.list_day_chart_data(user, utc_start, utc_end, dtu_id)
        yields = Devices.list_range_yield_data(user, utc_start, utc_end, dtu_id)
        stats = Devices.compute_day_period_stats(yields, points)

        # Self-consumption % for the historical day. Same
        # computation as the today branch — `(production - exported)
        # / production × 100` — so a user drilling back into "last
        # Tuesday" gets the same headline number for that day.
        day_self_consumption_pct =
          Devices.compute_self_consumption_pct(user, dtu_id, utc_start, utc_end)

        stats_with_self_consumption =
          Map.put(stats, :self_consumption_pct, day_self_consumption_pct)

        socket
        |> assign(:selected_period, date)
        |> assign(:stats, stats_with_self_consumption)
        |> assign(:consumption_stats, consumption_stats)
        |> assign(:consumption_period_stats, consumption_period_stats)
        |> assign(:net_flow_stats, net_flow_stats)
        |> assign(:savings, Devices.compute_savings(stats.total_yield, cents))
        |> assign(:chart_type, :line)
        |> assign_line_chart_data(user, date, tz_offset_seconds, dtu_id)

      "week" ->
        monday =
          case selected_period do
            %Date{} = d ->
              d

            _ ->
              selectable = socket.assigns.selectable_dates
              latest_date = List.first(selectable) || TimeHelpers.local_today(tz_offset_seconds)
              Date.add(latest_date, -(Date.day_of_week(latest_date) - 1))
          end

        sunday = Date.add(monday, 6)

        {monday_utc, sunday_utc_end} =
          {elem(Devices.local_day_utc_range(monday, tz_offset_seconds), 0),
           elem(Devices.local_day_utc_range(sunday, tz_offset_seconds), 1)}

        yields = Devices.list_range_yield_data(user, monday_utc, sunday_utc_end, dtu_id)
        stats = Devices.compute_range_period_stats(yields, 7)

        # Peak watts + time across the week, plus self-consumption %.
        # `compute_peak_watts_in_period/4` reads from readings_5m and
        # the live tail — same source as the chart, so the dashboard's
        # peak wattage matches what the chart shows for the same window.
        {week_peak_w, week_peak_time} =
          Devices.compute_peak_watts_in_period(user, dtu_id, monday_utc, sunday_utc_end)

        week_self_consumption_pct =
          Devices.compute_self_consumption_pct(user, dtu_id, monday_utc, sunday_utc_end)

        stats =
          stats
          |> Map.put(:peak_power, week_peak_w)
          |> Map.put(:peak_time, week_peak_time)
          |> Map.put(:self_consumption_pct, week_self_consumption_pct)

        yield_map = Map.new(yields)

        bar_data =
          for day_offset <- 0..6 do
            d = Date.add(monday, day_offset)
            label = Calendar.strftime(d, "%a")
            value = Map.get(yield_map, d, 0.0)
            %{label: label, value: value}
          end

        socket
        |> assign(:selected_period, monday)
        |> assign(:stats, stats)
        |> assign(:consumption_stats, consumption_stats)
        |> assign(:consumption_period_stats, consumption_period_stats)
        |> assign(:net_flow_stats, net_flow_stats)
        |> assign(:savings, Devices.compute_savings(stats.total_yield, cents))
        |> assign(:chart_type, :bar)
        |> assign_bar_chart_data(bar_data)

      "month" ->
        first_day =
          case selected_period do
            %Date{} = d ->
              d

            _ ->
              selectable = socket.assigns.selectable_dates
              latest_date = List.first(selectable) || TimeHelpers.local_today(tz_offset_seconds)
              Date.new!(latest_date.year, latest_date.month, 1)
          end

        last_day = Date.end_of_month(first_day)

        {first_utc, last_utc_end} =
          {elem(Devices.local_day_utc_range(first_day, tz_offset_seconds), 0),
           elem(Devices.local_day_utc_range(last_day, tz_offset_seconds), 1)}

        yields = Devices.list_range_yield_data(user, first_utc, last_utc_end, dtu_id)
        total_days = Date.diff(last_day, first_day) + 1
        stats = Devices.compute_range_period_stats(yields, total_days)

        {month_peak_w, month_peak_time} =
          Devices.compute_peak_watts_in_period(user, dtu_id, first_utc, last_utc_end)

        month_self_consumption_pct =
          Devices.compute_self_consumption_pct(user, dtu_id, first_utc, last_utc_end)

        stats =
          stats
          |> Map.put(:peak_power, month_peak_w)
          |> Map.put(:peak_time, month_peak_time)
          |> Map.put(:self_consumption_pct, month_self_consumption_pct)

        yield_map = Map.new(yields)

        bar_data =
          for day_offset <- 0..(total_days - 1) do
            d = Date.add(first_day, day_offset)
            label = to_string(d.day)
            value = Map.get(yield_map, d, 0.0)
            %{label: label, value: value}
          end

        socket
        |> assign(:selected_period, first_day)
        |> assign(:stats, stats)
        |> assign(:consumption_stats, consumption_stats)
        |> assign(:consumption_period_stats, consumption_period_stats)
        |> assign(:net_flow_stats, net_flow_stats)
        |> assign(:savings, Devices.compute_savings(stats.total_yield, cents))
        |> assign(:chart_type, :bar)
        |> assign_bar_chart_data(bar_data)

      "year" ->
        year =
          case selected_period do
            %Date{} = d ->
              d.year

            y when is_integer(y) ->
              y

            _ ->
              selectable = socket.assigns.selectable_dates
              latest_date = List.first(selectable) || TimeHelpers.local_today(tz_offset_seconds)
              latest_date.year
          end

        start_date = Date.new!(year, 1, 1)
        end_date = Date.new!(year, 12, 31)

        {start_utc, end_utc_end} =
          {elem(Devices.local_day_utc_range(start_date, tz_offset_seconds), 0),
           elem(Devices.local_day_utc_range(end_date, tz_offset_seconds), 1)}

        yields = Devices.list_range_yield_data(user, start_utc, end_utc_end, dtu_id)
        stats = Devices.compute_range_period_stats(yields, 12)

        {year_peak_w, year_peak_time} =
          Devices.compute_peak_watts_in_period(user, dtu_id, start_utc, end_utc_end)

        year_self_consumption_pct =
          Devices.compute_self_consumption_pct(user, dtu_id, start_utc, end_utc_end)

        stats =
          stats
          |> Map.put(:peak_power, year_peak_w)
          |> Map.put(:peak_time, year_peak_time)
          |> Map.put(:self_consumption_pct, year_self_consumption_pct)

        yield_map = Map.new(yields)

        bar_data =
          for month <- 1..12 do
            month_yield =
              yield_map
              |> Enum.filter(fn {date, _} -> date.month == month end)
              |> Enum.map(fn {_, y} -> y end)
              |> Enum.sum()

            first_day_of_month = Date.new!(year, month, 1)
            label = Calendar.strftime(first_day_of_month, "%b")
            %{label: label, value: month_yield}
          end

        socket
        |> assign(:selected_period, Date.new!(year, 1, 1))
        |> assign(:stats, stats)
        |> assign(:consumption_stats, consumption_stats)
        |> assign(:consumption_period_stats, consumption_period_stats)
        |> assign(:net_flow_stats, net_flow_stats)
        |> assign(:savings, Devices.compute_savings(stats.total_yield, cents))
        |> assign(:chart_type, :bar)
        |> assign_bar_chart_data(bar_data)

      "7d" ->
        # Last 7 days ending today, daily yields → bar chart. Anchored on
        # the user's tz offset so a CET user at 01:00 local on Monday sees
        # the window start at the previous Tuesday's local midnight
        # (matching the dashboard's other local-day boundaries).
        yields =
          Devices.list_last_n_days_yield_data(user, 7, tz_offset_seconds, dtu_id)

        # Stats use the range period helper — divisor is the calendar
        # span (7) so the average matches what the user gets on a custom
        # week view, not just the days that have data.
        stats = Devices.compute_range_period_stats(yields, 7)

        # `local_day_utc_range/2` returns {utc_start, utc_end}; for a
        # rolling 7-day window we anchor on `today_local` so the peak
        # watts query covers the same span the bar chart plots.
        today_local = TimeHelpers.local_today(tz_offset_seconds)

        {seven_day_utc_start, seven_day_utc_end} =
          Devices.local_day_utc_range(today_local, tz_offset_seconds)

        {seven_day_peak_w, seven_day_peak_time} =
          Devices.compute_peak_watts_in_period(
            user,
            dtu_id,
            DateTime.add(seven_day_utc_start, -6 * 86_400, :second),
            seven_day_utc_end
          )

        seven_day_self_consumption_pct =
          Devices.compute_self_consumption_pct(
            user,
            dtu_id,
            DateTime.add(seven_day_utc_start, -6 * 86_400, :second),
            seven_day_utc_end
          )

        stats =
          stats
          |> Map.put(:peak_power, seven_day_peak_w)
          |> Map.put(:peak_time, seven_day_peak_time)
          |> Map.put(:self_consumption_pct, seven_day_self_consumption_pct)

        yield_map = Map.new(yields)

        bar_data =
          for day_offset <- -6..0 do
            d = Date.add(today_local, day_offset)
            label = Calendar.strftime(d, "%a")
            value = Map.get(yield_map, d, 0.0)
            %{label: label, value: value}
          end

        socket
        |> assign(:stats, stats)
        |> assign(:consumption_stats, consumption_stats)
        |> assign(:consumption_period_stats, consumption_period_stats)
        |> assign(:net_flow_stats, net_flow_stats)
        |> assign(:savings, Devices.compute_savings(stats.total_yield, cents))
        |> assign(:chart_type, :bar)
        |> assign_bar_chart_data(bar_data)

      "30d" ->
        # Last 30 days ending today, daily yields → bar chart. Same
        # boundary handling as `7d` above; just a wider window.
        yields =
          Devices.list_last_n_days_yield_data(user, 30, tz_offset_seconds, dtu_id)

        stats = Devices.compute_range_period_stats(yields, 30)

        today_local = TimeHelpers.local_today(tz_offset_seconds)

        {thirty_day_utc_start, thirty_day_utc_end} =
          Devices.local_day_utc_range(today_local, tz_offset_seconds)

        {thirty_day_peak_w, thirty_day_peak_time} =
          Devices.compute_peak_watts_in_period(
            user,
            dtu_id,
            DateTime.add(thirty_day_utc_start, -29 * 86_400, :second),
            thirty_day_utc_end
          )

        thirty_day_self_consumption_pct =
          Devices.compute_self_consumption_pct(
            user,
            dtu_id,
            DateTime.add(thirty_day_utc_start, -29 * 86_400, :second),
            thirty_day_utc_end
          )

        stats =
          stats
          |> Map.put(:peak_power, thirty_day_peak_w)
          |> Map.put(:peak_time, thirty_day_peak_time)
          |> Map.put(:self_consumption_pct, thirty_day_self_consumption_pct)

        yield_map = Map.new(yields)

        bar_data =
          for day_offset <- -29..0 do
            d = Date.add(today_local, day_offset)
            # %-d → no zero-pad; with 30 bars the wider "%b %-d" format
            # keeps each label readable on a tight x-axis.
            label = Calendar.strftime(d, "%b %-d")
            value = Map.get(yield_map, d, 0.0)
            %{label: label, value: value}
          end

        socket
        |> assign(:stats, stats)
        |> assign(:consumption_stats, consumption_stats)
        |> assign(:consumption_period_stats, consumption_period_stats)
        |> assign(:net_flow_stats, net_flow_stats)
        |> assign(:savings, Devices.compute_savings(stats.total_yield, cents))
        |> assign(:chart_type, :bar)
        |> assign_bar_chart_data(bar_data)

      "ytd" ->
        # Year-to-date (Jan 1 of current year → today), monthly yields →
        # bar chart. Same shape as the existing `year` branch above but
        # window starts on Jan 1 (not Jan 1 of an arbitrary year), so the
        # bars stop at the current month rather than going all the way to
        # December.
        monthly_yields = Devices.list_ytd_yield_data(user, dtu_id)
        today = Date.utc_today()
        months_in_window = today.month

        # `Devices.list_ytd_yield_data/2` returns
        # `[{{year, month}, kwh}]` — the range-period stats helper
        # expects `[{Date.t(), float()}]` so we widen the tuple back
        # into a first-of-month `Date`. Multi-year installs (rare:
        # one full January's worth of cross-year data is the only
        # case where the same `{year, month}` would collide) collapse
        # cleanly because we group by `month` only below for the bars.
        stats =
          Devices.compute_range_period_stats(
            Enum.map(monthly_yields, fn {{year, month}, kwh} ->
              {Date.new!(year, month, 1), kwh}
            end),
            months_in_window
          )

        # Peak watts + self-consumption across Jan 1 → today (the
        # YTD window). Uses the user's tz offset so the boundaries
        # line up with the bar chart's first bar (January).
        ytd_start_date = Date.new!(today.year, 1, 1)

        {ytd_utc_start, ytd_utc_end} =
          Devices.local_day_utc_range(ytd_start_date, tz_offset_seconds)

        {ytd_peak_w, ytd_peak_time} =
          Devices.compute_peak_watts_in_period(user, dtu_id, ytd_utc_start, ytd_utc_end)

        ytd_self_consumption_pct =
          Devices.compute_self_consumption_pct(user, dtu_id, ytd_utc_start, ytd_utc_end)

        stats =
          stats
          |> Map.put(:peak_power, ytd_peak_w)
          |> Map.put(:peak_time, ytd_peak_time)
          |> Map.put(:self_consumption_pct, ytd_self_consumption_pct)

        bar_data =
          for month <- 1..months_in_window do
            first_day = Date.new!(today.year, month, 1)
            label = Calendar.strftime(first_day, "%b")

            value =
              monthly_yields
              |> Enum.filter(fn {{_y, m}, _} -> m == month end)
              |> Enum.map(fn {_, kwh} -> kwh end)
              |> Enum.sum()

            %{label: label, value: value}
          end

        socket
        |> assign(:stats, stats)
        |> assign(:consumption_stats, consumption_stats)
        |> assign(:consumption_period_stats, consumption_period_stats)
        |> assign(:net_flow_stats, net_flow_stats)
        |> assign(:savings, Devices.compute_savings(stats.total_yield, cents))
        |> assign(:chart_type, :bar)
        |> assign_bar_chart_data(bar_data)
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
              <%= if @path_data == "" do %>
                <div
                  class="flex flex-col items-center justify-center h-64 border-2 border-dashed border-zinc-300 dark:border-zinc-700 rounded-lg"
                  id="empty-chart"
                >
                  <.icon name="hero-presentation-chart-line" class="h-12 w-12 text-zinc-400 mb-2" />
                  <p class="text-sm text-zinc-500 dark:text-zinc-400">
                    {gettext("No power readings logged for this day.")}
                  </p>
                </div>
              <% else %>
                <div
                  class="relative w-full overflow-hidden"
                  id="solar-chart-container"
                  phx-hook=".ChartTooltip"
                >
                  <!-- Chart SVG -->
                  <svg
                    viewBox="0 0 800 280"
                    class="w-full h-auto overflow-visible"
                    id="solar-chart-svg"
                    data-x-min-seconds={@x_min_seconds}
                    data-x-max-seconds={@x_max_seconds}
                  >
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
                    <line
                      x1="0"
                      y1={chart_grid_bottom}
                      x2="800"
                      y2={chart_grid_bottom}
                      stroke="#e4e4e7"
                      class="dark:stroke-zinc-600"
                      stroke-width="1.5"
                    />

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
                      <line
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
                      <g pointer-events="none">
                        <rect
                          x={@now_marker_x - 18}
                          y="6"
                          width="36"
                          height="14"
                          rx="3"
                          fill="#6366f1"
                          class="dark:fill-indigo-400"
                        />
                        <text
                          x={@now_marker_x}
                          y="16"
                          text-anchor="middle"
                          fill="white"
                          class="dark:fill-zinc-900"
                          font-size="10"
                          font-weight="600"
                          font-family="ui-sans-serif, system-ui, sans-serif"
                        >
                          now
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

                      // Push the browser's geographic position so the
                      // server can compute astronomical sunrise / sunset
                      // for the chart's vertical guide lines. Best-effort:
                      // permission denial, unavailable API, and timeout
                      // all silently fall through (the chart simply
                      // shows no sun markers for users without captured
                      // coords). We deliberately do NOT prompt the user
                      // again on subsequent hook mounts — `set_location`
                      // re-fires on every page load, but only AFTER a
                      // successful resolve; a denial sticks for the
                      // session unless the user manually clears the
                      // site permission.
                      if (navigator.geolocation) {
                        navigator.geolocation.getCurrentPosition(
                          (pos) => {
                            this.pushEvent("set_location", {
                              latitude: pos.coords.latitude,
                              longitude: pos.coords.longitude
                            });
                          },
                          () => {
                            // Silent: user denied, position unavailable,
                            // or timeout. The chart will simply omit
                            // sun markers; no error UI needed.
                          },
                          // 10s timeout is well above the typical
                          // 1–3s fix time but well below the user's
                          // patience for a "loading" state.
                          { timeout: 10_000, maximumAge: 60_000 }
                        );
                      }

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
              <% end %>
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
                          <%= if ro_sink_kind?(device) do %>
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
    </Layouts.app>
    """
  end
end
