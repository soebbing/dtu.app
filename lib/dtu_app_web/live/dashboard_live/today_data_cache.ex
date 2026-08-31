defmodule DtuAppWeb.DashboardLive.TodayDataCache do
  @moduledoc """
  In-process TTL cache for the two heavy pre-fetches at the top of
  `DashboardLive.assign_dashboard_data/5`:

    * `Devices.list_today_consumption_chart_data/2` — today-window
      consumption readings bucketed into 5-minute means. Backed by
      `SELECT ... FROM readings WHERE power_type = 'consumption'`
      and scanned every time the LiveView re-runs the function.
    * `Devices.list_net_chart_data/4` — net-flow (production
      minus consumption) bucket means for today. Same shape of
      scan over `readings`, just filtered on `power_type` and
      bucketed with `FILTER` aggregates in SQL.

  The profile harness
  (`test/dtu_app_web/live/dashboard_mount_profile_test.exs`) shows
  these two queries together cost ~10 s of cumulative DB time per
  mount — second only to the chart-path queries that #4 will
  eventually cache at a higher level. Caching them here is the
  safest first cut of #4: small blast radius (no refactor of
  `assign_dashboard_data/5`'s body), and the cache key is just
  `{user_id, dtu_id_or_nil}` because both functions are
  today-scoped (the call sites pass today's `utc_start`/`utc_end`
  or compute it internally from `Date.utc_today/0`).

  TTL is **15 seconds**. Long enough that a single mount (warm
  ~3 s, cold ~30 s) hits the cache for every call after the
  first; short enough that a user who opens the dashboard, walks
  away for a minute, and reloads sees readings that landed in
  the interim within the same window. The 1D "today" branch
  still picks up fresh readings via the existing PubSub
  `handle_info({:reading, ...})` path, which calls
  `invalidate/1` to drop the cached entry — the next
  `assign_dashboard_data/5` then re-fetches.

  This is **only** the pre-fetched today calls. Other branches
  (day / week / month / year / 7d / 30d / ytd) and the chart
  data inside `assign_line_chart_data/6` are deliberately not
  cached here — those depend on `selected_period` and would need
  the broader assign-level cache. They land as a follow-up once
  this layer's hit rate is measured.
  """

  use GenServer

  @ttl_ms 15 * 1000

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def child_spec(_) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
  end

  @doc """
  Read-through cache for the two today-scoped chart-data
  fetches. Returns `%{consumption: [...], net: [...]}` for
  `user_id`, running `fetcher` (a 0-arity function) on a miss.

  `fetcher` runs inside the caller's process — that's important
  because `Devices.list_today_consumption_chart_data/2` issues
  `Repo.all/1`, which has to run inside the Ecto Sandbox for
  tests. Wrapping the call in a `Task` would break the sandbox
  ownership (the task would run on a different process and lose
  the checked-out connection).
  """
  @spec fetch(integer() | nil, (-> map())) :: map()
  def fetch(nil, fetcher), do: fetcher.()

  def fetch(user_id, fetcher) when is_integer(user_id) and is_function(fetcher, 0) do
    case :ets.lookup(__MODULE__, user_id) do
      [{^user_id, %{value: data, stored_at: stored_at_ms}}] ->
        if fresh?(stored_at_ms), do: data, else: refresh(user_id, fetcher)

      _ ->
        refresh(user_id, fetcher)
    end
  end

  @doc """
  Drop the cached entry for `user_id`. Called by
  `DashboardLive`'s `handle_info({:reading, ...})` so the next
  `assign_dashboard_data/5` call after a reading lands refetches
  the today window and the live chart updates within seconds.

  Safe to call on missing / `nil` entries.
  """
  @spec invalidate(integer() | nil) :: :ok
  def invalidate(nil), do: :ok

  def invalidate(user_id) when is_integer(user_id),
    do: GenServer.call(__MODULE__, {:invalidate, user_id})

  defp refresh(user_id, fetcher) do
    data = fetcher.()
    GenServer.call(__MODULE__, {:put, user_id, data})
    data
  end

  defp fresh?(stored_at_ms) do
    :erlang.system_time(:millisecond) - stored_at_ms < @ttl_ms
  end

  @impl true
  def init(_) do
    :ets.new(__MODULE__, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, user_id, data}, _from, state) do
    :ets.insert(
      __MODULE__,
      {user_id, %{value: data, stored_at: :erlang.system_time(:millisecond)}}
    )

    {:reply, :ok, state}
  end

  def handle_call({:invalidate, user_id}, _from, state) do
    :ets.delete(__MODULE__, user_id)
    {:reply, :ok, state}
  end
end
