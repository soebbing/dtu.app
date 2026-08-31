defmodule DtuApp.Time.Cache do
  @moduledoc """
  In-process TTL cache for `DtuApp.Time.utc_now/0`'s DB-clock round
  trip. Same pattern as `DtuApp.Weather.Cache` and
  `DtuApp.Accounts.PasskeyChallengeCache` — `:public, :named_table`
  ETS for cheap reads, GenServer-mediated writes for the lazy sweep.

  Why this exists: a single dashboard mount calls
  `DtuApp.Time.utc_now/0` ~41 times (every helper that derives a
  cutoff, every "online?" / "fresh?" check, every stat-card window).
  Each call was a `SELECT now() AT TIME ZONE 'UTC'` round trip
  through the connection pool, costing 100–500 ms of queue_time
  alone on a busy pool. The profile harness
  (`test/dtu_app_web/live/dashboard_mount_profile_test.exs`) showed
  35.57 s of cumulative DB time on the `now()` query across one
  mount — more than any other single line of work.

  The cache holds **one** entry. The TTL is short (10 s) so the
  freshness invariant `DtuApp.Time.utc_now/0`'s docstring promises
  ("use the DB clock, not the app clock") stays intact — drift of
  up to 10 s is acceptable for the dashboard's time-windowed queries,
  for token validity windows, and for `last_seen_at` freshness
  checks. The companion `utc_now_usec/0` does **not** use this
  cache — microsecond precision is needed for the readings
  hypertable's composite PK, and a stale `last_seen_at` write would
  shift a freshly-arrived reading backwards in time.

  App-clock (`:erlang.system_time/0`) is used for the freshness
  check, not the DB clock — using `DtuApp.Time.utc_now/0` to decide
  whether to call `DtuApp.Time.utc_now/0` would be circular. App
  clock drift over 10 s is well under 1 s even on un-synced hosts.
  """

  use GenServer

  @ttl_ms 10 * 1000

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def child_spec(_) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
  end

  @doc """
  Read the cached `now()` value if it's younger than `@ttl_ms`.
  Returns `nil` when the cache is empty or stale.
  """
  @spec peek() :: DateTime.t() | nil
  def peek do
    case :ets.lookup(__MODULE__, :now) do
      [{:now, %{value: value, stored_at: stored_at}}] ->
        if fresh?(stored_at), do: value, else: nil

      _ ->
        nil
    end
  end

  @doc """
  Store `value` under the singleton `:now` key. Used by
  `DtuApp.Time.utc_now/0`'s read-through path.
  """
  @spec put(DateTime.t()) :: :ok
  def put(value) do
    GenServer.call(__MODULE__, {:put, value})
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
    GenServer.call(__MODULE__, :invalidate)
  end

  @impl true
  def init(_) do
    :ets.new(__MODULE__, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, value}, _from, state) do
    :ets.insert(
      __MODULE__,
      {:now, %{value: value, stored_at: :erlang.system_time(:millisecond)}}
    )

    {:reply, :ok, state}
  end

  def handle_call(:invalidate, _from, state) do
    :ets.delete(__MODULE__, :now)
    {:reply, :ok, state}
  end

  # App-clock freshness check (see moduledoc — using the DB clock
  # here would be circular). Stored as `:erlang.system_time/1` ms so
  # the comparison is plain integer arithmetic, no DateTime round
  # trip.
  defp fresh?(stored_at_ms) do
    :erlang.system_time(:millisecond) - stored_at_ms < @ttl_ms
  end
end
