defmodule DtuApp.Repo.Migrations.AddSunUpNotificationAndTzToUsers do
  use Ecto.Migration

  # `notify_sun_up` — third optional notification. Fires once per user
  # per local day when the fleet first transitions from 0 W to > 0 W
  # (i.e. the user's array has woken up for the day). Default false so
  # existing users don't silently start receiving a new notification on
  # deploy. Read by `DtuApp.Notifications.SunUp` (the server-side
  # producer) and the per-event gate in
  # `DtuApp.Notifications.broadcast/2`.
  #
  # `tz_offset_seconds` — the user's local UTC offset in seconds
  # (positive east of UTC; e.g. 7200 for CEST). Mirrors the
  # existing `user_tz_offset_seconds` assign on the dashboard
  # LiveView, which is currently ephemeral (sent by JS on every
  # page load); persisting it lets the server-side `SunUp`
  # producer do the same without a LV being attached. Updated on
  # dashboard mount — see
  # `DashboardLive.handle_info({:set_timezone, ...})`. Default 0
  # (UTC) so the producer's "today" check works for users who
  # have never opened the dashboard with TZ detection enabled.
  def change do
    alter table(:users) do
      add :notify_sun_up, :boolean, default: false, null: false
      add :tz_offset_seconds, :integer, default: 0, null: false
    end
  end
end
