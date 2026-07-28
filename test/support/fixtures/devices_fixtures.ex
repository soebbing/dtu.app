defmodule DtuApp.DevicesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `DtuApp.Devices` context.
  """

  alias DtuApp.Devices.{Reading}

  def unique_device_name, do: "device#{System.unique_integer()}"
  def unique_mqtt_username, do: "mqtt_user#{System.unique_integer()}"
  def unique_inverter_serial, do: "inv#{System.unique_integer([:positive])}"

  def device_fixture(user, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: unique_device_name(),
        kind: :opendtu,
        mqtt_username: unique_mqtt_username(),
        mqtt_password: "supersecretpassword",
        base_topic: "solar"
      })

    {:ok, device} = DtuApp.Devices.create_device(user, attrs)
    device
  end

  @doc """
  Insert a raw reading for the given device. `inserted_at` defaults to
  `DateTime.utc_now/0`; pass an explicit value when the test needs the
  reading to fall inside or outside the today-UTC window.
  """
  def reading_fixture(device, attrs \\ %{}) do
    {raw_inserted_at, attrs} = Map.pop(attrs, :inserted_at, DateTime.utc_now())
    inserted_at = DateTime.truncate(raw_inserted_at, :microsecond)

    {inverter_serial, attrs} = Map.pop(attrs, :inverter_serial, unique_inverter_serial())
    {ac_power, attrs} = Map.pop(attrs, :ac_power, 0.0)
    {yield_day, attrs} = Map.pop(attrs, :yield_day, 0.0)
    {yield_total, attrs} = Map.pop(attrs, :yield_total, 0.0)

    base = %{
      dtu_id: device.id,
      inverter_serial: inverter_serial,
      ac_power: ac_power,
      dc_power: ac_power,
      yield_day: yield_day,
      yield_total: yield_total,
      frequency: 50.0,
      temperature: 25.0,
      producing: ac_power > 0,
      reachable: true,
      inserted_at: inserted_at
    }

    overrides =
      Map.take(attrs, [
        :ac_power,
        :yield_day,
        :yield_total,
        :inserted_at,
        :inverter_serial,
        :producing,
        :reachable
      ])

    DtuApp.Repo.insert!(struct(Reading, Map.merge(base, overrides)))
  end
end
