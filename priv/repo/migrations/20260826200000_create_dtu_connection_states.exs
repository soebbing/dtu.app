defmodule DtuApp.Repo.Migrations.CreateDtuConnectionStates do
  @moduledoc """
  Persistent per-device connection-marker table for the
  `dtu_connection` notification producer.

  The producer (`DtuApp.Notifications.DtuConnection`) used to hold
  the per-device connection state entirely in the GenServer's
  in-memory cache:
    `%{device_id => %{user_id, name, last_seen_at, disconnected?}}`
  Any restart of the GenServer (deploy, crash, application
  restart) wiped the cache and let the very next `:dtu_connected`
  event for a device that was already on the broker at boot fire
  `:back_online` — a duplicate "your inverter is publishing
  telemetry again" push.

  Storage model:
    * Primary key on `device_id` — one row per device (FK to
      `dtus`, `on_delete: :delete_all`). A device that's deleted
      leaves no orphan row behind.
    * `disconnected` (boolean, default false) — the producer's
      persistent "we saw this device go offline" marker. The
      connect path consults this before firing `:back_online`.
    * `last_seen_at` (`:utc_datetime_usec`) — the timestamp the
      recency guards compare against. Matches the precision on
      `dtus.last_seen_at` so the producer's arithmetic doesn't
      need a cast.
    * `connected_at` (`:utc_datetime`) — the wall-clock UTC
      instant the producer last saw a CONNECT. Read by the
      disconnect-side C1 gate to compute "device was online for
      >= @recency_seconds". Second-precision is sufficient.
    * `inserted_at` / `updated_at` carry the DB clock for
      debugging ("when did the producer last see this device?")
      without joining to `dtus` / `notifications`.

  Why a separate table instead of reusing `notifications`?
    * The producer needs the *current* marker, not a history.
      `notifications` is the user-visible history surface (paginated,
      user-deletable) — clearing history shouldn't reset the
      connection gate.
    * The producer writes the marker on every CONNECT / DISCONNECT
      the broker observes; that's a hot path. A history-style
      append-only log would inflate quickly and force us to keep
      pruning.
    * The marker is per-device (not per-user), so it doesn't fit
      the `notifications` shape (per-user, one event at a time).

  A unique constraint on `device_id` is enforced by the primary
  key itself — `device_id` is the only column with a
  single-column index.
  """

  use Ecto.Migration

  def change do
    create table(:dtu_connection_states, primary_key: false) do
      add :device_id, references(:dtus, on_delete: :delete_all),
        null: false, primary_key: true

      add :disconnected, :boolean, null: false, default: false

      # `:utc_datetime_usec` to match `dtus.last_seen_at`. The C1 /
      # recency guards compare against `Time.utc_now_usec/0`, which
      # already carries 6-digit microsecond precision.
      add :last_seen_at, :utc_datetime_usec

      # `:utc_datetime` is enough — the C1 gate compares against a
      # 5-minute threshold, where microsecond precision is
      # immaterial.
      add :connected_at, :utc_datetime

      timestamps(type: :utc_datetime_usec)
    end
  end
end