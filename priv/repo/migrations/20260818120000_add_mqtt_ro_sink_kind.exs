defmodule DtuApp.Repo.Migrations.AddMqttRoSinkKind do
  use Ecto.Migration

  @moduledoc """
  Adds the `:mqtt_ro_sink` kind to the `dtus.kind` column.

  ## Background

  A read-only MQTT device is one that **subscribes** to every other
  DTU's uplink topics but is **never allowed to PUBLISH** — useful for
  brokers, dashboards, or analytics tools that want a real-time feed
  of telemetry without the ability to inject fake readings. The broker
  enforces this with a hard reject on PUBLISH (reason code 0x86, "Not
  Authorised") and the dashboard treats it as a presence-only device
  (no chart line).

  ## Why a migration (and not just a schema change)

  Ecto's `:string` + Ecto.Enum validates kinds at the changeset
  boundary, so the schema-only change in `lib/dtu_app/devices/dtu.ex`
  is enough for the application. This migration adds a defensive
  `CHECK` constraint at the database level so an out-of-band write
  (raw SQL, an external ETL, a future migration that forgets the
  Ecto.Enum) can't sneak an unrecognised value past the schema. The
  whole list of legal kinds mirrors `@kinds` in the schema — keep them
  in sync when adding a new one.

  The constraint is named `dtus_kind_check` so a future migration can
  drop and re-add it atomically when introducing another kind.
  """

  def up do
    # Idempotent: only add the constraint if it doesn't already exist
    # (handles databases that were built before this migration landed
    # and have been rolling forward through earlier migrations that
    # also create dtus with the prior three-kind check).
    execute """
    ALTER TABLE dtus
      ADD CONSTRAINT dtus_kind_check
      CHECK (kind IN ('opendtu', 'ahoydtu', 'shelly3em', 'mqtt_ro_sink'))
    """
  end

  def down do
    execute "ALTER TABLE dtus DROP CONSTRAINT IF EXISTS dtus_kind_check"
  end
end
