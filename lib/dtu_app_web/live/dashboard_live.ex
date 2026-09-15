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

  # Per-device status card rendered in the dashboard's
  # device-status grid. Extracted from the inline heex block
  # (formerly lines 2027-2181 of `dashboard_live.html.heex`)
  # so the per-device card has its own unit-test surface and
  # the dashboard template stays focused on page-level layout.
  import DtuAppWeb.DeviceStatusCard, only: [device_status_card: 1]

  # The "Power consumption" row (Total / Today's / Peak) rendered
  # between the production stat_card_row and the chart panel.
  # Extracted from the inline heex block (formerly lines 300-492 of
  # `dashboard_live.html.heex`) so the per-card render branches
  # (live/day view vs. historical view; the Total placeholder; the
  # Peak Power Day peak_date sub-label) have a stable unit-test
  # surface. Mirrors the production-side `<.stat_card_row>` pattern
  # from PR #269.
  import DtuAppWeb.ConsumptionStatCards, only: [consumption_stat_cards: 1]

  # The "Net flow" row (Current Net Flow / Exported today /
  # Imported today / Peak power) rendered between the consumption
  # row and the chart panel. Only visible for paired-inverter-and-
  # shelly users. Extracted from the inline heex block (formerly
  # lines 313-498 of `dashboard_live.html.heex`) so the
  # sign-aware "Current Net Flow" card (the only card whose label
  # + colour + absolute-value branches off `current_net_flow >= 0`)
  # has a stable unit-test surface.
  import DtuAppWeb.NetFlowStatCards, only: [net_flow_stat_cards: 1]

  # The `<h2 id="chart-title">` heading above the chart panel.
  # Extracted from the inline 9-case `<%= cond do %>` block
  # (formerly lines 334-360 of `dashboard_live.html.heex`) so
  # the German-only month-name branch (the one place the
  # template calls `Gettext.gettext/2` directly instead of the
  # `gettext/1` macro on the Gettext backend) has a stable
  # unit-test surface.
  import DtuAppWeb.ChartTitle, only: [chart_title: 1]

  # The bar chart fallback panel — rendered when the dashboard's
  # `@chart_type` resolves to a non-`:line` variant (week / month /
  # year / 7d / 30d / ytd). The dashboard template keeps the
  # `@chart_type` switch and decides which panel to invoke; this
  # component owns the bar-specific SVG, empty-state, and palette.
  import DtuAppWeb.BarChartPanel, only: [bar_chart_panel: 1]

  # The primary line chart panel - rendered when the dashboard's
  # `@chart_type` resolves to `:line` (today / historical day / week
  # / month / year views). The component owns the full SVG, the
  # legend strip, the empty-state, and the colocated `.ChartTooltip`
  # JS hook that paints the cursor guide and the now-marker live
  # tick. The dashboard template keeps the `@chart_type` switch and
  # decides which panel to invoke; this component owns the line-
  # specific rendering, palette, and event handling. Sister to
  # `DtuAppWeb.BarChartPanel` (PR #278).
  import DtuAppWeb.LineChartPanel, only: [line_chart_panel: 1]

  # The anonymous current-day dashboard share panel — rendered below
  # the chart so the URL row never has to compete for horizontal
  # space with the quick-range / period stepper. The component owns
  # the toggle row, the three-state inner row (spinner / URL row +
  # copy button / static hint), and the colocated `.CopyToClipboardWithHint`
  # + `.SelectOnFocus` JS hooks. The dashboard still owns the
  # `@share_loading?` / `@share_active?` / `@share_url` assigns and
  # the `toggle_share` event handler — those ride along on every
  # render and don't need a separate component. Sister to
  # `DtuAppWeb.LineChartPanel` (PR #279).
  import DtuAppWeb.SharePanel, only: [share_panel: 1]

  # The first-visit onboarding panel rendered when the user has
  # no DTUs yet (`@devices == []`). Bundles the welcome card
  # (bolt icon + heading + MQTT-explainer paragraph + Add-your-
  # first-DTU CTA) with the quieter "How it works" three-step
  # rail that sits beneath it. The component takes only
  # `@locale`; the dashboard's outer template keeps the
  # `if @devices == []` guard. Sister to
  # `DtuAppWeb.SharePanel` (PR #280).
  import DtuAppWeb.OnboardingPanel, only: [onboarding_panel: 1]

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
end
