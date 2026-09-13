defmodule DtuApp.Devices.Readings do
  @moduledoc """
  Telemetry reading ingestion.

  Covers the write-side of the `readings` hypertable: insert a raw
  reading, insert + touch the owning DTU's `last_power_at`, and the
  two backfill paths OpenDTU occasionally emits (`{serial}/name`
  and `{serial}/status/{producing,reachable}`).

  Reading queries (chart-data, stats, exports, etc.) live in their
  own sub-modules. This module is the *write* surface only.

  Re-exported through `DtuApp.Devices` via `defdelegate` so existing
  `Devices.create_reading/1`-style call sites continue to work
  unchanged after the extraction.
  """

  import Ecto.Query

  alias DtuApp.Devices.Dtu
  alias DtuApp.Devices.Reading
  alias DtuApp.Repo


  @doc "Create a telemetry reading."
  def create_reading(attrs) do
    %Reading{}
    |> Reading.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Insert a reading and, when it carries an AC-aggregate measurement
  (`mppt_index = 0`), touch the owning DTU's `last_power_at` column so
  the dashboard's online indicators (`Dtu.producing_power?/2`) flip in
  sync with the live power data.

  `last_power_at` is touched *unconditionally on the AC-aggregate
  row*, including when `ac_power = 0` (night, mid-day clouds). That
  keeps the indicator honest: a DTU that's still publishing telemetry
  — even if it's reporting zero watts — stays "online" on the
  dashboard, matching the current-power card's behaviour.

  Failure modes:

    * Reading insert fails → returns the `{:error, changeset}`
      unchanged. The DTU's `last_power_at` is not touched, which is
      consistent: if we couldn't persist the reading, the timestamp
      shouldn't claim the data was fresh.
    * Reading insert succeeds but the DTU row has vanished (race with
      device deletion) → `safe_touch_last_power_at/1` swallows the
      lookup error and returns `:ok`. The reading row is still
      returned to the caller; downstream subscribers don't see the
      outage.

  Returns the same `{:ok, %Reading{}} | {:error, changeset}` shape as
  `create_reading/1` so existing call sites need no pattern-match
  changes.
  """
  @spec create_reading_and_touch_power_at(map()) ::
          {:ok, Reading.t()} | {:error, Ecto.Changeset.t()}
  def create_reading_and_touch_power_at(attrs) do
    case create_reading(attrs) do
      {:ok, %Reading{mppt_index: 0, dtu_id: dtu_id} = reading}
      when is_integer(dtu_id) ->
        # Best-effort. The DTU row lookup + column write are wrapped in
        # `safe_db_call`-style rescue so a deleted-DTU race can't
        # surface as a failed telemetry insert to the caller.
        _ = safe_touch_last_power_at(dtu_id)
        {:ok, reading}

      other ->
        other
    end
  end

  defp safe_touch_last_power_at(dtu_id) when is_integer(dtu_id) do
    Repo.transaction(fn ->
      case Repo.get(Dtu, dtu_id) do
        nil ->
          Repo.rollback(:not_found)

        %Dtu{} = dtu ->
          dtu
          |> Ecto.Changeset.change(%{last_power_at: DtuApp.Time.utc_now_usec()})
          |> Repo.update!()
      end
    end)
    |> case do
      {:ok, _dtu} -> :ok
      {:error, _reason} -> :ok
    end
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

end
