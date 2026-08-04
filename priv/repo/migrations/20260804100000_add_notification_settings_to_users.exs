defmodule DtuApp.Repo.Migrations.AddNotificationSettingsToUsers do
  use Ecto.Migration

  # Two boolean switches, both default-false so existing users don't
  # silently start receiving notifications. The end-of-day firing
  # logic in `DtuApp.Notifications.SunDownScheduler` reads
  # `notify_sun_down`; the DTU connection state-change path reads
  # `notify_dtu_connection`. The user toggles them on the new
  # `/notifications` page.
  def change do
    alter table(:users) do
      add :notify_dtu_connection, :boolean, default: false, null: false
      add :notify_sun_down, :boolean, default: false, null: false
    end
  end
end
