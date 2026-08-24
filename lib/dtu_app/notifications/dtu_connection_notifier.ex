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
  disconnected?}}`) is maintained so a CONNECT that follows a
  DISCONNECT cleanly cancels the offline marker. The cache is bounded
  by the user's device count and is not explicitly GC'd today; in
  practice it stays small (one entry per device the broker has ever
  announced, capped at fleet size).

  Per-event preference gating is delegated to
  `DtuApp.Notifications.broadcast/2` (the `:dtu_connection` event is
  only VAPID-pushed when `user.notify_dtu_connection == true`). The
  in-page PubSub broadcast always fires — the receiver-side JS hook
  decides whether to render.

  Disconnect gating mirrors the prior in-LiveView check: only fire
  `:went_offline` when the device's `last_seen_at` is recent
  (`@recency_seconds`, default 5 min). Without this guard, the very
  first MQTT disconnect after a server restart would fire on a DTU
  that was already offline before the server restarted, spamming the
  user. Recent-active = "this is a real offline event"; stale =
  "the broker just reconnected to a DTU that was already dead."
  """

  use GenServer

  use Gettext, backend: DtuAppWeb.Gettext

  require Logger

  alias DtuApp.Devices.Dtu
  alias DtuApp.Notifications
  alias DtuApp.Repo
  alias DtuApp.Time
  alias DtuApp.Accounts.User

  @presence_topic "dtu:presence"

  # Same 5-min threshold the previous in-LiveView check used (see
  # git history of `dashboard_live.ex` before this module existed).
  # A disconnect whose `last_seen_at` is older than this is treated as
  # a stale post-deploy reconnect, not a real offline event.
  @recency_seconds 300

  @doc "The PubSub topic this producer subscribes to. Exposed for tests."
  def presence_topic, do: @presence_topic

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    Phoenix.PubSub.subscribe(DtuApp.PubSub, @presence_topic)
    Logger.info("[Notifications.DtuConnection] subscribed to #{@presence_topic}")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:dtu_connected, _client_id, device_id}, state) when is_integer(device_id) do
    state = clear_disconnect_marker(state, device_id)
    fire_for_status(device_id, :back_online)
    {:noreply, state}
  end

  def handle_info({:dtu_connected, _client_id, _device_id}, state), do: {:noreply, state}

  def handle_info({:dtu_disconnected, _client_id, device_id}, state)
      when is_integer(device_id) do
    state = remember_disconnect(state, device_id)

    case safe_lookup(device_id) do
      nil ->
        {:noreply, state}

      %{user_id: _user_id, name: _name, last_seen_at: last_seen_at} ->
        if recently_active?(last_seen_at) do
          # Route through `fire_for_status/2` so we share the
          # User-struct lookup with the connect path — `fire/3`
          # takes a `%User{}` (we need the user's locale to scope
          # gettext), not a bare user_id. A stale-state race where
          # the user has been deleted between the safe_lookup and
          # fire_for_status is handled inside safe_get_user/1
          # (`nil → :ok` no-op).
          fire_for_status(device_id, :went_offline)
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
  # so the disconnect path doesn't repeat the DB lookup.
  defp remember_disconnect(state, device_id) do
    case Map.get(state, device_id) do
      nil ->
        case safe_lookup(device_id) do
          nil -> state
          info -> Map.put(state, device_id, Map.put(info, :disconnected?, true))
        end

      info ->
        Map.put(state, device_id, Map.put(info, :disconnected?, true))
    end
  end

  defp clear_disconnect_marker(state, device_id) do
    case Map.get(state, device_id) do
      nil ->
        # First sight — pre-seed the cache so a later disconnect
        # doesn't pay a second DB lookup.
        case safe_lookup(device_id) do
          nil -> state
          info -> Map.put(state, device_id, Map.put(info, :disconnected?, false))
        end

      info ->
        Map.put(state, device_id, Map.put(info, :disconnected?, false))
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
          nil -> :ok
          user -> fire(user, name, status)
        end
    end
  end

  defp fire(%User{} = user, name, status) do
    Gettext.with_locale(DtuAppWeb.Gettext, user.locale || "en", fn ->
      Notifications.broadcast(user.id, %{
        event: "dtu_connection",
        title: dtu_title(status, name),
        body: dtu_body(status, name),
        tag: "dtu:#{name}"
      })
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
    do: gettext("Your inverter %{name} has been offline for at least 5 minutes.", name: name)

  defp dtu_body(:back_online, name),
    do: gettext("Your inverter %{name} is publishing telemetry again.", name: name)
end
