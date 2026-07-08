defmodule DtuApp.Repo.Migrations.EnableTimescaledb do
  use Ecto.Migration

  @moduledoc """
  Enables the TimescaleDB extension. Requires a superuser (or a role with the
  TimescaleDB privileges). Locally the docker `timescale/timescaledb` image runs
  as the `postgres` superuser, so this just works. In CI / managed databases,
  create the extension once out-of-band with a superuser role.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS timescaledb"
  end

  def down do
    execute "DROP EXTENSION IF EXISTS timescaledb"
  end
end
