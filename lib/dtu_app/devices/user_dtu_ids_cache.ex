defmodule DtuApp.Devices.UserDtuIdsCache do
  @moduledoc """
  In-process TTL cache for `DtuApp.Devices.owned_dtu_ids/2`'s
  `SELECT id FROM dtus WHERE user_id = $1` round trip.

  Why this exists: a single dashboard mount calls
  `Devices.owned_dtu_ids/2` ~22 times — once per helper that scopes
  its `WHERE dtu_id IN ^dtu_ids` clause (`get_daily_stats/3`,
  `get_consumption_daily_stats/3`, `list_today_consumption_chart_data/2`,
  `list_net_chart_data/4`, the chart-cagg fetcher, the per-series
  peak computation, the cloud-cover band fixture, and several
  others). Each call was a separate round trip through the
  connection pool, costing 100–500 ms of queue_time alone on a
  busy pool. The profile harness
  (`test/dtu_app_web/live/dashboard_mount_profile_test.exs`) showed
  18.39 s of cumulative DB time on the `owned_dtu_ids` query
  across one mount.

  Only the `dtu_id = nil` branch (returns all of the user's DTU
  ids) is cached — the `dtu_id = <id>` branch runs a per-dtu
  ownership check (`Repo.exists?`) and is rare (it fires when the
  user has explicitly picked a DTU in the toolbar). Caching that
  per-user-per-dtu pair would multiply the keyspace without
  matching the savings.

  The TTL is 30 s — long enough that a single mount (warm = ~3 s,
  cold = ~30 s) is fully served from the first fetch, short
  enough that a user who adds or removes a DTU sees the change
  within the same window. The dashboard's
  `refresh_devices/2` calls `invalidate/1` after every device
  write so a freshly-created DTU never appears stale.
  """

  use GenServer

  @ttl_ms 30 * 1000

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def child_spec(_) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
  end

  @doc """
  Read-through cache. Returns the cached list for `user_id` if
  younger than `@ttl_ms`; otherwise runs `fetcher` (a 0-arity
  function that issues the actual `SELECT`), stores the result,
  and returns it.
  """
  @spec get(integer() | nil, (-> [integer()])) :: [integer()]
  def get(nil, _fetcher), do: []

  def get(user_id, fetcher) when is_integer(user_id) and is_function(fetcher, 0) do
    case :ets.lookup(__MODULE__, user_id) do
      [{^user_id, %{value: ids, stored_at: stored_at_ms}}] ->
        if fresh?(stored_at_ms), do: ids, else: refresh(user_id, fetcher)

      _ ->
        refresh(user_id, fetcher)
    end
  end

  @doc """
  Drop the cached entry for `user_id`. Called by the dashboard's
  `refresh_devices/2` after every successful DTU mutation so a
  freshly-created or removed device is reflected in the next
  `owned_dtu_ids/2` call.
  """
  @spec invalidate(integer() | nil) :: :ok
  def invalidate(nil), do: :ok

  def invalidate(user_id) when is_integer(user_id),
    do: GenServer.call(__MODULE__, {:invalidate, user_id})

  defp refresh(user_id, fetcher) do
    ids = fetcher.()
    GenServer.call(__MODULE__, {:put, user_id, ids})
    ids
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
  def handle_call({:put, user_id, ids}, _from, state) do
    :ets.insert(
      __MODULE__,
      {user_id, %{value: ids, stored_at: :erlang.system_time(:millisecond)}}
    )

    {:reply, :ok, state}
  end

  def handle_call({:invalidate, user_id}, _from, state) do
    :ets.delete(__MODULE__, user_id)
    {:reply, :ok, state}
  end
end
