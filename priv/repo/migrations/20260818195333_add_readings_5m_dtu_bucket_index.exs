defmodule DtuApp.Repo.Migrations.AddReadings5mDtuBucketIndex do
  use Ecto.Migration

  @moduledoc """
  Add a btree index on `readings_5m (dtu_id, bucket DESC)` so the dashboard's
  per-device chart queries can filter by `dtu_id` and range-scan by `bucket`
  in a single index walk.

  Without this index, `SELECT bucket, dtu_id, inverter_serial, mppt_index,
  avg_ac_power, max_ac_power, inverter_name FROM readings_5m WHERE dtu_id IN
  ($1, ...) AND bucket BETWEEN $2 AND $3 ORDER BY bucket` falls back to a
  TimescaleDB ChunkAppend scan across every hypertable chunk. The index lets
  the planner pick index-only scans for the bucket range, which is the new
  hot query introduced by the dashboard perf branch.

  The DESC on `bucket` matches the dashboard's `ORDER BY bucket` so the
  index walk produces ordered rows; an ASC index would still work but a
  backward index walk is slower than a forward one on TimescaleDB-licensed
  versions.

  `WITH (timescaledb.transaction_per_chunk)` isn't needed for the dashboard
  query — it's a single SELECT, not a multi-chunk UPSERT.
  """

  @disable_ddl_transaction true

  def up do
    # The `IF NOT EXISTS` guard makes the migration idempotent: replaying it
    # on a database where the index already exists is a no-op instead of an
    # error.
    execute """
    CREATE INDEX IF NOT EXISTS readings_5m_dtu_id_bucket_idx
      ON readings_5m (dtu_id, bucket DESC)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS readings_5m_dtu_id_bucket_idx"
  end
end
