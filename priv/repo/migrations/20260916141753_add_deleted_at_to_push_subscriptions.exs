defmodule DtuApp.Repo.Migrations.AddDeletedAtToPushSubscriptions do
  @moduledoc """
  Adds a soft-delete column to `push_subscriptions` so the dispatcher
  can prune a `:gone` endpoint while still leaving enough server-side
  state for the capability card to detect "your browser cleared its
  push subscription" and prompt the user to re-subscribe.

  Before this column existed, `DtuApp.PushSubscriptions.delete_by_endpoint/1`
  was a hard `DELETE` — the row vanished, the dispatcher never tried
  the endpoint again, and the next mount of the Notifications page
  had no way to tell the user "your push was working yesterday and
  isn't today". Users with cleared site data or a reinstalled PWA
  silently lost banners until they manually re-enabled notifications
  in `/notifications`.

  Why soft-delete (instead of an audit table or a sticky cookie)?

    * The dispatcher is the only writer (`DtuApp.Push.send_to/2`,
      called from `deliver_many/2`) — one writer, one column.
    * A partial index keyed on `user_id` keeps the
      "recently revoked for this user" query cheap even as the
      soft-deleted tail grows.
    * No new table = no migration churn for the existing FK /
      unique-index / list-for-user code paths. The only call sites
      that need to know about soft-deletion are `list_for_user/1`
      (filter) and `delete_by_endpoint/1` (mark instead of delete).

  The column is intentionally nullable rather than `DEFAULT now()` —
  active rows have `deleted_at = NULL`. A future periodic prune task
  can hard-delete rows where `deleted_at < now() - INTERVAL '30
  days'`; for now the table is bounded (a user only gets a handful
  of rows over a device lifetime) and the partial index keeps the
  hot query path cheap.
  """

  use Ecto.Migration

  def change do
    alter table(:push_subscriptions) do
      add :deleted_at, :utc_datetime
    end

    # Partial index on soft-deleted rows only — supports the
    # `revoked_within_days?/2` query which filters by `user_id` and
    # `deleted_at > now() - interval`. Active rows (the dispatcher's
    # hot path) don't need to be in this index.
    create index(:push_subscriptions, [:user_id, :deleted_at],
             where: "deleted_at IS NOT NULL",
             name: :push_subscriptions_revoked_user_id_deleted_at_index
           )
  end
end
