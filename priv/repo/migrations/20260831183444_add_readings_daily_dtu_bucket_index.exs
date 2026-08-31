defmodule DtuApp.Repo.Migrations.AddReadingsDailyDtuBucketIndex do
  use Ecto.Migration

  @moduledoc """
  Add a btree index on `readings_daily (dtu_id, bucket DESC)` so a
  future `list_selectable_dates/2`-on-cagg rewrite can run as a
  single index range scan over <6k rows (3 devices × 5 y × 365 d)
  instead of a heap scan over the materialized view.

  Why we don't switch to the cagg NOW: the cagg is
  `materialized_only => true` (verified against
  `timescaledb_information.continuous_aggregates`) with a 60-day
  `start_offset` and a 1-day `end_offset`, refreshed once a day.
  A reading that landed yesterday is therefore only in the cagg
  after the next daily policy tick — for ~24 h the dashboard's
  stepper would silently miss "today"/"yesterday". Querying raw
  `readings` keeps the freshness guarantee, and the
  `(dtu_id, inserted_at)` btree on the raw table keeps the 5-year
  scan cheap. We add this index now so the cagg path is one PR
  away the day we (a) flip the cagg to `materialized_only => false`,
  or (b) introduce a daily-marker materialised view.

  Mirrors `20260818195333_add_readings_5m_dtu_bucket_index.exs`,
  which added the same shape of index on `readings_5m`.
  """

  @disable_ddl_transaction true

  def up do
    execute """
    CREATE INDEX IF NOT EXISTS readings_daily_dtu_id_bucket_idx
      ON readings_daily (dtu_id, bucket DESC)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS readings_daily_dtu_id_bucket_idx"
  end
end
