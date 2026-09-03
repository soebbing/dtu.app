defmodule DtuApp.Repo.Migrations.AddNotifyYieldAnomalyToUsers do
  @moduledoc """
  Adds the `notify_yield_anomaly` boolean to `users`.

  The fourth optional notification. Fires when the user's fleet
  output drops sharply *during the sun-up window* (between
  local sunrise and sunset) and stays collapsed for longer than
  `YieldAnomaly.collapse_seconds` — i.e. the "panels stopped
  producing mid-day without a sunset to explain it" case the
  existing three producers (`sun_up`, `sun_down`,
  `dtu_connection`) cannot catch by design.

  Default `false` so users who shipped before this producer
  existed don't silently start receiving a new notification on
  deploy. Mirrors the gating pattern that `notify_sun_up` and
  `notify_dtu_connection` use; both also defaulted to `false` on
  their own migrations.

  Read by:
    * `DtuApp.Notifications.YieldAnomaly` — the server-side
      producer (checks `User.notify_yield_anomaly` before doing
      any visible work).
    * `DtuApp.Push.native_enabled?/2` — the per-event
      preference gate inside the dispatcher; the new branch in
      that function must be added in lockstep.
    * `DtuAppWeb.NotificationsLive` — the settings-page
      checkbox that flips this flag.
  """

  use Ecto.Migration

  def change do
    alter table(:users) do
      add :notify_yield_anomaly, :boolean, default: false, null: false
    end
  end
end
