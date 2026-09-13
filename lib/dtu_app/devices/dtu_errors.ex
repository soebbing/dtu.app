defmodule DtuApp.Devices.DtuErrors do
  @moduledoc """
  Per-DTU error-history tracking.

  The `dtu_errors` table is a thin sidecar to `dtu_errors_group`
  capturing one row per "unhealthy event" raised by OpenDTU's
  status uplinks (`{serial}/status/{producing,reachable}`,
  `{serial}/reachable=false`, …) and the broker's own
  `connection_lost` reports. The cap is a count, not a TTL — see the
  `@dtu_error_history_cap 200` attribute below for the rationale.

  Two write paths:
    * `record_dtu_error/2` inserts a new event and prunes the cap
      in the same transaction.
    * `update_dtu_error/2` patches an existing row when
      follow-up telemetry recharacterises the error.

  Read paths:
    * `count_distinct_dtu_errors/2` and `list_dtu_error_groups/2`
      feed the manage-device expansion panel.
    * `clear_stale_dtu_error/1` is the SunUp-side cleanup.

  Re-exported through `DtuApp.Devices` via `defdelegate` so existing
  `Devices.record_dtu_error/2`-style call sites continue to work
  unchanged after the extraction.
  """

  import Ecto.Query

  alias DtuApp.Devices.Dtu
  alias DtuApp.Devices.DtuError
  alias DtuApp.Repo

  @dtu_error_history_cap 200

  @doc """
  Per-device cap on the number of `dtu_errors` rows kept. Exposed so
  tests can assert the prune step runs after every insert without
  reaching into the module's private state.
  """
  def dtu_error_history_cap, do: @dtu_error_history_cap

  # Recency cutoff for the user-visible error surfaces (dashboard edge
  # badge, manage-device expansion panel). An error that hasn't fired
  # within this window is hidden — a misconfigured DTU that's been
  # silent for two days doesn't deserve a permanent red badge. The
  # cutoff is enforced at query time on `dtu_errors.inserted_at`, not
  # via deletion, so a once-silent DTU that suddenly starts misbehaving
  # again shows the new error immediately without waiting for the
  # history table to be re-populated. 48 hours is wide enough to
  # cover an overnight WiFi dropout plus a workday silence, and tight
  # enough that a healthy DTU never carries a permanent badge from a
  # one-off weekend hiccup.
  @dtu_error_recency_seconds 48 * 60 * 60

  @doc """
  Cutoff (in seconds) for hiding stale `dtu_errors` rows from the
  user-visible surfaces. Errors whose `MAX(inserted_at)` per group
  is older than this many seconds before `now` are not counted or
  listed. Defaults to 48 hours.
  """
  def dtu_error_recency_seconds, do: @dtu_error_recency_seconds

  @doc """
  Resolve the recency cutoff as a DB-clock `DateTime`. The dashboard
  and manage-device panel pass this into the query helpers so the
  filter's `now` matches the row's `inserted_at` (both via the DB
  clock — see `DtuApp.Time.utc_now/0` for the rationale).
  """
  def dtu_error_recency_cutoff do
    DtuApp.Time.utc_now_usec()
    |> DateTime.add(-@dtu_error_recency_seconds, :second)
    |> DateTime.truncate(:microsecond)
  end

  @doc """
  Record an MQTT-side error for a DTU — appends one row to `dtu_errors`
  and updates the denormalised `dtus.last_error` / `last_error_at`
  cache columns in the same transaction. Read by:

    * `count_distinct_dtu_errors/2` — the dashboard's edge badge counter
    * `list_dtu_error_groups/2`     — the manage-device expansion panel
    * the existing `dtus.last_error` readers (single most-recent error)

  Whitespace-only / empty messages are a no-op (matches
  `update_inverter_name/3`'s convention). A missing DTU returns
  `{:error, :not_found}` so the caller can distinguish "device vanished"
  from "DB write failed".

  Pruning: after the insert, the per-device history is truncated to
  `dtu_error_history_cap/0` rows so the table stays bounded. The prune
  is a single `DELETE … WHERE id IN (SELECT … ORDER BY inserted_at
  DESC OFFSET cap)` — no full table scan.
  """
  @spec record_dtu_error(integer(), String.t()) :: :ok | {:error, term()}
  def record_dtu_error(dtu_id, message)
      when is_integer(dtu_id) and is_binary(message) do
    trimmed = String.trim(message)

    if trimmed == "" do
      :ok
    else
      Repo.transaction(fn ->
        case Repo.get(Dtu, dtu_id) do
          nil ->
            Repo.rollback({:not_found, dtu_id})

          %Dtu{} = dtu ->
            now = DtuApp.Time.utc_now_usec()

            case %DtuError{}
                 |> DtuError.changeset(%{dtu_id: dtu.id, message: trimmed})
                 |> Repo.insert() do
              {:ok, _error} ->
                dtu
                |> Ecto.Changeset.change(%{last_error: trimmed, last_error_at: now})
                |> Repo.update!()
                |> tap(fn _dtu -> prune_dtu_errors(dtu.id) end)

                :ok

              {:error, changeset} ->
                Repo.rollback({:insert_failed, changeset})
            end
        end
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, {:not_found, _id}} -> {:error, :not_found}
        {:error, {:insert_failed, changeset}} -> {:error, changeset}
      end
    end
  end

  @doc """
  Backwards-compatible alias for `record_dtu_error/2`. Kept so the
  previous MR (#86)'s test suite and any in-flight callers don't break.
  The new helper writes a `dtu_errors` row in addition to the column
  update; this alias delegates to it.
  """
  @spec update_dtu_error(integer(), String.t()) :: :ok | {:error, term()}
  def update_dtu_error(dtu_id, message),
    do: record_dtu_error(dtu_id, message)

  @doc """
  Clear any stale `dtus.last_error` / `last_error_at` for `dtu_id` and
  broadcast `:dtu_error` so the dashboard's edge badge / manage-device
  expansion panel re-renders without the cleared error.

  Used by `DtuApp.MqttBroker.Telemetry` on every successfully-parsed
  uplink: a device that recognises today's `inverter/total/YieldDay`
  topic but has a stale `last_error` from a *previous* version of the
  parser (which used to write `:ignored_topic` errors for fields like
  `MaxPower`) needs that stale row cleared — otherwise the device
  shows a red error bubble forever, even though the parser has long
  since stopped writing the error and the corresponding `dtu_errors`
  row is now older than the 48 h recency cutoff.

  Per-row update — only writes when the current row has a non-nil
  `last_error`, so devices that have never errored don't generate
  write traffic on every uplink. The `:dtu_error` broadcast still
  fires (no-op on the device-list side, since the manage-device
  LiveView's `handle_info({:dtu_error, _id})` does a fresh re-stream
  that already reads the cleared column).

  Returns `:ok` for a missing DTU (race: the device was deleted
  between an uplink landing and the clear running). Errors are
  swallowed and logged at warn — the worst case is a stale bubble
  persisting until the next uplink clears it.
  """
  @spec clear_stale_dtu_error(integer()) :: :ok
  def clear_stale_dtu_error(dtu_id) when is_integer(dtu_id) do
    try do
      # Per-row update gated on `not is_nil(d.last_error)` so devices
      # that have never errored don't generate write traffic on every
      # uplink. `update_all` returns `{0, nil}` when nothing matched
      # (a healthy device's `last_error` is already `nil`) — we
      # capture the count and only broadcast `:dtu_error` when at
      # least one row actually changed, so LiveViews don't re-stream
      # on every healthy uplink.
      {updated_count, _} =
        Repo.update_all(
          from(d in Dtu, where: d.id == ^dtu_id and not is_nil(d.last_error)),
          set: [last_error: nil, last_error_at: nil]
        )

      if updated_count > 0 do
        Phoenix.PubSub.broadcast(
          DtuApp.PubSub,
          DtuApp.MqttBroker.Telemetry.status_topic(),
          {:dtu_error, dtu_id}
        )
      end

      :ok
    rescue
      e ->
        require Logger
        Logger.warning("[Devices] clear_stale_dtu_error(#{dtu_id}) failed: #{inspect(e)}")
        :ok
    end
  end

  @doc """
  Number of *distinct* error messages recorded against `dtu_id` whose
  most recent occurrence is within the recency cutoff. Powers the
  dashboard's edge-badge counter: "N errors" is what the user sees at
  a glance, not the raw event count (a Shelly spamming the same
  `unknown_topic` 50× in a minute should not produce a `50`).

  Errors older than the cutoff are excluded — a misconfigured DTU
  that's been silent for two days doesn't deserve a permanent red
  badge. The cutoff defaults to `dtu_error_recency_cutoff/0` (DB
  clock minus `dtu_error_recency_seconds/0`); callers can pass a
  custom cutoff (e.g. tests pinning to a fixed instant).

  Returns 0 for devices with no history (or whose entire history is
  older than the cutoff).
  """
  @spec count_distinct_dtu_errors(integer(), DateTime.t()) :: non_neg_integer()
  def count_distinct_dtu_errors(dtu_id, cutoff \\ nil)

  def count_distinct_dtu_errors(dtu_id, nil) when is_integer(dtu_id),
    do: count_distinct_dtu_errors(dtu_id, dtu_error_recency_cutoff())

  def count_distinct_dtu_errors(dtu_id, cutoff)
      when is_integer(dtu_id) and is_struct(cutoff, DateTime) do
    # `count(e.id, :distinct)` would also work, but `count(e.message)` is
    # clearer for the table layout (`message` is the column the user
    # cares about — multiple rows with the same message collapse to one).
    # `:distinct` is a keyword flag, not a boolean — passing `true` is
    # what trips the Ecto.Query.CompileError. Wrap in `case` so a device
    # with zero errors returns 0 rather than `nil`.
    case Repo.one(
           from e in DtuError,
             where: e.dtu_id == ^dtu_id and e.inserted_at >= ^cutoff,
             select: count(e.message, :distinct)
         ) do
      nil -> 0
      n -> n
    end
  end

  @doc """
  Distinct-message rollup for `dtu_id`. Each row carries:

    * `:message`         — the user-visible error text
    * `:occurrences`     — how many times this exact message has fired
                           **within the recency cutoff**
    * `:last_seen`       — most recent `inserted_at` for this message
                           (within the cutoff)

  Ordered by `last_seen DESC` so the most-recent error appears first in
  the manage-device expansion panel. Returns `[]` for devices with no
  history (or whose entire history is older than the cutoff).

  `cutoff` defaults to `dtu_error_recency_cutoff/0` (DB clock minus
  `dtu_error_recency_seconds/0`); tests pass an explicit cutoff for
  predictability.
  """
  @spec list_dtu_error_groups(integer(), DateTime.t()) :: [
          %{message: String.t(), occurrences: non_neg_integer(), last_seen: DateTime.t()}
        ]
  def list_dtu_error_groups(dtu_id, cutoff \\ nil)

  def list_dtu_error_groups(dtu_id, nil) when is_integer(dtu_id),
    do: list_dtu_error_groups(dtu_id, dtu_error_recency_cutoff())

  def list_dtu_error_groups(dtu_id, cutoff)
      when is_integer(dtu_id) and is_struct(cutoff, DateTime) do
    Repo.all(
      from e in DtuError,
        where: e.dtu_id == ^dtu_id and e.inserted_at >= ^cutoff,
        group_by: e.message,
        # Secondary `desc: max(e.id)` tie-breaks groups whose
        # `MAX(inserted_at)` collides at the same µs — postgres coalesces
        # `now()` calls landing inside the same transaction to the same
        # value, so without the tiebreaker the rollup's order between
        # same-second groups is non-deterministic. `dtu_errors.id` is a
        # `bigserial` (monotonically increasing), so `MAX(id)` matches the
        # most recently inserted row for each group — exactly the
        # insertion-order tiebreaker the user expects. Can't sort on
        # `e.id` directly without grouping by it.
        order_by: [desc: max(e.inserted_at), desc: max(e.id)],
        select: %{
          message: e.message,
          occurrences: count(e.id),
          last_seen: max(e.inserted_at)
        }
    )
  end

  # Delete the oldest `dtu_errors` rows for `dtu_id` so the table stays
  # within `dtu_error_history_cap/0` rows. Runs inside the same
  # transaction as `record_dtu_error/2`'s insert — if the prune fails
  # the whole write rolls back, so the cache and the history table can
  # never disagree about "what is the most recent error".
  defp prune_dtu_errors(dtu_id) do
    Repo.delete_all(
      from e in DtuError,
        where:
          e.dtu_id == ^dtu_id and
            e.id not in subquery(recent_dtu_error_ids(dtu_id, @dtu_error_history_cap))
    )
  end

  defp recent_dtu_error_ids(dtu_id, cap) do
    from e in DtuError,
      where: e.dtu_id == ^dtu_id,
      order_by: [desc: e.inserted_at],
      limit: ^cap,
      select: e.id
  end

end
