defmodule DtuApp.Repo.Migrations.ReadingsToHypertable do
  use Ecto.Migration

  @moduledoc """
  Converts the existing `readings` table into a TimescaleDB hypertable keyed on
  `inserted_at`, enables compression (segmented by `dtu_id`), and adds a
  retention policy that drops raw readings older than one year.
  """

  @disable_ddl_transaction true

  def up do
    # `inserted_at` and `inverter_serial` must be NOT NULL (they're part of the
    # composite PK). `inverter_serial` already is; `inserted_at` is too from
    # timestamps/0 but enforce it defensively.
    execute "ALTER TABLE readings ALTER COLUMN inserted_at SET NOT NULL"

    # Timescale requires the partitioning column to be part of every unique
    # index. The table's default `id` serial PK doesn't include inserted_at, so
    # replace it with a composite PK. No foreign key references readings.id.
    execute "ALTER TABLE readings DROP CONSTRAINT readings_pkey"
    execute "ALTER TABLE readings DROP COLUMN id"

    execute """
    ALTER TABLE readings
      ADD CONSTRAINT readings_pkey PRIMARY KEY (dtu_id, inverter_serial, inserted_at)
    """

    execute """
    SELECT create_hypertable(
      'readings',
      'inserted_at',
      chunk_time_interval => INTERVAL '7 days',
      if_not_exists       => TRUE
    )
    """

    execute """
    ALTER TABLE readings SET (
      timescaledb.compress,
      timescaledb.compress_segmentby = 'dtu_id',
      timescaledb.compress_orderby   = 'inserted_at DESC'
    )
    """

    execute "SELECT add_compression_policy('readings', INTERVAL '7 days')"
    execute "SELECT add_retention_policy('readings', INTERVAL '365 days')"
  end

  def down do
    execute "SELECT remove_retention_policy('readings', if_exists => TRUE)"
    execute "SELECT remove_compression_policy('readings', if_exists => TRUE)"
    execute "ALTER TABLE readings SET (timescaledb.compress = false)"

    execute "ALTER TABLE readings DROP CONSTRAINT readings_pkey"
    execute "ALTER TABLE readings ADD COLUMN id BIGSERIAL PRIMARY KEY"
    execute "ALTER TABLE readings ALTER COLUMN inserted_at DROP NOT NULL"
  end
end
