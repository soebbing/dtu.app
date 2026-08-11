defmodule DtuApp.Repo.Migrations.CreateDtuErrors do
  @moduledoc """
  Add a `dtu_errors` table to persist MQTT-side error history per DTU.

  The previous MR (#86) added two columns on `dtus` — `last_error` and
  `last_error_at` — that carried the *single most recent* error. That was
  enough for the bubble UI but limited: it didn't expose how many distinct
  errors a device had, when each one last fired, or how often it recurred.

  This table fixes all three:

  * `dtu_errors.dtu_id`     — FK back to the owning DTU
  * `dtu_errors.message`    — the user-visible error string (e.g.
                              "Shelly topic mismatch (expected …)")
  * `dtu_errors.inserted_at` — `:utc_datetime_usec` so it lines up with
                              `readings.inserted_at` and `dtus.last_seen_at`

  No new column on `dtus`. The existing `dtus.last_error` /
  `dtus.last_error_at` columns stay as a denormalised cache of the most
  recent row, written by `DtuApp.Devices.record_dtu_error/2` inside the
  same transaction that inserts into `dtu_errors`. The dashboard's
  refresh path stays O(1) — no per-card group-by query.

  Backfill: any pre-existing `last_error` values are inserted as the
  initial history row, so the manage-device expansion panel and the
  dashboard's distinct-error counter are correct from the moment this
  migration runs (rather than only counting errors that arrived
  post-deploy).

  The `on_delete: :delete_all` FK cascades the row deletion when the
  owning `dtu` is removed — matches the existing `users` -> `dtus`
  cascade behaviour elsewhere in the schema.

  Reversible `down/0` drops the table. The `dtus.last_error` /
  `dtus.last_error_at` columns stay (they're preserved by an earlier
  migration, not this one).
  """

  use Ecto.Migration

  def up do
    create table(:dtu_errors, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :dtu_id, references(:dtus, on_delete: :delete_all), null: false
      add :message, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    # Hot path for "give me the error history for one device" — the
    # dashboard's per-device count and the manage-device expansion
    # panel both filter by `dtu_id` and order by `inserted_at`.
    create index(:dtu_errors, [:dtu_id, desc: :inserted_at])

    # Distinct-message rollup: every panel that says "X distinct
    # errors" runs `GROUP BY message WHERE dtu_id = $1`. An index on
    # `(dtu_id, message)` lets that aggregation use an index-only
    # scan instead of a sequential one.
    create index(:dtu_errors, [:dtu_id, :message])

    # Backfill: every device that already has a `last_error` written
    # by the previous MR (#86) gets one matching `dtu_errors` row so
    # the new UI surfaces it. Empty / nil `last_error` devices stay
    # empty in the history table (the dashboard's edge badge stays
    # absent for them).
    execute("""
    INSERT INTO dtu_errors (dtu_id, message, inserted_at)
    SELECT id, last_error, last_error_at
    FROM dtus
    WHERE last_error IS NOT NULL
      AND last_error_at IS NOT NULL
    """)
  end

  def down do
    drop table(:dtu_errors)
  end
end
