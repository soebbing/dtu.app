defmodule DtuApp.Notifications.DtuConnection do
  @moduledoc """
  Server-side producer for `event: "dtu_connection"` notifications.

  Subscribes to the broker's presence topic (`dtu:presence`) and fires
  `DtuApp.Notifications.broadcast/2` on every CONNECT / DISCONNECT. The
  receiver side (in-page JS hook + native Web Push) does the user-
  visible work; this module is the producer that lives **outside** the
  LiveView, so notifications also fire when the user has no tab open.

  History: this logic used to live in `DashboardLive.handle_info/2` —
  the dashboard subscribed to the same `dtu:presence` PubSub topic and
  fired `broadcast_dtu_connection/3` from its own `handle_info/2`
  clauses. That meant notifications only fired while a dashboard LiveView
  process was alive. Closing the tab (or never opening `/dashboard`)
  silently disabled the notification. Moving the producer into a
  supervised GenServer fixes that — the supervisor keeps the producer
  alive across every nav, deploy, and disconnected tab.

  Per-device state (`%{device_id => %{user_id, name, last_seen_at,
  disconnected?, connected_at}}`) is maintained so a CONNECT that
  follows a DISCONNECT cleanly cancels the offline marker. The
  cache is bounded by the user's device count and is not explicitly
  GC'd today; in practice it stays small (one entry per device the
  broker has ever announced, capped at fleet size).

  The per-device marker (`disconnected`, `last_seen_at`,
  `connected_at`) is mirrored into the `dtu_connection_states`
  table on every transition, and re-hydrated from there on
  `init/1`. The in-memory cache is the hot path; the DB row is the
  recovery path — without it, any GenServer restart would wipe the
  cache and let the very next `:dtu_connected` event for a device
  that was already on the broker at boot fire `:back_online` (a
  duplicate "your inverter is publishing telemetry again" push).
  `user_id` and `name` are NOT stored in the row — those are
  recovered on demand via `Repo.get(Dtu, device_id)` at the next
  `:dtu_*` event for the device (the producer's existing
  `safe_lookup/1` already does this).

  Per-event preference gating is now **producer-level**: when
  `user.notify_dtu_connection == false` the producer itself skips
  `fire_for_status/2`, so no in-page PubSub event, no native push,
  and no `notifications` history row are produced. This matches the
  user-facing semantics of `notify_sun_up` (a single low-value ping
  that should be silent when off) and the same rationale that drove
  SunDown to a producer-level gate in the same revision.

  Disconnect gating is layered (all conditions must hold):
    * `recently_active?(last_seen_at)` — `last_seen_at` must be
      within `@recency_seconds` (5 min). Without this guard, the very
      first MQTT disconnect after a server restart would fire on a DTU
      that was already offline before the server restarted, spamming
      the user. Recent-active = "this is a real offline event"; stale =
      "the broker just reconnected to a DTU that was already dead."
    * `prior_uptime?(connected_at)` — the device must have been online
      for at least `@prior_uptime_seconds` (15 min) before the
      disconnect. Without this guard, a brief WiFi reconnect storm
      (connect → 30s later disconnect) would fire "Your inverter has
      gone offline" on a device that was never actually online long
      enough to merit one. 15 min was chosen over the original 5 min
      after user reports of "dozens of offline pushes" from inverters
      that flap every few minutes — a 5-min threshold still lets
      long-cycle flappers through, a 15-min threshold requires a
      genuinely stable session before a disconnect is notification-
      worthy.
    * `not was_disconnected?` — the prior `disconnected?` flag (read
      BEFORE `remember_disconnect/2` mutates it) must be false. This
      is the duplicate-fire gate: a burst of `:dtu_disconnected`
      events arriving without an intervening `:dtu_connected`
      produces exactly one `:went_offline`, not dozens. The first
      event transitions online → offline (fires); the rest stay
      offline → offline (silent). Symmetric with the connect-side
      `disconnected?: true` gate. The DB-backed
      `dtu_connection_states.disconnected` row carries the suppression
      across producer restarts.
    * `cooldown_over?(last_offline_fired_at)` — the per-device
      `last_offline_fired_at` timestamp must be older than
      `@cooldown_seconds` (30 min), OR nil (never fired). This is
      orthogonal to `was_disconnected?` — that gate only suppresses
      duplicate fires within ONE offline period; this gate suppresses
      re-fires across MANY offline periods when a device flaps in
      short cycles (connect → disconnect → reconnect → disconnect…)
      and each cycle is long enough to satisfy `prior_uptime?`. A
      user-reported failure mode: a WiFi-fragile inverter that drops
      every 20 min generated one push per cycle. The 30-min cooldown
      caps that at one push per 30-min window per device. The
      timestamp is kept in the in-memory cache only — restart resets
      it. We don't persist across deploys because a deploy landing
      mid-flap-cycle shouldn't lock the user out of a genuine-outage
      notification for 30 min post-deploy.
  """

  use GenServer

  use Gettext, backend: DtuAppWeb.Gettext

  require Logger

  import Ecto.Query, only: [from: 2]

  alias DtuApp.Devices.Dtu
  alias DtuApp.Notifications
  alias DtuApp.Notifications.Dispatcher
  alias DtuApp.Notifications.DtuConnectionState
  alias DtuApp.Repo
  alias DtuApp.Time
  alias DtuApp.Accounts.User

  @presence_topic "dtu:presence"

  # Same 5-min threshold the previous in-LiveView check used (see
  # git history of `dashboard_live.ex` before this module existed).
  # A disconnect whose `last_seen_at` is older than this is treated as
  # a stale post-deploy reconnect, not a real offline event.
  @recency_seconds 300

  # The "must have been online continuously for X before a disconnect
  # is notification-worthy" threshold. Raised from the historical
  # `@recency_seconds` (5 min) after user reports that inverters which
  # flap every few minutes (connect → ~10 min later → disconnect →
  # reconnect → ~10 min later → disconnect …) still produced one push
  # per cycle. 15 min catches the long-cycle flapper without dropping
  # notifications on devices that genuinely reconnect and stay up.
  @prior_uptime_seconds 900

  # Per-device re-fire cooldown. After a `:went_offline` fires, the
  # same device is suppressed for this many seconds — even across
  # connect/disconnect cycles. See the moduledoc's disconnect-gating
  # paragraph for the design rationale.
  @cooldown_seconds 1800

  @doc "The PubSub topic this producer subscribes to. Exposed for tests."
  def presence_topic, do: @presence_topic

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    Phoenix.PubSub.subscribe(DtuApp.PubSub, @presence_topic)
    Logger.info("[Notifications.DtuConnection] subscribed to #{@presence_topic}")
    # Hydrate the in-memory cache from the persistent marker table.
    # `disconnected` and `connected_at` survive across restarts; the
    # `last_seen_at` field is intentionally NOT preloaded here
    # because it's read from the live `dtus.last_seen_at` column on
    # the disconnect path (the recency guard needs the freshest
    # possible reading, not the cached-at-write-time value).
    # `user_id` / `name` are recovered on the next `:dtu_*` event
    # for that device via `safe_lookup/1`.
    {:ok, hydrate_persisted_markers()}
  end

  # Read all `dtu_connection_states` rows and turn them into the
  # initial in-memory cache shape. Rows that have `disconnected: true`
  # are the only ones that matter at boot — a `disconnected: false`
  # row is the same as no row at all (the producer only consults the
  # marker on the connect path to decide "should I fire back_online?").
  # We preserve both shapes verbatim so the connect-path case-match
  # (`%{disconnected?: true, last_seen_at: %DateTime{}}`) still
  # works after a restart.
  defp hydrate_persisted_markers do
    from(s in DtuConnectionState, where: s.disconnected == true)
    |> Repo.all()
    |> Map.new(fn %DtuConnectionState{device_id: id, connected_at: connected_at} ->
      # `last_seen_at` is not loaded from the DB on hydrate — see
      # `init/1` comment. The disconnect-side recency guard reads
      # `dtus.last_seen_at` fresh from the DB on every disconnect
      # anyway, so a stale cached value here would only break the
      # connect-side recency guard. We stamp `nil` and rely on the
      # fact that the connect-side gate requires `disconnected?:
      # true` AND `last_seen_at: %DateTime{}` — without the
      # latter, the connect path falls through silently (no fire).
      # A restart that re-fires `:back_online` would only happen if
      # the broker reconnects to a previously-disconnected DTU
      # within 5 min of the prior disconnect; in practice that's
      # vanishingly rare and the conservative answer (don't fire
      # until we re-confirm) is the safer one.
      {id,
       %{
         user_id: nil,
         name: nil,
         last_seen_at: nil,
         disconnected?: true,
         connected_at: connected_at
       }}
    end)
  end

  @impl true
  def handle_info({:dtu_connected, _client_id, device_id}, state) when is_integer(device_id) do
    # Fix A: only fire `:back_online` if the producer has previously
    # seen a disconnect for this device. Without this gate, every
    # MQTT re-connect (WiFi blip, broker restart, deploy) fires a
    # notification even though the device was never offline from
    # the user's perspective. The `disconnected?` marker was
    # already being tracked in state — this is the first time it's
    # actually consulted on the connect path.
    #
    # Fix B: mirror the existing recency guard on the connect side.
    # If `last_seen_at` is older than @recency_seconds, the reconnect
    # is a stale post-deploy re-attachment, not a recovery from a
    # real outage.
    #
    # IMPORTANT: read the prior `disconnected?` flag BEFORE
    # `clear_disconnect_marker/2` resets it. The two operations
    # must happen in this order — calling clear first would mean
    # the case-match on `disconnected?: true` can never succeed
    # and the back-online path becomes a dead branch.
    case Map.get(state, device_id) do
      %{disconnected?: true, last_seen_at: %DateTime{} = last_seen_at} ->
        if recently_active?(last_seen_at) do
          fire_for_status(device_id, :back_online)
        end

      _ ->
        :ok
    end

    state = clear_disconnect_marker(state, device_id)
    {:noreply, state}
  end

  def handle_info({:dtu_connected, _client_id, _device_id}, state), do: {:noreply, state}

  def handle_info({:dtu_disconnected, _client_id, device_id}, state)
      when is_integer(device_id) do
    # Read the prior `disconnected?` flag BEFORE
    # `remember_disconnect/2` mutates it. The fire is gated on
    # `was_disconnected? == false` (i.e. we observed the offline
    # *transition* this time, not a duplicate event for an
    # already-noted offline period). Without this gate the very
    # common "broker disconnect storm" pattern (multiple
    # `:dtu_disconnected` events arriving within seconds, no
    # `:dtu_connected` in between) fires `:went_offline` on each
    # one — the user reports "dozens of dtus-offline pushes in a
    # row". The first event transitions online → offline (fires);
    # the rest stay offline → offline (silent). Symmetric with the
    # connect-side `disconnected?: true` gate added in PR #167.
    was_disconnected? =
      case Map.get(state, device_id) do
        %{disconnected?: true} -> true
        _ -> false
      end

    state = remember_disconnect(state, device_id)

    case safe_lookup(device_id) do
      nil ->
        {:noreply, state}

      %{user_id: _user_id, name: _name, last_seen_at: last_seen_at} ->
        # Fix C1: in addition to the existing recency guard on
        # `last_seen_at`, require the device to have been online
        # for at least @prior_uptime_seconds before we call it
        # "offline". Without this gate, a brief WiFi reconnect
        # (connect → 30s later disconnect) would fire "Your inverter
        # has gone offline" — a misleading notification on a device
        # that was never actually online long enough to merit one.
        # 15 min was chosen over the historical 5 min after user
        # reports of long-cycle flap storms. `connected_at` is
        # recorded in state at connect-time below.
        connected_at = get_connected_at(state, device_id)

        # Per-device re-fire cooldown. Read BEFORE the fire — the
        # gate fires on `cooldown_over?` (which is true for `nil`
        # and for timestamps older than @cooldown_seconds). If all
        # four gates pass, the fire path stamps the current time
        # into state via `remember_offline_fire/2` so the next
        # disconnect within @cooldown_seconds is gated silent.
        last_fired_at = get_last_offline_fired_at(state, device_id)

        # The `if` expression returns its last value; the `else`
        # branch yields `state` unchanged when any gate fails.
        # Without the explicit `else`, Elixir would warn about an
        # unused reassignment inside the `if` block (the `if`
        # body is its own scope, so a re-bound `state` inside it
        # would not be visible to the `{:noreply, state}` below).
        state =
          if recently_active?(last_seen_at) and prior_uptime?(connected_at) and
               not was_disconnected? and cooldown_over?(last_fired_at) do
            # Route through `fire_for_status/2` so we share the
            # User-struct lookup with the connect path — `fire/3`
            # takes a `%User{}` (we need the user's locale to scope
            # gettext), not a bare user_id. A stale-state race where
            # the user has been deleted between the safe_lookup and
            # fire_for_status is handled inside safe_get_user/1
            # (`nil → :ok` no-op).
            fire_for_status(device_id, :went_offline)
            remember_offline_fire(state, device_id)
          else
            state
          end

        {:noreply, state}
    end
  end

  def handle_info({:dtu_disconnected, _client_id, _device_id}, state), do: {:noreply, state}

  # Trap exits to match the sibling Telemetry GenServer's defensive
  # pattern (long-lived process that outlives individual queries —
  # see the comment in `DtuApp.MqttBroker.Telemetry.init/1`).
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # Devices we haven't seen yet: store user_id + name on first sight
  # so the disconnect path doesn't repeat the DB lookup. The
  # `connected_at` from the prior connect path is preserved if
  # present — the disconnect-side C1 gate reads it to enforce the
  # "must have been online for >= @recency_seconds" rule.
  defp remember_disconnect(state, device_id) do
    state =
      case Map.get(state, device_id) do
        nil ->
          case safe_lookup(device_id) do
            nil -> state
            info -> Map.put(state, device_id, Map.put(info, :disconnected?, true))
          end

        info ->
          Map.put(state, device_id, Map.put(info, :disconnected?, true))
      end

    # Mirror the marker to the DB so the next GenServer restart
    # picks it up. `last_seen_at` comes from the live `Dtu` row
    # (the recency guard's source of truth) so the connect path's
    # recency check stays correct after a restart. A DB failure here
    # is logged and dropped — the in-memory cache still drives the
    # current process, and the worst case is "the next restart loses
    # this marker", which degrades to the old duplicate-fire
    # behaviour, not a crash.
    last_seen_at =
      case safe_lookup(device_id) do
        %{last_seen_at: ts} when not is_nil(ts) -> ts
        _ -> nil
      end

    persist_marker(device_id, %{
      disconnected: true,
      last_seen_at: last_seen_at
    })

    state
  end

  defp clear_disconnect_marker(state, device_id) do
    connected_at = Time.utc_now()
    updated = %{disconnected?: false, connected_at: connected_at}

    state =
      case Map.get(state, device_id) do
        nil ->
          # First sight — pre-seed the cache so a later disconnect
          # doesn't pay a second DB lookup. Stamp `connected_at` at
          # the current DB-clock time so the disconnect-side C1 gate
          # can compare it to `last_seen_at` and reject brief-connection
          # cases.
          case safe_lookup(device_id) do
            nil -> state
            info -> Map.put(state, device_id, Map.merge(info, updated))
          end

        info ->
          Map.put(state, device_id, Map.merge(info, updated))
      end

    # Mirror the connect-side reset to the DB. `last_seen_at` comes
    # from the live `Dtu` row when available, falling back to `nil`
    # (no device, no reading). The DB row's `connected_at` is the
    # fresh stamp — it's what the disconnect-side C1 gate compares
    # against to enforce "device was online for >= @recency_seconds"
    # after a restart.
    last_seen_at =
      case safe_lookup(device_id) do
        %{last_seen_at: ts} when not is_nil(ts) -> ts
        _ -> nil
      end

    persist_marker(device_id, %{
      disconnected: false,
      last_seen_at: last_seen_at,
      connected_at: connected_at
    })

    state
  end

  # Upsert the persistent marker for `device_id`. We do NOT use
  # `Repo.insert_or_update` (it would query before deciding) — a
  # single `INSERT … ON CONFLICT DO UPDATE` covers both branches
  # in one round trip. Errors are logged at `:warning` (not `:error`)
  # because the in-memory cache is the source of truth for the
  # current process; the DB row is purely the recovery path.
  defp persist_marker(device_id, attrs) do
    set_fields =
      attrs
      |> Map.take([:disconnected, :last_seen_at, :connected_at])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    %DtuConnectionState{}
    |> DtuConnectionState.changeset(Map.put(attrs, :device_id, device_id))
    |> Repo.insert(
      on_conflict: [set: set_fields],
      conflict_target: :device_id
    )
    |> case do
      {:ok, _row} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "[Notifications.DtuConnection] persist_marker failed device_id=#{device_id} errors=#{inspect(changeset.errors)}"
        )

        :ok
    end
  end

  defp get_connected_at(state, device_id) do
    case Map.get(state, device_id) do
      %{connected_at: %DateTime{} = at} -> at
      _ -> nil
    end
  end

  # C1 gate: the device must have been online for at least
  # @prior_uptime_seconds before a disconnect can be called "offline".
  # `connected_at` is stamped at every connect (above); a `nil`
  # value means we've never seen a connect for this device — the
  # conservative answer is to suppress the fire (we have no way
  # to confirm prior uptime).
  defp prior_uptime?(%DateTime{} = connected_at) do
    DateTime.before?(connected_at, DateTime.add(Time.utc_now(), -@prior_uptime_seconds, :second))
  end

  defp prior_uptime?(_), do: false

  # Read the timestamp of the most recent `:went_offline` fire for this
  # device. `nil` when we have never fired (the common case for the
  # very first disconnect of a device).
  defp get_last_offline_fired_at(state, device_id) do
    case Map.get(state, device_id) do
      %{last_offline_fired_at: %DateTime{} = at} -> at
      _ -> nil
    end
  end

  # Cooldown gate: returns true if the per-device re-fire window is
  # open. `nil` (never fired) is always open. A timestamp within
  # `@cooldown_seconds` is closed (suppress the fire). A timestamp
  # older than `@cooldown_seconds` is open (allow the fire).
  defp cooldown_over?(nil), do: true

  defp cooldown_over?(%DateTime{} = last_fired_at) do
    DateTime.before?(
      last_fired_at,
      DateTime.add(Time.utc_now(), -@cooldown_seconds, :second)
    )
  end

  # Stamp `last_offline_fired_at` on the device's state entry so the
  # next disconnect within `@cooldown_seconds` is gated silent by
  # `cooldown_over?/1`. No-op for devices we have no entry for — the
  # caller is responsible for only stamping after a successful fire.
  defp remember_offline_fire(state, device_id) do
    case Map.get(state, device_id) do
      nil ->
        state

      info ->
        Map.put(state, device_id, Map.put(info, :last_offline_fired_at, Time.utc_now()))
    end
  end

  defp safe_lookup(device_id) do
    try do
      case Repo.get(Dtu, device_id) do
        nil ->
          nil

        %{user_id: user_id, name: name, last_seen_at: last_seen_at} ->
          %{user_id: user_id, name: name, last_seen_at: last_seen_at}
      end
    rescue
      _ -> nil
    end
  end

  defp recently_active?(%DateTime{} = last_seen_at) do
    DateTime.after?(last_seen_at, DateTime.add(Time.utc_now(), -@recency_seconds, :second))
  end

  defp recently_active?(_), do: false

  defp fire_for_status(device_id, status) do
    case safe_lookup(device_id) do
      nil ->
        :ok

      %{user_id: user_id, name: name} ->
        # Look up the User struct (not just the id) so `fire/3` can
        # wrap the gettext calls in the user's locale. The producer
        # runs as a long-lived GenServer without a request context,
        # so a bare `gettext/1` here would default to whatever
        # Gettext was initialized with (≈ "en") regardless of
        # preference — see SunDownNotifier / SunUpNotifier for the
        # parallel pattern.
        case safe_get_user(user_id) do
          nil ->
            :ok

          user ->
            # Producer-level preference gate. `Notifications.broadcast/2`
            # already gates the *native push* path via
            # `native_push_enabled?/2`, but always publishes the
            # in-page PubSub event and records the row in the user's
            # notification history. For `dtu_connection` the user
            # explicitly wants "off = silent everywhere" — same
            # rationale as `SunUp` (see the moduledoc on
            # `Notifications.SunUp`). `SunDown` is the odd one out
            # (see its moduledoc) and keeps the broadcast-always
            # behaviour so the history page still surfaces the
            # summary even when native push is off.
            if user.notify_dtu_connection == true do
              fire(user, name, status)
            end

            :ok
        end
    end
  end

  defp fire(%User{} = user, name, status) do
    Gettext.with_locale(DtuAppWeb.Gettext, user.locale || "en", fn ->
      # Status is the atom (`:went_offline` / `:back_online`) — the
      # dispatcher reads `Push.native_enabled?/2` (which has explicit
      # atom- and string-keyed clauses) so the atom flows through
      # unchanged. The `:status` field on the payload mirrors it for
      # the email / history path.
      payload = %{
        event: "dtu_connection",
        title: dtu_title(status, name),
        # `body` is a list (the email/layout pipeline expects a list
        # of paragraphs; the dispatcher's history-row insert coerces
        # it back to a single string for the `:body` column).
        body: [dtu_body(status, name)],
        # Existing tag semantics kept (Ruling F: prefer existing tag
        # unless the brief's version adds clear value). The brief's
        # `dtu_connection:#{name}:#{status}` would dedup by status,
        # which is redundant — the producer-side `not was_disconnected?`
        # / `disconnected?: true` gates already suppress duplicate
        # fires within a single offline period.
        tag: "dtu:#{name}",
        # Email + history extras. `:dtu_name` and `:status` are the
        # data the email subject + body lines key off; `:since` is
        # the moment the producer observed the state change (used by
        # the email's "at HH:MM" line and by history drill-down UIs).
        dtu_name: name,
        status: status,
        since: DateTime.utc_now()
      }

      # In-page PubSub broadcast for the dashboard LiveView hook
      # (`Notifications.subscribe(user.id)` →
      # `handle_info({:notification, payload}, ...)`). The
      # dispatcher fan-out below handles push + email + history;
      # both call sites are independent and safe.
      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        Notifications.user_topic(user.id),
        {:notification, payload}
      )

      Dispatcher.fire(user, "dtu_connection", payload)
    end)
  end

  defp safe_get_user(user_id) do
    try do
      Repo.get(User, user_id)
    rescue
      _ -> nil
    end
  end

  defp dtu_title(:went_offline, _name), do: gettext("DTU went offline")
  defp dtu_title(:back_online, _name), do: gettext("DTU back online")
  defp dtu_title(_status, name), do: gettext("DTU status changed for %{name}", name: name)

  defp dtu_body(:went_offline, name),
    do: gettext("Your inverter %{name} has gone offline.", name: name)

  defp dtu_body(:back_online, name),
    do: gettext("Your inverter %{name} is publishing telemetry again.", name: name)
end
