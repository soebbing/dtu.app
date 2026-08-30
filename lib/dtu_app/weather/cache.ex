defmodule DtuApp.Weather.Cache do
  @moduledoc """
  In-memory TTL cache for Open-Meteo responses, keyed by a 1°-rounded
  coordinate pair and the local calendar date.

  Why 1°-rounded keys? The geolocation capture is browser-precision
  (six decimal places), so two reads from the same flat can land on
  `52.5123456` vs `52.5123891`. Rounding to 1° (~111 km) collapses
  every read inside a city into one cache slot — Open-Meteo won't
  give a meaningfully different reading inside that radius anyway,
  and we avoid one ETS row per browser-precision coord. The cache is
  per-process-and-reboot (in-memory only); the same key gets
  re-fetched after a deploy.

  Backed by a `:public, :named_table` ETS table owned by this
  GenServer. Same shape as `DtuApp.Accounts.PasskeyChallengeCache` —
  read concurrency on, write concurrency off (one writer at a time
  is fine for our traffic), and a lazy sweep on every `put/2` so
  stale rows are pruned without a scheduled timer.

  Reads can happen from any process without a GenServer round-trip
  (`:public, :named_table`); the GenServer only mediates writes.
  """

  use GenServer

  @ttl_ms 15 * 60 * 1000

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def child_spec(_) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
  end

  @doc """
  Builds the cache key for a coordinate pair on a local date.

  Latitude and longitude are rounded to integers (1°-resolution
  buckets); two readings inside the same bucket collide intentionally.
  """
  @spec key(float() | integer() | Decimal.t(), float() | integer() | Decimal.t(), Date.t()) ::
          {integer(), integer(), Date.t()}
  def key(lat, lon, %Date{} = date) do
    {trunc_float(lat), trunc_float(lon), date}
  end

  @doc """
  Stores `value` under `key`. Lazy-sweeps TTL-expired entries first.
  """
  @spec put({integer(), integer(), Date.t()}, term()) :: :ok
  def put(key, value) do
    GenServer.call(__MODULE__, {:put, key, value})
  end

  @doc """
  Returns the value for `key` if younger than `@ttl_ms`, else `nil`.
  """
  @spec get({integer(), integer(), Date.t()}) :: term() | nil
  def get(key) do
    case :ets.lookup(__MODULE__, key) do
      [] ->
        nil

      [{^key, %{inserted_at: %DateTime{} = ts} = entry}] ->
        if fresh?(ts), do: entry.value, else: nil

      [_] ->
        nil
    end
  end

  @impl true
  def init(_) do
    :ets.new(__MODULE__, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    sweep()
    :ets.insert(__MODULE__, {key, %{value: value, inserted_at: DateTime.utc_now()}})
    {:reply, :ok, state}
  end

  # Walks the table and drops entries whose `inserted_at` is older
  # than `@ttl_ms`. The same `:public` named-table trick the rest of
  # the codebase uses (`:passkey_rate_limit`); ETS match specs can't
  # compare DateTime values directly so we walk the rows in Elixir.
  defp sweep do
    cutoff = DateTime.add(DateTime.utc_now(), -@ttl_ms, :millisecond)

    for {key, %{inserted_at: %DateTime{} = ts}} <- :ets.tab2list(__MODULE__),
        DateTime.compare(ts, cutoff) == :lt,
        do: :ets.delete(__MODULE__, key)
  end

  defp fresh?(%DateTime{} = ts) do
    cutoff = DateTime.add(DateTime.utc_now(), -@ttl_ms, :millisecond)
    DateTime.compare(ts, cutoff) != :lt
  end

  defp trunc_float(n) when is_float(n), do: trunc(n)
  defp trunc_float(n) when is_integer(n), do: n
  defp trunc_float(%Decimal{} = d), do: d |> Decimal.round(0) |> Decimal.to_integer()
end
