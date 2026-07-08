defmodule DtuApp.Repo.Migrations.CreateReadingsContinuousAggregates do
  use Ecto.Migration

  @moduledoc """
  Continuous aggregates over the `readings` hypertable, used by the dashboard
  to render charts and summary stats without scanning raw rows.

    * `readings_5m`    — 5-minute power avg/max plus yield (per dtu_id).
    * `readings_hourly`— hourly power avg/max plus yield (per dtu_id).
    * `readings_daily` — daily power avg/max plus yield (per dtu_id).

  All are created `WITH NO DATA` (instant; materialized by refresh policies).
  `materialized_only => false` (the default) unions recent raw rows in so the
  dashboard sees "now" without waiting for the policy.
  """

  @disable_ddl_transaction true

  def up do
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

  def down do
    execute "DROP MATERIALIZED VIEW IF EXISTS readings_daily"
    execute "DROP MATERIALIZED VIEW IF EXISTS readings_hourly"
    execute "DROP MATERIALIZED VIEW IF EXISTS readings_5m"
  end
end
