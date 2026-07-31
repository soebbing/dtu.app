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

  `mppt_index` is 0 for the AC-side aggregate reading (AhoyDTU ch0, OpenDTU
  total) and 1+ for individual MPPT channels. `inverter_name` is the
  human-friendly label, populated by the AhoyDTU parser from the topic
  name and by the device edit page for OpenDTU.

  Per-MPPT rows only carry `dc_power` (the firmware publishes per-channel
  DC scalars on `[serial]/[1-4]/...`); pass `dc_power:` explicitly to
  override the default. Setting `ac_power:` to nil for a per-MPPT row is
  supported — the fixture just leaves `dc_power` at whatever default you
  pass and won't coerce it from `ac_power`.
  """
  def reading_fixture(device, attrs \\ %{}) do
    {raw_inserted_at, attrs} = Map.pop(attrs, :inserted_at, DateTime.utc_now())
    inserted_at = DateTime.truncate(raw_inserted_at, :microsecond)

    {inverter_serial, attrs} = Map.pop(attrs, :inverter_serial, unique_inverter_serial())
    {mppt_index, attrs} = Map.pop(attrs, :mppt_index, 0)
    {inverter_name, attrs} = Map.pop(attrs, :inverter_name, nil)
    {ac_power, attrs} = Map.pop(attrs, :ac_power, 0.0)
    {dc_power, attrs} = Map.pop(attrs, :dc_power, ac_power)
    {yield_day, attrs} = Map.pop(attrs, :yield_day, 0.0)
    {yield_total, attrs} = Map.pop(attrs, :yield_total, 0.0)

    base = %{
      dtu_id: device.id,
      inverter_serial: inverter_serial,
      mppt_index: mppt_index,
      inverter_name: inverter_name,
      ac_power: ac_power,
      dc_power: dc_power,
      yield_day: yield_day,
      yield_total: yield_total,
      frequency: 50.0,
      temperature: 25.0,
      # `producing` is a hint — only true when AC-side power > 0. Per-MPPT
      # rows publish `dc_power` but never `ac_power`, so leave the flag
      # alone unless the caller overrides it.
      producing: not is_nil(ac_power) and ac_power > 0,
      reachable: true,
      inserted_at: inserted_at
    }

    overrides =
      Map.take(attrs, [
        :ac_power,
        :dc_power,
        :yield_day,
        :yield_total,
        :inserted_at,
        :inverter_serial,
        :mppt_index,
        :inverter_name,
        :producing,
        :reachable
      ])

    DtuApp.Repo.insert!(struct(Reading, Map.merge(base, overrides)))
  end
end
