defmodule DtuAppWeb.DashboardLive do
  use DtuAppWeb, :live_view

  import Ecto.Query

  alias DtuApp.Devices
  alias DtuApp.Accounts
  alias DtuApp.MqttBroker.Telemetry
  alias DtuApp.MqttBroker.Broker
  alias DtuApp.Notifications
  alias DtuApp.PushSubscriptions

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
      # Anonymous share toggle for the current-day dashboard. On mount we
      # only know whether sharing is on (the row exists) — the plaintext
      # URL token is never persisted, so a page reload leaves the toggle
      # visibly on but the URL field blank. The user toggles off+on to
      # mint a new URL (which invalidates the old share row). This keeps
      # "show URL once, then it's gone if you didn't copy it" honest.
      |> assign_share_state(user)
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
      |> assign_selectable_periods(user, nil)
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

  @impl true
  def handle_event("select_dtu", %{"id" => id_str}, socket) do
    selected_id = if id_str == "total", do: nil, else: String.to_integer(id_str)
    user = socket.assigns.current_scope.user

    socket = assign_selectable_periods(socket, user, selected_id)

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
    current = socket.assigns.selected_period || local_today(socket.assigns.user_tz_offset_seconds)

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
  # On enable the handler is split into two phases so the UI gets a
  # chance to render a spinner between the click and the URL appearing:
  #
  #   1. `toggle_share` flips `:share_loading?` true and sends a
  #      follow-up message to itself (`{:mint_share_token, user_id}`).
  #      The socket reply is rendered immediately, so the toolbar
  #      swaps the URL row for the spinner before the DB transaction
  #      starts.
  #   2. `handle_info({:mint_share_token, _}, socket)` does the actual
  #      `Accounts.create_shared_link/1` work and emits a second render
  #      with the URL + `:share_loading?` false.
  #
  # The two-phase pattern is what makes the spinner visible — a single
  # synchronous handler would batch the spinner and the URL into one
  # render and the user would never see the in-flight state.
  #
  # On disable the work is synchronous and the URL row disappears in
  # one render, so no spinner is needed.
  #
  # Both modes are best-effort — a DB failure logs at warning and
  # leaves the UI in its prior state rather than crashing the
  # dashboard.
  @impl true
  def handle_event("toggle_share", %{"enabled" => "true"}, socket) do
    user = socket.assigns.current_scope.user
    send(self(), {:mint_share_token, user.id})
    {:noreply, assign(socket, :share_loading?, true)}
  end

  def handle_event("toggle_share", %{"enabled" => "false"}, socket) do
    user = socket.assigns.current_scope.user
    :ok = Accounts.revoke_shared_link(user)

    {:noreply,
     socket
     |> assign(:share_active?, false)
     |> assign(:share_url, nil)
     |> assign(:share_loading?, false)}
  end

  def handle_event("toggle_share", _payload, socket), do: {:noreply, socket}

  defp do_mint_share_token(socket) do
    user = socket.assigns.current_scope.user

    case Accounts.create_shared_link(user) do
      {:ok, {plaintext, _link}} ->
        {:noreply,
         socket
         |> assign(:share_active?, true)
         |> assign(:share_url, url_for_token(plaintext))
         |> assign(:share_loading?, false)}

      {:error, reason} ->
        Logger.warning(
          "[dashboard] create_shared_link failed user=#{user.id} reason=#{inspect(reason)}"
        )

        {:noreply,
         socket
         |> assign(:share_loading?, false)
         |> assign(:share_active?, false)
         |> assign(:share_url, nil)}
    end
  end

  # Build the public share URL from a plaintext token. Uses the configured
  # PHX_HOST so the link points at the right deployment (dev / staging /
  # production) without a hard-coded hostname.
  defp url_for_token(token) do
    DtuAppWeb.Endpoint.url() <> "/s/" <> token
  end

  # Phase 2 of the share-toggle enable flow: do the actual DB work
  # now that the toolbar has already rendered the spinner. We pin
  # the user id into the message (rather than passing the user
  # struct) so a stale message from a previous session can't
  # resurrect a deleted user's share row.
  @impl true
  def handle_info({:mint_share_token, user_id}, socket) do
    current_user_id = socket.assigns.current_scope.user.id

    if user_id == current_user_id do
      do_mint_share_token(socket)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:reading, _client_id, _reading}, socket) do
    user = socket.assigns.current_scope.user
    selected_id = socket.assigns.selected_dtu_id

    socket = assign_selectable_periods(socket, user, selected_id)

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
  # The plaintext is intentionally left nil on mount — only the hash
  # is persisted, so a returning user can't recover the old URL
  # without regenerating (which invalidates the old row anyway).
  defp assign_share_state(socket, user) do
    active? = Accounts.get_shared_link(user) != nil

    socket
    |> assign(:share_active?, active?)
    |> assign(:share_url, nil)
    |> assign(:share_loading?, false)
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
    {x_min_seconds, x_max_seconds} = chart_time_range(chart_points, tz_offset_seconds)
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
    inverter_color = inverte_order_to_color(series_points)

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

    x_labels = chart_x_labels(x_min_seconds, x_max_seconds)

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
           %{time: seconds, power: power_at_from_unified_y(y, zero_y, y_max)}
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
        %{time: seconds, power: power_at_from_unified_y(y, zero_y, y_max)}
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
        %{time: seconds, power: power_at_from_unified_y(y, zero_y, y_max)}
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
    |> assign(:y_gridlines, chart_y_gridlines(y_min, y_max, zero_y, chart_bottom_y, lower_height))
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
  end

  # Reverse the per-series / total / consumption Y coord back to watts
  # against the unified Y-axis. When the chart extends below zero
  # (`y_min < 0`), the zero line sits at `zero_y` instead of the
  # default y=135, so the reverse mapping must use the upper-half
  # scale (`zero_y - 20` pixels over `y_max` W) — the same factor
  # the forward mapping uses.
  defp power_at_from_unified_y(y, zero_y, y_max),
    do: round((zero_y - y) / max(zero_y - 20.0, 1.0) * y_max)

  # Compute the chart's X-axis time range (in LOCAL seconds-of-day,
  # so the labels read in the user's timezone).
  #
  #   * Empty `chart_points`         → full day (00:00–24:00)
  #   * Non-empty `chart_points`      → from the floor-of-the-hour of the
  #                                     first data point to the next full
  #                                     hour after the last data point
  #
  # Bucket boundaries are multiples of 5 minutes (UTC). Their hour-of-day
  # in the user's zone is `rem(bucket_utc_hour + tz_offset_hours, 24)`,
  # so we shift first/last before computing the range. `end_hour`
  # adds a 1-hour buffer so the line doesn't end at the chart's right
  # edge.
  @spec chart_time_range([%{required(:time) => DateTime.t()}], integer()) ::
          {non_neg_integer(), pos_integer()}
  defp chart_time_range([], _tz_offset_seconds), do: {0, 86_400}

  defp chart_time_range(points, tz_offset_seconds) do
    first_local = shift_local(Enum.min_by(points, & &1.time).time, tz_offset_seconds)
    last_local = shift_local(Enum.max_by(points, & &1.time).time, tz_offset_seconds)

    start_hour = first_local.hour
    end_hour = min(last_local.hour + 1, 24)

    # Ensure at least a 1-hour window so single-bucket data (e.g. one
    # point at 12:00) still draws as a 1-hour segment instead of a
    # single-pixel spike.
    end_hour = max(end_hour, min(start_hour + 1, 24))

    {start_hour * 3600, end_hour * 3600}
  end

  # Convert a UTC DateTime to a (possibly-wrapped) LOCAL seconds-of-day.
  # Used by the chart's range computation, the X-axis label generator,
  # and the ChartTooltip data embedding. Returns a `%Time{}` struct
  # because we only need hour/minute/second — and we want the wrap
  # to happen naturally (23 + 2h offset in CET = 01 next day).
  @spec shift_local(DateTime.t(), integer()) :: %Time{}
  defp shift_local(%DateTime{} = dt, tz_offset_seconds) do
    shifted = DateTime.add(dt, tz_offset_seconds, :second)
    # DateTime.add can return a datetime on the previous or next day;
    # we only care about the time-of-day component.
    %Time{
      hour: shifted.hour,
      minute: shifted.minute,
      second: shifted.second,
      microsecond: {0, 0}
    }
  end

  # Generate X-axis label positions for the chart. Returns a list of
  # `{x, label}` tuples where `x` is the SVG x-coordinate (0–800) and
  # `label` is the LOCAL time-of-day string (e.g. "07:00"). Labels
  # always include the chart's start and end hours; intermediate hours
  # are spaced at 1 or 2 hours depending on the total span. The step
  # is capped at 2 hours regardless of zoom — a 24-hour view shows a
  # tick every 2 hours (00:00, 02:00, …, 24:00), a ≤2h zoom shows
  # every hour. The previous ladder (1/2/3/6) traded tick density for
  # label clutter at long spans; the user's explicit ask was a max
  # 2-hour interval.
  @spec chart_x_labels(non_neg_integer(), pos_integer()) :: [{float(), String.t()}]
  defp chart_x_labels(x_min_seconds, x_max_seconds) do
    start_hour = div(x_min_seconds, 3600)
    end_hour = div(x_max_seconds, 3600)
    total_hours = end_hour - start_hour

    step =
      cond do
        total_hours <= 2 -> 1
        true -> 2
      end

    span = x_max_seconds - x_min_seconds

    for hour <- start_hour..end_hour,
        hour == start_hour or hour == end_hour or rem(hour - start_hour, step) == 0 do
      seconds = hour * 3600
      x = (seconds - x_min_seconds) / span * 800.0
      {Float.round(x, 1), format_hour_label(hour)}
    end
  end

  # Format a local hour-of-day (0–24) as "HH:00". The ChartTooltip
  # also uses this for its tooltip body.
  defp format_hour_label(0), do: "00:00"
  defp format_hour_label(24), do: "24:00"
  defp format_hour_label(hour) when hour < 10, do: "0#{hour}:00"
  defp format_hour_label(hour), do: "#{hour}:00"

  # Generate the Y-axis gridline + label positions for the chart.
  # Returns a list of `{watts, y_pixel}` tuples, ascending. The
  # gridline step is 500 W (the user's explicit ask: "at least every
  # 500 W"). The set always includes the chart's edge ticks (`y_min`
  # and `y_max`) plus every 500 W step in between, regardless of
  # whether `y_min` is zero or below.
  #
  # Examples:
  #   * y_min = 0,   y_max = 400 → [0, 400]  (400 isn't a 500 step;
  #     the next aligned tick above 0 is 500, but that's above y_max,
  #     so it's dropped — only the edges remain). In practice y_max
  #     is rounded up to a multiple of 100, so this is the common
  #     "small peak" case.
  #   * y_min = 0,   y_max = 500 → [0, 500]
  #   * y_min = 0,   y_max = 2500 → [0, 500, 1000, 1500, 2000, 2500]
  #   * y_min = -500, y_max = 2500 → [-500, 0, 500, 1000, …, 2500]
  #   * y_min = -100, y_max = 2500 → [-100, 0, 500, …, 2500] — the
  #     -100 edge tick is preserved even though it's not on the 500 W
  #     grid (the bottom edge of the chart must always be labelled).
  #
  # The function returns raw watts + pixel positions; the SVG template
  # iterates the list and renders each tick with a dashed stroke for
  # the `watts == 0` case.
  @spec chart_y_gridlines(float(), float(), float(), float(), float()) :: [{float(), float()}]
  defp chart_y_gridlines(y_min, y_max, zero_y, chart_bottom_y, lower_height) do
    step = 500.0

    # First interior tick above y_min aligned to the 500 W grid, then
    # the edge ticks (y_min and y_max) added back in. We add the
    # edges separately so a non-500-multiple edge (y_min = -100, say)
    # still gets a label even though it's off the grid.
    interior_first = Float.ceil(y_min / step) * step

    interior_last = Float.floor(y_max / step) * step

    interior = tick_range(interior_first, interior_last, step)

    # Dedupe edges if they happen to coincide with an interior tick
    # (e.g. y_min = 0, y_max = 500 → interior = [0, 500], edges are
    # the same set — no dups needed).
    edges = Enum.uniq([y_min, y_max, 0.0])

    ticks =
      (interior ++ edges)
      |> Enum.uniq()
      |> Enum.sort()

    pixels_per_watt_positive = (zero_y - 20.0) / y_max
    pixels_per_watt_negative = (chart_bottom_y - zero_y) / max(lower_height, 1.0)

    for tick <- ticks do
      y_pixel =
        if tick >= 0.0 do
          zero_y - tick * pixels_per_watt_positive
        else
          chart_bottom_y - abs(tick) * pixels_per_watt_negative
        end

      {tick, Float.round(y_pixel, 1)}
    end
  end

  # Inclusive ascending range from `first` to `last` in `step`
  # increments. Uses arithmetic to avoid Float drift on long runs.
  defp tick_range(first, last, step) do
    if first > last do
      []
    else
      count = trunc((last - first) / step) + 1
      Enum.map(0..(count - 1), &(first + &1 * step))
    end
  end

  # Today's date in the user's local timezone. `Date.utc_today()`
  # would give us "today in London"; for a Berlin user looking at the
  # dashboard at 23:30 UTC (= 00:30 Berlin next day) we want the
  # Berlin date so the chart shows the day they're actually in.
  @spec local_today(integer()) :: Date.t()
  defp local_today(tz_offset_seconds) do
    # Use the database clock so "today in the user's timezone" matches
    # the day the readings table's `inserted_at` was bucketed under.
    # See `DtuApp.Time`.
    DtuApp.Time.utc_now()
    |> DateTime.add(tz_offset_seconds, :second)
    |> DateTime.to_date()
  end

  # Convert a local date (as the user sees it on the dashboard) to the
  # inclusive UTC day range `[start_utc, end_utc]` that the DB query
  # needs to fetch readings for that local day.
  @spec utc_day_range_for_local_date(Date.t(), integer()) ::
          {DateTime.t(), DateTime.t()}
  def utc_day_range_for_local_date(%Date{} = local_date, tz_offset_seconds) do
    {:ok, start_local} = DateTime.new(local_date, ~T[00:00:00])
    {:ok, end_local} = DateTime.new(local_date, ~T[23:59:59])

    {DateTime.add(start_local, -tz_offset_seconds, :second),
     DateTime.add(end_local, -tz_offset_seconds, :second)}
  end

  # Empty `series_paths` map is OK; we just need a default for the
  # `path_data` assign so the template always has a string.
  defp hd_or_first_key(map) when map_size(map) == 0, do: nil
  defp hd_or_first_key(map), do: map |> Enum.at(0) |> elem(0)

  # Format a UTC DateTime as the user's local HH:MM. Falls back to `—`
  # when the time is nil (the bucket-peak helper returns nil for an
  # empty window — no buckets means no peak time). The shift uses the
  # same `tz_offset_seconds` channel as the chart axis labels so the
  # peak-time card and the chart agree on what "13:42" means.
  @spec format_peak_time(DateTime.t() | nil, integer()) :: String.t()
  def format_peak_time(nil, _tz_offset_seconds), do: "—"

  def format_peak_time(%DateTime{} = dt, tz_offset_seconds) do
    dt
    |> DateTime.add(tz_offset_seconds, :second)
    |> format_time_hhmm()
  end

  defp format_time_hhmm(%DateTime{} = dt) do
    :io_lib.format("~2..0B:~2..0B", [dt.hour, dt.minute])
    |> IO.iodata_to_binary()
  end

  # Human-readable label for the active period. Drives the sub-caption
  # under the Yield card's headline ("Last 7 days", "Year to date", …)
  # so the user can see what window the kWh figure covers at a glance.
  # The full mapping mirrors the chart-title copy in `chart_title/2`.
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

  # Deterministic palette: assign each (dtu_id, inverter_serial) pair a
  # base hue from a fixed set, in the order they first appear. Stable
  # across requests so the chart doesn't flicker.
  @palette ~w(emerald amber sky violet rose fuchsia cyan lime orange teal)

  defp inverte_order_to_color(series_points) do
    series_points
    |> Enum.map(fn {series, _} -> {elem(series, 0), elem(series, 1)} end)
    |> Enum.uniq()
    |> Enum.with_index()
    |> Map.new(fn {{dtu_id, serial}, idx} ->
      {{dtu_id, serial}, Enum.at(@palette, rem(idx, length(@palette)))}
    end)
  end

  # Map a (base, shade) Tailwind palette pair to a hex color string.
  # The ChartTooltip JS hook renders the tooltip's color swatches as
  # inline `style="background-color: …"` (we can't reach CSS custom
  # properties or theme tokens from a colocated hook without shipping
  # the Tailwind output as JSON), so we resolve to a concrete hex.
  # Values are the Tailwind v3 default emerald/amber/sky/violet/rose/
  # fuchsia/cyan/lime/orange/teal palette at the requested shade.
  @tailwind_colors %{
    {"emerald", "400"} => "#34d399",
    {"emerald", "600"} => "#059669",
    {"emerald", "800"} => "#065f46",
    {"emerald", "900"} => "#064e3b",
    {"amber", "400"} => "#fbbf24",
    {"amber", "600"} => "#d97706",
    {"amber", "800"} => "#92400e",
    {"amber", "900"} => "#78350f",
    {"sky", "400"} => "#38bdf8",
    {"sky", "600"} => "#0284c7",
    {"sky", "800"} => "#075985",
    {"sky", "900"} => "#0c4a6e",
    {"violet", "400"} => "#a78bfa",
    {"violet", "600"} => "#7c3aed",
    {"violet", "800"} => "#5b21b6",
    {"violet", "900"} => "#4c1d95",
    {"rose", "400"} => "#fb7185",
    {"rose", "600"} => "#e11d48",
    {"rose", "800"} => "#9f1239",
    {"rose", "900"} => "#881337",
    {"fuchsia", "400"} => "#e879f9",
    {"fuchsia", "600"} => "#c026d3",
    {"fuchsia", "800"} => "#86198f",
    {"fuchsia", "900"} => "#701a75",
    {"cyan", "400"} => "#22d3ee",
    {"cyan", "600"} => "#0891b2",
    {"cyan", "800"} => "#155e75",
    {"cyan", "900"} => "#164e63",
    {"lime", "400"} => "#a3e635",
    {"lime", "600"} => "#65a30d",
    {"lime", "800"} => "#3f6212",
    {"lime", "900"} => "#365314",
    {"orange", "400"} => "#fb923c",
    {"orange", "600"} => "#ea580c",
    {"orange", "800"} => "#9a3412",
    {"orange", "900"} => "#7c2d12",
    {"teal", "400"} => "#2dd4bf",
    {"teal", "600"} => "#0d9488",
    {"teal", "800"} => "#115e59",
    {"teal", "900"} => "#134e4a"
  }
  @doc """
  Resolve a Tailwind (`base`, `shade`) pair to a hex color, falling back
  to a neutral grey when the pair isn't in `@tailwind_colors`. The map
  only ships 400/600/800/900 shades — picking a 500 from habit was a
  silent crash that 500'd the whole dashboard for users with a paired
  Shelly. The grey fallback keeps the chart readable even when the
  palette is misconfigured.

  Public so the regression test in `test/dtu_app_web/live/dashboard_live_test.exs`
  can pin both the happy-path and the missing-shade fallback.
  """
  def tooltip_to_hex(base, shade) do
    case Map.fetch(@tailwind_colors, {base, shade}) do
      {:ok, hex} -> hex
      :error -> "#6b7280"
    end
  end

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

  defp assign_selectable_periods(socket, user, dtu_id) do
    dates = Devices.list_selectable_dates(user, dtu_id)

    socket
    |> assign(:selectable_dates, dates)
    |> assign(:selectable_days, build_selectable_days(dates))
    |> assign(:selectable_weeks, build_selectable_weeks(dates))
    |> assign(:selectable_months, build_selectable_months(dates))
    |> assign(:selectable_years, build_selectable_years(dates))
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

  # Human-readable label for the stepper's current position.
  defp stepper_label(%Date{} = date, "day"), do: Calendar.strftime(date, "%a %b %-d, %Y")

  defp stepper_label(%Date{} = date, "week"),
    do: gettext("Week of %{date}", date: Calendar.strftime(date, "%b %-d, %Y"))

  defp stepper_label(%Date{} = date, "month"), do: Calendar.strftime(date, "%B %Y")
  defp stepper_label(%Date{} = date, "year"), do: to_string(date.year)
  defp stepper_label(year, _), do: to_string(year)

  # Value for the native date input (yyyy-mm-dd).
  defp date_input_value(%Date{} = date), do: Date.to_iso8601(date)

  defp date_input_value(year) when is_integer(year),
    do: Date.new!(year, 1, 1) |> Date.to_iso8601()

  defp date_input_value(_), do: Date.utc_today() |> Date.to_iso8601()

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

  # Earliest date with data, for the calendar's `min` bound (yyyy-mm-dd, or nil).
  defp date_min_bound([]), do: nil
  defp date_min_bound(dates), do: dates |> Enum.min(Date) |> Date.to_iso8601()

  # Latest date with data, for the calendar's `max` bound.
  defp date_max_bound([]), do: nil
  defp date_max_bound(dates), do: dates |> Enum.max(Date) |> Date.to_iso8601()

  # True when the current historical granularity has no data to show.
  defp historical_empty?("day", days, _, _, _), do: days == []
  defp historical_empty?("week", _, weeks, _, _), do: weeks == []
  defp historical_empty?("month", _, _, months, _), do: months == []
  defp historical_empty?("year", _, _, _, years), do: years == []
  defp historical_empty?(_, _, _, _, _), do: false

  defp quick_range_btn(assigns) do
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
      <%!-- The label and the spinner are *both* in the DOM at all
           times. LiveView's `phx-click-loading` class is added to the
           button while the round-trip is in flight, and the project's
           Tailwind 4 setup declares a `@custom-variant phx-click-loading`
           (assets/css/app.css) so the label hides and the spinner shows
           exactly for that window. We can't use `phx-disable-with` here
           because LiveView sets its value via `el.textContent`, which
           renders any embedded HTML markup as visible text instead of
           parsed HTML — that was the "literal <svg>…</svg> on the page"
           bug. Keeping both elements in the DOM and toggling them via
           the LiveView-managed class also handles rapid clicks: the
           class is added on click and removed when the response
           arrives, so no leftover text accumulates. --%>
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

  defp build_selectable_days(dates) do
    dates
    |> Enum.map(fn date ->
      label = Calendar.strftime(date, "%Y-%m-%d")
      {label, Date.to_string(date)}
    end)
  end

  defp build_selectable_weeks(dates) do
    dates
    |> Enum.group_by(fn d ->
      :calendar.iso_week_number({d.year, d.month, d.day})
    end)
    |> Enum.map(fn {{year, week}, week_dates} ->
      representative_date = hd(week_dates)
      monday = Date.add(representative_date, -(Date.day_of_week(representative_date) - 1))

      label =
        gettext("Year %{year}, Week %{week} (starting %{monday})",
          year: year,
          week: week,
          monday: monday
        )

      {label, Date.to_string(monday)}
    end)
    |> Enum.sort_by(fn {_, val} -> val end, :desc)
  end

  defp build_selectable_months(dates) do
    dates
    |> Enum.map(fn d -> {d.year, d.month} end)
    |> Enum.uniq()
    |> Enum.map(fn {year, month} ->
      first_day = Date.new!(year, month, 1)
      translated_month = Gettext.gettext(DtuAppWeb.Gettext, Calendar.strftime(first_day, "%B"))
      label = "#{translated_month} #{first_day.year}"
      {label, Date.to_string(first_day)}
    end)
    |> Enum.sort_by(fn {_, val} -> val end, :desc)
  end

  defp build_selectable_years(dates) do
    dates
    |> Enum.map(& &1.year)
    |> Enum.uniq()
    |> Enum.map(fn year ->
      {to_string(year), to_string(year)}
    end)
    |> Enum.sort(:desc)
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
        today_local = local_today(tz_offset_seconds)

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
              List.first(selectable) || local_today(tz_offset_seconds)
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
              latest_date = List.first(selectable) || local_today(tz_offset_seconds)
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
              latest_date = List.first(selectable) || local_today(tz_offset_seconds)
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
              latest_date = List.first(selectable) || local_today(tz_offset_seconds)
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
        today_local = local_today(tz_offset_seconds)

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

        today_local = local_today(tz_offset_seconds)

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
        <% else %>
          <!-- Toolbar: Switcher & Time Ranges -->
          <div class="flex flex-col gap-4">
            <!-- DTU Switcher -->
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

              <%!-- Share cluster: anonymous current-day dashboard share.
                   Switch toggles a row in `shared_links`; when on, the
                   plaintext URL appears next to it for one-shot copy.
                   `ms-auto` pins the cluster to the right edge of the
                   toolbar row so the quick-range buttons keep their
                   left-aligned grouping. --%>
              <div
                class="flex flex-wrap items-center gap-2 ms-auto border border-zinc-200 dark:border-zinc-700 bg-zinc-50/80 dark:bg-zinc-800/40 p-1.5 rounded-xl max-w-max"
                id="share-cluster"
              >
                <label
                  id="share-toggle-label"
                  class="flex items-center gap-2 px-2.5 py-1.5 rounded-lg cursor-pointer select-none transition"
                  title={gettext("Share today's dashboard read-only")}
                >
                  <.icon name="hero-share" class="size-4 text-zinc-500 dark:text-zinc-400" />
                  <span class="text-xs font-semibold text-zinc-700 dark:text-zinc-200">
                    {gettext("Share")}
                  </span>
                  <%!-- The visible switch: a checkbox styled as a pill
                       with a sliding dot. `peer-checked:` Tailwind
                       variants flip the on-colors without a separate
                       state class — same accessibility surface as a
                       real checkbox, just skinned to match the rest
                       of the toolbar. --%>
                  <span class="relative inline-flex items-center">
                    <input
                      type="checkbox"
                      id="share-toggle"
                      phx-click="toggle_share"
                      phx-value-enabled={to_string(!@share_active?)}
                      checked={@share_active?}
                      class="peer sr-only"
                    />
                    <span class="w-8 h-4 rounded-full bg-zinc-300 dark:bg-zinc-600 peer-checked:bg-emerald-500 transition-colors"></span>
                    <span class="absolute left-0.5 top-0.5 size-3 rounded-full bg-white shadow transition-transform peer-checked:translate-x-4"></span>
                  </span>
                </label>

                <%= if @share_loading? do %>
                  <%!-- Inline spinner shown while the token is being
                       minted (see `toggle_share` + `handle_info
                       ({:mint_share_token, _}, _)`). The label is
                       screen-reader-friendly via `aria-live="polite"`
                       so assistive tech announces the in-flight state
                       without interrupting the user. --%>
                  <div
                    id="share-loading-row"
                    class="flex items-center gap-1.5 text-xs text-zinc-500 dark:text-zinc-400"
                    aria-live="polite"
                  >
                    <.icon
                      name="hero-arrow-path"
                      class="size-3.5 animate-spin text-emerald-500"
                    />
                    <span>{gettext("Generating link…")}</span>
                  </div>
                <% end %>

                <%= if @share_active? and @share_url do %>
                  <div
                    id="share-url-row"
                    class="flex items-center gap-1.5"
                  >
                    <input
                      type="text"
                      id="share-url-input"
                      readonly
                      value={@share_url}
                      class="w-72 max-w-[40vw] px-2.5 py-1.5 text-xs font-mono rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-800 text-zinc-800 dark:text-zinc-100 focus:outline-none focus:ring-1 focus:ring-emerald-500"
                      data-value={@share_url}
                      phx-hook="CopyToClipboard"
                      onfocus="this.select()"
                      aria-label={gettext("Shareable URL")}
                    />
                    <button
                      type="button"
                      id="btn-share-copy"
                      title={gettext("Copy URL")}
                      aria-label={gettext("Copy URL")}
                      class="p-1.5 rounded-lg text-zinc-600 hover:text-zinc-900 dark:text-zinc-300 dark:hover:text-white hover:bg-zinc-200/50 dark:hover:bg-zinc-700/50 transition"
                      data-value={@share_url}
                      phx-hook="CopyToClipboardWithHint"
                    >
                      <.icon name="hero-clipboard-document" class="size-4" />
                    </button>
                    <%!-- Visually hidden until the copy hook adds the
                         `.visible` class on success. `aria-live="polite"`
                         so screen readers announce the copied state
                         without stealing focus. --%>
                    <span
                      id="share-copy-hint"
                      class="text-xs font-semibold text-emerald-600 dark:text-emerald-400 opacity-0 transition-opacity"
                      aria-live="polite"
                    >
                      {gettext("Copied!")}
                    </span>
                  </div>
                <% end %>
              </div>

              <!-- Historical stepper: ‹ [Granularity ▾] [Date ▾] › — only rendered
                   when the user picked the `Custom` preset; the
                   1D/7D/30D/YTD presets already encode their own
                   window and don't need the stepper UI. -->
              <%= if @range_preset == "custom" do %>
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

                  <!-- Date label: clicking reveals the native calendar -->
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
            <%!-- The grid's `lg:` column count must match the actual
                 number of cards rendered below, otherwise users without
                 the conditional cards (savings without a configured rate,
                 self-consumption without a Shelly, etc.) see a row of
                 three cards with three empty grid columns. Three baseline
                 cards (yield, peak power, peak time) plus up to four
                 conditional cards (current power on 1D, savings when a rate
                 is set, current consumption when a Shelly is paired,
                 self-consumption when a Shelly is paired and the helper
                 returned a number).

                 Each possible `cols` value maps to a literal Tailwind
                 class below — Tailwind v4's source-based JIT doesn't
                 detect interpolated class strings, so we list them
                 statically via `cond`. The `cond` arms map to
                 `lg:grid-cols-3` … `lg:grid-cols-7`; a user with every
                 card visible lands on 7. --%>
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
              <%!-- Card 0: Current Power (W). 1D-only — a live
                 "what's the inverter producing right now" signal that
                 doesn't make sense for historical periods (7D, 30D,
                 YTD, Custom). Hidden when the seeded value is 0 so a
                 quiet inverter doesn't pollute the row. Sits at the
                 start of the grid so the live signal is the first
                 thing the user reads on the today view. --%>
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
                              {Devices.format_number(@stats.current_power, 0, @locale)} W
                            </div>
                          </dd>
                        </dl>
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>

              <%!-- Card 1: Yield (kWh). The headline number stays the
                 same shape — `total_yield` rounded to one decimal —
                 whether the period is today, a week, a month, or a
                 year. The sub-label below the headline names the
                 period ("Today", "Last 7 days", etc.) so the user
                 knows what window the kWh figure covers. --%>
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
                            {Devices.format_number(@stats.total_yield, 1, @locale)} kWh
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

              <%!-- Card 2: Peak Power (W). The same headline number
                 across all presets — `stats.peak_power` — but the
                 underlying query changes (today's `bucket_max` vs the
                 range-wide peak via `compute_peak_watts_in_period/4`).
                 A user on 7D sees the highest single bucket over the
                 last 7 days, not the daily peak. --%>
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
                            {Devices.format_number(@stats.peak_power, 0, @locale)} W
                          </div>
                        </dd>
                      </dl>
                    </div>
                  </div>
                </div>
              </div>

              <%!-- Card 3: Peak Time. The bucket time of the peak
                 wattage above, formatted in the user's local timezone
                 (the underlying DateTime is UTC; `format_peak_time/2`
                 adds the tz offset and emits HH:MM). The card falls
                 back to `—` when the window has no readings. --%>
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
                            {format_peak_time(@stats.peak_time, @user_tz_offset_seconds)}
                          </div>
                        </dd>
                      </dl>
                    </div>
                  </div>
                </div>
              </div>

              <%!-- Card 4: Self-consumption (%). Period-aware:
                 `(production - exported) / production × 100`. Hidden
                 when the user has no consumption devices (no Shelly
                 paired) — `self_consumption_pct == nil` is the helper's
                 "no scope" signal, the consumption card's
                 `current_consumption > 0` is the dashboard-level
                 guard. The card clamps at 0 % (not negative) when
                 export exceeds production (battery edge case). --%>
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
                              {Devices.format_number(@stats.self_consumption_pct, 1, @locale)} %
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
                 Hidden when nil so a brand-new user without a rate
                 doesn't see a misleading "€0.00 saved" claim. --%>
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
                              {Devices.format_savings(@savings)}
                            </div>
                          </dd>
                        </dl>
                        <p class="mt-1 text-xs text-zinc-400 dark:text-zinc-500">
                          {gettext("at %{rate}",
                            rate:
                              if(is_integer(@cents_per_kwh),
                                do: Devices.format_savings(@cents_per_kwh),
                                else: "—"
                              )
                          )}
                        </p>
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>

              <%!-- Current Consumption card: only visible when the user
                 has paired a Shelly Plus 3EM (Gen3+) energy meter.
                 Sits in the same headline row because it's also a top-
                 of-dashboard signal — a 5-up grid can absorb one
                 conditional card cleanly on lg screens. --%>
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
                              {Devices.format_number(
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
                      <% ystroke_hex = tooltip_to_hex(ybase, yshade) %>
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
                      <% stroke_hex = tooltip_to_hex(base, shade) %>
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
                      <% total_stroke_hex = tooltip_to_hex(tbase, tshade) %>
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
                      <% consumption_stroke_hex = tooltip_to_hex(cbase, cshade) %>
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
                      <% net_stroke_hex = tooltip_to_hex(nbase, nshade) %>
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

              navigator.clipboard.writeText(text).then(() => {
                if (this.hint) {
                  this.hint.classList.add("opacity-100")
                  this.hint.classList.remove("opacity-0")
                }

                this.el.classList.add("copied")
                const svg = this.el.querySelector("svg")

                if (svg) {
                  svg.dataset.originalClass = svg.getAttribute("class") || ""
                  svg.setAttribute("class", "size-4 text-emerald-500")
                }

                clearTimeout(this._resetTimer)
                this._resetTimer = setTimeout(() => {
                  if (this.hint) {
                    this.hint.classList.add("opacity-0")
                    this.hint.classList.remove("opacity-100")
                  }

                  this.el.classList.remove("copied")

                  if (svg) {
                    svg.setAttribute("class", svg.dataset.originalClass || "")
                  }
                }, 1500)
              }).catch((err) => {
                console.error("CopyToClipboardWithHint hook: copy failed", err)
              })
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
    </Layouts.app>
    """
  end
end
