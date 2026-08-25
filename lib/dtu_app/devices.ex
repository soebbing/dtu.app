defmodule DtuApp.Devices do
  @moduledoc """
  The Devices context.

  Every function is scoped to an owning `DtuApp.Accounts.User`, so a user can
  only ever touch their own devices. Create/update/delete refresh the MQTT
  credential cache (see `DtuApp.MqttBroker.Credentials`) so the broker sees new
  credentials without a restart.

  Readings are stored in a TimescaleDB hypertable (`readings`) with continuous
  aggregates (`readings_5m`, `readings_hourly`, `readings_daily`). Chart and
  summary queries prefer the aggregates to avoid scanning raw rows.
  """

  import Ecto.Query
  alias DtuApp.Repo
  alias DtuApp.Accounts.User
  alias DtuApp.Devices.Dtu
  alias DtuApp.Devices.DtuError
  alias DtuApp.Devices.Reading

  @doc "List all devices owned by `user`, newest first."
  def list_devices(%User{} = user) do
    Dtu
    |> where([d], d.user_id == ^user.id)
    |> order_by([d], desc: d.inserted_at)
    |> Repo.all()
  end

  @doc "Fetch a device owned by `user`. Raises if missing or owned by someone else."
  def get_device!(%User{} = user, id) do
    Dtu
    |> where([d], d.user_id == ^user.id and d.id == ^id)
    |> Repo.one!()
  end

  @doc """
  Non-raising variant of `get_device!/2`. Returns `nil` if the device
  doesn't exist or is owned by another user — callers use this when
  they're validating a user-supplied id (e.g. a query-param from a
  deep-link) and want the page to render with no expansion rather
  than 404 when the id is bogus.
  """
  def get_device(%User{} = user, id) do
    Dtu
    |> where([d], d.user_id == ^user.id and d.id == ^id)
    |> Repo.one()
  end

  @doc "Look up a device by its globally-unique MQTT username (broker auth path)."
  def get_device_by_username(username) when is_binary(username) do
    Repo.one(from d in Dtu, where: d.mqtt_username == ^username)
  end

  @doc "Create a device for `user` from `attrs`."
  def create_device(%User{} = user, attrs) do
    Dtu.create_changeset(user, attrs)
    |> Repo.insert()
    |> tap_on_success(&refresh_credentials/1)
  end

  @doc "Update a device from `attrs`."
  def update_device(%Dtu{} = dtu, attrs) do
    dtu
    |> Dtu.update_changeset(attrs)
    |> Repo.update()
    |> tap_on_success(&refresh_credentials/1)
  end

  @doc "Delete a device."
  def delete_device(%Dtu{} = dtu) do
    Repo.delete(dtu)
    |> tap_on_success(fn _ -> drop_credentials(dtu.mqtt_username) end)
  end

  @doc "Build a changeset for rendering a form (create)."
  def change_device(%User{} = user, %Dtu{} = dtu \\ %Dtu{}, attrs \\ %{}) do
    changeset =
      if dtu.id do
        Dtu.update_changeset(dtu, attrs)
      else
        Dtu.create_changeset(user, attrs)
      end

    Map.put(changeset, :action, :validate)
  end

  # --- Credential cache hooks -------------------------------------------------

  defp refresh_credentials(%Dtu{mqtt_username: username}) do
    safe_call(fn -> DtuApp.MqttBroker.Credentials.refresh(username) end)
  end

  defp drop_credentials(username) do
    safe_call(fn -> DtuApp.MqttBroker.Credentials.drop(username) end)
  end

  defp safe_call(fun) do
    # The Credentials GenServer runs alongside the broker (gated off in test,
    # where it isn't started). Only call it when it's actually alive.
    if GenServer.whereis(DtuApp.MqttBroker.Credentials) do
      fun.()
    end
  end

  defp tap_on_success({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_on_success(error, _fun), do: error

  # --- Readings Context -------------------------------------------------------

  @doc "Create a telemetry reading."
  def create_reading(attrs) do
    %Reading{}
    |> Reading.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Backfill `inverter_name` for every existing reading of `(dtu_id, inverter_serial)`.

  Called when OpenDTU publishes `{serial}/name` — the inverter's friendly
  name as configured in the OpenDTU web UI. Updating every historical row
  makes the chart legend pick up the new name immediately, instead of only
  appearing on readings that arrive after the name uplink.

  Empty / whitespace-only names are ignored so we don't blank out a name
  that a different uplink already set.
  """
  def update_inverter_name(dtu_id, inverter_serial, name)
      when is_integer(dtu_id) and is_binary(inverter_serial) and is_binary(name) do
    trimmed = String.trim(name)

    if trimmed == "" do
      # Empty / whitespace-only payload — refuse to blank out a name a prior
      # uplink already set. Returns `{:ok, 0}` so the caller's pattern match
      # is uniform with the success path.
      {:ok, 0}
    else
      {count, _} =
        Repo.update_all(
          from(r in Reading,
            where: r.dtu_id == ^dtu_id and r.inverter_serial == ^inverter_serial
          ),
          set: [inverter_name: trimmed]
        )

      {:ok, count}
    end
  end

  @doc """
  Update `producing` / `reachable` flags on the latest reading for an inverter.

  OpenDTU's `{serial}/status/{producing|reachable}` uplinks arrive
  independently from the `realtime/data` consolidated message. To avoid
  producing yet another row per flag change, we patch the most recent
  existing reading for that `(dtu_id, inverter_serial)` in place.

  Returns `{:error, :no_readings}` if the inverter has no readings yet —
  the next `realtime/data` uplink will create the first row and pick up
  the flags via the consolidated payload.
  """
  def patch_latest_reading_status(dtu_id, inverter_serial, flags)
      when is_integer(dtu_id) and is_binary(inverter_serial) and is_map(flags) do
    sub =
      from(r in Reading,
        where: r.dtu_id == ^dtu_id and r.inverter_serial == ^inverter_serial,
        order_by: [desc: r.inserted_at],
        limit: 1
      )

    case Repo.one(sub) do
      nil ->
        {:error, :no_readings}

      latest ->
        # `flags` may have atom keys (tests) or string keys (the OpenDTU
        # parser emits string keys from the MQTT topic). Normalise to atoms
        # so the schema cast receives the right field names.
        atom_flags =
          flags
          |> Enum.map(fn
            {k, v} when is_atom(k) -> {k, v}
            {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
          end)
          |> Map.new()

        update_attrs =
          atom_flags
          |> Map.take([:producing, :reachable])
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

        if map_size(update_attrs) == 0 do
          {:ok, latest}
        else
          {:ok,
           latest
           |> Reading.changeset(update_attrs)
           |> Repo.update!()}
        end
    end
  end

  # Per-device cap for the `dtu_errors` history. Each insert prunes the
  # oldest rows beyond this number so the table stays bounded without a
  # separate sweep job. 200 events per device covers ~weeks of typical
  # misbehaviour (a Shelly spamming `unknown_topic` every few seconds)
  # and gives the manage-device expansion panel plenty of rows to
  # summarise. A cap rather than a TTL is deliberate: a DTU that's been
  # misbehaving for a month should still have its oldest error visible —
  # the user's *first* encounter with the issue is often the most
  # diagnostic one, and a TTL would erase it.
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

  @doc "List recent readings for a specific user-owned DTU."
  def list_recent_readings(%User{} = user, dtu_id, limit \\ 100) do
    if owned?(user, dtu_id) do
      Repo.all(
        from r in Reading,
          where: r.dtu_id == ^dtu_id,
          order_by: [desc: r.inserted_at],
          limit: ^limit
      )
    else
      []
    end
  end

  @doc """
  Fetch all readings for the user's DTUs whose `inserted_at` falls within
  the inclusive UTC range `[utc_start, utc_end]`. Use `local_day_utc_range/2`
  to translate a user-facing local date into a UTC range before calling.
  """
  def list_day_readings_for_chart(%User{} = user, utc_start, utc_end, dtu_id \\ nil)
      when is_struct(utc_start, DateTime) and is_struct(utc_end, DateTime) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      []
    else
      Repo.all(
        from r in Reading,
          where:
            r.dtu_id in ^dtu_ids and
              r.inserted_at >= ^utc_start and r.inserted_at <= ^utc_end,
          order_by: [asc: r.inserted_at],
          select: %{
            inserted_at: r.inserted_at,
            ac_power: r.ac_power,
            # Per-MPPT rows store their power in `dc_power` (the firmware
            # only emits per-channel DC scalars). The chart aggregation
            # below picks the right one per row via `chart_power_for_mppt/1`.
            dc_power: r.dc_power,
            dtu_id: r.dtu_id,
            inverter_serial: r.inverter_serial,
            mppt_index: r.mppt_index,
            inverter_name: r.inverter_name
          }
      )
    end
  end

  @doc """
  Translate a user-facing local date into the inclusive UTC range
  `[00:00 local, 23:59:59 local]` — what the readings table actually
  queries against. Pass `tz_offset_seconds` from
  `socket.assigns.user_tz_offset_seconds`.

  Examples (winter, no DST):

      iex> local_day_utc_range(~D[2026-07-31], 3600)
      {~U[2026-07-30 23:00:00Z], ~U[2026-07-31 22:59:59Z]}

      iex> local_day_utc_range(~D[2026-07-31], 0)
      {~U[2026-07-31 00:00:00Z], ~U[2026-07-31 23:59:59Z]}
  """
  @spec local_day_utc_range(Date.t(), integer()) :: {DateTime.t(), DateTime.t()}
  def local_day_utc_range(%Date{} = local_date, tz_offset_seconds) do
    {:ok, start_local} = DateTime.new(local_date, ~T[00:00:00])
    {:ok, end_local} = DateTime.new(local_date, ~T[23:59:59])

    {DateTime.add(start_local, -tz_offset_seconds, :second),
     DateTime.add(end_local, -tz_offset_seconds, :second)}
  end

  # A chart series identifies one line on the live/day chart: one
  # (inverter, mppt) pair. `inverter_name` is the optional display label
  # the user can set; the chart falls back to the serial when it's nil.
  @type series_key ::
          {dtu_id :: pos_integer(), inverter_serial :: String.t(),
           mppt_index :: non_neg_integer(), inverter_name :: String.t() | nil}

  @type chart_point :: %{time: DateTime.t(), series: series_key(), power: float()}

  @doc """
  Fetch a day's worth of readings for the user's DTUs and bucket them
  per (dtu_id, inverter_serial, mppt_index) into 5-minute averages, so
  the chart can render one line per (inverter, MPPT) instead of a
  single total.

  Each `power` point picks `ac_power` for the AC-aggregate row
  (`mppt_index = 0` — the AhoyDTU ch0 / OpenDTU total) and `dc_power`
  for the per-MPPT rows (`mppt_index >= 1` — individual DC strings).
  Per-MPPT rows never carry `ac_power` (the firmware only emits
  per-channel DC on `[serial]/[1-4]/...` topics), so collapsing them
  to `ac_power || 0.0` would draw every per-MPPT line flat at the
  X-axis even when those strings are producing.

  This implementation walks the raw `readings` hypertable and buckets
  in the BEAM, which is fine for a few hundred rows but scales poorly
  once a DTU starts emitting a row every 10–30s for a full day
  (≈20 000+ raw rows per device). The dashboard's hot path uses
  `list_day_chart_data_for_dashboard/4` (aggregate-backed) instead;
  this helper stays for callers that need a row-accurate view (e.g.
  `compute_day_period_stats/2` against a single historical day where
  the per-MPPT detail matters).
  """
  def list_day_chart_data(%User{} = user, utc_start, utc_end, dtu_id \\ nil)
      when is_struct(utc_start, DateTime) and is_struct(utc_end, DateTime) do
    readings = list_day_readings_for_chart(user, utc_start, utc_end, dtu_id)

    if readings == [] do
      []
    else
      readings
      |> Enum.group_by(fn r -> div(DateTime.to_unix(r.inserted_at), 300) end)
      |> Enum.flat_map(fn {bucket, bucket_readings} ->
        time = DateTime.from_unix!(bucket * 300)

        bucket_readings
        |> Enum.group_by(fn r -> {r.dtu_id, r.inverter_serial, r.mppt_index, r.inverter_name} end)
        |> Enum.map(fn {series, series_readings} ->
          powers = Enum.map(series_readings, &chart_power_for_mppt/1)
          power = Enum.sum(powers) / length(series_readings)

          %{time: time, series: series, power: power}
        end)
      end)
      |> Enum.sort_by(& &1.time)
    end
  end

  # Live / historical day chart, aggregate-backed. Replaces the per-row
  # scan that `list_day_chart_data/4` did for the dashboard's hot path.
  # See the `Devices` moduledoc for the broader rationale.
  @doc """
  Same shape as `list_day_chart_data/4`, but reads the per-bucket
  average from the `readings_5m` continuous aggregate for everything
  older than the aggregate's `end_offset` (5 min — matches the
  policy: `add_continuous_aggregate_policy('readings_5m', end_offset =>
  INTERVAL '5 minutes')`). The most recent 5 minutes of the day
  aren't materialised yet, so we union with the raw `readings` table
  for that tail.

  Returns a flat list of `%{time, series, power}` map points — the
  exact contract `list_day_chart_data/4` returns — so the dashboard
  can swap the implementation without touching the chart code.

  ## Why this matters

  Without the aggregate, `list_day_chart_data/4` would walk every raw
  `readings` row in the day for every dashboard mount and every
  reading-triggered refresh. A typical AhoyDTU install publishes
  ~4 300 AC rows + ~10–20 000 per-MPPT rows per day per DTU; a fleet
  of two inverters plus a Shelly produces 20–30 thousand rows / day,
  most in the current (uncompressed) hypertable chunk. The 5-minute
  aggregate holds one row per `(bucket, dtu_id, inverter_serial,
  mppt_index)` — at 288 buckets/day that's ≤ 1 200 rows per device
  per day, an order-of-magnitude fewer rows than the raw table.

  The 5-minute live tail (`utc_tail_start = now - 5 min`) is read
  from the raw table because the aggregate lags by `end_offset`. The
  tail's bucket means are computed in the BEAM (the same way
  `list_day_chart_data/4` does for the full day) — the small row
  count there makes the BEAM bucketing a non-issue.

  Returns `[]` when the user has no devices or no readings in the
  window.
  """
  @spec list_day_chart_data_for_dashboard(User.t(), DateTime.t(), DateTime.t(), integer() | nil) ::
          [
            chart_point()
          ]
  def list_day_chart_data_for_dashboard(
        %User{} = user,
        utc_start,
        utc_end,
        dtu_id \\ nil
      )
      when is_struct(utc_start, DateTime) and is_struct(utc_end, DateTime) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      []
    else
      now_usec = DtuApp.Time.utc_now_usec()

      # The continuous aggregate has a 5-minute `end_offset`, so the
      # newest closed bucket is `now - 5min`. Anything more recent than
      # that lands in the raw-table "live tail".
      utc_tail_start =
        now_usec |> DateTime.add(-300, :second) |> DateTime.truncate(:microsecond)

      # Materialised buckets: `bucket < utc_tail_start` (closed-only).
      # `readings_5m.bucket` is the aggregate's time column.
      #
      # `avg_ac_power` is NULL on per-MPPT rows (`mppt_index >= 1`,
      # where the firmware only publishes `dc_power`) — but the
      # dashboard filters those out (`Enum.filter` in
      # `assign_line_chart_data/5`), so this NULL never reaches the
      # chart.
      aggregate_points =
        Repo.all(
          from a in "readings_5m",
            where:
              a.dtu_id in ^dtu_ids and a.bucket < ^utc_tail_start and
                a.bucket >= ^utc_start and a.bucket <= ^utc_end,
            select: %{
              # `readings_5m.bucket` is the aggregate's time column
              # (TimescaleDB's `time_bucket(...)` result). The chart
              # pipeline expects `:time` everywhere — the live tail
              # (`live_tail_bucketed_chart_points/3`) and the
              # raw-row fallback (`list_day_chart_data/4`) both use
              # `:time` for the same field. Selecting the column as
              # `:time` here keeps the consumer contract uniform and
              # lets the `case pt.time` argument coercion below
              # (NaiveDateTime → DateTime) handle the aggregate rows
              # in the same pass as the live tail.
              time: a.bucket,
              dtu_id: a.dtu_id,
              inverter_serial: a.inverter_serial,
              mppt_index: a.mppt_index,
              inverter_name: a.inverter_name,
              power: a.avg_ac_power
            }
        )
        # The aggregate SELECT returns a wide-table shape (`dtu_id`,
        # `inverter_serial`, `mppt_index`, `inverter_name` as separate
        # fields) — that's what TimescaleDB's continuous aggregate view
        # exposes. The chart pipeline (`DashboardLive.assign_line_chart_data/5`,
        # `get_daily_stats/3`'s `bucket_max`, the `chart_power_for_mppt/1` per-MPPT
        # filter) consumes the `chart_point()` contract, where `:series`
        # is a 4-tuple `{dtu_id, inverter_serial, mppt_index, inverter_name}`
        # — not four fields. Without this reshape, every consumer that does
        # `elem(pt.series, N)` raises `KeyError: key :series not found`.
        # The live tail (`live_tail_bucketed_chart_points/3`) and the
        # raw-row fallback (`list_day_chart_data/4`) already produce the
        # 4-tuple shape; only the aggregate path needs the reshape.
        |> Enum.map(fn pt ->
          %{
            time: pt.time,
            series: {pt.dtu_id, pt.inverter_serial, pt.mppt_index, pt.inverter_name},
            power: pt.power
          }
        end)

      # Live tail — raw rows, bucketed via `time_bucket` in SQL so the
      # shape matches the aggregate exactly. The 5-minute tail is
      # small (≤ 5 min × 30 uplinks/min × N devices) so the bucketing
      # is cheap, and skipping it would make the chart's "most
      # recent bucket" lag up to 5 min behind reality.
      live_tail_chart_points = live_tail_bucketed_chart_points(utc_tail_start, dtu_ids, utc_end)

      # Fallback: a brand-new or never-refreshed `readings_5m`
      # aggregate is empty (`WITH NO DATA` from the migration + no
      # policy run since the first uplink). The first dashboard
      # mount for a fresh install — or a test DB with no materialised
      # buckets — would render an empty chart even though raw rows
      # exist for the period. The fallback fires whenever the
      # aggregate is empty, **regardless of the live tail** — the
      # live tail only covers the last 5 minutes, so a cold
      # aggregate plus day-old readings would otherwise drop
      # everything but the last 5 minutes of data. The fallback
      # path (`list_day_chart_data/4`) walks the raw rows for the
      # full day and produces the same chart the pre-aggregate code
      # did, so a cold aggregate doesn't blank the chart or lose
      # out-of-tail readings. Once the aggregate fills in (after
      # the first 5-min policy run), this branch won't fire and the
      # hot path serves the optimised read.
      result =
        if aggregate_points == [] do
          list_day_chart_data(user, utc_start, utc_end, dtu_id)
        else
          aggregate_points ++ live_tail_chart_points
        end

      result
      |> Enum.map(fn pt ->
        # `readings_5m.bucket` and the SQL `time_bucket(...)` result
        # are `timestamp without time zone` columns. Without a schema
        # cast (the aggregate has no Ecto schema), Postgrex decodes
        # them as `NaiveDateTime`, but the rest of the dashboard
        # (`shift_local/2`, `chart_time_range/2`, the bucket-mean
        # arithmetic) expects `%DateTime{}`. Lift the value back into
        # a UTC `DateTime` here so the contract matches
        # `list_day_chart_data/4`. The raw-row fallback already
        # returns `%DateTime{}` from `list_day_chart_data/4`, so the
        # `case` keeps the function's contract uniform across both
        # branches.
        case pt.time do
          %DateTime{} -> pt
          %NaiveDateTime{} -> %{pt | time: DateTime.from_naive!(pt.time, "Etc/UTC")}
        end
      end)
      |> Enum.sort_by(& &1.time)
    end
  end

  # Live-today ghost chart: yesterday's closed-bucket chart points for
  # the user's DTU scope. Backs the dashboard's "yesterday ghost line"
  # overlay behind today's curve.
  #
  # Returns the same `%{time, series, power}` shape as
  # `list_day_chart_data_for_dashboard/4`. Yesterday is fully closed
  # (no live tail needed — there's no 5-min raw tail for a day that's
  # already past midnight), so this reads from `readings_5m` only.
  # Falls back to `list_day_chart_data/4` against the same window when
  # the aggregate is empty (cold installs, fresh test DBs).
  @doc """
  Returns yesterday's per-bucket chart points for the same scope
  (`dtu_id`) and time window as `list_day_chart_data_for_dashboard/4`,
  shifted by -1 day. Used by the dashboard's 1D live view to render
  a translucent ghost line behind today's curve.

  The window is computed by subtracting 1 day from the supplied
  `utc_start` / `utc_end`, so callers can reuse their today's-window
  DateTimes without re-deriving them. `dtu_id` filters the same way
  it does in the today function (nil = fleet-wide).

  Returns `[]` when the user has no devices or no readings in the
  yesterday window.
  """
  @spec list_yesterday_chart_data_for_dashboard(
          User.t(),
          DateTime.t(),
          DateTime.t(),
          integer() | nil
        ) :: [chart_point()]
  def list_yesterday_chart_data_for_dashboard(
        %User{} = user,
        utc_start,
        utc_end,
        dtu_id \\ nil
      )
      when is_struct(utc_start, DateTime) and is_struct(utc_end, DateTime) do
    # Shift the window back by one day so callers can reuse the same
    # DateTimes they pass to `list_day_chart_data_for_dashboard/4`.
    yesterday_start = DateTime.add(utc_start, -86_400, :second)
    yesterday_end = DateTime.add(utc_end, -86_400, :second)

    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      []
    else
      # Yesterday is past — every bucket is closed. No live tail to
      # union with; the aggregate alone covers the full window.
      # We still apply the same defensive contract as the today path:
      # the cold-aggregate fallback keeps a fresh test DB / brand-new
      # install from rendering an empty ghost when raw rows exist.
      aggregate_points =
        Repo.all(
          from a in "readings_5m",
            where:
              a.dtu_id in ^dtu_ids and
                a.bucket >= ^yesterday_start and a.bucket <= ^yesterday_end,
            select: %{
              time: a.bucket,
              dtu_id: a.dtu_id,
              inverter_serial: a.inverter_serial,
              mppt_index: a.mppt_index,
              inverter_name: a.inverter_name,
              power: a.avg_ac_power
            }
        )
        |> Enum.map(fn pt ->
          %{
            time: pt.time,
            series: {pt.dtu_id, pt.inverter_serial, pt.mppt_index, pt.inverter_name},
            power: pt.power
          }
        end)
        |> Enum.map(fn pt ->
          case pt.time do
            %DateTime{} -> pt
            %NaiveDateTime{} -> %{pt | time: DateTime.from_naive!(pt.time, "Etc/UTC")}
          end
        end)

      if aggregate_points == [] do
        list_day_chart_data(user, yesterday_start, yesterday_end, dtu_id)
      else
        aggregate_points
      end
    end
  end

  # Returns the chart's bucket-mean shape for raw rows whose
  # `inserted_at >= utc_tail_start`. Aggregated by
  # `(bucket, dtu_id, inverter_serial, mppt_index)` via `time_bucket`
  # so the output rows match the `readings_5m` schema 1:1. Returns
  # the same `%{time, series, power}` map shape as
  # `list_day_chart_data/4`.
  defp live_tail_bucketed_chart_points(utc_tail_start, dtu_ids, utc_end) do
    # `time_bucket('5 minutes', ...)` has the same boundary semantics
    # as `readings_5m`'s bucket column, so concatenating with the
    # aggregate rows produces a single ordered stream.
    tail_rows =
      Repo.all(
        from r in Reading,
          where:
            r.dtu_id in ^dtu_ids and
              r.inserted_at >= ^utc_tail_start and r.inserted_at <= ^utc_end,
          group_by: [
            fragment("time_bucket(INTERVAL '5 minutes', ?)", r.inserted_at),
            r.dtu_id,
            r.inverter_serial,
            r.mppt_index,
            r.inverter_name
          ],
          select: %{
            bucket: fragment("time_bucket(INTERVAL '5 minutes', ?)", r.inserted_at),
            dtu_id: r.dtu_id,
            inverter_serial: r.inverter_serial,
            mppt_index: r.mppt_index,
            inverter_name: r.inverter_name,
            ac_power: fragment("avg(?)", r.ac_power),
            dc_power: fragment("avg(?)", r.dc_power)
          }
      )

    Enum.map(tail_rows, fn row ->
      series = {row.dtu_id, row.inverter_serial, row.mppt_index, row.inverter_name}

      %{
        time: row.bucket,
        series: series,
        # Per `list_day_chart_data/4`: pick `ac_power` for AC-aggregate
        # rows (`mppt_index = 0`) and `dc_power` for per-MPPT rows.
        # The aggregate's NULLs for per-MPPT rows are dropped by the
        # dashboard's filter, so we don't have to guard against them
        # here.
        power:
          chart_power_for_mppt(%{
            mppt_index: row.mppt_index,
            ac_power: row.ac_power,
            dc_power: row.dc_power
          })
      }
    end)
  end

  @doc "Fetch today's readings for the user's DTUs (raw rows)."
  def list_today_readings_for_chart(%User{} = user, dtu_id \\ nil) do
    today_utc = Date.utc_today()
    {utc_start, _} = local_day_utc_range(today_utc, 0)
    list_day_readings_for_chart(user, utc_start, ~U[9999-12-31 23:59:59Z], dtu_id)
  end

  @doc "Fetch today's power readings as 5-minute buckets for charts."
  def list_today_chart_data(%User{} = user, dtu_id \\ nil) do
    today_utc = Date.utc_today()
    {utc_start, _} = local_day_utc_range(today_utc, 0)
    list_day_chart_data(user, utc_start, ~U[9999-12-31 23:59:59Z], dtu_id)
  end

  @doc """
  Same shape as `list_today_chart_data/2`, but only for
  `power_type = :consumption` rows — i.e. the household's drawn power
  published by a paired Shelly Plus 3EM (Gen3+) energy meter. Each
  Shelly device is a single series (one meter), so the buckets
  collapse to one point per 5-minute window per device.
  """
  def list_today_consumption_chart_data(%User{} = user, dtu_id \\ nil) do
    today_utc = Date.utc_today()
    {utc_start, _} = local_day_utc_range(today_utc, 0)

    list_consumption_chart_data(user, utc_start, ~U[9999-12-31 23:59:59Z], dtu_id)
  end

  def list_consumption_chart_data(%User{} = user, utc_start, utc_end, dtu_id \\ nil)
      when is_struct(utc_start, DateTime) and is_struct(utc_end, DateTime) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      []
    else
      readings =
        Repo.all(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and r.power_type == "consumption" and
                r.inserted_at >= ^utc_start and r.inserted_at <= ^utc_end,
            select: %{
              inserted_at: r.inserted_at,
              consumption_power: r.consumption_power,
              dtu_id: r.dtu_id
            }
        )

      if readings == [] do
        []
      else
        readings
        |> Enum.group_by(fn r -> div(DateTime.to_unix(r.inserted_at), 300) end)
        |> Enum.flat_map(fn {bucket, bucket_readings} ->
          time = DateTime.from_unix!(bucket * 300)

          # One chart series per (dtu_id) — a Shelly device is a single
          # physical meter even if it publishes per-phase fields; we sum
          # across phases upstream and store a single `total_act_power`
          # in `consumption_power`. So the bucket mean is the
          # household's average drawn watts in that window, per device.
          bucket_readings
          |> Enum.group_by(fn r -> r.dtu_id end)
          |> Enum.map(fn {dtu_id, series_readings} ->
            # `clamp_household_draw/1` filters the Shelly's signed
            # `total_act_power` to ≥ 0 W so the consumption overlay
            # never dips below the X-axis when the home is net-
            # exporting. The net-flow arithmetic still subtracts the
            # clamped value (see `list_net_chart_data/4`), keeping
            # "net export" bounded above by total solar production.
            powers =
              Enum.map(series_readings, fn r -> clamp_household_draw(r.consumption_power) end)

            power = Enum.sum(powers) / length(series_readings)

            %{time: time, series: {dtu_id, "em:0", 0, nil}, power: power}
          end)
        end)
        |> Enum.sort_by(& &1.time)
      end
    end
  end

  @doc """
  Net flow chart series — production minus consumption, bucketed into
  the same 5-minute windows used by `list_day_chart_data/4` and
  `list_consumption_chart_data/4`. Net flow is the most actionable
  single number on a solar dashboard: positive means the home is
  exporting (selling to the grid), negative means importing (buying).

  Both sides must be present for a meaningful series — without a Shelly,
  the household draw is unknown and the dashboard falls back to the
  pure-production view. Without an inverter, there's nothing to net
  against. The dashboard hides the net-flow chart and stat cards
  unless both kinds are present (`@net_flow_active`).

  The series is built by:
    1. Fetching all readings (production + consumption) in the UTC
       window — one SQL query, no per-power-type round-trip.
    2. Grouping by 5-minute bucket.
    3. Within each bucket, computing the **bucket mean** per device on
       each side: the AC aggregate row (`mppt_index = 0`) is the
       inverter's true AC output (per-MPPT DC rows are excluded — they
       duplicate the AC output and would double-count the inverter),
       and each Shelly device contributes its `consumption_power` mean
       across all uplinks in the bucket. The per-device means are then
       summed across devices so a 2-MPPT Hoymiles (1 row per bucket)
       and a Shelly (~10 rows per bucket) both contribute a single
       house-wide figure to the net.
    4. Returning `%{time, power}` per bucket, where `power` is
       `production - consumption`. A positive value means export;
       negative means import.

  ## Why per-device mean instead of sum?

  Summing every raw row in the bucket produces wildly wrong numbers:

    * **Production** — a multi-MPPT Hoymiles publishes the AC total
      on `realtime/data` *and* per-string DC on `[serial]/[1-N]/power`.
      Summing all rows double- or triples the inverter's actual AC
      output.
    * **Consumption** — a Shelly Plus 3EM publishes ~10× per 5-min
      window (every 30s). Summing every reading reports 10× the true
      household draw (e.g. `76 W` on the Shelly app rendered as
      `760 W` on the dashboard — exactly the "factor of 10" users
      reported).

  Averaging per device collapses each side to a single number in the
  same units (W) before the subtraction, mirroring what
  `list_day_chart_data/4` and `list_consumption_chart_data/4` already
  do for their chart buckets.

  Returns `[]` when the user has no devices or no readings in the
  window — the dashboard hides the net-flow row.
  """
  @spec list_net_chart_data(User.t(), DateTime.t(), DateTime.t(), integer() | nil) :: [
          %{time: DateTime.t(), power: float()}
        ]
  def list_net_chart_data(%User{} = user, utc_start, utc_end, dtu_id \\ nil)
      when is_struct(utc_start, DateTime) and is_struct(utc_end, DateTime) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      []
    else
      # Single SQL query that pushes the production/consumption split
      # into the database via `FILTER` aggregates on the raw
      # `readings` rows. The result is one row per
      # `(bucket, dtu_id, inverter_serial)` that has any data on either
      # side — typically a few hundred rows for a day's worth of data,
      # versus the ~30k raw rows the BEAM-driven path used to fetch.
      #
      # The `FILTER` clauses mirror the BEAM-side guards the previous
      # implementation used:
      #
      #   * `power_type = 'production' AND mppt_index = 0` selects the
      #     AC aggregate row only — per-MPPT DC rows duplicate the AC
      #     total and would 2×/3× the inverter's actual output if
      #     included.
      #   * `power_type = 'consumption'` selects the Shelly's
      #     instantaneous draw. `GREATEST(consumption_power, 0)` clamps
      #     to ≥ 0 W so net-export windows where the Shelly publishes
      #     negative `total_act_power` don't inflate the net figure
      #     past the inverter's actual output.
      #
      # `time_bucket('5 minutes', inserted_at)` is the same bucketing
      # the `readings_5m` continuous aggregate uses, so the bucket
      # boundaries line up with the production chart's buckets.
      # `AVG(...)` collapses each Shelly's ~10× per-5-min readings
      # (and a multi-MPPT Hoymiles's per-minute per-string rows) to
      # a single figure per (bucket, device) — the same per-device
      # average the pre-rewrite code computed in BEAM.
      bucketed =
        Repo.all(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and
                r.inserted_at >= ^utc_start and r.inserted_at <= ^utc_end,
            group_by: [
              fragment("time_bucket(INTERVAL '5 minutes', ?)", r.inserted_at),
              r.dtu_id,
              r.inverter_serial
            ],
            select: %{
              bucket: fragment("time_bucket(INTERVAL '5 minutes', ?)", r.inserted_at),
              dtu_id: r.dtu_id,
              inverter_serial: r.inverter_serial,
              production_w:
                fragment(
                  "avg(?) FILTER (WHERE ? = 'production' AND ? = 0)",
                  r.ac_power,
                  r.power_type,
                  r.mppt_index
                ),
              consumption_w:
                fragment(
                  "avg(GREATEST(?, 0)) FILTER (WHERE ? = 'consumption')",
                  r.consumption_power,
                  r.power_type
                ),
              # `count(*) FILTER (WHERE power_type='consumption')` lets the
              # drop-bucket guard below distinguish "bucket had at least
              # one consumption row" from "no consumption row at all".
              # The clamped mean can be 0 W (a net-export window where
              # every Shelly reading was negative) while the bucket still
              # contains real data — keeping it preserves the
              # production − 0 = export signal. Without this flag, the
              # guard would drop those buckets and lose the export curve
              # for net-exporting homes. Adds one extra `count(*)` per
              # bucket to the work the planner already does alongside
              # the two `avg`s.
              consumption_presence:
                fragment(
                  "count(*) FILTER (WHERE ? = 'consumption')",
                  r.power_type
                )
            }
        )

      if bucketed == [] do
        []
      else
        bucketed
        |> Enum.group_by(fn row -> row.bucket end)
        |> Enum.flat_map(fn {bucket, bucket_rows} ->
          # `production_w` is NULL for rows that only have consumption
          # rows in the bucket (and vice versa) — `|| 0.0` collapses
          # both to a numeric zero so the SUM below doesn't drop NULL
          # and skip the bucket.
          production_w =
            bucket_rows
            |> Enum.map(fn r -> r.production_w || 0.0 end)
            |> Enum.sum()

          consumption_w =
            bucket_rows
            |> Enum.map(fn r -> r.consumption_w || 0.0 end)
            |> Enum.sum()

          # Drop buckets where no Shelly uplink landed at all —
          # without this guard, the net-flow curve would equal the
          # production line (`production - 0 = production`) and just be
          # a duplicate of the Total. A bucket where the clamped
          # consumption is 0 but the bucket had at least one
          # consumption row (net-export window where every Shelly reading
          # was negative) is *kept* — `production - 0 = production` is
          # exactly the export signal the chart should plot. Matches
          # the pre-rewrite BEAM guard
          # (`Enum.any?(&(&1.power_type == "consumption"))`).
          has_consumption_row =
            Enum.any?(bucket_rows, fn row ->
              (row.consumption_presence || 0) > 0
            end)

          if consumption_w > 0.0 or has_consumption_row do
            [%{time: lift_naive!(bucket), power: production_w - consumption_w}]
          else
            []
          end
        end)
        |> Enum.sort_by(& &1.time)
      end
    end
  end

  # `time_bucket` returns a `timestamp without time zone` so Postgres
  # decodes it as `NaiveDateTime`. The dashboard's chart pipeline
  # (`shift_local/2`, `chart_time_range/2`, the bucket-mean math)
  # expects `%DateTime{}` — see the matching `case` in
  # `list_day_chart_data_for_dashboard/4` for the same coercion.
  defp lift_naive!(%NaiveDateTime{} = naive),
    do: DateTime.from_naive!(naive, "Etc/UTC")

  defp lift_naive!(%DateTime{} = dt), do: dt

  @doc """
  Net flow stat snapshot — mirrors `get_daily_stats/3` /
  `get_consumption_daily_stats/2` for the difference between the two.

  Returns:
    * `current_net_flow`   — W, fresh (last 2 min). Positive = exporting,
      negative = importing. `production - consumption` summed across
      the user's devices, computed from the latest reading per
      `(dtu_id, power_type)` pair (so a Shelly publishing every 30s
      isn't summed 10× like the bucket paths used to — see
      `list_net_chart_data/4` for the matching per-bucket fix).
    * `today_net_export`   — kWh, total energy exported today (the sum
      of positive net-flow buckets, in kWh).
    * `today_net_import`   — kWh, total energy imported today (the sum
      of negative net-flow buckets, in absolute kWh).
    * `peak_export` / `peak_import` — W, largest single-bucket export /
      import in the day, used for the dashboard's headline.

  Returns zero defaults when the user has no devices or no readings.
  """
  @spec get_net_flow_stats(User.t(), integer() | nil) :: %{
          current_net_flow: float(),
          today_net_export: float(),
          today_net_import: float(),
          peak_export: float(),
          peak_import: float()
        }
  def get_net_flow_stats(%User{} = user, dtu_id \\ nil) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      %{
        current_net_flow: 0.0,
        today_net_export: 0.0,
        today_net_import: 0.0,
        peak_export: 0.0,
        peak_import: 0.0
      }
    else
      today_start = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
      today_end = DateTime.new!(Date.utc_today(), ~T[23:59:59], "Etc/UTC")
      two_minutes_ago = DtuApp.Time.utc_now() |> DateTime.add(-120, :second)

      points = list_net_chart_data(user, today_start, today_end, dtu_id)

      if points == [] do
        %{
          current_net_flow: 0.0,
          today_net_export: 0.0,
          today_net_import: 0.0,
          peak_export: 0.0,
          peak_import: 0.0
        }
      else
        # Convert the bucket-mean power (W) into energy (Wh) by
        # multiplying by the bucket duration (5 min = 1/12 h).
        bucket_h = 5.0 / 60.0
        net_per_bucket = Enum.map(points, fn p -> p.power * bucket_h end)

        # Exports are positive bucket-hours; imports are negative.
        # We sum the absolute values on each side to express
        # `today_net_export` and `today_net_import` in Wh, then convert
        # to kWh at the end.
        exported_wh =
          net_per_bucket
          |> Enum.filter(&(&1 > 0.0))
          |> Enum.sum()

        imported_wh =
          net_per_bucket
          |> Enum.filter(&(&1 < 0.0))
          |> Enum.map(&abs/1)
          |> Enum.sum()

        # Peak export = largest single positive bucket; peak import =
        # largest single negative bucket (as a positive W).
        peak_export = Enum.max(Enum.map(points, & &1.power), fn -> 0.0 end)
        peak_import = Enum.max(Enum.map(points, fn p -> abs(p.power) end), fn -> 0.0 end)

        # Live net flow: take the freshest reading's `production_power -
        # consumption_power` rather than relying on the bucket mean
        # (which lags a few minutes when the bucket hasn't filled).
        latest_readings =
          Repo.all(
            from r in Reading,
              where: r.dtu_id in ^dtu_ids,
              distinct: [r.dtu_id, r.power_type],
              order_by: [r.dtu_id, r.power_type, desc: r.inserted_at]
          )

        # `distinct: [r.dtu_id, r.power_type]` gives one row per
        # (dtu_id, power_type) — production and consumption latest.
        {production_now, consumption_now} =
          Enum.reduce(latest_readings, {0.0, 0.0}, fn r, {p, c} ->
            fresh? = DateTime.after?(r.inserted_at, two_minutes_ago)

            cond do
              not fresh? -> {p, c}
              r.power_type == "production" -> {p + chart_power_for_mppt(r), c}
              # Clamp the Shelly's signed `total_act_power` to the
              # household-draw reading the dashboard reports as
              # "Current Consumption" (always ≥ 0 W). Without the
              # clamp, a sunny midday with low draw would render the
              # "Net export" figure as `production - (-|draw|) =
              # production + |draw|`, exceeding the inverter's
              # actual output.
              r.power_type == "consumption" -> {p, c + clamp_household_draw(r.consumption_power)}
              true -> {p, c}
            end
          end)

        current_net_flow = production_now - consumption_now

        %{
          current_net_flow: Float.round(current_net_flow * 1.0, 1),
          today_net_export: Float.round(exported_wh / 1000, 2),
          today_net_import: Float.round(imported_wh / 1000, 2),
          peak_export: Float.round(peak_export * 1.0, 1),
          peak_import: Float.round(peak_import * 1.0, 1)
        }
      end
    end
  end

  @doc "Calculate aggregated daily stats for a user's DTUs (or a specific DTU)."
  def get_daily_stats(%User{} = user, dtu_id \\ nil) do
    get_daily_stats(user, dtu_id, Date.utc_today(), [])
  end

  @doc """
  Variant of `get_daily_stats/4` that lets callers thread in a pre-fetched
  chart-points list. The dashboard's `today` branch fetches the day-chart
  points once (for both the SVG render and the peak-power `bucket_max`)
  and passes them in here so we don't run the same
  `list_day_chart_data_for_dashboard/4` query twice back-to-back on every
  dashboard mount. Pass `[]` (or call the 2-arity) when no pre-fetch is
  available — the helper then runs the query itself.
  """
  def get_daily_stats(%User{} = user, dtu_id, %Date{} = date, chart_points)
      when is_list(chart_points) do
    impl_get_daily_stats(user, dtu_id, date, chart_points)
  end

  @doc """
  Same as `get_daily_stats/2` but accepts the target date (UTC) so
  the sun-down scheduler can request yesterday's totals without
  duplicating the SQL. `current_power` and `peak_power` are still
  computed against *today* (the most recent readings) — they only
  make sense for the live day — but `today_yield` reflects the
  requested date so we can compare day-over-day.

  `today_yield` and `total_yield` are computed by **summing each
  inverter's last reading of the day** (for `today_yield`) or its
  max-recorded `yield_total` (for `total_yield`). Each per-inverter
  `yield_day` counter is a monotonic Wh figure that resets at
  midnight and climbs through the day — so the day's total per
  inverter IS its last reading of the day. Summing that across
  inverters (and across the user's DTUs) gives the fleet's daily
  total without relying on the firmware-aggregated `{base}/total`
  topic, which the parser now drops (no `_fleet` row persisted).

  Restricted to `mppt_index = 0` so multi-MPPT AhoyDTU inverters
  don't double-count ch0 + ch1 + ch2 yields. OpenDTU only persists
  `yield_day` / `yield_total` on `mppt_index = 0`, so the
  restriction is a no-op for OpenDTU. `cast_ahoy_yield/1` in the
  parser normalises AhoyDTU's kWh `YieldTotal` to Wh at the
  boundary, so `readings.yield_total` is uniformly Wh.

  As a defence against any legacy `_fleet` rows that older parser
  versions persisted, the chart data paths still filter
  `inverter_serial != "_fleet"` — see
  `list_day_readings_for_chart/4` and friends. The `today_yield` /
  `total_yield` queries below take the per-inverter latest row
  ordered by `inserted_at DESC LIMIT 1` per `(dtu_id,
  inverter_serial)`, which inherently skips `_fleet` (no real
  inverter goes by that name).
  """
  def get_daily_stats(%User{} = user, dtu_id, %Date{} = date) do
    impl_get_daily_stats(user, dtu_id, date, [])
  end

  defp impl_get_daily_stats(%User{} = user, dtu_id, %Date{} = date, pre_fetched_chart_points)
       when is_list(pre_fetched_chart_points) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      %{
        current_power: 0.0,
        today_yield: 0.0,
        total_yield: 0.0,
        peak_power: 0.0,
        peak_time: nil,
        per_series: []
      }
    else
      # "Recent" reads against `readings.inserted_at`, which is written
      # via `DtuApp.Time.utc_now_usec/0`. Use the same DB clock for the
      # cutoff so a drifted app clock doesn't artificially age out fresh
      # rows (or vice versa).
      two_minutes_ago = DtuApp.Time.utc_now() |> DateTime.add(-120, :second)

      today_start = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      today_end = DateTime.new!(date, ~T[23:59:59], "Etc/UTC")

      # Current power: only the AC aggregate row carries `ac_power`. A DTU
      # can publish many per-MPPT rows in between (and they're the most
      # recent rows for any given inverter), so we filter to mppt_index = 0
      # before picking the latest reading per inverter. Without this filter,
      # a per-MPPT row whose `ac_power` is nil would zero out the whole
      # `current_power` sum.
      #
      # The `inserted_at >= ^today_start` bound turns the unbounded
      # `DISTINCT ON` into a single-chunk range scan via the `(dtu_id,
      # inverter_serial, mppt_index, inserted_at)` primary key. The
      # oldest-fresh-filter for `current_power` is `two_minutes_ago`;
      # the oldest "latest reading" we need is from today. Bounding to
      # the today chunk keeps the planner inside the active chunk even
      # on multi-year installs where the whole-table DISTINCT ON would
      # touch every compressed chunk.
      latest_ac_readings =
        Repo.all(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and r.mppt_index == 0 and
                r.inserted_at >= ^today_start and r.inserted_at <= ^today_end,
            distinct: [r.dtu_id, r.inverter_serial],
            order_by: [r.dtu_id, r.inverter_serial, desc: r.inserted_at]
        )

      # Latest reading per (dtu_id, inverter_serial, mppt_index) for the
      # per-series peak computation. The chart's per-series power uses the
      # same `chart_power_for_mppt/1` selection as the rest of this module
      # (ac_power for mppt_index = 0, dc_power for >= 1). Same today-chunk
      # bound as `latest_ac_readings/1` above so the DISTINCT ON walks the
      # today chunk only.
      latest_per_series_readings =
        Repo.all(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and
                r.inserted_at >= ^today_start and r.inserted_at <= ^today_end,
            distinct: [r.dtu_id, r.inverter_serial, r.mppt_index],
            order_by: [r.dtu_id, r.inverter_serial, r.mppt_index, desc: r.inserted_at]
        )

      current_power =
        latest_ac_readings
        |> Enum.filter(fn r -> DateTime.after?(r.inserted_at, two_minutes_ago) end)
        |> Enum.map(&(&1.ac_power || 0.0))
        |> Enum.sum()

      # Today's total yield.
      #
      # Sum each inverter's **last reading of the day** (its
      # `yield_day` value at the day's most recent uplink). The
      # firmware's per-inverter `yield_day` is a monotonic Wh
      # counter that resets at midnight and climbs through the day,
      # so the day's per-inverter total IS its last reading —
      # summing that across inverters (and across the user's DTUs)
      # gives the fleet's daily total without depending on the
      # AhoyDTU `{base}/total` MQTT topic, which the parser now
      # drops.
      #
      # `SELECT DISTINCT ON (dtu_id, inverter_serial)` with
      # `ORDER BY ..., inserted_at DESC` picks the latest row per
      # inverter within the day. Restricted to `mppt_index = 0`
      # so multi-MPPT AhoyDTU inverters don't double-count ch0 +
      # ch1 + ch2 yields (OpenDTU only persists `yield_day` on
      # `mppt_index = 0`, so the restriction is a no-op for
      # OpenDTU). `yield_day` is uniformly Wh across all firmwares
      # — `cast_ahoy_yield/1` only normalises the *lifetime*
      # counter.
      #
      # `inverter_serial != "_fleet"` is a defensive filter against
      # any legacy `_fleet` rows that older parser versions
      # persisted; the current parser never creates them (see
      # `telemetry.ex`'s `[binary_base, "total"]` ignored-topic
      # clauses).

      today_yield_per_inverter =
        Repo.all(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and r.mppt_index == 0 and
                r.inverter_serial != "_fleet" and
                r.inserted_at >= ^today_start and r.inserted_at <= ^today_end,
            distinct: [r.dtu_id, r.inverter_serial],
            order_by: [r.dtu_id, r.inverter_serial, desc: r.inserted_at],
            select: %{yield_day: r.yield_day}
        )

      today_yield =
        today_yield_per_inverter
        |> Enum.map(fn row -> row.yield_day || 0.0 end)
        |> Enum.sum()

      # Lifetime total yield.
      #
      # Same per-inverter summation as `today_yield`, but using
      # `MAX(yield_total)` per inverter (the lifetime counter is
      # monotonic and never resets, so MAX == latest recorded
      # lifetime value). Summing those across inverters gives the
      # fleet's lifetime total. `yield_total` is uniformly Wh across
      # all firmwares because `cast_ahoy_yield/1` normalises
      # AhoyDTU's kWh-published lifetime counter to Wh at the
      # parser boundary.
      #
      # The `inserted_at >= ^lifetime_cutoff` filter constrains the
      # scan to a recent 30-day window — `yield_total` is monotonic
      # per `(dtu_id, inverter_serial)` and the latest reported
      # value within the window is by definition the largest, so
      # `MAX(yield_total)` is unchanged for any inverter that has
      # uplinked within the last 30 days (every active DTU). The
      # bound collapses a full-hypertable `GROUP BY` into a single
      # chunk's range scan via the `(dtu_id, inverter_serial,
      # mppt_index, inserted_at)` primary key — without it, a
      # multi-year install's `GROUP BY dtu_id, inverter_serial
      # SELECT MAX(...)` walked every compressed chunk the DTU had
      # ever written, which dominated the noon mount latency on
      # long-running installs.
      lifetime_cutoff =
        DtuApp.Time.utc_now_usec() |> DateTime.add(-30 * 86_400, :second)

      total_yield_per_inverter =
        Repo.all(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and r.mppt_index == 0 and
                r.inverter_serial != "_fleet" and
                r.inserted_at >= ^lifetime_cutoff,
            group_by: [r.dtu_id, r.inverter_serial],
            select: %{max_yield_total: max(r.yield_total)}
        )

      total_yield_wh =
        total_yield_per_inverter
        |> Enum.map(fn row -> row.max_yield_total || 0.0 end)
        |> Enum.sum()

      # Peak power today comes from the 5-minute continuous aggregate
      # via `list_day_chart_data_for_dashboard/4` (no per-row scan).
      # The aggregate's bucket stays closed until its window fills, so a
      # fast-rising morning ramp can leave `bucket_max` several
      # minutes behind the live `current_power`. Lift the peak to the
      # live reading whenever it exceeds the bucket max so the
      # displayed number reflects what the inverter is producing *now*.
      #
      # `pre_fetched_chart_points == []` is the "no pre-fetch" signal from
      # the 2-arity wrapper (an empty list is the default for a
      # dashboard-threaded caller that didn't run the chart yet). The
      # dashboard thread passes a non-empty list it already rendered so
      # we don't re-run `list_day_chart_data_for_dashboard/4`
      # immediately after `assign_line_chart_data/5` ran the exact same
      # query.
      #
      # Empty-list semantics: `[] || fetched` returns `[]` (empty lists
      # are truthy in Elixir) and `bucket_max_from_chart_points([]) == 0.0`,
      # which would silently collapse the headline peak power to the
      # live `current_power`. Pattern-match instead so an empty list
      # falls through to the fetch.
      chart_points_for_max =
        case pre_fetched_chart_points do
          [] -> list_day_chart_data_for_dashboard(user, today_start, today_end, dtu_id)
          [_ | _] = pts -> pts
        end

      bucket_max = bucket_max_from_chart_points(chart_points_for_max)

      peak_power = max(current_power, bucket_max)

      # Peak time: the bucket that produced `bucket_max`. If the live
      # `current_power` wins, attribute peak to "now" (the inverter is
      # at peak right now). The chart-point bucket-time is UTC; the
      # dashboard formats it as HH:MM in the user's local timezone.
      peak_time =
        case peak_power do
          p when p > bucket_max ->
            DtuApp.Time.utc_now()

          _ ->
            case chart_points_for_max do
              [] ->
                nil

              pts ->
                top = Enum.max_by(pts, fn pt -> pt.power || 0.0 end)
                top.time
            end
        end

      # Per-(inverter, MPPT) peak so the dashboard can show, e.g., "MPPT 1
      # peaked at 580 W". The "right" power field depends on the MPPT index:
      #   mppt_index = 0 → ac_power (the AC aggregate the firmware emits
      #     via `realtime/data` / AhoyDTU ch0)
      #   mppt_index >= 1 → dc_power (per-string DC input the firmware emits
      #     via `[serial]/[1-4]/...` / AhoyDTU ch1..N)
      # Using `chart_power_for_mppt/1` keeps this consistent with the chart
      # bucketing above so the legend's per-series peaks match what the
      # lines actually plot.
      per_series_peak =
        latest_per_series_readings
        |> Enum.filter(fn r -> DateTime.after?(r.inserted_at, two_minutes_ago) end)
        |> Enum.reduce(%{}, fn r, acc ->
          series = {r.dtu_id, r.inverter_serial, r.mppt_index, r.inverter_name}
          power = chart_power_for_mppt(r)

          Map.update(acc, series, power, fn cur ->
            max(cur, power)
          end)
        end)

      # Per-inverter breakdown for the chart legend. Computed
      # independently of the headline `today_yield` /
      # `total_yield` aggregation above — `per_series` is about
      # showing the user "which inverter produced what" on the chart,
      # so each row is per-(inverter) rather than a fleet sum.
      # The `_fleet` row is excluded so the legend shows per-inverter
      # entries only; the parser no longer creates `_fleet` rows so
      # the filter is defensive against legacy data.
      per_series_rows =
        Repo.all(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and r.mppt_index == 0 and
                r.inverter_serial != "_fleet" and
                r.inserted_at >= ^today_start and r.inserted_at <= ^today_end,
            group_by: [r.dtu_id, r.inverter_serial, r.inverter_name],
            select: %{
              dtu_id: r.dtu_id,
              inverter_serial: r.inverter_serial,
              inverter_name: r.inverter_name,
              max_yield: max(r.yield_day)
            }
        )

      %{
        current_power: Float.round(current_power * 1.0, 1),
        # `readings.yield_day` is published by OpenDTU/AhoyDTU in Wh (per the
        # firmware's `YieldDay` field). The dashboard renders this stat with
        # a kWh label, so divide by 1000 before returning so the displayed
        # number matches the unit.
        #
        # Round to one decimal place so the "Today's Total Yield" stat reads
        # as e.g. `12.3 kWh` rather than `12.345 kWh`.
        today_yield: Float.round(today_yield / 1000, 1),
        # Lifetime cumulative yield from the firmware's `YieldTotal` field
        # (Wh). Wh → kWh so the dashboard's kWh label matches. One decimal
        # place for consistency with `today_yield`.
        total_yield: Float.round(total_yield_wh / 1000, 1),
        peak_power: Float.round(peak_power * 1.0, 1),
        peak_time: peak_time,

        # Per (inverter) breakdown so the dashboard can show each
        # string's contribution and name in the chart legend. Yields are
        # in kWh, peak powers in W (matching the totals' units). Since the
        # aggregation is restricted to `mppt_index = 0` (the AC aggregate
        # row), each entry is per-inverter, not per-MPPT.
        per_series:
          Enum.map(per_series_rows, fn row ->
            series = {row.dtu_id, row.inverter_serial, 0, row.inverter_name}

            %{
              dtu_id: row.dtu_id,
              inverter_serial: row.inverter_serial,
              inverter_name: row.inverter_name,
              mppt_index: 0,
              # nil can leak in if every reading for a series has yield_day: nil.
              today_yield: Float.round((row.max_yield || 0.0) / 1000, 3),
              peak_power: Float.round(Map.get(per_series_peak, series, 0.0), 1)
            }
          end)
      }
    end
  end

  @doc """
  Consumption-side mirror of `get_daily_stats/2`. Reads only
  `power_type = :consumption` rows (Shelly Plus 3EM telemetry) and
  returns the same `{current_consumption, today_consumption,
  peak_consumption}` shape so the dashboard can render the
  "Current Consumption" / "Today's Consumption" stat cards next
  to the existing production cards.

  `current_consumption` is the latest fresh reading's
  `consumption_power` summed across the user's Shelly devices. A
  fresh reading is anything in the last two minutes (matching the
  cutoff used by `get_daily_stats/3`).

  `today_consumption` is the household energy consumed within the
  current UTC day (in kWh), computed by integrating the bucket-mean
  `consumption_power` over time. The Shelly Plus 3EM publishes a
  *signed* `total_act_power` per uplink (positive when the home is
  drawing from the grid, negative when the home is exporting
  surplus solar). The integration sums raw values, floored at 0
  per-bucket, so a solar home whose self-consumption exceeds grid
  draw reports non-zero kWh (the bucket-mean × 5/60h gives a real
  consumption value). A home fully covered by solar with no grid
  import still reads 0 because the bucket-mean is non-positive.

  Note that the "Today's Consumption" computation is a best
  approximation: the Shelly meter only sees net grid flow, not
  direct solar use, so a fully solar self-sufficient home will
  show zero regardless of household activity. The integration uses
  the bucket-mean rather than summing raw readings because the
  Shelly publishes ~10× per 5-min bucket — summing would 10× the
  result.

  `peak_consumption` mirrors `peak_power`: the higher of (a) the
  live fresh reading, (b) the highest 5-minute bucket mean.

  Returns the same zero defaults as `get_daily_stats/2` when the
  user has no devices.
  """
  def get_consumption_daily_stats(%User{} = user, dtu_id \\ nil) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      %{current_consumption: 0.0, today_consumption: 0.0, peak_consumption: 0.0}
    else
      two_minutes_ago = DtuApp.Time.utc_now() |> DateTime.add(-120, :second)

      # Latest reading per (dtu_id) — Shelly only publishes one
      # meter (em:0) per device, so we don't key by inverter_serial.
      # `distinct: [r.dtu_id]` is the Ecto spelling of PostgreSQL's
      # `SELECT DISTINCT ON (dtu_id)` — it returns ONE row per device,
      # the one with the highest `inserted_at` thanks to the `order_by`.
      # Using `distinct: true` instead (full-row dedup) was a subtle bug:
      # since every uplink writes a row with a different `(consumption_power,
      # inserted_at)` tuple, no two rows were duplicates and the query
      # returned every recent row, so the `Enum.sum/1` below added up
      # ~N latest readings instead of the latest one. A typical Shelly
      # uplink every 5–10s meant the dashboard rendered ~7× the true
      # value (530W on the dashboard vs 76W on the Shelly app).
      latest_readings =
        Repo.all(
          from r in Reading,
            where: r.dtu_id in ^dtu_ids and r.power_type == "consumption",
            distinct: [r.dtu_id],
            order_by: [r.dtu_id, desc: r.inserted_at]
        )

      current_consumption =
        latest_readings
        |> Enum.filter(fn r -> DateTime.after?(r.inserted_at, two_minutes_ago) end)
        # Clamp each fresh reading to the household-draw reading
        # (≥ 0 W). The Shelly's `total_act_power` is signed; during
        # net-export windows it would otherwise show a negative
        # wattage on the "Current Consumption" card. Multi-device
        # households sum the clamped values across devices.
        |> Enum.map(&clamp_household_draw(&1.consumption_power))
        |> Enum.sum()

      today_start = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
      today_end = DateTime.new!(Date.utc_today(), ~T[23:59:59], "Etc/UTC")

      # Today's household consumption in kWh, integrated from the
      # per-device bucket-mean consumption_power draw. The bucket-mean
      # approach (matching `list_consumption_chart_data/4`) collapses
      # each Shelly's ~10× per-5-min readings down to a single figure
      # per bucket, so the time integral reflects actual household
      # draw without the Shelly's per-uplink over-counting.
      today_consumption = integrate_consumption_kwh(user, dtu_id, today_start, today_end)

      # Bucket max for the peak: same convention as production —
      # the live reading wins when it exceeds the bucket max.
      bucket_max =
        case list_today_consumption_chart_data(user, dtu_id) do
          [] ->
            0.0

          points ->
            points
            |> Enum.map(&max(&1.power, 0.0))
            |> Enum.max(fn -> 0.0 end)
        end

      peak_consumption = max(current_consumption, bucket_max)

      %{
        current_consumption: Float.round(current_consumption * 1.0, 1),
        # Integrated from per-bucket-mean consumption_power (W).
        today_consumption: Float.round(today_consumption, 2),
        peak_consumption: Float.round(peak_consumption * 1.0, 1)
      }
    end
  end

  # Integrate the user's household consumption (kWh) over a UTC time
  # window from per-device bucket-mean `consumption_power` readings.
  # Same bucket-mean approach `list_consumption_chart_data/4` uses
  # for the chart series: each bucket is 5 minutes long, and the
  # per-device mean across the bucket's rows is the average watts
  # drawn during that window. The sum of `bucket_W * (5/60) h` over
  # the window is the household energy consumed in Wh, converted to
  # kWh for the dashboard.
  #
  # This replaces the earlier `MAX - MIN` lifetime-counter delta:
  # the Shelly's `consumption_energy_total` is a *grid-import* counter
  # that only grows when current flows from grid to home. For a solar
  # home that offsets its own consumption, the lifetime counter
  # barely changes and the dashboard always rendered 0 kWh. Integrating
  # the instantaneous `consumption_power` gives the actual household
  # consumption regardless of whether the energy comes from the grid
  # or directly from solar.
  #
  # Floor each bucket-mean at 0 (negative readings mean solar export;
  # we count those as zero contribution since the user is consuming
  # energy from solar directly rather than from the grid — and we
  # cannot distinguish that from solar-export with no direct use).
  # Round to 2 decimal places so small continuous loads (e.g. 30 W for
  # a few hours) don't round down to 0.
  @spec integrate_consumption_kwh(User.t(), integer() | nil, DateTime.t(), DateTime.t()) ::
          float()
  def integrate_consumption_kwh(%User{} = user, dtu_id, utc_start, utc_end) do
    list_consumption_chart_data(user, utc_start, utc_end, dtu_id)
    |> Enum.reduce(0.0, fn point, acc ->
      # Floor each bucket-mean at 0 (the Shelly's signed reading means
      # a negative value indicates grid export, which the household
      # consumed from solar directly; we approximate this as "no grid
      # contribution" for the integration). Bucket-mean W × bucket
      # duration (5/60 h) = Wh contributed.
      watts = max(point.power, 0.0)
      acc + watts * (5.0 / 60.0)
    end)
    # Wh → kWh, two decimal places to give continuous low loads
    # (e.g. 30 W for an hour = 0.03 kWh) a chance to surface on the
    # dashboard rather than rounding to 0.
    |> Kernel./(1000)
    |> Float.round(2)
  end

  @doc """
  Period-aware consumption stats — mirrors `get_daily_stats/3` /
  `compute_day_period_stats/2` / `compute_range_period_stats/2` for the
  consumption side. Returns one map shape per time_range so the
  dashboard can render the same row of three stat cards regardless of
  whether the user is on Today/Day (current/today/peak) or on a
  Week/Month/Year view (period total / period peak / peak date).

  All numerics are in the units the dashboard renders:

    * `current_consumption`        — W (whole-number, mirrors Current Power)
    * `today_consumption`          — kWh (1 decimal place)
    * `peak_consumption`           — W (whole-number)
    * `period_total_consumption`   — kWh (1 decimal place)
    * `period_peak_consumption`    — W (whole-number)
    * `peak_date`                  — Date.t() | nil

  The week/month/year `period_total_consumption` is the integral of
  `consumption_power` over the period via
  `integrate_consumption_kwh/4` — same approach as the today view so
  household consumption is reported correctly for solar self-sufficient
  homes (where the Shelly's grid-import lifetime counter barely
  changes). The peak helper for week/month/year picks the highest
  single-day peak via `MAX(consumption_power)` per day.

  Returns zero defaults when the user has no devices.

  ## Performance note

  The today and day branches both used to call
  `get_consumption_daily_stats/2` internally — once to fetch the
  today-side fields, and once again because the dashboard already
  fetches the same data for the consumption stat cards. The second
  call walks the day's entire consumption log twice (once for the
  latest-readings lookup, once via `integrate_consumption_kwh/4`) and
  is pure overhead on the dashboard's hot path.

  The 5th argument (`consumption_daily_stats`) lets the caller thread
  its pre-fetched result through. The dashboard passes the value it
  already computed for the consumption stat cards, so the today / day
  branches consume it directly instead of re-fetching. When the
  argument is `nil` (older callers, the NotificationsLive page, and
  tests that don't care about the perf path) the helper computes the
  value itself — preserves the existing 4-arg API.
  """
  def get_consumption_period_stats(
        %User{} = user,
        dtu_id,
        time_range,
        selected_period,
        consumption_daily_stats \\ nil
      ) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      zero_period_stats()
    else
      today_start = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
      # Single source of truth for the today-side consumption fields.
      # `nil` callers hit the underlying helper; the dashboard thread
      # passes its pre-fetched value to skip the round-trip.
      today = consumption_daily_stats || get_consumption_daily_stats(user, dtu_id)

      case time_range do
        "today" ->
          # Live view: it's identical to the today consumption stats
          # by construction — just rename the keys into the
          # period-stats shape.
          %{
            current_consumption: today.current_consumption,
            today_consumption: today.today_consumption,
            peak_consumption: today.peak_consumption,
            period_total_consumption: today.today_consumption,
            period_peak_consumption: today.peak_consumption,
            peak_date: Date.utc_today()
          }

        "day" ->
          # Single-day historical view: same shape as today, but the
          # *period* total / peak are scoped to the selected day
          # rather than `today`. The today-side fields still come
          # from the passed-through `today` snapshot so the
          # "Current" / "Today" cards keep showing what's happening
          # now even when the user is looking at a past day.
          {_date_utc, date_local} = resolve_consumption_period_date(selected_period, today_start)
          {utc_start, utc_end} = local_day_utc_range(date_local, 0)

          period_total = compute_consumption_total_kwh(user, dtu_ids, utc_start, utc_end)
          period_peak = compute_consumption_peak_w(user, dtu_ids, utc_start, utc_end)

          %{
            current_consumption: today.current_consumption,
            today_consumption: today.today_consumption,
            peak_consumption: period_peak,
            period_total_consumption: period_total,
            period_peak_consumption: period_peak,
            peak_date: date_local
          }

        "week" ->
          {monday, sunday} = week_range(selected_period, today_start)

          {utc_start, utc_end} =
            {elem(local_day_utc_range(monday, 0), 0), elem(local_day_utc_range(sunday, 0), 1)}

          period_total = compute_consumption_total_kwh(user, dtu_ids, utc_start, utc_end)
          {peak_date, peak_val} = compute_consumption_peak_day(user, dtu_ids, utc_start, utc_end)

          %{
            current_consumption: 0.0,
            today_consumption: 0.0,
            peak_consumption: 0.0,
            period_total_consumption: period_total,
            period_peak_consumption: peak_val,
            peak_date: peak_date
          }

        "month" ->
          {first_day, last_day} = month_range(selected_period, today_start)

          {utc_start, utc_end} =
            {elem(local_day_utc_range(first_day, 0), 0),
             elem(local_day_utc_range(last_day, 0), 1)}

          period_total = compute_consumption_total_kwh(user, dtu_ids, utc_start, utc_end)
          {peak_date, peak_val} = compute_consumption_peak_day(user, dtu_ids, utc_start, utc_end)

          %{
            current_consumption: 0.0,
            today_consumption: 0.0,
            peak_consumption: 0.0,
            period_total_consumption: period_total,
            period_peak_consumption: peak_val,
            peak_date: peak_date
          }

        "year" ->
          year = year_value(selected_period)
          start_date = Date.new!(year, 1, 1)
          end_date = Date.new!(year, 12, 31)

          {utc_start, utc_end} =
            {elem(local_day_utc_range(start_date, 0), 0),
             elem(local_day_utc_range(end_date, 0), 1)}

          period_total = compute_consumption_total_kwh(user, dtu_ids, utc_start, utc_end)
          {peak_date, peak_val} = compute_consumption_peak_day(user, dtu_ids, utc_start, utc_end)

          %{
            current_consumption: 0.0,
            today_consumption: 0.0,
            peak_consumption: 0.0,
            period_total_consumption: period_total,
            period_peak_consumption: peak_val,
            peak_date: peak_date
          }

        "7d" ->
          # Last 7 days ending today — same window as the production
          # side. Computed against the user's tz-offset local midnight
          # boundaries so a CET user at 23:30 local on a Sunday still
          # gets a 7-day window ending on local Sunday (not UTC
          # Monday). The dashboard passes `tz_offset_seconds = 0` here
          # because `get_consumption_period_stats/5` doesn't take it;
          # for the dashboard's default UTC offset the boundary is
          # identical to the `local_day_utc_range(today, 0)` one.
          {today_local, start_local} = last_n_days_window(7, today_start)
          {_, utc_end} = local_day_utc_range(today_local, 0)
          {start_utc, _} = local_day_utc_range(start_local, 0)
          period_total = compute_consumption_total_kwh(user, dtu_ids, start_utc, utc_end)
          {peak_date, peak_val} = compute_consumption_peak_day(user, dtu_ids, start_utc, utc_end)

          %{
            current_consumption: 0.0,
            today_consumption: 0.0,
            peak_consumption: 0.0,
            period_total_consumption: period_total,
            period_peak_consumption: peak_val,
            peak_date: peak_date
          }

        "30d" ->
          # Same as `7d` but a 30-day window.
          {today_local, start_local} = last_n_days_window(30, today_start)
          {_, utc_end} = local_day_utc_range(today_local, 0)
          {start_utc, _} = local_day_utc_range(start_local, 0)
          period_total = compute_consumption_total_kwh(user, dtu_ids, start_utc, utc_end)
          {peak_date, peak_val} = compute_consumption_peak_day(user, dtu_ids, start_utc, utc_end)

          %{
            current_consumption: 0.0,
            today_consumption: 0.0,
            peak_consumption: 0.0,
            period_total_consumption: period_total,
            period_peak_consumption: peak_val,
            peak_date: peak_date
          }

        "ytd" ->
          # Year-to-date (Jan 1 of the current year → today).
          today_local = today_start |> DateTime.to_date()
          start_date = Date.new!(today_local.year, 1, 1)
          {start_utc, _} = local_day_utc_range(start_date, 0)
          {_, utc_end} = local_day_utc_range(today_local, 0)
          period_total = compute_consumption_total_kwh(user, dtu_ids, start_utc, utc_end)
          {peak_date, peak_val} = compute_consumption_peak_day(user, dtu_ids, start_utc, utc_end)

          %{
            current_consumption: 0.0,
            today_consumption: 0.0,
            peak_consumption: 0.0,
            period_total_consumption: period_total,
            period_peak_consumption: peak_val,
            peak_date: peak_date
          }
      end
    end
  end

  # Build the (today, start) date pair for the trailing-N-days presets.
  # `today_start` is `DateTime.new!(Date.utc_today(), ~T[00:00:00],
  # "Etc/UTC")` — the helper the rest of the function passes around;
  # we only need its date component.
  defp last_n_days_window(n, today_start) do
    today_local = DateTime.to_date(today_start)
    {today_local, Date.add(today_local, -(n - 1))}
  end

  defp zero_period_stats do
    %{
      current_consumption: 0.0,
      today_consumption: 0.0,
      peak_consumption: 0.0,
      period_total_consumption: 0.0,
      period_peak_consumption: 0.0,
      peak_date: nil
    }
  end

  # Sum of per-device-per-day "last_total - first_total" Wh deltas across a UTC
  # window, returned in kWh. Each row carries a lifetime Wh counter;
  # grouping by `(dtu_id, date)` and taking the difference between the
  # earliest and latest reading of each day gives the energy consumed on
  # that day. Summing across days and devices yields the household total.
  #
  # Grouping by date is critical — without it, MIN/MAX across a multi-day
  # window would collapse to a single global delta that includes the
  # lifetime counter's natural growth between days (e.g. 7 AM Monday →
  # 7 AM Tuesday could span thousands of Wh even though only 24 h passed).
  # nil-handling mirrors `get_consumption_daily_stats/2`.
  #
  # The legacy implementation is preserved for reference but the
  # dashboard now uses `integrate_consumption_kwh/4` (same approach
  # `get_consumption_daily_stats/2` uses for the today view) so the
  # period total reflects actual household draw rather than grid-import
  # counter deltas. The legacy path stays here temporarily as a
  # regression fallback in case the integration approach turns out to
  # misbehave for a multi-day window that crosses the Shelly's local
  # midnight counter reset; remove once production data confirms it
  # covers week/month/year views correctly.
  def compute_consumption_total_kwh(user, dtu_ids, utc_start, utc_end) do
    # `get_consumption_daily_stats/2` integrates via power; the week/month/
    # year views must use the same approach so the headline behaviour
    # is consistent across time ranges.
    _ = dtu_ids
    integrate_consumption_kwh(user, nil, utc_start, utc_end)
  end

  # Peak household demand (W) across a UTC window — MAX of the
  # 5-minute-bucket-mean consumption chart points. Returns 0.0 when
  # the window has no consumption rows.
  defp compute_consumption_peak_w(user, dtu_ids, utc_start, utc_end) do
    pts =
      list_consumption_chart_data(user, utc_start, utc_end)
      |> Enum.filter(fn pt -> elem(pt.series, 0) in dtu_ids end)

    case pts do
      [] -> 0.0
      list -> list |> Enum.map(& &1.power) |> Enum.max(fn -> 0.0 end)
    end
    |> Float.round(1)
  end

  # Per-day peak (W) across a UTC window — returns the {date, peak_w}
  # of the day with the highest single-day maximum, or {nil, 0.0}
  # if no data. Used for week/month/year views so the dashboard can
  # highlight which day was the peak.
  defp compute_consumption_peak_day(_user, dtu_ids, utc_start, utc_end) do
    rows =
      Repo.all(
        from r in Reading,
          where:
            r.dtu_id in ^dtu_ids and r.power_type == "consumption" and
              r.inserted_at >= ^utc_start and r.inserted_at <= ^utc_end and
              not is_nil(r.consumption_power),
          group_by: fragment("?::date", r.inserted_at),
          select: %{
            date: fragment("?::date", r.inserted_at),
            peak_w: max(r.consumption_power)
          }
      )

    case rows do
      [] ->
        {nil, 0.0}

      list ->
        top = Enum.max_by(list, fn r -> r.peak_w || 0.0 end)
        date = top.date
        # The SQL aggregate sees raw `consumption_power`; a Shelly
        # reporting only reverse-flow (solar surplus) would otherwise
        # surface a negative per-day peak on the "Peak Demand" card.
        # Clamp to ≥ 0 W so the card reports household draw.
        peak_w = clamp_household_draw(top.peak_w)

        normalized_date =
          case date do
            %Date{} = d -> d
            str when is_binary(str) -> Date.from_iso8601!(str)
            nil -> nil
          end

        {normalized_date, Float.round(peak_w, 1)}
    end
  end

  # Resolve the local Date for a consumption-period stats query. The
  # dashboard passes `selected_period` which can be `nil` (today) or
  # a `%Date{}` for historical views.
  defp resolve_consumption_period_date(nil, today_utc_start) do
    {today_utc_start, Date.utc_today()}
  end

  defp resolve_consumption_period_date(%Date{} = d, _today_utc_start), do: {d, d}

  defp resolve_consumption_period_date(_other, today_utc_start),
    do: {today_utc_start, Date.utc_today()}

  # Mon..Sun range for the week view, anchored on the most recent
  # week with data (or this week if `selected_period` is `nil`).
  defp week_range(nil, today_utc_start) do
    week_range(
      Date.utc_today() |> Date.add(-(Date.day_of_week(Date.utc_today()) - 1)),
      today_utc_start
    )
  end

  defp week_range(%Date{} = d, _today_utc_start) do
    monday = Date.add(d, -(Date.day_of_week(d) - 1))
    sunday = Date.add(monday, 6)
    {monday, sunday}
  end

  # First..last day of the month, anchored on the month of the
  # provided Date (or this month if `nil`).
  defp month_range(nil, _today_utc_start) do
    today = Date.utc_today()
    first = Date.new!(today.year, today.month, 1)
    {first, Date.end_of_month(first)}
  end

  defp month_range(%Date{} = d, _today_utc_start) do
    first = Date.new!(d.year, d.month, 1)
    {first, Date.end_of_month(first)}
  end

  # Integer year for the year view, anchored on the year of the
  # provided Date (or this year if `nil`).
  defp year_value(nil), do: Date.utc_today().year
  defp year_value(%Date{} = d), do: d.year
  defp year_value(y) when is_integer(y), do: y

  @doc """
  Highest 5-min-bucket-mean wattage within `[utc_start, utc_end]`, and
  the bucket's timestamp. Returns `{0.0, nil}` when the window has no
  AC-aggregate rows (no DTU has uplinked for the period).

  Reads from the `readings_5m` continuous aggregate when the bucket is
  in the past, falls back to the live `readings` table for the most
  recent 5 minutes (matching the rest of the dashboard's tail strategy).
  Restricted to `mppt_index = 0` so multi-MPPT AhoyDTU inverters don't
  double-count — same convention as `get_daily_stats/3`.

  `peak_time` is the bucket's UTC `time` field; the dashboard
  formats it as HH:MM in the user's local timezone.
  """
  @spec compute_peak_watts_in_period(User.t(), integer() | nil, DateTime.t(), DateTime.t()) ::
          {float(), DateTime.t() | nil}
  def compute_peak_watts_in_period(%User{} = user, dtu_id, utc_start, utc_end) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      {0.0, nil}
    else
      utc_tail_start = DateTime.add(utc_end, -300, :second)

      # Aggregate buckets strictly before the live tail.
      aggregate_top =
        if DateTime.compare(utc_start, utc_tail_start) == :lt do
          from_buckets =
            list_day_chart_data_for_dashboard(user, utc_start, utc_tail_start, dtu_id)

          case from_buckets do
            [] ->
              nil

            pts ->
              top = Enum.max_by(pts, fn pt -> pt.power || 0.0 end)

              %{
                power: top.power || 0.0,
                time: top.time
              }
          end
        else
          nil
        end

      # Live tail: latest AC-aggregate row per DTU in the tail window.
      live_top =
        if DateTime.compare(utc_tail_start, utc_end) in [:lt, :eq] do
          tail_rows =
            Repo.all(
              from r in Reading,
                where:
                  r.dtu_id in ^dtu_ids and r.mppt_index == 0 and
                    r.inserted_at >= ^utc_tail_start and r.inserted_at <= ^utc_end,
                distinct: [r.dtu_id, r.inverter_serial],
                order_by: [r.dtu_id, r.inverter_serial, desc: r.inserted_at],
                select: %{power: r.ac_power, time: r.inserted_at}
            )

          case tail_rows do
            [] ->
              nil

            rows ->
              max_row = Enum.max_by(rows, fn r -> r.power || 0.0 end)
              %{power: max_row.power || 0.0, time: max_row.time}
          end
        else
          nil
        end

      pick_higher = aggregate_top || live_top

      case pick_higher do
        nil ->
          {0.0, nil}

        %{power: power, time: time} ->
          {Float.round(power * 1.0, 1), time}
      end
    end
  end

  @doc """
  Self-consumption percentage for a UTC period: `(production - exported) /
  production × 100`, rounded to one decimal place. Returns `nil` when no
  consumption devices (Shelly) are in scope — the dashboard uses this to
  decide whether to show the self-consumption stat card at all.

  `production_kwh` is the period's total yield in kWh, derived from the
  same per-inverter last-yield query that powers `get_daily_stats/3`'s
  `today_yield` (sum of each inverter's last `yield_day` of the window).

  `exported_kwh` is the positive-net-flow energy that left the home,
  computed by summing 5-min-bucket-equivalents from the Shelly's signed
  `total_act_power` readings (negative readings = export). The
  approximation uses one bucket-equivalent per distinct uplink to avoid
  10× overcount from the Shelly's bursty uplink rate. The result is a
  headline number for the stat card, not an audit figure.

  Edge cases:
  * No production at all → returns `0.0` (the card shows "0 %", not
    `nil`, because the user has solar, just no output this period).
  * Exported > production → clamp at 0 % (a battery discharging into
    the home during a sunny stretch can flip the net-flow sign; the
    clamp keeps the percentage non-negative by definition).
  """
  @spec compute_self_consumption_pct(User.t(), integer() | nil, DateTime.t(), DateTime.t()) ::
          float() | nil
  def compute_self_consumption_pct(%User{} = user, dtu_id, utc_start, utc_end) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      nil
    else
      production_wh =
        Repo.all(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and r.mppt_index == 0 and
                r.inverter_serial != "_fleet" and
                r.inserted_at >= ^utc_start and r.inserted_at <= ^utc_end,
            distinct: [r.dtu_id, r.inverter_serial],
            order_by: [r.dtu_id, r.inverter_serial, desc: r.inserted_at],
            select: %{yield_day: r.yield_day}
        )
        |> Enum.map(fn row -> row.yield_day || 0.0 end)
        |> Enum.sum()

      exported_wh =
        Repo.all(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and r.power_type == "consumption" and
                r.inserted_at >= ^utc_start and r.inserted_at <= ^utc_end,
            distinct: [r.dtu_id, desc: r.inserted_at],
            order_by: [r.dtu_id, desc: r.inserted_at],
            select: %{consumption_power: r.consumption_power}
        )
        |> Enum.reduce(0.0, fn r, acc ->
          # Shelly sign convention: positive = importing, negative =
          # exporting. `consumption_power == nil` means the meter
          # hasn't reported yet — skip the row entirely so we don't
          # 0× the partial total.
          if r.consumption_power == nil do
            acc
          else
            export_w = max(0.0, -(r.consumption_power || 0.0))
            # One 5-min-bucket-equivalent per distinct uplink.
            acc + export_w * (5.0 / 60.0)
          end
        end)

      production_kwh = production_wh / 1000.0
      exported_kwh = exported_wh / 1000.0

      cond do
        production_kwh <= 0.0 -> 0.0
        exported_kwh <= 0.0 -> 100.0
        exported_kwh >= production_kwh -> 0.0
        true -> Float.round((1.0 - exported_kwh / production_kwh) * 100.0, 1)
      end
    end
  end

  @doc "List selectable dates containing telemetry readings."
  def list_selectable_dates(%User{} = user, dtu_id \\ nil) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      []
    else
      Repo.all(
        from r in Reading,
          where: r.dtu_id in ^dtu_ids,
          select: fragment("(?::date)", r.inserted_at),
          distinct: true,
          order_by: [desc: fragment("(?::date)", r.inserted_at)]
      )
      |> Enum.map(fn
        %Date{} = d -> d
        str when is_binary(str) -> Date.from_iso8601!(str)
      end)
    end
  end

  @doc "Fetch daily yield totals over a date range."
  def list_range_yield_data(%User{} = user, utc_start, utc_end, dtu_id \\ nil)
      when is_struct(utc_start, DateTime) and is_struct(utc_end, DateTime) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      []
    else
      # Sum each inverter's last `yield_day` reading of the day across
      # every inverter (and across the user's DTUs). Per-inverter
      # `yield_day` is monotonic Wh that resets at midnight, so the
      # day's per-inverter total IS its last reading of the day —
      # summing across inverters gives the fleet's daily total
      # without depending on the firmware-aggregated `{base}/total`
      # topic (which the parser now drops).
      #
      # `DISTINCT ON (date, dtu_id, inverter_serial)` ordered by
      # `inserted_at DESC` picks the latest row per inverter per day.
      # `mppt_index = 0` so multi-MPPT AhoyDTU inverters don't
      # double-count ch0 + ch1 + ch2 yields. `inverter_serial !=
      # "_fleet"` is defensive against any legacy `_fleet` rows
      # older parser versions persisted (the current parser never
      # creates them — see `telemetry.ex`'s `[binary_base, "total"]`
      # ignored-topic clauses).
      latest_per_inverter_per_day =
        Repo.all(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and r.mppt_index == 0 and
                r.inverter_serial != "_fleet" and
                r.inserted_at >= ^utc_start and r.inserted_at <= ^utc_end,
            distinct: [fragment("?::date", r.inserted_at), r.dtu_id, r.inverter_serial],
            order_by: [
              fragment("?::date", r.inserted_at),
              r.dtu_id,
              r.inverter_serial,
              desc: r.inserted_at
            ],
            select: %{
              date: fragment("?::date", r.inserted_at),
              dtu_id: r.dtu_id,
              inverter_serial: r.inverter_serial,
              yield_day: r.yield_day
            }
        )

      daily_yields =
        latest_per_inverter_per_day
        |> Enum.group_by(fn r ->
          case r.date do
            %Date{} = d -> d
            str when is_binary(str) -> Date.from_iso8601!(str)
          end
        end)
        |> Enum.map(fn {date, date_readings} ->
          # Sum each inverter's last reading of the day. Missing
          # `yield_day` (nil from a half-published reading) counts
          # as 0 so a partial day doesn't blow up the headline.
          {date, date_readings |> Enum.map(&(&1.yield_day || 0.0)) |> Enum.sum()}
        end)
        |> Map.new()

      all_dates =
        Map.keys(daily_yields)
        |> Enum.uniq()
        |> Enum.sort()

      # `readings.yield_day` is in Wh (see comment in `get_daily_stats/2`).
      # The historical chart and `total_yield` for the `stats` map both
      # render with a kWh label, so convert here.
      Enum.map(all_dates, fn date ->
        {date, (daily_yields[date] || 0.0) / 1000}
      end)
    end
  end

  @doc """
  Fetch the daily yield totals for the trailing `n` days (inclusive of
  today). Backed by `list_range_yield_data/4` over the `[start_of_window,
  end_of_today]` UTC range — pure call-site convenience for the dashboard's
  `7D` and `30D` presets, which would otherwise have to compute the window
  themselves.

  The window is anchored at **local midnight** `n - 1` days ago (so a `7D`
  request always returns up to 7 daily buckets, today included) and ends
  at the same local midnight + 24 h. The `tz_offset_seconds` argument is
  the user's offset (set by `DashboardLive`'s `SetTimezone` hook) so a
  user in CET calling `7D` at 01:00 local gets a window starting at the
  previous Monday 00:00 CET, not Sunday 23:00 UTC.

  Returns `[]` for users with no DTUs (matches `list_range_yield_data/4`).
  """
  @spec list_last_n_days_yield_data(User.t(), pos_integer(), integer(), integer() | nil) ::
          [{Date.t(), float()}]
  def list_last_n_days_yield_data(%User{} = user, n, tz_offset_seconds, dtu_id \\ nil)
      when is_integer(n) and n > 0 and is_integer(tz_offset_seconds) do
    today_local = devices_local_today(tz_offset_seconds)
    start_local = Date.add(today_local, -(n - 1))
    {start_utc, _} = local_day_utc_range(start_local, tz_offset_seconds)
    {_, end_utc} = local_day_utc_range(today_local, tz_offset_seconds)
    list_range_yield_data(user, start_utc, end_utc, dtu_id)
  end

  @doc """
  Fetch monthly yield totals for the year-to-date (Jan 1 of the current
  year through today), bucketed per month. Backed by
  `list_range_yield_data/4` over the same UTC range and then rolled up
  into `[{{year, month}, kWh}]` for the dashboard's `YTD` preset.

  The current year is computed from `Date.utc_today/0` (no timezone
  adjustment — the user's local year and the UTC year agree for every
  real-world solar installer's workday; switching on the user's tz
  here would cause a CET user's January 1 morning to land on the
  previous year's December 31 bucket).

  Returns `[]` for users with no DTUs.
  """
  @spec list_ytd_yield_data(User.t(), integer() | nil) :: [{{integer(), 1..12}, float()}]
  def list_ytd_yield_data(%User{} = user, dtu_id \\ nil) do
    today = Date.utc_today()
    start_date = Date.new!(today.year, 1, 1)
    {start_utc, _} = local_day_utc_range(start_date, 0)
    {_, end_utc} = local_day_utc_range(today, 0)

    list_range_yield_data(user, start_utc, end_utc, dtu_id)
    |> Enum.group_by(fn {date, _} -> {date.year, date.month} end)
    |> Enum.map(fn {{year, month}, yields} ->
      {{year, month}, yields |> Enum.map(fn {_, kwh} -> kwh end) |> Enum.sum()}
    end)
    |> Enum.sort()
  end

  # Local "today" anchored on the user's tz offset. Mirrors
  # `DtuAppWeb.DashboardLive.local_today/1` — the dashboard already
  # passes the offset in, so we just need the helper here to keep
  # `list_last_n_days_yield_data/3` self-contained (it doesn't reach
  # into a LiveView).
  defp devices_local_today(tz_offset_seconds) do
    DtuApp.Time.utc_now()
    |> DateTime.add(tz_offset_seconds, :second)
    |> DateTime.to_date()
  end

  @doc """
  Roll up the day-view "stat cards" from a day's yields and chart points.

  Used by `DashboardLive` for the per-day granularity. The day shape is
  `{total_yield, peak_power, avg_power}` (no `peak_date` — the day view's
  peak is the highest sampled power, which is intrinsically tied to the
  day itself).

  Both inputs are already user-scoped (yields come from
  `list_range_yield_data/4`, points from `list_day_chart_data/4`), so this
  function is pure data-shaping with no DB access.
  """
  @spec compute_day_period_stats([{Date.t(), float()}], [chart_point()]) :: %{
          total_yield: float(),
          peak_power: float(),
          peak_time: DateTime.t() | nil,
          avg_power: float()
        }
  def compute_day_period_stats(yields, points) do
    total_yield =
      case yields do
        [{_date, y}] -> y
        _ -> 0.0
      end

    # Peak power + peak time come from the same 5-min bucket scan.
    # The `peak_time` is the bucket's `time` field (UTC). The
    # dashboard formats it as HH:MM in the user's local timezone.
    # `peak_time == nil` when the window has no chart points — the
    # stats card then renders a `—` placeholder instead of `00:00`.
    {peak_power, peak_time} =
      case points do
        [] ->
          {0.0, nil}

        pts ->
          top =
            Enum.max_by(pts, fn pt ->
              case pt.power do
                nil -> 0.0
                p -> p
              end
            end)

          {top.power || 0.0, top.time}
      end

    avg_power =
      case points do
        [] -> 0.0
        pts -> Enum.sum(pts |> Enum.map(& &1.power)) / length(pts)
      end

    %{
      total_yield: Float.round(total_yield * 1.0, 1),
      peak_power: Float.round(peak_power * 1.0, 1),
      peak_time: peak_time,
      avg_power: Float.round(avg_power * 1.0, 1)
    }
  end

  @doc """
  Roll up the week/month/year "stat cards" from a range's daily yields.

  Returns `{total_yield, avg_yield, peak_date, peak_val}` — `avg_yield`
  is the average per day across the period (`total_yield / divisor`),
  `peak_date`/`peak_val` are the single highest-yield day. `divisor` is
  the number of days the period spans (7 for a week, days-in-month for a
  month, 12 for a year) — the caller computes it from the calendar, not
  from the data, so a partial period (e.g. the first week of operation)
  still averages over the calendar's full span.

  `yields` comes from `list_range_yield_data/4` (already user-scoped).
  """
  @spec compute_range_period_stats([{Date.t(), float()}], pos_integer()) :: %{
          total_yield: float(),
          avg_yield: float(),
          peak_date: Date.t() | nil,
          peak_val: float()
        }
  def compute_range_period_stats(yields, divisor) when is_integer(divisor) and divisor > 0 do
    total_yield = yields |> Enum.map(fn {_, y} -> y end) |> Enum.sum()
    avg_yield = total_yield / (divisor * 1.0)

    {peak_date, peak_val} =
      case yields do
        [] -> {nil, 0.0}
        list -> list |> Enum.max_by(fn {_, y} -> y end, fn -> {nil, 0.0} end)
      end

    %{
      total_yield: Float.round(total_yield * 1.0, 1),
      avg_yield: Float.round(avg_yield * 1.0, 1),
      peak_date: peak_date,
      peak_val: Float.round(peak_val * 1.0, 1)
    }
  end

  @doc """
  Compute the euro-cent savings for a given yield in kWh at a given
  rate. `cents_per_kwh` is the integer-cent rate stored on the
  `User` schema; `kwh` is the period's total yield (already rounded
  to one decimal by the per-period `compute_*_period_stats`
  functions). The product is the euro-cent savings as an integer
  (e.g. `250.0 kWh × 32 c/kWh = 8000 c = €80.00`):

      compute_savings(250.0, 32)  # 250 kWh at €0.32/kWh
      # => 8000                     # 8000 euro-cents (€80.00)

  Pure data shaping, no DB access. `nil` rate (user hasn't set one
  on `/users/settings`) propagates as `nil` so the dashboard can
  hide the savings card rather than show "€0.00 saved".

  Note: this function deliberately does NOT divide by 100 — the
  product `kwh × cents_per_kwh` is already in euro cents (e.g.
  `0.32 €/kWh × 250 kWh = 80 € = 8000 cents`), and `format_savings/1`
  performs the cents→euros split when it formats the value for the
  dashboard. Dividing here as well would shrink every card value by
  100× and collapse typical residential daily yields (single-digit
  kWh at €0.32/kWh) to a rounded 0 — see the
  `compute_savings/2 + format_savings/1` describe block in
  `test/dtu_app/devices_test.exs`.
  """
  @spec compute_savings(float() | nil, pos_integer() | nil) :: pos_integer() | nil
  def compute_savings(nil, _cents), do: nil
  def compute_savings(_kwh, nil), do: nil

  def compute_savings(kwh, cents) when is_number(kwh) and is_integer(cents) and cents > 0 do
    round(kwh * cents)
  end

  @doc """
  Format a euro-cent integer as a `€X.XX` string for display in the
  dashboard. Mirrors the precision contract of the
  `compute_*_period_stats` family (two decimal places, no
  thousands separator — a self-hosted solar app rarely shows four-
  digit-savings totals, and the dashboard's "Saved this month"
  card is already in a compact stat-card layout). Returns "€0.00"
  for `nil` so the template can render a stable placeholder.

  `format_savings/1` reads the current Gettext locale and uses the
  matching number-formatting convention (English `1,234.56 €`,
  German `1.234,56 €`, French `1 234,56 €`). The dashboard calls
  `format_savings/1` from a locale-aware context, so the appropriate
  number format is selected automatically. `format_savings/2` is
  the explicit-locale form for tests and any future caller that
  needs to format for a locale other than the current request.

  ## Locales

  | locale | format           | example 1234.56 |
  | ------ | ---------------- | --------------- |
  | `en`   | `1,234.56 €`     | English         |
  | `de`   | `1.234,56 €`     | German          |
  | `fr`   | `1 234,56 €`     | French (NBSP)   |
  | _other_| falls back to `en` | —               |

  Returns "€0.00" / locale equivalent for `nil`.
  """
  @spec format_savings(pos_integer() | nil) :: String.t()
  def format_savings(cents), do: format_savings(cents, Gettext.get_locale(DtuAppWeb.Gettext))

  @spec format_savings(pos_integer() | nil, String.t()) :: String.t()
  def format_savings(nil, _locale), do: format_savings(0, "en")

  def format_savings(cents, locale) when is_integer(cents) and cents >= 0 do
    # Build the whole and fractional parts separately. Doing it via a
    # single `:erlang.float_to_binary(cents/100)` would lose the
    # magnitude (e.g. 12_345/100 → "123.45" — there's no way to
    # recover that 12345 cents came from 5 digits, so a thousands
    # separator becomes impossible to add).
    whole = Integer.to_string(div(cents, 100))
    frac = cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")

    formatted =
      case locale do
        # German: dot as thousand separator, comma as decimal, symbol after.
        "de" -> "#{insert_thousands_separator(whole, ".")},#{frac} €"
        # French: non-breaking space (U+00A0) as thousand separator per
        # French/European typographic convention (DIN 5008 / AFNOR).
        "fr" -> "#{insert_thousands_separator(whole, " ")},#{frac} €"
        # English: comma as thousand separator, dot as decimal.
        "en" -> "#{insert_thousands_separator(whole, ",")}.#{frac} €"
        _ -> "#{insert_thousands_separator(whole, ",")}.#{frac} €"
      end

    formatted
  end

  # Insert a thousands separator every three digits from the right.
  # The separator is passed as a UTF-8 binary ("," "." or NBSP) so a
  # multibyte separator like U+00A0 round-trips correctly through the
  # recursion — `<<sep, last_three::binary>>` would only append the
  # first byte. We split out the separator's byte length and glue
  # the result back together with explicit byte-counts instead.
  defp insert_thousands_separator(whole, _sep) when byte_size(whole) <= 3, do: whole

  defp insert_thousands_separator(whole, sep) do
    {head, last_three} = String.split_at(whole, -3)
    head = insert_thousands_separator(head, sep)

    sep_bytes = byte_size(sep)
    head_bytes = byte_size(head)
    <<head::binary-size(head_bytes), sep::binary-size(sep_bytes), last_three::binary>>
  end

  @doc """
  Format a unit-less number for display in the dashboard. The
  dashboard's stat cards (`Current Power`, `Today's Total Yield`,
  `Peak Power`, etc.) and chart Y-axis labels need a locale-aware
  number without a trailing unit — `format_savings/1` doesn't fit
  because it always appends ` €`. The convention is the same as
  `format_savings/1`:

  | locale | format           | example 1234.5 |
  | ------ | ---------------- | --------------- |
  | `en`   | `1,234.5`        | English         |
  | `de`   | `1.234,5`        | German          |
  | `fr`   | `1 234,5`        | French (NBSP)   |
  | _other_| falls back to `en` | —               |

  `decimals` controls precision (default `1` to match the kWh stat
  cards, which read better as `1.3 kWh` than `1 kWh`). Pass
  `decimals: 0` for integer-only output — the W (watts) stat cards
  use this so `350.0 W` reads as `350 W` (the underlying value is
  already rounded to one decimal upstream; rendering the trailing
  `.0` would just be visual noise).

  Returns `"—"` (em-dash) for `nil` so the template can render a
  stable placeholder without a conditional.

  `format_number/1` and `format_number/2` read the current Gettext
  locale — the dashboard calls them from a request-scoped LiveView
  process, so the user's selected language is picked up automatically.
  `format_number/3` is the explicit-locale form for tests and any
  future caller that needs to format for a locale other than the
  current request.
  """
  @spec format_number(number() | nil) :: String.t()
  def format_number(value), do: format_number(value, 1, Gettext.get_locale(DtuAppWeb.Gettext))

  @spec format_number(number() | nil, non_neg_integer()) :: String.t()
  def format_number(value, decimals),
    do: format_number(value, decimals, Gettext.get_locale(DtuAppWeb.Gettext))

  @spec format_number(number() | nil, non_neg_integer(), String.t()) :: String.t()
  def format_number(nil, _decimals, _locale), do: "—"

  def format_number(value, decimals, locale)
      when is_number(value) and is_integer(decimals) and decimals >= 0 do
    {whole_int, frac_str, sign} = split_value(value, decimals)
    {sep_t, sep_d} = locale_separators(locale)
    formatted_whole = insert_thousands_separator(Integer.to_string(whole_int), sep_t)

    case decimals do
      0 -> "#{sign}#{formatted_whole}"
      _ -> "#{sign}#{formatted_whole}#{sep_d}#{frac_str}"
    end
  end

  # Round to `decimals` digits after the point, then split into
  # (whole, fractional-string, sign). `Integer.to_string(whole)` is
  # later fed into `insert_thousands_separator/2` so the locale-aware
  # separator can be inserted.
  @spec split_value(number(), non_neg_integer()) :: {integer(), String.t(), String.t()}
  defp split_value(value, decimals) do
    sign = if value < 0, do: "-", else: ""
    rounded = Float.round(abs(value) * 1.0, decimals)
    scaled = round(rounded * :math.pow(10, decimals))
    scale = round(:math.pow(10, decimals))
    whole = div(scaled, scale)
    frac = rem(scaled, scale) |> Integer.to_string() |> String.pad_leading(decimals, "0")
    {whole, frac, sign}
  end

  # Per-locale {thousands_separator, decimal_separator} tuple. Falls
  # back to English for any unknown locale so a stale Gettext backend
  # (e.g. a new language without a project-side translation yet) still
  # produces a readable, machine-parseable number rather than `?`.
  @spec locale_separators(String.t()) :: {String.t(), String.t()}
  defp locale_separators("de"), do: {".", ","}
  # French typography (DIN 5008 / AFNOR): non-breaking space (U+00A0)
  # as thousands separator. A regular space would let a line break
  # split the number — the NBSP keeps the digits glued together.
  defp locale_separators("fr"), do: {"\u00A0", ","}
  defp locale_separators(_), do: {",", "."}

  # --- Helpers ----------------------------------------------------------------

  # Clamp `consumption_power` to the household-draw reading the dashboard
  # expects (≥ 0 W). The Shelly Plus 3EM publishes `total_act_power` as
  # a SIGNED value — negative when the home is net-exporting (the meter
  # sees reverse flow), positive when drawing from the grid. The
  # dashboard, however, treats "consumption" as household draw, which
  # is intrinsically non-negative. Without this clamp, a sunny midday
  # with low draw would render the "Current Consumption" stat as a
  # negative wattage and the consumption overlay would dip below the
  # chart's X-axis — both confusing. Centralising the clamp here keeps
  # every helper (`get_consumption_daily_stats/2`,
  # `list_consumption_chart_data/4`, `list_net_chart_data/4`,
  # `get_net_flow_stats/2`, the period stats) consistent: callers
  # don't need to remember to clamp.
  #
  # Note: the net-flow arithmetic still subtracts the *clamped* draw,
  # so the headline "Net export" caps at +production (not
  # +production + |reverse-flow|). That's the intended behaviour —
  # the dashboard's net flow answers "how much am I exporting beyond
  # what my house is using?", which is bounded above by total solar
  # production.
  @spec clamp_household_draw(float() | nil) :: float()
  def clamp_household_draw(nil), do: 0.0
  def clamp_household_draw(value) when is_number(value) and value < 0.0, do: 0.0
  def clamp_household_draw(value) when is_number(value), do: value * 1.0

  # Pick the right "power" field for a row depending on its MPPT index.
  # AC aggregate rows (`mppt_index = 0` — AhoyDTU ch0 / OpenDTU realtime/data)
  # carry `ac_power` (the inverter's AC output). Per-MPPT rows
  # (`mppt_index >= 1`) only carry `dc_power` (per-string DC input the
  # firmware publishes on `[serial]/[1-4]/...`). Reading `ac_power` on a
  # per-MPPT row returns nil and zeroes the line out — this helper ensures
  # each series plots whatever the firmware actually publishes for it.
  @spec chart_power_for_mppt(%{
          required(:mppt_index) => integer(),
          optional(:ac_power) => float(),
          optional(:dc_power) => float()
        }) :: float()
  def chart_power_for_mppt(%{mppt_index: 0, ac_power: ac}) when not is_nil(ac), do: ac
  def chart_power_for_mppt(%{mppt_index: _, dc_power: dc}) when not is_nil(dc), do: dc
  def chart_power_for_mppt(_), do: 0.0

  @doc """
  Day-peak from a `list_day_chart_data_for_dashboard/4` result.

  Filters down to `mppt_index = 0` (the AC aggregate the firmware emits
  via `realtime/data` / AhoyDTU ch0) and returns the max `:power` so the
  dashboard's `peak_power` matches what the user sees on the chart. Non-
  AC-aggregate points are dropped so per-MPPT row averages don't compete
  with the AC peak.

  Returns `0.0` for an empty chart-point list (no readings today) so
  `peak_power = max(current_power, bucket_max)` always has a numeric
  base.

  ## Why this is a separate helper

  `avg_ac_power` in the `readings_5m` continuous aggregate is NULL
  whenever a 5-minute bucket contains only rows whose `ac_power` was
  nil — e.g. an AhoyDTU yield-only buffer flush that landed before the
  AC reading arrived. The chart pipeline exposes that NULL as a
  chart-point with `power: nil`. `Enum.max([nil, …])` poisons to `nil`
  in Erlang term order (`atom > number`), so the downstream
  `peak_power * 1.0` raises `ArithmeticError`. Coalescing each
  `nil` to `0.0` before `Enum.max` keeps the max numeric.

  Extracted as a public helper so the nil-coalesce has a direct
  regression test — going through the full `readings_5m` aggregate
  refresh from a unit test would need a separate Postgres connection
  (CALL refresh_continuous_aggregate can't run inside the sandbox's
  per-test transaction), and the raw-row fallback
  (`list_day_chart_data/4`) never produces nil powers, so neither
  end-to-end path exercises the nil-only bucket case from a test.
  """
  @spec bucket_max_from_chart_points([chart_point()]) :: float()
  def bucket_max_from_chart_points([]), do: 0.0

  def bucket_max_from_chart_points(points) do
    points
    |> Enum.filter(fn pt -> elem(pt.series, 2) == 0 end)
    |> Enum.map(fn pt -> pt.power || 0.0 end)
    |> Enum.max(fn -> 0.0 end)
  end

  # Resolve the user's DTU ids for a query, scoped to either all of the user's
  # devices or one specific (owned) device. Returns [] if the device isn't owned.
  defp owned_dtu_ids(%User{} = user, nil) do
    Repo.all(from d in Dtu, where: d.user_id == ^user.id, select: d.id)
  end

  defp owned_dtu_ids(%User{} = user, dtu_id) do
    if owned?(user, dtu_id), do: [dtu_id], else: []
  end

  defp owned?(%User{} = user, dtu_id) do
    Repo.exists?(from d in Dtu, where: d.user_id == ^user.id and d.id == ^dtu_id)
  end
end
