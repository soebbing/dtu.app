defmodule DtuAppWeb.DashboardLive.TodayDataCache do
  @moduledoc """
  In-process TTL cache for the dashboard's per-branch pre-fetches in
  `DashboardLive.assign_dashboard_data/5`. Despite the "Today" name,
  the cache is branch-agnostic — every `time_range` branch (today,
  day, week, month, year, 7d, 30d, ytd) wraps its query work in
  `fetch/3` with a distinct `branch:` opt, and the cache key
  partitions accordingly.

  Today branch (the historical original consumer):

    * `Devices.list_today_consumption_chart_data/2` — today-window
      consumption readings bucketed into 5-minute means.
    * `Devices.list_net_chart_data/4` — net-flow (production
      minus consumption) bucket means for today.
    * `Devices.list_day_chart_data_for_dashboard/4` — today-window
      day-chart points (production series).
    * `Devices.get_consumption_daily_stats/3` — consumption stat-card
      numbers (current draw, today's kWh, peak).
    * `Devices.get_net_flow_stats/3` — net-flow stat-card numbers
      (current net flow, today's export/import, peak export/import).
    * `Devices.get_daily_stats/4` — production stat-card numbers
      (current power, today's yield, peak, per-series peak).
    * `Devices.compute_self_consumption_pct/5` — self-consumption
      percentage for the today row.
    * `Devices.list_yesterday_chart_data_for_dashboard/4` — yesterday
      ghost-overlay data on the 1D live view.

  Historical-day branch (`time_range == "day"`):

    * `Devices.list_day_chart_data/4` — historical-day chart points.
    * `Devices.list_range_yield_data/4` — historical-day yield.
    * `Devices.compute_self_consumption_pct/5` — historical-day
      self-consumption percentage.

  Week / month / year / 7d / 30d / ytd branches share the same
  shape (`list_range_yield_data` + `compute_peak_watts_in_period` +
  `compute_self_consumption_pct`), each wrapped in its own cache
  entry so a user navigating between, say, "this month" and
  "YTD" doesn't poison either view's cache.

  `fetch/3` covers the whole `assign_dashboard_data/5` work pass
  per branch, so a 2–6 Hz PubSub `:reading` stream collapses to a
  single ~10-round-trip work pass per 15 s window instead of one
  per broadcast. The reading-broadcast handler in `DashboardLive`
  calls `invalidate_today/1` to drop just the live-today entry;
  the next `assign_dashboard_data/5` re-fetches only that branch.
  Historical branches don't receive a `:reading`-driven
  invalidation — their data is fixed at render time, so the 15 s
  TTL handles staleness on its own.

  ## Cache key

  The key is `{user_id, opts}` where `opts` is the keyword list
  passed to `fetch/3`. Every caller passes at least
  `tz_offset_seconds:` and `dtu_id:` (a tz change or DTU switch
  produces a new key automatically — no extra `invalidate/1` calls
  needed; `select_dtu` and `:set_timezone` do call it as a belt-
  and-braces safety net, but the new key alone would suffice).
  The today branch additionally passes `branch: :today`,
  and the historical branches pass `branch: :day | :week | :month
  | :year | :"7d" | :"30d" | :ytd` plus the period identifier
  (`:date`, `:monday`, `:first_day`, `:year`) where applicable —
  clicking through the calendar naturally invalidates by changing
  the key.

  ## TTL

  15 seconds. Long enough that a single mount (warm ~3 s, cold
  ~30 s) hits the cache for every call after the first; short
  enough that a user who opens the dashboard, walks away for a
  minute, and reloads sees readings that landed in the interim
  within the same window. The reading handler's explicit
  `invalidate_today/1` is what makes the today view pick up fresh
  readings within the broadcast coalesce window. Historical
  branches don't strictly need the invalidate (their data is
  fixed), but the same TTL covers a user clicking between
  adjacent historical periods without paying a round-trip on
  each click.

  ## `fetcher` runs in the caller's process

  `fetcher` runs inside the caller's process — that's important
  because `Devices.list_*` helpers issue `Repo.all/1`, which has
  to run inside the Ecto Sandbox for tests. Wrapping the call in
  a `Task` would break the sandbox ownership (the task would run
  on a different process and lose the checked-out connection).
  """

  use GenServer

  @ttl_ms 15 * 1000

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def child_spec(_) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
  end

  @doc """
  Read-through cache for the full today-branch data fetch. The
  `opts` keyword list is part of the cache key — pass any inputs
  the closure captures (typically `tz_offset_seconds`, `dtu_id`,
  `cents_per_kwh`). On a hit, `fetcher` is **not** invoked; on a
  miss, `fetcher.()` runs in the caller's process and the result
  is stored under `{user_id, opts}` for `ttl_ms`.

  Returns whatever the `fetcher` closure returns — typically a
  map with all the data inputs the today branch needs to assign
  the socket (chart points + stat-card numbers + savings).
  """
  @spec fetch(integer() | nil, keyword(), (-> term())) :: term()
  def fetch(nil, _opts, fetcher), do: fetcher.()

  def fetch(user_id, opts, fetcher)
      when is_integer(user_id) and is_list(opts) and is_function(fetcher, 0) do
    key = {user_id, opts}

    case :ets.lookup(__MODULE__, key) do
      [{^key, %{value: data, stored_at: stored_at_ms}}] ->
        if fresh?(stored_at_ms), do: data, else: refresh(key, fetcher)

      _ ->
        refresh(key, fetcher)
    end
  end

  @doc """
  Backward-compatible 2-arg form. Same semantics as
  `fetch/3` with `opts = []`. Returns `%{consumption: [...],
  net: [...]}` for `user_id` (the original today-window contract
  that callers outside the dashboard — e.g. the existing
  `today_data_cache_test.exs` — still use).
  """
  @spec fetch(integer() | nil, (-> map())) :: map()
  def fetch(user_id, fetcher) when is_function(fetcher, 0) do
    fetch(user_id, [], fetcher)
  end

  @doc """
  Drop every cached entry for `user_id`, regardless of `opts`.
  Called by `DashboardLive.handle_event("select_dtu", ...)` and
  `handle_info({:set_timezone, ...})` — both change a key
  component (`dtu_id` / `tz_offset_seconds`) that participates in
  the cache key, but the stale entry would still sit in ETS under
  the OLD key until TTL. The narrow `invalidate_today/1` is what
  the `:reading` broadcast handler uses; this broad variant is
  for the two callers that legitimately need every branch wiped.

  Safe to call on missing / `nil` entries.
  """
  @spec invalidate(integer() | nil) :: :ok
  def invalidate(nil), do: :ok

  def invalidate(user_id) when is_integer(user_id) do
    # The cache key is `{user_id, opts}` (any opts tuple the
    # caller passed), so a `match_delete` on `{{user_id, :_}}`
    # clears every variant. Without this we'd need to know the
    # caller's exact opts to delete one row.
    :ets.match_delete(__MODULE__, {{user_id, :_}, :_})
    :ok
  end

  @doc """
  Drop only the `branch: :today` cached entry for `user_id`. The
  historical branches (day / week / month / year / 7d / 30d / ytd)
  keep their entries under the 15 s TTL — the user's last 15 s of
  work on a historical view is preserved across live-reading refresh
  bursts. Called by `DashboardLive.handle_info({:reading, ...})`
  because live readings invalidate the live today view, not
  historical ones.
  """
  @spec invalidate_today(integer() | nil) :: :ok
  def invalidate_today(nil), do: :ok

  def invalidate_today(user_id) when is_integer(user_id) do
    # The keyword-list opts always start with `{:branch, :today}` for
    # live-today entries; match against that exact head and discard the
    # tail. Non-today entries (`{:branch, :day}`, `{:branch, :week}`,
    # …) have a different head, so their rows don't match this pattern.
    #
    # Note 1 — `:_` (the atom underscore, the canonical ETS wildcard)
    # is used in the cons tail where Erlang would write bare `_`. In
    # an ETS match spec `[_|_]` and `[_|:_]` are equivalent — both
    # match any list with the given head — but Elixir's parser rejects
    # bare `_` outside pattern position, so the atom form is used.
    #
    # Note 2 — the pattern is a 2-tuple `{key, value}` matching the
    # full ETS row (key = `{user_id, opts}`, value = the
    # `%{value: ..., stored_at: ...}` map inserted by `handle_call/3`).
    # `:ets.match_delete/2` takes a *pattern*, not a *match spec* — a
    # match-spec-shaped `[pat, [], [true]]` wrapper would match
    # nothing because the row's value is a map, not `[]`.
    :ets.match_delete(
      __MODULE__,
      {{user_id, [{:branch, :today} | :_]}, :_}
    )

    :ok
  end

  defp refresh(key, fetcher) do
    data = fetcher.()
    GenServer.call(__MODULE__, {:put, key, data})
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
  def handle_call({:put, key, data}, _from, state) do
    :ets.insert(
      __MODULE__,
      {key, %{value: data, stored_at: :erlang.system_time(:millisecond)}}
    )

    {:reply, :ok, state}
  end
end
