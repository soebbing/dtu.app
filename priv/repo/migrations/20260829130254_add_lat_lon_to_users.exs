defmodule DtuApp.Repo.Migrations.AddLatLonToUsers do
  use Ecto.Migration

  # `latitude` / `longitude` — the user's geographic position, captured
  # by the dashboard's colocated JS hook via
  # `navigator.geolocation.getCurrentPosition(...)` and persisted via
  # `DtuApp.Accounts.update_user_location/2`. The dashboard uses them
  # to compute astronomical sunrise / sunset on the chart's X axis
  # (NOAA algorithm in `DtuApp.SunCalc`).
  #
  # Nullable on purpose: existing users have no captured location,
  # and the chart shows nothing (rather than an "unknown" marker)
  # when either column is nil. The next time such a user loads the
  # dashboard with browser geolocation permission granted, the JS
  # hook pushes fresh coords and the columns populate.
  #
  # Stored as `:decimal` with precision 9 / scale 6 so we can capture
  # any latitude (max 6 decimals ≈ 11 cm at the equator, well below
  # the 1m resolution that browser geolocation APIs typically report
  # anyway) without rounding. Float drift is unacceptable because the
  # sunrise/sunset calculation is sensitive in the third decimal of
  # the latitude (a 0.001° shift ≈ 111 m north-south → tens of seconds
  # of sun-time near the solstice).
  def change do
    alter table(:users) do
      add :latitude, :decimal, precision: 9, scale: 6, null: true
      add :longitude, :decimal, precision: 9, scale: 6, null: true
    end
  end
end
