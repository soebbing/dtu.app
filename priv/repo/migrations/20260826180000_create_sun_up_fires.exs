defmodule DtuApp.Repo.Migrations.CreateSunUpFires do
  @moduledoc """
  Persistent dedup table for the `sun_up` notification producer.

  The producer (`DtuApp.Notifications.SunUp`) is supposed to fire
  at most once per user per local day. Before this migration, the
  dedup cache was held entirely in the GenServer's in-memory state —
  `state.users[user_id].fired_on_date` — which meant any restart of
  the GenServer (deploy, crash, application restart) wiped the cache
  and let the next production reading fire `sun_up` again, producing
  a duplicate push to the user.

  Storage model:
    * Composite primary key `(user_id, fired_on)` — at most one row
      per user per UTC date.
    * `fired_on` is the producer's view of the user's local date
      (computed from `user.tz_offset_seconds` at fire time).
      Stored as `:date` (no time component) so the producer can
      query it as `WHERE user_id = ? AND fired_on = ?` against a
      plain date literal without timezone gymnastics in SQL.
    * `inserted_at` carries the wall-clock UTC instant for audit /
      debug ("did this fire today? what wall-clock time?").
    * Foreign key to `users` with `on_delete: :delete_all` so a
      deleted user doesn't leave orphan dedup rows behind.

  Why a separate table instead of reusing `notifications`?
    * `notifications` is the history surface (UI, paginated,
      user-deletable). A user clearing their history shouldn't
      make them eligible for a second same-day `sun_up`.
    * `notifications` is paginated and may eventually be
      window-bounded; dedup needs unbounded retention per
      (user_id, fired_on) pair.
    * Keeping the dedup surface separate makes the producer's
      behaviour easier to read — `fired_on_date` cache becomes a
      single-row lookup, no joins.
  """

  use Ecto.Migration

  def change do
    create table(:sun_up_fires, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :fired_on, :date, null: false
      # Wall-clock UTC instant the producer fired. Useful for
      # debugging duplicate-fire reports without joining to
      # `notifications.delivered_at`. DB clock via `DEFAULT now()`
      # so the producer doesn't have to read it back.
      add :inserted_at, :utc_datetime_usec, null: false,
        default: fragment("now()")
    end

    # Composite primary key — at most one row per (user, local-date).
    # Migration-level constraint name matches what the Ecto schema
    # (`DtuApp.Notifications.SunUpFire`) declares via
    # `primary_key: true` on each field — Ecto derives the PK name
    # as `<table>_pkey` for composite keys.
    execute(
      "ALTER TABLE sun_up_fires ADD CONSTRAINT sun_up_fires_pkey PRIMARY KEY (user_id, fired_on)"
    )
  end
end
