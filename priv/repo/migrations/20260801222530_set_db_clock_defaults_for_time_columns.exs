defmodule DtuApp.Repo.Migrations.SetDbClockDefaultsForTimeColumns do
  @moduledoc """
  Set a `DEFAULT now()` on every timestamp column in the schema, so any
  INSERT that doesn't supply an explicit value still gets the **DB
  clock**, not the app container's clock.

  Application code now also routes every timestamped write through
  `DtuApp.Time.utc_now/0` (a `SELECT now()` round trip), so the value
  the DB stores and the value the DB compares against in time-windowed
  queries come from the same source. This migration is the schema-level
  safety net for any code path that doesn't go through the helper (raw
  SQL, ad-hoc `Repo.insert_all`, future migrations, etc.).

  Only the column DEFAULTs change — no column types, no data backfill.
  Setting `DEFAULT now()` on a `timestamp` column is a metadata-only
  operation in Postgres; it doesn't rewrite the table and doesn't
  require dropping the continuous aggregates over `readings`.

  Reversible: `down/0` drops the default from each column.
  """

  use Ecto.Migration

  @tables [
    # {table, [columns to give DEFAULT now()]}
    {"users", [:confirmed_at, :inserted_at, :updated_at]},
    {"users_tokens", [:inserted_at]},
    {"dtus", [:last_seen_at, :inserted_at, :updated_at]},
    {"readings", [:inserted_at]}
  ]

  def up do
    for {table, columns} <- @tables do
      for column <- columns do
        execute(
          "ALTER TABLE #{table} ALTER COLUMN #{column} SET DEFAULT now()",
          "ALTER TABLE #{table} ALTER COLUMN #{column} DROP DEFAULT"
        )
      end
    end
  end

  def down do
    for {table, columns} <- @tables do
      for column <- columns do
        execute(
          "ALTER TABLE #{table} ALTER COLUMN #{column} DROP DEFAULT",
          "ALTER TABLE #{table} ALTER COLUMN #{column} SET DEFAULT now()"
        )
      end
    end
  end
end
