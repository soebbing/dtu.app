defmodule DtuApp.Repo.Migrations.AddChannelToNotifications do
  use Ecto.Migration

  @moduledoc """
  Adds a `channel` column to `notifications` so the history page
  can show which delivery path a row represents ("this notification
  was sent as email" vs "as push").

  Defaults to `"push"` so the historical rows written before this
  migration report a channel that matches what was actually
  delivered — `Notifications.broadcast/2` (before the dispatcher
  refactor) only invoked the push path.
  """

  def change do
    alter table(:notifications) do
      add :channel, :string, default: "push", null: false
    end
  end
end
