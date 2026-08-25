defmodule DtuApp.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  @moduledoc """
  Per-user notification history.

  Every time `DtuApp.Notifications.broadcast/2` fires (sun-up,
  sun-down, dtu_connection, and the synthetic `test` event from
  the test button), the user's already-localized title/body is
  persisted here so the `/notifications` page can show a paginated
  history of what the server actually sent.

  Why store the localized text and not just the msgid?
    * The user's locale can change over time — if we stored the
      msgid and re-rendered on read, the history would flip
      languages under the user. The text in the row is what they
      actually saw.
    * The payload field keeps the raw shape (event/title/body/tag)
      for any future drill-down UI without needing a schema change.

  Retention: indefinite (matches the "store everything" product
  decision). Users can prune via the per-row delete button or the
  "Clear all" button on the page. No automatic TTL — the user is
  the only party who decides what stays.
  """

  def change do
    create table(:notifications) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :event, :text, null: false
      add :title, :text, null: false
      add :body, :text, null: false
      add :tag, :text
      # Full broadcast payload as jsonb so we don't have to migrate
      # the schema every time a new field shows up in a payload.
      add :payload, :map, null: false
      # When the broadcast actually happened — distinct from
      # `inserted_at` because the row is written inside broadcast/2
      # immediately after the PubSub fan-out, but `delivered_at`
      # is the user-visible timestamp on the history page.
      add :delivered_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    # The history page queries `WHERE user_id = ? ORDER BY
    # delivered_at DESC LIMIT 50 OFFSET N`. The composite index
    # supports both the equality filter and the sort without a
    # separate sort step.
    create index(:notifications, [:user_id, desc: :delivered_at])
  end
end
