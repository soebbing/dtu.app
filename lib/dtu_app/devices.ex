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

  @doc "Calculate aggregated daily stats for a user's DTUs (or a specific DTU)."
  def get_daily_stats(%User{} = user, dtu_id \\ nil) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      %{current_power: 0.0, today_yield: 0.0, peak_power: 0.0, per_series: []}
    else
      # "Recent" reads against `readings.inserted_at`, which is written
      # via `DtuApp.Time.utc_now_usec/0`. Use the same DB clock for the
      # cutoff so a drifted app clock doesn't artificially age out fresh
      # rows (or vice versa).
      two_minutes_ago = DtuApp.Time.utc_now() |> DateTime.add(-120, :second)

      # Current power: only the AC aggregate row carries `ac_power`. A DTU
      # can publish many per-MPPT rows in between (and they're the most
      # recent rows for any given inverter), so we filter to mppt_index = 0
      # before picking the latest reading per inverter. Without this filter,
      # a per-MPPT row whose `ac_power` is nil would zero out the whole
      # `current_power` sum.
      latest_ac_readings =
        Repo.all(
          from r in Reading,
            where: r.dtu_id in ^dtu_ids and r.mppt_index == 0,
            distinct: [r.dtu_id, r.inverter_serial],
            order_by: [r.dtu_id, r.inverter_serial, desc: r.inserted_at]
        )

      # Latest reading per (dtu_id, inverter_serial, mppt_index) for the
      # per-series peak computation. The chart's per-series power uses the
      # same `chart_power_for_mppt/1` selection as the rest of this module
      # (ac_power for mppt_index = 0, dc_power for >= 1).
      latest_per_series_readings =
        Repo.all(
          from r in Reading,
            where: r.dtu_id in ^dtu_ids,
            distinct: [r.dtu_id, r.inverter_serial, r.mppt_index],
            order_by: [r.dtu_id, r.inverter_serial, r.mppt_index, desc: r.inserted_at]
        )

      current_power =
        latest_ac_readings
        |> Enum.filter(fn r -> DateTime.after?(r.inserted_at, two_minutes_ago) end)
        |> Enum.map(&(&1.ac_power || 0.0))
        |> Enum.sum()

      # Today's total yield: MAX(yield_day) per (dtu_id, inverter_serial,
      # mppt_index) within today's UTC window, summed across all series.
      # yield_day is the cumulative daily counter (resets at the
      # inverter's local midnight) per MPPT string, so MAX guarantees
      # we use the freshest reading for each (inverter, MPPT) even when
      # the latest raw row is stale. For OpenDTU and 1-MPPT inverters,
      # mppt_index = 1 and this reduces to the per-inverter sum.
      today = Date.utc_today()
      today_start = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")
      today_end = DateTime.new!(today, ~T[23:59:59], "Etc/UTC")

      today_yield_per_series =
        Repo.all(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and
                r.inserted_at >= ^today_start and r.inserted_at <= ^today_end,
            group_by: [r.dtu_id, r.inverter_serial, r.mppt_index, r.inverter_name],
            select: %{
              dtu_id: r.dtu_id,
              inverter_serial: r.inverter_serial,
              mppt_index: r.mppt_index,
              inverter_name: r.inverter_name,
              max_yield: max(r.yield_day)
            }
        )

      today_yield =
        today_yield_per_series
        |> Enum.map(fn row ->
          # nil can leak in if every reading for a series has yield_day: nil
          # (e.g. an inverter that has never reported a daily total).
          case row.max_yield do
            nil -> 0.0
            v -> v
          end
        end)
        |> Enum.sum()

      # Peak power today comes from the 5-minute continuous aggregate. The
      # bucket stays closed until its window fills, so a fast-rising
      # morning ramp can leave `bucket_max` several minutes behind the
      # live `current_power`. Lift the peak to the live reading whenever
      # it exceeds the bucket max so the displayed number reflects what
      # the inverter is producing *now*.
      bucket_max =
        case list_today_chart_data(user, dtu_id) do
          [] ->
            0.0

          points ->
            points
            |> Enum.map(& &1.power)
            |> Enum.max(fn -> 0.0 end)
        end

      peak_power = max(current_power, bucket_max)

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

      %{
        current_power: Float.round(current_power * 1.0, 1),
        # `readings.yield_day` is published by OpenDTU/AhoyDTU in Wh (per the
        # firmware's `YieldDay` field). The dashboard renders this stat with
        # a kWh label, so divide by 1000 before returning so the displayed
        # number matches the unit.
        today_yield: Float.round(today_yield / 1000, 3),
        peak_power: Float.round(peak_power * 1.0, 1),

        # Per (inverter, MPPT) breakdown so the dashboard can show each
        # string's contribution and name in the chart legend. Yields are
        # in kWh, peak powers in W (matching the totals' units).
        per_series:
          Enum.map(today_yield_per_series, fn row ->
            series = {row.dtu_id, row.inverter_serial, row.mppt_index, row.inverter_name}

            %{
              dtu_id: row.dtu_id,
              inverter_serial: row.inverter_serial,
              inverter_name: row.inverter_name,
              mppt_index: row.mppt_index,
              # nil can leak in if every reading for a series has yield_day: nil.
              today_yield: Float.round((row.max_yield || 0.0) / 1000, 3),
              peak_power: Float.round(Map.get(per_series_peak, series, 0.0), 1)
            }
          end)
      }
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
      readings =
        Repo.all(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and r.inserted_at >= ^utc_start and r.inserted_at <= ^utc_end,
            group_by: [fragment("?::date", r.inserted_at), r.dtu_id, r.inverter_serial],
            select: %{
              date: fragment("?::date", r.inserted_at),
              dtu_id: r.dtu_id,
              inverter_serial: r.inverter_serial,
              max_yield: max(r.yield_day)
            }
        )

      readings
      |> Enum.group_by(fn r ->
        case r.date do
          %Date{} = d -> d
          str when is_binary(str) -> Date.from_iso8601!(str)
        end
      end)
      |> Enum.map(fn {date, date_readings} ->
        # `readings.yield_day` is in Wh (see comment in `get_daily_stats/2`).
        # The historical chart and `total_yield` for the `stats` map both
        # render with a kWh label, so convert here.
        total_yield =
          date_readings
          |> Enum.map(&(&1.max_yield || 0.0))
          |> Enum.sum()
          |> Kernel./(1000)

        {date, total_yield}
      end)
      |> Enum.sort_by(fn {date, _} -> date end)
    end
  end

  # --- Helpers ----------------------------------------------------------------

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
