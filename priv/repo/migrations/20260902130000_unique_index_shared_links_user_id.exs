defmodule DtuApp.Repo.Migrations.UniqueIndexSharedLinksUserId do
  use Ecto.Migration

  @moduledoc """
  Enforces "at most one share per user" at the DB level.

  The `accounts.create_shared_link/1` flow used a `delete_all` +
  `insert` inside a single transaction. Under contention that's NOT
  safe: when no row matches the `delete_all`, Postgres acquires no
  row lock, so N concurrent transactions each `insert` a fresh row
  with a fresh UUID and a unique `token_hash` — none of the inserts
  conflict, so all of them commit. The resulting duplicates crash
  `Accounts.get_shared_link/1` (it uses `Repo.one/1` which raises
  `Ecto.MultipleResultsError` on >1 row), which in turn crashes the
  dashboard LiveView mount.

  The fix has two parts:
    1. The schema declares `has_one :shared_link` but the migration
       that created the table only had `unique_index(:shared_links,
       [:token_hash])`. There was no DB-level guarantee that one
       user → one share row. Adding `unique_index(:shared_links,
       [:user_id])` closes that gap: even if a future code path
       forgets to delete before inserting, the second insert fails
       with `23505 unique_violation`.
    2. `create_shared_link/1` now uses `INSERT ... ON CONFLICT (user_id)
       DO UPDATE` (Ecto's `Repo.insert(on_conflict: ...)`), which is
       a single atomic statement and doesn't depend on row-lock
       acquisition.

  Backfill: any pre-existing duplicate rows would block the index
  creation. The migration deletes all-but-newest per user first —
  keeping the row with the most recent `inserted_at` (and within
  ties, the larger `id` UUID). The newest row is what
  `get_shared_link/1` would surface anyway.
  """

  def up do
    # `inserted_at` tiebreaker + `id` is a `binary_id` UUID whose
    # text ordering is lexicographic on the UUID bytes. For UUIDs the
    # lex order isn't a temporal order — but the (rare) collision
    # case (`a.inserted_at = b.inserted_at`) leaves us picking one
    # arbitrarily; the dashboard only ever reads the row via
    # `get_shared_link/1`, which (post-fix) orders by `inserted_at`
    # desc + `id` desc, so the chosen row stays stable.
    execute("""
    DELETE FROM shared_links a
    USING shared_links b
    WHERE a.user_id = b.user_id
      AND (a.inserted_at, a.id) < (b.inserted_at, b.id)
    """)

    create unique_index(:shared_links, [:user_id])
  end

  def down do
    drop unique_index(:shared_links, [:user_id])
  end
end
