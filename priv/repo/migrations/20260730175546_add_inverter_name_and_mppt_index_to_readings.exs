defmodule DtuApp.Repo.Migrations.AddInverterNameAndMpptIndexToReadings do
  use Ecto.Migration

  @moduledoc """
  Each DTU can poll multiple inverters (or one inverter that exposes several
  MPPTs per string). The chart should be able to render per-inverter and
  per-MPPT lines, not just the total. So a single timestamp can produce
  multiple `readings` rows — one per (inverter_serial, mppt_index) — sharing
  the same `dtu_id` and `inserted_at`.

  The pk is widened from `(dtu_id, inverter_serial, inserted_at)` to
  `(dtu_id, inverter_serial, mppt_index, inserted_at)`. Existing rows
  backfill `mppt_index = 1` (the firmware's single "module" prior to this
  change) so that their keys remain unique after the constraint
  change. `inverter_name` is null for legacy data — the user can edit it
  later through the device edit page, or it will be populated by the
  AhoyDTU parser from the topic name on the next uplink.
  """

  @disable_ddl_transaction true

  def up do
    # 1. Add the new columns. The default fills existing rows so the
    #    primary-key constraint we re-add below doesn't trip on a NULL.
    alter table(:readings) do
      add :inverter_name, :string
      add :mppt_index, :integer, default: 1, null: false
    end

    # 2. Widen the primary key. TimescaleDB's hypertable bookkeeping
    #    doesn't care which columns are in the PK as long as `inserted_at`
    #    stays the partitioning column.
    execute "ALTER TABLE readings DROP CONSTRAINT readings_pkey"

    execute """
    ALTER TABLE readings
      ADD CONSTRAINT readings_pkey PRIMARY KEY (dtu_id, inverter_serial, mppt_index, inserted_at)
    """

    # 3. Recreate the continuous aggregates with the finer grouping.
    #    Same as 20260708190115 but with `inverter_serial` and
    #    `mppt_index` in the GROUP BY (so two inverters / two MPPTs each
    #    produce distinct series) and `inverter_name` in the SELECT
    #    (so the chart can label each line without a separate lookup).
    execute "DROP MATERIALIZED VIEW IF EXISTS readings_5m"
    execute "DROP MATERIALIZED VIEW IF EXISTS readings_hourly"
    execute "DROP MATERIALIZED VIEW IF EXISTS readings_daily"

    execute """
    CREATE MATERIALIZED VIEW readings_5m
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket(INTERVAL '5 minutes', inserted_at) AS bucket,
      dtu_id,
      inverter_serial,
      MAX(inverter_name) AS inverter_name,
      mppt_index,
      avg(ac_power) AS avg_ac_power,
      max(ac_power) AS max_ac_power,
      max(yield_day) AS yield_day,
      max(yield_total) AS yield_total
    FROM readings
    GROUP BY bucket, dtu_id, inverter_serial, mppt_index
    WITH NO DATA
    """

    execute """
    CREATE MATERIALIZED VIEW readings_hourly
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket(INTERVAL '1 hour', inserted_at) AS bucket,
      dtu_id,
      inverter_serial,
      MAX(inverter_name) AS inverter_name,
      mppt_index,
      avg(ac_power) AS avg_ac_power,
      max(ac_power) AS max_ac_power,
      max(yield_day) AS yield_day,
      max(yield_total) AS yield_total
    FROM readings
    GROUP BY bucket, dtu_id, inverter_serial, mppt_index
    WITH NO DATA
    """

    execute """
    CREATE MATERIALIZED VIEW readings_daily
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket(INTERVAL '1 day', inserted_at) AS bucket,
      dtu_id,
      inverter_serial,
      MAX(inverter_name) AS inverter_name,
      mppt_index,
      avg(ac_power) AS avg_ac_power,
      max(ac_power) AS max_ac_power,
      max(yield_day) AS yield_day,
      max(yield_total) AS yield_total
    FROM readings
    GROUP BY bucket, dtu_id, inverter_serial, mppt_index
    WITH NO DATA
    """

    # 4. Re-attach the refresh policies. The policy arguments are
    #    unchanged — the new dimension doesn't change refresh cadence.
    execute """
    SELECT add_continuous_aggregate_policy('readings_5m',
      start_offset      => INTERVAL '2 days',
      end_offset        => INTERVAL '5 minutes',
      schedule_interval => INTERVAL '5 minutes')
    """

    execute """
    SELECT add_continuous_aggregate_policy('readings_hourly',
      start_offset      => INTERVAL '14 days',
      end_offset        => INTERVAL '1 hour',
      schedule_interval => INTERVAL '1 hour')
    """

    execute """
    SELECT add_continuous_aggregate_policy('readings_daily',
      start_offset      => INTERVAL '60 days',
      end_offset        => INTERVAL '1 day',
      schedule_interval => INTERVAL '1 day')
    """
  end

  def down do
    # Reverse: drop the aggregates, drop the new column, restore the old
    # primary key. Pre-existing rows are still in the table with their
    # original (inverter_serial, inserted_at) values; the old PK is
    # unique for them because they all have mppt_index = 1.
    execute "SELECT remove_continuous_aggregate_policy('readings_5m',    if_exists => TRUE)"
    execute "SELECT remove_continuous_aggregate_policy('readings_hourly',if_exists => TRUE)"
    execute "SELECT remove_continuous_aggregate_policy('readings_daily', if_exists => TRUE)"

    execute "DROP MATERIALIZED VIEW IF EXISTS readings_daily"
    execute "DROP MATERIALIZED VIEW IF EXISTS readings_hourly"
    execute "DROP MATERIALIZED VIEW IF EXISTS readings_5m"

    execute "ALTER TABLE readings DROP CONSTRAINT readings_pkey"

    execute """
    ALTER TABLE readings
      ADD CONSTRAINT readings_pkey PRIMARY KEY (dtu_id, inverter_serial, inserted_at)
    """

    alter table(:readings) do
      remove :mppt_index
      remove :inverter_name
    end

    execute """
    CREATE MATERIALIZED VIEW readings_5m
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket(INTERVAL '5 minutes', inserted_at) AS bucket,
      dtu_id,
      avg(ac_power) AS avg_ac_power,
      max(ac_power) AS max_ac_power,
      max(yield_day) AS yield_day,
      max(yield_total) AS yield_total
    FROM readings
    GROUP BY bucket, dtu_id
    WITH NO DATA
    """

    execute """
    CREATE MATERIALIZED VIEW readings_hourly
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket(INTERVAL '1 hour', inserted_at) AS bucket,
      dtu_id,
      avg(ac_power) AS avg_ac_power,
      max(ac_power) AS max_ac_power,
      max(yield_day) AS yield_day,
      max(yield_total) AS yield_total
    FROM readings
    GROUP BY bucket, dtu_id
    WITH NO DATA
    """

    execute """
    CREATE MATERIALIZED VIEW readings_daily
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket(INTERVAL '1 day', inserted_at) AS bucket,
      dtu_id,
      avg(ac_power) AS avg_ac_power,
      max(ac_power) AS max_ac_power,
      max(yield_day) AS yield_day,
      max(yield_total) AS yield_total
    FROM readings
    GROUP BY bucket, dtu_id
    WITH NO DATA
    """

    execute """
    SELECT add_continuous_aggregate_policy('readings_5m',
      start_offset      => INTERVAL '2 days',
      end_offset        => INTERVAL '5 minutes',
      schedule_interval => INTERVAL '5 minutes')
    """

    execute """
    SELECT add_continuous_aggregate_policy('readings_hourly',
      start_offset      => INTERVAL '14 days',
      end_offset        => INTERVAL '1 hour',
      schedule_interval => INTERVAL '1 hour')
    """

    execute """
    SELECT add_continuous_aggregate_policy('readings_daily',
      start_offset      => INTERVAL '60 days',
      end_offset        => INTERVAL '1 day',
      schedule_interval => INTERVAL '1 day')
    """
  end
end
