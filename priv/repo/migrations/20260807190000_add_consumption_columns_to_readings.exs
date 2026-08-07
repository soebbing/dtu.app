defmodule DtuApp.Repo.Migrations.AddConsumptionColumnsToReadings do
  use Ecto.Migration

  @moduledoc """
  Extends the `readings` hypertable so a single schema can carry both
  solar **production** telemetry (the original OpenDTU/AhoyDTU use case)
  and household **consumption** telemetry from a paired Shelly Plus 3EM
  (Gen3+) energy meter.

  Without `power_type` we'd silently flip the meaning of every existing
  query the moment a Shelly row landed: the dashboard's "Current Power"
  card would start showing *consumed* watts for Shelly users. The enum
  column lets the dashboard branch cleanly — production sums and
  consumption sums stay separate.

  Three new columns capture the Shelly-relevant metrics that don't map
  cleanly onto the existing production fields:

    * `consumption_power` (W) — Shelly `em:0.total_act_power`, signed
      (negative on net export)
    * `consumption_energy_day` (kWh) — Shelly `em:0.total_act_energy`,
      converted from Wh
    * `consumption_energy_total` (kWh) — same source, lifetime counter

  All three are nullable; existing rows (and OpenDTU/AhoyDTU rows in
  the future) leave them `NULL`. `power_type` defaults to `:production`
  so existing rows don't need a backfill.

  The composite primary key `(dtu_id, inverter_serial, mppt_index,
  inserted_at)` still works for Shelly rows: a single EM device publishes
  one logical meter (`em:0`), so `inverter_serial = "em:0"` and
  `mppt_index = 0` — identical to OpenDTU's AC-aggregate rows.
  """

  def change do
    alter table(:readings) do
      add :power_type, :string, default: "production", null: false
      add :consumption_power, :float
      add :consumption_energy_day, :float
      add :consumption_energy_total, :float
    end

    # Index for the dashboard's consumption queries. The dashboard's
    # "Current Consumption" / "Today's Consumption" cards filter by
    # `power_type = 'consumption'` and bucket by time range — an index on
    # (power_type, dtu_id, inserted_at) keeps those queries cheap once
    # the readings table grows.
    create index(:readings, [:power_type, :dtu_id, :inserted_at],
             name: :readings_power_type_dtu_id_inserted_at_index
           )
  end
end
