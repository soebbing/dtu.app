defmodule DtuApp.Accounts.SharedLink do
  @moduledoc """
  Anonymous share-link for a user's current-day dashboard.

  Backs the "Share" toggle on the authenticated dashboard toolbar.
  When the user flips the toggle on, we mint a fresh
  32-byte cryptographically random URL token, hand the plaintext to
  the UI exactly once (the LiveView surfaces it for copy-to-clipboard),
  and persist only its SHA-256 hash. The public `/s/:token` route
  hashes the inbound token and looks it up here.

  Privacy properties:

    * The URL contains no user id, no device id, no email — just the
      43-char base32 token. A person with the URL can view the share;
      anyone without it cannot enumerate or guess (256-bit space).
    * Token plaintext is never written to disk — only the SHA-256 hash
      lands in the DB. A leaked DB backup cannot replay URLs.
    * `on_delete: :delete_all` from `users` cascades so a deleted user
      immediately invalidates all outstanding share URLs.
    * One row per user — toggling on while a previous share exists
      deletes the old row first.

  Lifetime: no expiry. The share lives until the user toggles it off,
  deletes their account, or the row is otherwise removed.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias DtuApp.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  # `binary_id` so the row ID is a UUID — keeps IDs opaque in any
  # accidental log line. Not used in the URL (the token is).

  schema "shared_links" do
    belongs_to :user, User

    # SHA-256 of the plaintext URL token, exactly 32 bytes.
    field :token_hash, :binary

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(shared_link, attrs) do
    shared_link
    |> cast(attrs, [:user_id, :token_hash])
    |> validate_required([:user_id, :token_hash])
    |> validate_length(:token_hash, is: 32)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:token_hash)
    # Matches `unique_index(:shared_links, [:user_id])` (added in
    # 20260902130000_unique_index_shared_links_user_id). Ecto uses
    # this to translate Postgres `23505 unique_violation` on the
    # `user_id` column into a changeset error rather than a raw
    # raise, so the caller sees a useful `:unique_user_id` key in
    # `changeset.errors`.
    |> unique_constraint(:user_id)
  end

  @doc """
  Generate a fresh URL-safe token and its SHA-256 hash.

  The plaintext is meant for the user to copy out of the dashboard
  UI exactly once; the hash is what the public route stores and
  looks up. 32 random bytes gives a 256-bit search space; we
  base32-encode without padding so the URL stays clean.

  Returns `{plaintext_token, hashed_token}`.
  """
  @spec generate() :: {String.t(), binary()}
  def generate do
    raw = :crypto.strong_rand_bytes(32)
    plaintext = Base.encode32(raw, padding: false)
    hashed = :crypto.hash(:sha256, plaintext)
    {plaintext, hashed}
  end

  @doc """
  Hash an inbound plaintext token the same way `generate/0` does.
  Used by the public `/s/:token` route to look up the matching row.
  """
  @spec hash(String.t()) :: binary()
  def hash(plaintext) when is_binary(plaintext) do
    :crypto.hash(:sha256, plaintext)
  end
end
