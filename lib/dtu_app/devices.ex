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
            powers = Enum.map(series_readings, fn r -> r.consumption_power || 0.0 end)
            power = Enum.sum(powers) / length(series_readings)

            %{time: time, series: {dtu_id, "em:0", 0, nil}, power: power}
          end)
        end)
        |> Enum.sort_by(& &1.time)
      end
    end
  end

  @doc "Calculate aggregated daily stats for a user's DTUs (or a specific DTU)."
  def get_daily_stats(%User{} = user, dtu_id \\ nil) do
    get_daily_stats(user, dtu_id, Date.utc_today())
  end

  @doc """
  Same as `get_daily_stats/2` but accepts the target date (UTC) so
  the sun-down scheduler can request yesterday's totals without
  duplicating the SQL. `current_power` and `peak_power` are still
  computed against *today* (the most recent readings) — they only
  make sense for the live day — but `today_yield` reflects the
  requested date so we can compare day-over-day.
  """
  def get_daily_stats(%User{} = user, dtu_id, %Date{} = date) do
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
      today_start = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      today_end = DateTime.new!(date, ~T[23:59:59], "Etc/UTC")

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
        #
        # Round to one decimal place so the "Today's Total Yield" stat reads
        # as e.g. `12.3 kWh` rather than `12.345 kWh`.
        today_yield: Float.round(today_yield / 1000, 1),
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

  `today_consumption` is MAX(consumption_energy_day) summed across
  the user's Shelly devices for today. `consumption_energy_day`
  arrives from Shelly in Wh (same unit as OpenDTU's `yield_day`,
  but for the *consumed* side), so the result is divided by 1000
  to kWh to match the unit on the dashboard.

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
      latest_readings =
        Repo.all(
          from r in Reading,
            where: r.dtu_id in ^dtu_ids and r.power_type == "consumption",
            distinct: true,
            order_by: [r.dtu_id, desc: r.inserted_at]
        )

      current_consumption =
        latest_readings
        |> Enum.filter(fn r -> DateTime.after?(r.inserted_at, two_minutes_ago) end)
        |> Enum.map(&(&1.consumption_power || 0.0))
        |> Enum.sum()

      today_start = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
      today_end = DateTime.new!(Date.utc_today(), ~T[23:59:59], "Etc/UTC")

      # Shelly reports `consumption_energy_total` as a lifetime
      # counter (Wh) and `consumption_energy_day` as a daily counter
      # (Wh). The daily counter resets at Shelly's local midnight,
      # so MAX() within today's window gives the freshest value per
      # device. Sum across devices for the household total.
      today_consumption_per_device =
        Repo.all(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and r.power_type == "consumption" and
                r.inserted_at >= ^today_start and r.inserted_at <= ^today_end,
            group_by: r.dtu_id,
            select: %{dtu_id: r.dtu_id, max_day: max(r.consumption_energy_day)}
        )

      today_consumption =
        today_consumption_per_device
        |> Enum.map(fn row ->
          case row.max_day do
            nil -> 0.0
            v -> v
          end
        end)
        |> Enum.sum()

      # Bucket max for the peak: same convention as production —
      # the live reading wins when it exceeds the bucket max.
      bucket_max =
        case list_today_consumption_chart_data(user, dtu_id) do
          [] ->
            0.0

          points ->
            points
            |> Enum.map(& &1.power)
            |> Enum.max(fn -> 0.0 end)
        end

      peak_consumption = max(current_consumption, bucket_max)

      %{
        current_consumption: Float.round(current_consumption * 1.0, 1),
        # Shelly `consumption_energy_day` is in Wh; dashboard shows kWh.
        today_consumption: Float.round(today_consumption / 1000, 1),
        peak_consumption: Float.round(peak_consumption * 1.0, 1)
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
          avg_power: float()
        }
  def compute_day_period_stats(yields, points) do
    total_yield =
      case yields do
        [{_date, y}] -> y
        _ -> 0.0
      end

    peak_power =
      case points do
        [] -> 0.0
        pts -> pts |> Enum.map(& &1.power) |> Enum.max(fn -> 0.0 end)
      end

    avg_power =
      case points do
        [] -> 0.0
        pts -> Enum.sum(pts |> Enum.map(& &1.power)) / length(pts)
      end

    %{
      total_yield: Float.round(total_yield * 1.0, 1),
      peak_power: Float.round(peak_power * 1.0, 1),
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
