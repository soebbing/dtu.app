defmodule DtuApp.DevicesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `DtuApp.Devices` context.
  """

  def unique_device_name, do: "device#{System.unique_integer()}"
  def unique_mqtt_username, do: "mqtt_user#{System.unique_integer()}"

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
end
