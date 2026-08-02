defmodule DtuApp.Repo.Migrations.SetDbClockDefaultsForTimeColumns do
  @moduledoc """
  Set a `DEFAULT now()` on every timestamp column in the schema that
  should *always* be filled with the current time when the INSERT
  doesn't supply an explicit value, so that any code path gets the **DB
  clock**, not the app container's clock.

  Application code also routes every timestamped write through
  `DtuApp.Time.utc_now/0` (a `SELECT now()` round trip), so the value
  the DB stores and the value the DB compares against in time-windowed
  queries come from the same source. This migration is the schema-level
  safety net for any code path that doesn't go through the helper (raw
  SQL, ad-hoc `Repo.insert_all`, future migrations, etc.).

  ## What is *not* defaulted

  `users.confirmed_at` is intentionally **not** defaulted. It's a
  tri-state semantic column (`nil` = "not yet confirmed", non-nil =
  "confirmed at <instant>"), and `Accounts.register_user/1` relies on
  the column being `nil` after a fresh INSERT to identify users that
  still need to click the confirmation link. A `DEFAULT now()` on this
  column would auto-confirm every newly-registered user, which is
  exactly the regression this migration's safety net must not introduce.
  `User.confirm_changeset/1` already sets `confirmed_at` to
  `DtuApp.Time.utc_now()` on the actual confirmation path, so the DB-
  clock invariant still holds for confirmed users.

  Only the column DEFAULTs change — no column types, no data backfill.
  Setting `DEFAULT now()` on a `timestamp` column is a metadata-only
  operation in Postgres; it doesn't rewrite the table and doesn't
  require dropping the continuous aggregates over `readings`.

  Reversible: `down/0` drops the default from each column.
  """

  use Ecto.Migration

  @tables [
    # {table, [columns to give DEFAULT now()]}
    # `users.confirmed_at` is deliberately absent — see the @moduledoc.
    {"users", [:inserted_at, :updated_at]},
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
