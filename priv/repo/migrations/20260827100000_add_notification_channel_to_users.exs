defmodule DtuApp.Repo.Migrations.AddNotificationChannelToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :notification_channel, :string, default: "push", null: false
    end

    # We don't index — `users` is small (single-tenant per install),
    # and the column isn't a lookup key. If a future feature selects
    # "all users on channel :email" add it then.
  end
end