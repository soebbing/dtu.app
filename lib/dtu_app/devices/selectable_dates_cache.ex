defmodule DtuApp.Devices.SelectableDatesCache do
  @moduledoc """
  In-process TTL cache for `DtuApp.Devices.list_selectable_dates/2`'s
  `SELECT DISTINCT (bucket::date) FROM readings_5m WHERE dtu_id IN
  (...) AND bucket >= now() - interval '5 years'` round trip.

  Why this exists: `list_selectable_dates/2` is called from
  `DashboardLive.PeriodSelectable.assign_selectable_periods/3`, which
  runs on every mount (HTTP+WS = 2×/mount) and on every DTU switch.
  Even after the readings_5m cagg move (PR #230), the DISTINCT scan
  across 5 years of buckets is non-trivial — the 2026-09-01 perf
  profile still listed it as one of the slower queries on the
  dashboard mount.

  ## Race-safe miss path (Tier 2 / Perf #35)

  Same pattern as `DtuApp.Time.Cache` and
  `DtuApp.Devices.UserDtuIdsCache`:

    * Hot path: `:ets.lookup/2` (cheap, lock-free).
    * Miss path: `:ets.insert_new/2` to atomically claim the slot;
      the first writer runs the fetcher in the caller's process
      (sandbox-safe), subsequent arrivals poll for the value.

  The fetcher MUST run in the caller's process because `Repo.all/1`
  needs the Ecto SQL Sandbox connection that the caller (a LiveView
  mount or test process) owns. The race-safety comes from the
  atomic claim, not from process isolation. See the
  `DtuApp.Time.Cache` moduledoc for the full rationale.

  ## Cache key

  `{user_id, dtu_id}`. The `dtu_id` is part of the key — `nil`
  means "all of the user's DTUs", a specific id means "just this
  one". A DTU switch produces a new key automatically.

  ## TTL + invalidation

  30 seconds — long enough that the HTTP+WS mount pair hits the
  cache on the second call (the typical mount pattern is sequential,
  not concurrent, so the second call almost always finds the first
  writer's value), short enough that the calendar widget picks up
  a fresh date the next time the user reloads after midnight.

  `invalidate/1` is called by `Devices.create_device/2` and
  `Devices.delete_device/1` (the actual mutation entry points) so a
  freshly-created or removed device is reflected in the next
  `list_selectable_dates/2` call without waiting for the TTL.
  `invalidate/2` clears a specific `(user_id, dtu_id)` slot if a
  caller needs precise control.
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
  Atomic read-through for a `(user_id, dtu_id)` slot. The hot path
  is a fast ETS lookup; on miss the fetcher runs in the **caller's
  process**, with concurrent miss-path callers collapsed via
  `:ets.insert_new/2` so only one fires the DB query.
  """
  @spec get(integer(), integer() | nil, (-> [Date.t()])) :: [Date.t()]
  def get(user_id, dtu_id, fetcher)
      when is_integer(user_id) and is_function(fetcher, 0) do
    key = {user_id, dtu_id}

    case :ets.lookup(__MODULE__, key) do
      [{^key, %{value: dates, stored_at: stored_at_ms}}] ->
        if fresh?(stored_at_ms), do: dates, else: atomic_fetch(key, fetcher)

      _ ->
        atomic_fetch(key, fetcher)
    end
  end

  @doc """
  Drop every cached entry for `user_id`, regardless of `dtu_id`.
  Called by `Devices.create_device/2` and `Devices.delete_device/1`
  so a freshly-created or removed DTU is reflected in the next
  `list_selectable_dates/2` call without waiting for the TTL.

  Safe to call on missing / `nil` entries — the underlying ETS
  match-delete is a no-op if nothing matches.
  """
  @spec invalidate(integer() | nil) :: :ok
  def invalidate(nil), do: :ok

  def invalidate(user_id) when is_integer(user_id) do
    :ets.match_delete(__MODULE__, {{user_id, :_}, :_})
    :ok
  end

  @doc """
  Drop a single cached entry for `(user_id, dtu_id)`. Used by tests
  that stamp state and want to bypass the TTL for that specific
  slot without nuking the whole user.
  """
  @spec invalidate(integer(), integer() | nil) :: :ok
  def invalidate(user_id, dtu_id) when is_integer(user_id) do
    :ets.delete(__MODULE__, {user_id, dtu_id})
    :ok
  end

  # --- Private ----------------------------------------------------------------

  defp atomic_fetch(key, fetcher) do
    case :ets.insert_new(__MODULE__, {key, :computing}) do
      true ->
        # Slot was empty — we won the race. Run the fetcher in the
        # caller's process (sandbox-safe), publish on success,
        # release the slot on failure.
        run_and_publish(key, fetcher)

      false ->
        # Slot is occupied — either another caller is computing or
        # there's a stale value. Poll for the next publish.
        poll_for_value(key, fetcher, @wait_max_attempts)
    end
  end

  defp run_and_publish(key, fetcher) do
    try do
      dates = fetcher.()

      :ets.insert(
        __MODULE__,
        {key, %{value: dates, stored_at: :erlang.system_time(:millisecond)}}
      )

      dates
    catch
      kind, reason ->
        # Release the slot so the next caller can try again. If we
        # left `:computing` in place, every subsequent caller would
        # time out polling for a value that will never arrive.
        :ets.delete(__MODULE__, key)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp poll_for_value(_key, _fetcher, 0),
    do: raise("DtuApp.Devices.SelectableDatesCache contention timeout")

  defp poll_for_value(key, fetcher, attempts_left) do
    case :ets.lookup(__MODULE__, key) do
      [{^key, %{value: dates, stored_at: t}}] when is_integer(t) ->
        if fresh?(t) do
          dates
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
