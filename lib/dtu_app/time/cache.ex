defmodule DtuApp.Time.Cache do
  @moduledoc """
  In-process TTL cache for `DtuApp.Time.utc_now/0`'s DB-clock round
  trip. Same pattern as `DtuApp.Weather.Cache` and
  `DtuApp.Accounts.PasskeyChallengeCache` — `:public, :named_table`
  ETS for cheap reads, atomic write-claim for race safety.

  Why this exists: a single dashboard mount calls
  `DtuApp.Time.utc_now/0` many times (every helper that derives a
  cutoff, every "online?" / "fresh?" check, every stat-card window).
  Each call was a `SELECT now() AT TIME ZONE 'UTC'` round trip
  through the connection pool, costing 100–500 ms of queue_time
  alone on a busy pool. The profile harness
  (`test/dtu_app_web/live/dashboard_mount_profile_test.exs`) showed
  double-digit seconds of cumulative DB time on the `now()` query
  across one mount — more than any other single line of work.

  ## Race-safe miss path (Tier 2 / Perf #10)

  A `Phoenix.LiveViewTest.live/2` call internally invokes `mount/3`
  twice — once for the HTTP render, once for the WebSocket upgrade —
  on different processes that race through `DtuApp.Time.utc_now/0`.
  The naive "peek then put" pattern (ETS lookup → if nil, fetch →
  ETS write) is racy: two concurrent lookups both see `nil` before
  either writes, so both fire the DB query.

  `fetch/1` closes the race with `:ets.insert_new/2` + polling:

    * **Empty slot:** the first caller's `insert_new` wins; only one
      runs the fetcher and writes the value. Subsequent callers'
      `insert_new` returns `false`, so they poll for the winner's
      value instead of re-fetching.
    * **Stale slot:** `insert_new` fails (key already exists). The
      polling waiter sees the stale entry, decides the value is no
      longer fresh, and falls through to a direct `compute_fn.()`
      without claiming. This is acceptable: the stale → empty → in-
      flight transition only happens on TTL expiry, which is rare
      enough that one or two extra fetcher calls per stale period
      is much cheaper than the original race-driven N.

  The fetcher runs in the **caller's process** — not in a GenServer
  process — because `Repo.query_now/1` needs the Ecto Sandbox
  connection that the caller (a LiveView mount or test process)
  owns. The race-safety comes from the atomic claim, not from
  process isolation.

  ## TTL

  10 seconds — short enough that the freshness invariant
  `DtuApp.Time.utc_now/0`'s docstring promises ("use the DB clock,
  not the app clock") stays intact (drift of up to 10 s is
  acceptable for the dashboard's time-windowed queries, for token
  validity windows, and for `last_seen_at` freshness checks). The
  companion `utc_now_usec/0` does **not** use this cache —
  microsecond precision is needed for the readings hypertable's
  composite PK, and a stale `last_seen_at` write would shift a
  freshly-arrived reading backwards in time.

  App-clock (`:erlang.system_time/0`) is used for the freshness
  check, not the DB clock — using `DtuApp.Time.utc_now/0` to decide
  whether to call `DtuApp.Time.utc_now/0` would be circular. App
  clock drift over 10 s is well under 1 s even on un-synced hosts.
  """

  @ttl_ms 10 * 1000
  # Worst-case wait before falling back to a direct fetch. The
  # polling loop sleeps `@wait_sleep_ms` per iteration; 500 × 2 ms
  # = 1000 ms (1 s) total.
  #
  # The 1 s ceiling matters: the HTTP-render-then-WebSocket-upgrade
  # double-mount races a single fetcher. On a slow DB the first
  # caller's fetcher can take longer than the second caller's
  # polling window. If the window is too tight, the second arrival
  # raises "DtuApp.Time.Cache contention timeout" mid-mount, which
  # propagates up through `mount/3` and crashes the LiveView
  # process — the WebSocket then closes and Phoenix fires
  # `phx-disconnected`, surfacing the "Etwas ist schiefgelaufen /
  # Attempting to reconnect" flash right after the page renders.
  # 1 s is enough headroom for any reasonable DB stall without
  # leaving the polling path hung during a real deadlock.
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
  Atomic read-through for `now()`. On a hit (entry younger than
  `@ttl_ms`) returns the cached `DateTime` without invoking
  `compute_fn`. On a miss, runs `compute_fn.()` in the caller's
  process — concurrent callers are serialised via `:ets.insert_new/2`,
  so the second arrival either polls for the first writer's value
  (empty-slot case) or fetches directly (stale-slot case). This
  eliminates the HTTP+WS `mount/3` race documented in the moduledoc.
  """
  @spec fetch((-> DateTime.t())) :: DateTime.t()
  def fetch(compute_fn) when is_function(compute_fn, 0) do
    case :ets.lookup(__MODULE__, :now) do
      [{:now, %{value: value, stored_at: stored_at_ms}}] ->
        if fresh?(stored_at_ms), do: value, else: atomic_fetch(compute_fn)

      _ ->
        atomic_fetch(compute_fn)
    end
  end

  @doc """
  Drop the cached entry. Used by tests that stamp state with
  backdated timestamps relative to `Time.utc_now_usec/0` and then
  expect `Time.utc_now/0` to agree within a sub-second margin — the
  cache can otherwise hold a value from a previous test for up to
  10 s, which trips that comparison.

  Not for production use: callers that genuinely need a fresh DB
  clock should call `Time.utc_now_usec/0` instead.
  """
  @spec invalidate() :: :ok
  def invalidate do
    :ets.delete(__MODULE__, :now)
    :ok
  end

  # --- Private ----------------------------------------------------------------

  defp atomic_fetch(compute_fn) do
    case :ets.insert_new(__MODULE__, {:now, :computing}) do
      true ->
        # Slot was empty — we won the race. Run the fetcher in the
        # caller's process (sandbox-safe), publish on success,
        # release the slot on failure.
        run_and_publish(compute_fn)

      false ->
        # Slot is occupied — either another caller is computing or
        # there's a stale value. Poll for the next publish.
        poll_for_value(compute_fn, @wait_max_attempts)
    end
  end

  defp run_and_publish(compute_fn) do
    try do
      value = compute_fn.()

      :ets.insert(
        __MODULE__,
        {:now, %{value: value, stored_at: :erlang.system_time(:millisecond)}}
      )

      value
    catch
      kind, reason ->
        # Release the slot so the next caller can try again. If we
        # left `:computing` in place, every subsequent caller would
        # time out polling for a value that will never arrive.
        :ets.delete(__MODULE__, :now)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp poll_for_value(_compute_fn, 0), do: raise("DtuApp.Time.Cache contention timeout")

  defp poll_for_value(compute_fn, attempts_left) do
    case :ets.lookup(__MODULE__, :now) do
      [{:now, %{value: value, stored_at: t}}] when is_integer(t) ->
        if fresh?(t) do
          value
        else
          # Stale — the cache is past its TTL but the slot is still
          # occupied. Rather than try to claim (insert_new can't
          # overwrite a stale entry, and a forced overwrite would
          # race with other stale-checkers), fetch directly without
          # claiming. Acceptable: the stale → empty → in-flight
          # transition only happens on TTL expiry, so this path
          # fires rarely.
          compute_fn.()
        end

      _ ->
        Process.sleep(@wait_sleep_ms)
        poll_for_value(compute_fn, attempts_left - 1)
    end
  end

  # App-clock freshness check (see moduledoc — using the DB clock
  # here would be circular). Stored as `:erlang.system_time/1` ms so
  # the comparison is plain integer arithmetic, no DateTime round
  # trip.
  defp fresh?(stored_at_ms) do
    :erlang.system_time(:millisecond) - stored_at_ms < @ttl_ms
  end
end
