defmodule DtuApp.Devices do
  @moduledoc """
  The Devices context.

  Every function is scoped to an owning `DtuApp.Accounts.User`, so a user can
  only ever touch their own devices. Create/update/delete refresh the MQTT
  credential cache (see `DtuApp.MqttBroker.Credentials`) so the broker sees new
  credentials without a restart.
  """

  import Ecto.Query
  alias DtuApp.Repo
  alias DtuApp.Accounts.User
  alias DtuApp.Devices.Dtu

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

  # Called after a successful create/update. The Credentials module lands in
  # Phase 3; until then these calls are no-ops (guarded by function_exported?).
  defp refresh_credentials(%Dtu{mqtt_username: username}) do
    safe_call(fn -> DtuApp.MqttBroker.Credentials.refresh(username) end)
  end

  defp drop_credentials(username) do
    safe_call(fn -> DtuApp.MqttBroker.Credentials.drop(username) end)
  end

  defp safe_call(fun) do
    if Code.ensure_loaded?(DtuApp.MqttBroker.Credentials) do
      fun.()
    end
  end

  defp tap_on_success({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_on_success(error, _fun), do: error

  # --- Readings Context -------------------------------------------------------

  alias DtuApp.Devices.Reading

  @doc "Create a telemetry reading."
  def create_reading(attrs) do
    %Reading{}
    |> Reading.changeset(attrs)
    |> Repo.insert()
  end

  @doc "List recent readings for a specific user-owned DTU."
  def list_recent_readings(%User{} = user, dtu_id, limit \\ 100) do
    if Repo.exists?(from d in Dtu, where: d.user_id == ^user.id and d.id == ^dtu_id) do
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

  @doc "Fetch all of today's readings for the user's DTUs (raw database level)."
  def list_today_readings_for_chart(%User{} = user) do
    dtu_ids = Repo.all(from d in Dtu, where: d.user_id == ^user.id, select: d.id)
    today_start = DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    if dtu_ids == [] do
      []
    else
      Repo.all(
        from r in Reading,
          where: r.dtu_id in ^dtu_ids and r.inserted_at >= ^today_start,
          order_by: [asc: r.inserted_at],
          select: %{inserted_at: r.inserted_at, ac_power: r.ac_power}
      )
    end
  end

  @doc "Fetch and downsample today's power readings into 5-minute buckets for charts."
  def list_today_chart_data(%User{} = user) do
    readings = list_today_readings_for_chart(user)

    if readings == [] do
      []
    else
      readings
      |> Enum.group_by(fn r ->
        div(DateTime.to_unix(r.inserted_at), 300)
      end)
      |> Enum.map(fn {bucket, bucket_readings} ->
        avg_power =
          bucket_readings
          |> Enum.map(&(&1.ac_power || 0.0))
          |> then(fn powers -> Enum.sum(powers) / length(powers) end)

        time = DateTime.from_unix!(bucket * 300)
        {time, avg_power}
      end)
      |> Enum.sort_by(fn {time, _} -> time end)
    end
  end

  @doc "Calculate aggregated daily stats for a user's DTUs."
  def get_daily_stats(%User{} = user) do
    dtu_ids = Repo.all(from d in Dtu, where: d.user_id == ^user.id, select: d.id)
    today_start = DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    if dtu_ids == [] do
      %{current_power: 0.0, today_yield: 0.0, peak_power: 0.0}
    else
      # Fetch the latest reading for each distinct (dtu_id, inverter_serial)
      sub =
        from r in Reading,
          where: r.dtu_id in ^dtu_ids,
          distinct: [r.dtu_id, r.inverter_serial],
          order_by: [r.dtu_id, r.inverter_serial, desc: r.inserted_at]

      latest_readings = Repo.all(sub)

      # 2 minutes cutoff for online current power status
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

      peak_power =
        Repo.one(
          from r in Reading,
            where: r.dtu_id in ^dtu_ids and r.inserted_at >= ^today_start,
            select: max(r.ac_power)
        ) || 0.0

      %{
        current_power: Float.round(current_power * 1.0, 1),
        today_yield: Float.round(today_yield * 1.0, 3),
        peak_power: Float.round(peak_power * 1.0, 1)
      }
    end
  end
end
