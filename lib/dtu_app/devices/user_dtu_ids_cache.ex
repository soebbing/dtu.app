defmodule DtuApp.Devices.UserDtuIdsCache do
  @moduledoc """
  In-process TTL cache for `DtuApp.Devices.owned_dtu_ids/2`'s
  `SELECT id FROM dtus WHERE user_id = $1` round trip.

  Why this exists: a single dashboard mount calls
  `Devices.owned_dtu_ids/2` many times — once per helper that
  scopes its `WHERE dtu_id IN ^dtu_ids` clause
  (`get_daily_stats/3`, `get_consumption_daily_stats/3`,
  `list_today_consumption_chart_data/2`, `list_net_chart_data/4`,
  the chart-cagg fetcher, the per-series peak computation, the
  cloud-cover band fixture, and several others). Each call was
  a separate round trip through the connection pool, costing
  100–500 ms of queue_time alone on a busy pool. The profile
  harness (`test/dtu_app_web/live/dashboard_mount_profile_test.exs`)
  showed several seconds of cumulative DB time on the
  `owned_dtu_ids` query across one mount.

  Only the `dtu_id = nil` branch (returns all of the user's DTU
  ids) is cached — the `dtu_id = <id>` branch runs a per-dtu
  ownership check (`Repo.exists?`) and is rare (it fires when the
  user has explicitly picked a DTU in the toolbar). Caching that
  per-user-per-dtu pair would multiply the keyspace without
  matching the savings.

  ## Race-safe miss path (Tier 2 / Perf #11)

  A `Phoenix.LiveViewTest.live/2` call internally invokes `mount/3`
  twice (HTTP render + WebSocket upgrade) on different processes
  that race through `owned_dtu_ids/2`. The naive "peek then put"
  pattern is racy — both lookups see `nil` before either puts, so
  both fire the DB query. `get/2` closes the race with the same
  `:ets.insert_new/2` + polling pattern as `DtuApp.Time.Cache.fetch/1`:
  the first caller's insert wins, the others poll for the value
  instead of re-fetching. The fetcher runs in the **caller's
  process** so the Ecto SQL Sandbox ownership stays intact — see
  the `DtuApp.Time.Cache` moduledoc for the rationale.

  ## TTL + invalidation (Tier 2 / Perf #11)

  TTL is 30 s — long enough that a single mount (warm = ~3 s, cold
  = ~30 s) is fully served from the first fetch, short enough that
  a user who adds or removes a DTU sees the change within the same
  window. `invalidate/1` is called by `Devices.create_device/2` and
  `Devices.delete_device/1` (the actual mutation entry points) so a
  freshly-created or removed device is reflected in the next
  `owned_dtu_ids/2` call without waiting for the TTL.

  The dashboard's `refresh_devices/2` used to call `invalidate/1`
  on every invocation — but `refresh_devices/2` runs on every
  mount and on every `:dtu_seen` PubSub broadcast (every MQTT
  uplink), so the invalidate fired far more often than the cache
  TTL could mask. The eager invalidate defeated the cache
  (every mount started with a miss). The fix removes that line:
  refreshes don't mutate the device list, so they don't need to
  invalidate. The mutation entry points do.
  """

  @ttl_ms 30 * 1000
  # Worst-case wait before falling back to a direct fetch. The
  # polling loop sleeps `@wait_sleep_ms` per iteration; 50 × 2 ms
  # = 100 ms total.
  @wait_max_attempts 50
  @wait_sleep_ms 2

  @doc """
  Starts the underlying `:ets` table. Idempotent — if the table
  already exists (e.g. on test reruns that restart the supervisor
  without restarting the VM) we leave it alone.

  Returns `:ignore` so the supervisor treats us as a one-shot-init
  child instead of a process it needs to monitor. The table's
  actual owner is the supervisor process itself (`:ets.new/2` ties
  the table to the calling process); when the application stops,
  the supervisor dies and the table is freed.
  """
  @spec start_link(any()) :: :ignore
  def start_link(_) do
    case :ets.whereis(__MODULE__) do
      :undefined -> :ets.new(__MODULE__, [:set, :public, :named_table, read_concurrency: true])
      _ref -> :ok
    end

    :ignore
  end

  def child_spec(_) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
  end

  @doc """
  Atomic read-through for the user's DTU id list. The hot path is
  a fast ETS lookup; on miss the fetcher runs in the **caller's
  process**, with concurrent miss-path callers collapsed via
  `:ets.insert_new/2` so only one fires the DB query.

  `nil` short-circuits without touching the cache (anon users have
  no devices and the fetcher would always return `[]`).
  """
  @spec get(integer() | nil, (-> [integer()])) :: [integer()]
  def get(nil, _fetcher), do: []

  def get(user_id, fetcher) when is_integer(user_id) and is_function(fetcher, 0) do
    case :ets.lookup(__MODULE__, user_id) do
      [{^user_id, %{value: ids, stored_at: stored_at_ms}}] ->
        if fresh?(stored_at_ms), do: ids, else: atomic_fetch(user_id, fetcher)

      _ ->
        atomic_fetch(user_id, fetcher)
    end
  end

  @doc """
  Drop the cached entry for `user_id`. Called by
  `Devices.create_device/2` and `Devices.delete_device/1` after
  every successful DTU mutation so a freshly-created or removed
  device is reflected in the next `owned_dtu_ids/2` call without
  waiting for the 30 s TTL.

  Safe to call on missing / `nil` entries — the underlying ETS
  delete is a no-op if the row isn't there.
  """
  @spec invalidate(integer() | nil) :: :ok
  def invalidate(nil), do: :ok

  def invalidate(user_id) when is_integer(user_id) do
    :ets.delete(__MODULE__, user_id)
    :ok
  end

  # --- Private ----------------------------------------------------------------

  defp atomic_fetch(user_id, fetcher) do
    case :ets.insert_new(__MODULE__, {user_id, :computing}) do
      true ->
        # Slot was empty — we won the race. Run the fetcher in the
        # caller's process (sandbox-safe), publish on success,
        # release the slot on failure.
        run_and_publish(user_id, fetcher)

      false ->
        # Slot is occupied — either another caller is computing or
        # there's a stale value. Poll for the next publish.
        poll_for_value(user_id, fetcher, @wait_max_attempts)
    end
  end

  defp run_and_publish(user_id, fetcher) do
    try do
      ids = fetcher.()

      :ets.insert(
        __MODULE__,
        {user_id, %{value: ids, stored_at: :erlang.system_time(:millisecond)}}
      )

      ids
    catch
      kind, reason ->
        # Release the slot so the next caller can try again. If we
        # left `:computing` in place, every subsequent caller would
        # time out polling for a value that will never arrive.
        :ets.delete(__MODULE__, user_id)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp poll_for_value(_user_id, _fetcher, 0),
    do: raise("DtuApp.Devices.UserDtuIdsCache contention timeout")

  defp poll_for_value(user_id, fetcher, attempts_left) do
    case :ets.lookup(__MODULE__, user_id) do
      [{^user_id, %{value: ids, stored_at: t}}] when is_integer(t) ->
        if fresh?(t) do
          ids
        else
          # Stale — the cache is past its TTL but the slot is still
          # occupied. Rather than try to claim (insert_new can't
          # overwrite a stale entry, and a forced overwrite would
          # race with other stale-checkers), fetch directly without
          # claiming. Acceptable: the stale → empty → in-flight
          # transition only happens on TTL expiry, so this path
          # fires rarely.
          fetcher.()
        end

      _ ->
        Process.sleep(@wait_sleep_ms)
        poll_for_value(user_id, fetcher, attempts_left - 1)
    end
  end

  # App-clock freshness check (using the DB clock here would be
  # circular). Stored as `:erlang.system_time/1` ms so the
  # comparison is plain integer arithmetic, no DateTime round trip.
  defp fresh?(stored_at_ms) do
    :erlang.system_time(:millisecond) - stored_at_ms < @ttl_ms
  end
end
