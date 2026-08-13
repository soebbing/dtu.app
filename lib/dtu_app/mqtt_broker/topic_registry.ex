defmodule DtuApp.MqttBroker.TopicRegistry do
  @moduledoc """
  Live buffer of every MQTT topic a connected DTU has published in the
  last few minutes. Used by the device-details LiveView to show the user
  the raw topics + payloads their firmware is sending — including topics
  the parser doesn't currently interpret, since "unused topic" is not an
  error (it just means a future firmware version publishes something we
  don't yet understand).

  The registry subscribes to `dtu:uplink` (the same PubSub topic the
  parser consumes) and keeps a per-DTU ETS-backed map of
  `topic => {payload, received_at}`. Every uplink also fans out
  `:topic_seen` on `dtu:topics` so subscribed LiveViews can re-fetch
  the affected DTU's snapshot without re-rendering the whole page.

  ## Memory bounds

  Three guards keep the in-memory footprint trivial:

    * **Per-topic staleness** — entries older than
      `@topic_max_age_seconds` (5 min, matching `Dtu.online?/2`) are
      pruned by a periodic `handle_info(:prune)` tick. A DTU that stops
      publishing drops its topics within the window, matching the
      derived online indicator.

    * **Per-DTU topic count cap** — `@max_topics_per_dtu` (200) bounds
      the worst case where a misbehaving firmware publishes thousands
      of unique topics. The cap is applied FIFO on insert: the oldest
      topic for that DTU is dropped when the cap is exceeded.

    * **Per-payload size cap** — payloads larger than
      `@max_payload_bytes` (4 KB) are truncated to that size with a
      trailing ellipsis, matching `Telemetry.format_payload_snippet/1`'s
      display convention. Real OpenDTU/AhoyDTU/Shelly payloads are
      well under 1 KB.

  ## Multi-tenant safety

  `get_topics_for/1` is unconstrained — the caller is expected to
  validate `dtu_id` ownership (the device-details LiveView scopes to the
  current `current_scope.user`'s owned devices). The ETS table stores
  every connected DTU's topics, regardless of which user owns them.

  ## Lifecycle

  Started in `DtuApp.Application` alongside `DtuApp.MqttBroker.Telemetry`
  so both consumers share the same uplink stream. The PubSub subscribe
  fires in `init/1`; the prune tick is scheduled on init and re-armed
  on each pass.
  """

  use GenServer

  require Logger

  alias DtuApp.MqttBroker.Broker

  # PubSub topic for "an uplink just landed" fan-out. Subscribed
  # LiveViews re-fetch the affected DTU's topic snapshot on this event.
  @topic_event_topic "dtu:topics"

  # Topics older than this are pruned on each tick. Matches
  # `Dtu.online?/2`'s 5-minute online threshold so a DTU that just
  # went offline has its topic tree cleared within the same window the
  # online badge flips to offline.
  @topic_max_age_seconds 300

  # Per-DTU topic cap. A real AhoyDTU publishes ~30 topics; a cap of
  # 200 covers a multi-firmware fleet while bounding memory in the
  # "publisher gone wild" worst case.
  @max_topics_per_dtu 200

  # Truncate any single payload to 4 KB. Real OpenDTU / AhoyDTU /
  # Shelly payloads are <1 KB; a multi-KB blob is usually firmware
  # status or a debug dump, neither of which is useful on a single
  # topic row in the tree.
  @max_payload_bytes 4096

  # How often to prune stale entries. One minute is a good balance:
  # fast enough that a fresh "device went offline" reads as such
  # within a minute, slow enough that the prune doesn't wake the
  # BEAM 60×/s.
  @prune_interval_ms :timer.minutes(1)

  # --- Public API -------------------------------------------------------------

  @doc "The PubSub topic `topic_seen` events are broadcast on."
  @spec topics_topic() :: String.t()
  def topics_topic, do: @topic_event_topic

  @doc """
  Subscribe the calling process to per-uplink topic events. The LiveView
  re-fetches the affected DTU's snapshot on each `:topic_seen`.

  The `dtu_id` filter is advisory only — it lets the caller avoid
  re-rendering on events for other DTUs. Subscribe once and filter in
  `handle_info/2`.
  """
  @spec subscribe_topics() :: :ok | {:error, term()}
  def subscribe_topics do
    Phoenix.PubSub.subscribe(DtuApp.PubSub, @topic_event_topic)
  end

  @doc """
  Snapshot of all recently-published topics for `dtu_id` as
  `%{topic => {payload, received_at}}`. Topics not seen within the
  staleness window have already been pruned, so a `nil` return here
  means the DTU has been silent for at least one prune tick.

  Returns an empty map for unknown `dtu_id`s (the ETS table simply has
  no row) — callers don't have to special-case "no data yet".
  """
  @spec get_topics_for(integer()) :: %{String.t() => {String.t(), DateTime.t()}}
  def get_topics_for(dtu_id) when is_integer(dtu_id) do
    case :ets.lookup(table_name(), dtu_id) do
      [{^dtu_id, topics}] -> topics
      [] -> %{}
    end
  end

  def get_topics_for(_), do: %{}

  @doc """
  Test/dev hook to wipe the in-memory cache. Not called from
  production code — the prune tick is the normal cleanup path.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc """
  Test/dev hook to trigger a synchronous prune pass. Returns `:ok`
  once the prune is complete so tests don't have to race the
  mailbox or sleep — the GenServer's call/return semantics guarantee
  the prune has finished by the time the call returns.
  """
  @spec prune_now() :: :ok
  def prune_now do
    GenServer.call(__MODULE__, :prune_now)
  end

  # --- GenServer --------------------------------------------------------------

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(:ok) do
    # ETS table owned by this process. `:set` keyed on `dtu_id`; the
    # value is a `%{topic => {payload, received_at}}` map. `:public`
    # so `get_topics_for/1` can read without round-tripping through the
    # GenServer mailbox (a 5× latency win for the LiveView's snapshot
    # call). Writes still go through the GenServer to serialise the
    # per-DTU FIFO eviction.
    :ets.new(table_name(), [:set, :public, {:read_concurrency, true}, :named_table])

    Broker.subscribe_uplink()
    schedule_prune()
    Logger.info("[TopicRegistry] subscribed to DTU uplinks")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:uplink, _client_id, device_info, topic_str, payload}, state) do
    if is_nil(device_info) do
      # Authless / pre-auth uplink — the broker still emits these for
      # audit-logging but they're not associated with a DTU. Drop
      # silently; the parser's `handle_info/2` does the same.
      {:noreply, state}
    else
      ingest(device_info.id, topic_str, payload)
      broadcast_seen(device_info.id)
      {:noreply, state}
    end
  end

  def handle_info(:prune, state) do
    prune_stale()
    schedule_prune()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(table_name())
    {:reply, :ok, state}
  end

  def handle_call(:prune_now, _from, state) do
    prune_stale()
    {:reply, :ok, state}
  end

  # --- Internals --------------------------------------------------------------

  # ETS table name. `:set` keyed on `dtu_id`. Public reads + serialised
  # writes via the GenServer mailbox.
  defp table_name, do: __MODULE__.Topics

  # Ingest one uplink into the per-DTU topic map. FIFO-eviction when
  # the cap is exceeded, payload truncation when the size cap is
  # exceeded. Synchronous GenServer dispatch so multi-uplink bursts
  # can't race the cap check.
  defp ingest(dtu_id, topic, payload) do
    stored_payload = truncate_payload(payload)
    # Microsecond precision so a fast burst of uplinks (typical
    # OpenDTU publishes 4-5 fields per second) gets distinct
    # `received_at` values, making the FIFO cap-eviction
    # deterministic. `utc_now/0` truncates to whole seconds, which
    # causes multiple uplinks within the same second to collide on
    # the eviction key.
    received_at = DtuApp.Time.utc_now_usec()
    new_entry = {stored_payload, received_at}

    topics =
      case :ets.lookup(table_name(), dtu_id) do
        [{^dtu_id, existing}] -> existing
        [] -> %{}
      end

    topics =
      Map.put(topics, topic, new_entry)
      |> evict_oldest_if_over_cap()

    :ets.insert(table_name(), {dtu_id, topics})
  end

  # Drop the oldest entry (by `received_at`) when the map is at or
  # above the cap. `Map.put/3` adds the new entry first, so by the
  # time we check `map_size > cap`, we've already exceeded the
  # bound by one. Dropping exactly one topic keeps the map at
  # `cap` after the insert — the cap is hard, not soft.
  #
  # `Enum.min_by/2` on `received_at` is O(n) but n is bounded by
  # `@max_topics_per_dtu` (200), so the cost is constant in
  # practice.
  defp evict_oldest_if_over_cap(topics) do
    if map_size(topics) > @max_topics_per_dtu do
      {oldest_topic, _} = Enum.min_by(topics, fn {_t, {_p, at}} -> at end)
      Map.delete(topics, oldest_topic)
    else
      topics
    end
  end

  # Truncate payloads to `@max_payload_bytes`, appending `…` so the
  # user can tell the value was cut. Matches the
  # `Telemetry.format_payload_snippet/1` convention for consistent UX
  # between the device-details view and the error panel's payload
  # snippet.
  defp truncate_payload(payload) when is_binary(payload) do
    if byte_size(payload) <= @max_payload_bytes do
      payload
    else
      binary_part(payload, 0, @max_payload_bytes) <> "…"
    end
  end

  defp truncate_payload(_), do: ""

  # Broadcast a `:topic_seen` so subscribed LiveViews can re-fetch the
  # snapshot. Fan-out is per-DTU-id so the LiveView can short-circuit
  # events for DTUs it isn't rendering.
  defp broadcast_seen(dtu_id) do
    Phoenix.PubSub.broadcast(DtuApp.PubSub, @topic_event_topic, {:topic_seen, dtu_id})
  end

  # Prune entries older than the staleness window. A DTU that hasn't
  # published in `@topic_max_age_seconds` is no longer "online" in
  # the same sense `Dtu.online?/2` uses, so its topic tree collapses
  # to `nil`. ETS `select_delete/2` is atomic — no race against a
  # concurrent uplink write.
  defp prune_stale do
    now = DtuApp.Time.utc_now()
    cutoff = DateTime.add(now, -@topic_max_age_seconds, :second)

    :ets.foldl(
      fn {dtu_id, topics}, _acc ->
        fresh =
          Enum.reject(topics, fn {_t, {_p, at}} ->
            DateTime.compare(at, cutoff) == :lt
          end)

        # `Enum.reject/2` returns a list, not a map — rebuild the map
        # so the value we re-insert (or compare) stays the same shape
        # as the values written by `ingest/3`. Storing a list here
        # would surface as `BadMapError` on the next `get_topics_for/1`
        # call (it pattern-matches `%{}` for the empty case).
        fresh_map = Map.new(fresh)

        case fresh_map do
          # Whole DTU went stale — drop the row entirely so
          # `get_topics_for/1` returns the empty-map default and the
          # device-details LiveView can render its "no live data"
          # empty state.
          map when map_size(map) == 0 ->
            :ets.delete(table_name(), dtu_id)

          map ->
            :ets.insert(table_name(), {dtu_id, map})
        end

        :ok
      end,
      :ok,
      table_name()
    )
  end

  defp schedule_prune do
    Process.send_after(self(), :prune, @prune_interval_ms)
  end
end
