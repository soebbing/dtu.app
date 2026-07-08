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

  @doc "Fetch all of a specific day's readings for the user's DTUs (raw rows)."
  def list_day_readings_for_chart(%User{} = user, date, dtu_id \\ nil) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      []
    else
      day_start = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      day_end = DateTime.new!(date, ~T[23:59:59], "Etc/UTC")

      Repo.all(
        from r in Reading,
          where:
            r.dtu_id in ^dtu_ids and r.inserted_at >= ^day_start and r.inserted_at <= ^day_end,
          order_by: [asc: r.inserted_at],
          select: %{inserted_at: r.inserted_at, ac_power: r.ac_power, dtu_id: r.dtu_id}
      )
    end
  end

  @doc """
  Fetch a specific day's power readings as 5-minute buckets for charts.

  Buckets raw rows in Elixir so the "today" view stays live (a continuous
  aggregate would lag by its refresh window and miss just-inserted readings).
  The `readings_5m` aggregate is available for batch/historical queries where
  a little staleness is acceptable.
  """
  def list_day_chart_data(%User{} = user, date, dtu_id \\ nil) do
    readings = list_day_readings_for_chart(user, date, dtu_id)

    if readings == [] do
      []
    else
      readings
      |> Enum.group_by(fn r -> div(DateTime.to_unix(r.inserted_at), 300) end)
      |> Enum.map(fn {bucket, bucket_readings} ->
        dtu_grouped = Enum.group_by(bucket_readings, & &1.dtu_id)

        sum_of_averages =
          dtu_grouped
          |> Enum.map(fn {_dtu_id, dtu_readings} ->
            powers = Enum.map(dtu_readings, &(&1.ac_power || 0.0))
            Enum.sum(powers) / length(powers)
          end)
          |> Enum.sum()

        {DateTime.from_unix!(bucket * 300), sum_of_averages}
      end)
      |> Enum.sort_by(fn {time, _} -> time end)
    end
  end

  @doc "Fetch all of today's readings for the user's DTUs (raw rows)."
  def list_today_readings_for_chart(%User{} = user, dtu_id \\ nil) do
    list_day_readings_for_chart(user, Date.utc_today(), dtu_id)
  end

  @doc "Fetch today's power readings as 5-minute buckets for charts."
  def list_today_chart_data(%User{} = user, dtu_id \\ nil) do
    list_day_chart_data(user, Date.utc_today(), dtu_id)
  end

  @doc "Calculate aggregated daily stats for a user's DTUs (or a specific DTU)."
  def get_daily_stats(%User{} = user, dtu_id \\ nil) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      %{current_power: 0.0, today_yield: 0.0, peak_power: 0.0}
    else
      # Latest reading per (dtu_id, inverter_serial) — uses the hypertable's
      # time-descending index.
      sub =
        from r in Reading,
          where: r.dtu_id in ^dtu_ids,
          distinct: [r.dtu_id, r.inverter_serial],
          order_by: [r.dtu_id, r.inverter_serial, desc: r.inserted_at]

      latest_readings = Repo.all(sub)

      two_minutes_ago = DateTime.utc_now() |> DateTime.add(-120, :second)

      current_power =
        latest_readings
        |> Enum.filter(fn r -> DateTime.after?(r.inserted_at, two_minutes_ago) end)
        |> Enum.map(&(&1.ac_power || 0.0))
        |> Enum.sum()

      today_yield =
        latest_readings
        |> Enum.map(&(&1.yield_day || 0.0))
        |> Enum.sum()

      # Peak power today comes from the 5-minute continuous aggregate.
      peak_power =
        case list_today_chart_data(user, dtu_id) do
          [] ->
            0.0

          points ->
            points
            |> Enum.map(fn {_, power} -> power end)
            |> Enum.max(fn -> 0.0 end)
        end

      %{
        current_power: Float.round(current_power * 1.0, 1),
        today_yield: Float.round(today_yield * 1.0, 3),
        peak_power: Float.round(peak_power * 1.0, 1)
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
  def list_range_yield_data(%User{} = user, start_date, end_date, dtu_id \\ nil) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    start_dt = DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC")
    end_dt = DateTime.new!(end_date, ~T[23:59:59], "Etc/UTC")

    if dtu_ids == [] do
      []
    else
      readings =
        Repo.all(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and r.inserted_at >= ^start_dt and r.inserted_at <= ^end_dt,
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
        total_yield =
          date_readings
          |> Enum.map(&(&1.max_yield || 0.0))
          |> Enum.sum()

        {date, total_yield}
      end)
      |> Enum.sort_by(fn {date, _} -> date end)
    end
  end

  # --- Helpers ----------------------------------------------------------------

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
