defmodule DtuAppWeb.DashboardLive.DashboardMountCache do
  @moduledoc """
  In-process TTL cache for the dashboard mount data that hasn't yet
  been covered by the dedicated per-query caches
  (`DtuApp.Devices.UserDtuIdsCache`,
  `DtuApp.Devices.SelectableDatesCache`,
  `DtuAppWeb.DashboardLive.TodayDataCache`,
  `DtuApp.Time.Cache`):

    * `Devices.list_devices/1` — full Dtu rows for the user.
    * `Devices.error_counts_by_dtu_id/1` — per-device error badge counts.
    * `PushSubscriptions.list_for_user/1` — native-push indicator.
    * `Accounts.get_shared_link/1` — share-toolbar toggle state.

  Each warm dashboard mount used to issue all four twice — once from
  the HTTP-render `mount/3`, once from the WebSocket-upgrade
  `mount/3` — for a combined 8 round-trips against a 10-slot
  connection pool. The profile harness
  (`test/dtu_app_web/live/dashboard_mount_profile_test.exs`) showed
  the four queries collectively responsible for ~60 s of cumulative
  DB time across three mounts.

  ## Race-safe miss path

  Same pattern as `DtuApp.Time.Cache` and
  `DtuApp.Devices.UserDtuIdsCache` — `:ets.insert_new/2` + polling
  closes the HTTP+WS race where two concurrent callers both see a
  missing slot and would otherwise both fire the fetcher. The first
  caller's `insert_new` wins; subsequent callers poll for the value.

  The fetcher runs in the **caller's process** — that matters
  because the closure issues `Repo.all/1` (and friends) which need
  the Ecto SQL Sandbox connection the caller (a LiveView mount or
  test process) owns. Wrapping the fetcher in a `Task` would break
  sandbox ownership — see `DtuAppWeb.DashboardLive.TodayDataCache`
  moduledoc for the same rationale.

  ## Cache key

  `{user_id, dtu_id, tz_offset_seconds}` — the three inputs the
  closure captures. A DTU switch or a tz change produces a new key
  automatically.

  ## TTL

  60 seconds — **must** span the full HTTP-render time. The HTTP
  mount fires the seed fetcher, then the response ships to the
  browser, then the WebSocket-upgrade `mount/3` arrives in a fresh
  process. On prod the HTTP mount can take 30 s (the very problem
  this cache is meant to help with); the WS upgrade follows a few
  hundred ms later. A TTL under ~35 s means the WS upgrade lands on
  a stale entry and re-fires the fetcher, defeating the cache.
  60 s gives us headroom for any reasonable mount time, while
  keeping the device/tz changes an existing user makes visible on
  the next page reload.

  ## Invalidation

  `invalidate/3` drops a specific `(user_id, dtu_id, tz)` slot;
  `invalidate/1` (user_id only) drops every slot for that user —
  the blast-radius helper for "the user's devices or tz changed,
  drop everything."
  """

  @ttl_ms 60 * 1000
  # Worst-case wait before falling back to a direct fetch. The
  # polling loop sleeps `@wait_sleep_ms` per iteration; 500 × 2 ms
  # = 1000 ms (1 s) total. See `DtuApp.Time.Cache` for why the
  # 1 s ceiling matters (HTTP+WS race on a slow DB).
  @wait_max_attempts 500
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
  Atomic read-through for a `{user_id, dtu_id, tz_offset_seconds}`
  slot. On a hit (entry younger than `@ttl_ms`) returns the cached
  seed map without invoking `fetcher`. On a miss, runs `fetcher.()`
  in the caller's process — concurrent miss-path callers are
  serialised via `:ets.insert_new/2`, so only one fires the DB
  queries.
  """
  @spec fetch(integer() | nil, integer() | nil, integer(), (-> map())) :: map()
  def fetch(nil, _dtu_id, _tz_offset_seconds, fetcher), do: fetcher.()

  def fetch(user_id, dtu_id, tz_offset_seconds, fetcher)
      when is_integer(user_id) and is_function(fetcher, 0) do
    key = {user_id, dtu_id, tz_offset_seconds}

    case :ets.lookup(__MODULE__, key) do
      [{^key, %{value: seed, stored_at: stored_at_ms}}] ->
        if fresh?(stored_at_ms), do: seed, else: atomic_fetch(key, fetcher)

      _ ->
        atomic_fetch(key, fetcher)
    end
  end

  @doc """
  Drop the cached entry for a specific `(user_id, dtu_id,
  tz_offset_seconds)` slot. Safe to call on missing / `nil` entries
  — the underlying ETS delete is a no-op if the row isn't there.
  """
  @spec invalidate(integer() | nil, integer() | nil, integer()) :: :ok
  def invalidate(nil, _dtu_id, _tz_offset_seconds), do: :ok

  def invalidate(user_id, dtu_id, tz_offset_seconds)
      when is_integer(user_id) and is_integer(tz_offset_seconds) do
    :ets.delete(__MODULE__, {user_id, dtu_id, tz_offset_seconds})
    :ok
  end

  @doc """
  Drop every cached entry for `user_id`, regardless of `dtu_id` or
  `tz_offset_seconds`. The blast-radius helper for "the user's
  devices or tz changed, drop everything" — called by
  `Devices.create_device/2`, `Devices.delete_device/1`, and the
  tz-offset write path.
  """
  @spec invalidate(integer() | nil) :: :ok
  def invalidate(nil), do: :ok

  def invalidate(user_id) when is_integer(user_id) do
    :ets.match_delete(__MODULE__, {{user_id, :_, :_}, :_})
    :ok
  end

  # --- Private ----------------------------------------------------------------

  defp atomic_fetch(key, fetcher) do
    case :ets.insert_new(__MODULE__, {key, :computing}) do
      true ->
        run_and_publish(key, fetcher)

      false ->
        poll_for_value(key, fetcher, @wait_max_attempts)
    end
  end

  defp run_and_publish(key, fetcher) do
    try do
      seed = fetcher.()

      :ets.insert(
        __MODULE__,
        {key, %{value: seed, stored_at: :erlang.system_time(:millisecond)}}
      )

      seed
    catch
      kind, reason ->
        :ets.delete(__MODULE__, key)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp poll_for_value(_key, _fetcher, 0),
    do: raise("DtuAppWeb.DashboardLive.DashboardMountCache contention timeout")

  defp poll_for_value(key, fetcher, attempts_left) do
    case :ets.lookup(__MODULE__, key) do
      [{^key, %{value: seed, stored_at: t}}] when is_integer(t) ->
        if fresh?(t) do
          seed
        else
          fetcher.()
        end

      _ ->
        Process.sleep(@wait_sleep_ms)
        poll_for_value(key, fetcher, attempts_left - 1)
    end
  end

  # App-clock freshness check (using the DB clock here would be
  # circular). Stored as `:erlang.system_time/1` ms so the
  # comparison is plain integer arithmetic, no DateTime round trip.
  defp fresh?(stored_at_ms) do
    :erlang.system_time(:millisecond) - stored_at_ms < @ttl_ms
  end
end
