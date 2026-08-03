defmodule DtuApp.Repo.Migrations.DropOnlineFromDtus do
  @moduledoc """
  Drop the `online` boolean column from `dtus`.

  Online/offline status is now **derived** from `last_seen_at`: a DTU
  is online iff it has produced an MQTT message (CONNECT or uplink)
  within the last 5 minutes, and offline otherwise. The dashboard and
  the device-list LiveView read the derived `Dtu.online?/2` helper
  directly, so the stored boolean is no longer needed and was actively
  lying to users: a DTU that stayed MQTT-connected but stopped
  publishing would keep `online: true` indefinitely with a stale
  `last_seen_at` and no automatic way to flip it back.

  `last_seen_at` is now touched on every uplink (see
  `DtuApp.MqttBroker.Telemetry.handle_info({:uplink, ...}, ...)`),
  so the derived value reflects the DTU's actual liveness in
  real time.

  Reversible: `down/0` re-adds the column with the same default as the
  original `20260705190905_create_dtus.exs` migration.
  """

  use Ecto.Migration

  def up do
    alter table(:dtus) do
      remove :online
    end
  end

  def down do
    alter table(:dtus) do
      add :online, :boolean, null: false, default: false
    end
  end
end
