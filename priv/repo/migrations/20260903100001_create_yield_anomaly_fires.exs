defmodule DtuApp.Repo.Migrations.CreateYieldAnomalyFires do
  @moduledoc """
  Persistent dedup table for the `yield_anomaly` notification
  producer (`DtuApp.Notifications.YieldAnomaly`).

  Storage model mirrors `sun_up_fires` /
  `sun_down_fires` exactly:
    * Composite primary key `(user_id, fired_on)` — at most one
      row per user per UTC date.
    * `fired_on` is the producer's view of the user's local date
      (computed from `user.tz_offset_seconds` at fire time).
      `:date` (no time component) keeps the SQL simple.
    * `inserted_at` carries the wall-clock UTC instant for
      audit / debug — DB clock via `DEFAULT now()` so the
      producer doesn't need to read it back.
    * Foreign key to `users` with `on_delete: :delete_all` so a
      deleted user doesn't leave orphan dedup rows behind.

  Why a separate table instead of reusing `notifications`?
    * `notifications` is the history surface (UI, paginated,
      user-deletable). A user clearing their history shouldn't
      qualify them for a second same-day `yield_anomaly`.
    * `notifications` is paginated and may eventually be
      window-bounded; dedup needs unbounded retention per
      (user_id, fired_on) pair.
    * Keeping the dedup surface separate makes the producer's
      behaviour easier to read — `fired_on_date` cache becomes
      a single-row lookup, no joins.
  """

  use Ecto.Migration

  def change do
    create table(:yield_anomaly_fires, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :fired_on, :date, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("now()")
    end

    # Composite PK — at most one row per (user, local-date).
    # Migration-level constraint name matches the Ecto schema
    # in `DtuApp.Notifications.YieldAnomalyFire`, which declares
    # both fields as `primary_key: true`. Ecto derives the
    # constraint name as `<table>_pkey` for composite keys.
    execute(
      "ALTER TABLE yield_anomaly_fires ADD CONSTRAINT yield_anomaly_fires_pkey PRIMARY KEY (user_id, fired_on)"
    )
  end
end
