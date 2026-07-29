defmodule DtuApp.Repo.Migrations.WidenReadingsTimestampPrecisionToMicroseconds do
  use Ecto.Migration

  @moduledoc """
  Widens `readings.inserted_at` from `timestamp(0)` (second-precision) to
  `timestamp(6)` (microsecond-precision). Required because the composite
  primary key `(dtu_id, inverter_serial, inserted_at)` collapses every
  insert within the same calendar second onto the same PK row, which
  caused unique-constraint crashes once AhoyDTU began flushing on every
  meaningful metric (yield/temperature uplinks arriving in the same
  second).

  Column type stays `timestamp without time zone` to preserve parity
  with the Ecto schema. Only the precision is widened; existing rows
  are preserved (their sub-second component is simply 0).

  The three continuous aggregates over `readings` (`readings_5m`,
  `readings_hourly`, `readings_daily`) select `inserted_at` internally
  and so Postgres refuses to alter the column type while they exist.
  They're dropped (CASCADE removes their policies) before the alter
  and recreated `WITH NO DATA` after, with their refresh policies
  re-attached. `materialized_only => false` on the dashboard queries
  means recent raw rows are unioned in regardless.
  """

  @disable_ddl_transaction true

  def up do
    # 1. Drop the continuous aggregate views. CASCADE also removes their
    #    refresh policies and the TimescaleDB internal helpers. Wrapped in a
    #    retry loop because the previous migration's
    #    `add_continuous_aggregate_policy` registered background workers
    #    that occasionally fire and acquire a lock on the same
    #    `_timescaledb_catalog.continuous_agg` tuple our DROP wants — the
    #    concurrent transaction then aborts with
    #    "tuple concurrently updated".
    execute """
    DO $$
    DECLARE
      attempts int := 0;
      ok boolean := false;
    BEGIN
      WHILE attempts < 60 AND NOT ok LOOP
        BEGIN
          DROP MATERIALIZED VIEW IF EXISTS readings_5m     CASCADE;
          DROP MATERIALIZED VIEW IF EXISTS readings_hourly CASCADE;
          DROP MATERIALIZED VIEW IF EXISTS readings_daily  CASCADE;
          ok := true;
        EXCEPTION WHEN OTHERS THEN
          attempts := attempts + 1;
          RAISE NOTICE 'retrying continuous-aggregate drop (attempt %): %',
            attempts, SQLERRM;
          PERFORM pg_sleep(1);
        END;
      END LOOP;
      IF NOT ok THEN
        RAISE EXCEPTION 'failed to drop continuous aggregates after 60 attempts';
      END IF;
    END $$;
    """

    # 2. The composite PK includes `inserted_at`, so drop it before altering.
    execute "ALTER TABLE readings DROP CONSTRAINT readings_pkey"

    # 3. Widen to microsecond precision. USING inserted_at is a no-op cast
    #    but is required for the type change; existing rows keep their
    #    values with sub-second 0.
    execute """
    ALTER TABLE readings
      ALTER COLUMN inserted_at TYPE timestamp(6)
      USING inserted_at
    """

    # 4. Re-add the composite PK.
    execute """
    ALTER TABLE readings
      ADD CONSTRAINT readings_pkey PRIMARY KEY (dtu_id, inverter_serial, inserted_at)
    """

    # 5. Recreate the continuous aggregates WITH NO DATA. Definitions must
    #    stay in lock-step with CreateReadingsContinuousAggregates so the
    #    dashboards don't change behaviour.
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

    # 6. Re-attach refresh policies.
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
    # Same retry-on-DROP strategy as `up/0` — the views+policy recreation
    # below re-attaches workers, and any concurrent DROP of the same views
    # races with their lock on the `_timescaledb_catalog.continuous_agg`
    # tuple.
    execute """
    DO $$
    DECLARE
      attempts int := 0;
      ok boolean := false;
    BEGIN
      WHILE attempts < 60 AND NOT ok LOOP
        BEGIN
          DROP MATERIALIZED VIEW IF EXISTS readings_5m     CASCADE;
          DROP MATERIALIZED VIEW IF EXISTS readings_hourly CASCADE;
          DROP MATERIALIZED VIEW IF EXISTS readings_daily  CASCADE;
          ok := true;
        EXCEPTION WHEN OTHERS THEN
          attempts := attempts + 1;
          RAISE NOTICE 'retrying continuous-aggregate drop (attempt %): %',
            attempts, SQLERRM;
          PERFORM pg_sleep(1);
        END;
      END LOOP;
      IF NOT ok THEN
        RAISE EXCEPTION 'failed to drop continuous aggregates after 60 attempts';
      END IF;
    END $$;
    """

    execute "ALTER TABLE readings DROP CONSTRAINT readings_pkey"

    # Truncate back to second precision. Rows within the same second
    # collide on the composite PK on the way down; the ALTER succeeds
    # but those rows stay distinct — the unique constraint fails to
    # re-add and the down migration aborts. Operators need to dedupe
    # by hand before rolling back.
    execute """
    ALTER TABLE readings
      ALTER COLUMN inserted_at TYPE timestamp(0)
      USING date_trunc('second', inserted_at)
    """

    execute """
    DELETE FROM readings a USING readings b
     WHERE a.ctid < b.ctid
       AND a.dtu_id = b.dtu_id
       AND a.inverter_serial = b.inverter_serial
       AND a.inserted_at = b.inserted_at
    """

    execute """
    ALTER TABLE readings
      ADD CONSTRAINT readings_pkey PRIMARY KEY (dtu_id, inverter_serial, inserted_at)
    """

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
