defmodule DtuApp.Repo.Migrations.AddLastPowerAtToDtus do
  @moduledoc """
  Add `last_power_at` column to `dtus`.

  The dashboard's "online" indicators (the green dot in the device-list
  LiveView and the "online/offline" pill on the dashboard's device card)
  were derived from `last_seen_at`, which the MQTT telemetry pipeline
  touches on every uplink — including status frames and DISCONNECT
  packets. That meant a DTU whose inverter stopped publishing telemetry
  while the MQTT session stayed connected still showed "online" with a
  blanked-out current-power card. The user saw a contradiction: "online"
  on every badge but no live readings.

  `last_power_at` is touched by `DtuApp.MqttBroker.Telemetry` whenever
  an AC-aggregate reading (`mppt_index = 0`) is persisted, regardless of
  the value of `ac_power`. So at night, when the inverter publishes
  `ac_power = 0` every 30 s, the timestamp stays fresh and the device
  stays "online" — every indicator agrees. When the inverter stops
  publishing telemetry but the MQTT session lives on, the timestamp
  goes stale and all three indicators flip to "offline" together.

  The new `DtuApp.Devices.Dtu.producing_power?/2` helper gates on this
  column with a 120 s threshold (the same window the dashboard already
  uses for `current_power`).

  Reversible: `down/0` drops the column. Existing rows get NULLs — the
  LiveView templates render "offline" for a device that has never had a
  power reading, matching the behaviour pre-migration for new devices.
  """

  use Ecto.Migration

  def change do
    alter table(:dtus) do
      add :last_power_at, :utc_datetime_usec
    end
  end
end
