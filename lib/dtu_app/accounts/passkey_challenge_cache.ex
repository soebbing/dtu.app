defmodule DtuApp.Accounts.PasskeyChallengeCache do
  @moduledoc """
  In-memory store for in-flight WebAuthn ceremonies.

  Each entry is `{challenge_bytes, user_id_or_nil, kind, friendly_name_or_nil,
  inserted_at}` keyed by a 32-hex-char `request_id`. Entries are
  one-shot (`fetch_and_delete/1` deletes on read) and TTL-pruned on
  every `put/2` (entries older than 5 minutes are dropped).

  Backed by a `:public, :named_table` ETS table owned by this GenServer.
  """

  use GenServer

  @ttl_ms 5 * 60 * 1000

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def child_spec(_) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]}
    }
  end

  @doc "Stores `entry` under `request_id`. Sweeps TTL-expired entries first."
  def put(request_id, entry) when is_binary(request_id) do
    GenServer.call(__MODULE__, {:put, request_id, entry})
  end

  @doc "Atomically reads and deletes the entry for `request_id`. One-shot."
  def fetch_and_delete(request_id) when is_binary(request_id) do
    GenServer.call(__MODULE__, {:fetch_and_delete, request_id})
  end

  @impl true
  def init(_) do
    table =
      :ets.new(__MODULE__, [:set, :public, :named_table, read_concurrency: true])

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put, request_id, entry}, _from, state) do
    sweep(state.table)

    :ets.insert(
      state.table,
      {request_id, Map.put(entry, :inserted_at, DateTime.utc_now())}
    )

    {:reply, :ok, state}
  end

  def handle_call({:fetch_and_delete, request_id}, _from, state) do
    case :ets.take(state.table, request_id) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [{^request_id, entry}] ->
        {:reply, {:ok, entry}, state}
    end
  end

  # Drops every entry whose `inserted_at` is older than `@ttl_ms`. Runs
  # on every `put/2`. No scheduled timer — the rate of new entries
  # bounds the cost.
  #
  # Walks the table with `:ets.tab2list/1` and compares timestamps in
  # Elixir via `DateTime.compare/2`. ETS match specifications cannot
  # compare struct values with `<` / `>` (only term-order on
  # primitives), so the comparison has to leave the match spec.
  defp sweep(table) do
    cutoff = DateTime.add(DateTime.utc_now(), -@ttl_ms, :millisecond)

    for {key, %{inserted_at: %DateTime{} = ts}} <- :ets.tab2list(table),
        DateTime.compare(ts, cutoff) == :lt,
        do: :ets.delete(table, key)
  end
end
