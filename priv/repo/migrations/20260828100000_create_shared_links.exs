defmodule DtuApp.Repo.Migrations.CreateSharedLinks do
  use Ecto.Migration

  @moduledoc """
  Anonymous, revocable share-link for the current-day dashboard view.

  One row per user. When the user toggles the "Share" switch on the
  authenticated dashboard, we generate a 32-byte random token, hand the
  plaintext to the UI (the user copies the URL), and persist only the
  SHA-256 hash. The hash is what the public `/s/:token` route resolves
  against — a leaked DB backup cannot replay share URLs because the
  raw tokens were never stored.

  Privacy design:
    * No `device_id` / `dtu_id` column — the share is always the
      "Total (all DTUs)" view, so there's no per-device exposure.
    * No `user_id`-derived data in the URL — the URL is opaque.
    * Deleted together with the user (`on_delete: :delete_all`).

  Expiry: intentionally not modelled. Per the feature design, the
  link works until the user toggles sharing off. If a future design
  adds TTL, add an `expires_at` column and an index on it then.
  """

  def change do
    # `primary_key: false` because we set the id column explicitly
    # below as a `:binary_id` (UUID). Without this, Ecto's
    # `create table/2` defaults to a `bigint` primary key — and the
    # `SharedLink` schema's `@primary_key {:id, :binary_id,
    # autogenerate: true}` then mismatches at INSERT time (Postgrex
    # sends a UUID for a `bigint` column). Using a UUID for the row
    # ID keeps it opaque in any accidental log line.
    create table(:shared_links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # SHA-256 hash of the URL token, 32 bytes binary. Unique so the
      # lookup is a single btree hit. We don't index on `user_id` —
      # the per-user query is "does this user have an active share?"
      # and is rare enough to scan; a single-row lookup by token is
      # the hot path and is covered by the unique index.
      add :token_hash, :binary, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:shared_links, [:token_hash])
  end
end
