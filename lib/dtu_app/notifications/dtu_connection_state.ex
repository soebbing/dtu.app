defmodule DtuApp.Notifications.DtuConnectionState do
  @moduledoc """
  Schema for the `dtu_connection_states` per-device marker table.

  Each row records the producer's persistent view of a single
  device's connection state — `disconnected` flag,
  `last_seen_at`, and `connected_at` — so the producer can resume
  the gate logic after a restart without re-firing on every
  previously-known disconnect.

  Before this table, the producer (`DtuApp.Notifications.DtuConnection`)
  held this state entirely in memory:
  `%{device_id => %{user_id, name, last_seen_at, disconnected?}}`.
  A restart wiped the cache and let the very next `:dtu_connected`
  / `:dtu_disconnected` event pass through as if it were a fresh
  state — producing duplicate "back online" notifications for
  devices that were already on the broker at server boot.

  Why a single composite per-device row instead of a per-event log?
    * The producer only ever needs the *current* marker
      (`disconnected`, `last_seen_at`, `connected_at`). Anything
      older is irrelevant — once a row is updated, the prior
      state is gone.
    * A log would let us replay the history, but the producer
      never does that. The whole point of the marker is
      "remember the last thing we saw."
    * A single row per device keeps the table bounded by the
      user's device count — same envelope as the in-memory cache
      we're replacing.

  `connected_at` is read by the disconnect-side C1 gate (the
  "device must have been online for >= @recency_seconds" check);
  `last_seen_at` is read by both the disconnect-side recency guard
  and the connect-side recency guard. `disconnected` is the
  primary "did we see a disconnect for this device" marker that
  the connect path consults before firing `:back_online`.

  Storage model:
    * `device_id` as the primary key — one row per device (FK to
      `dtus`, `on_delete: :delete_all`). A device that's deleted
      leaves no orphan row behind.
    * `inserted_at` carries the DB clock for the first-seen
      timestamp; `updated_at` (via Ecto's standard
      `timestamps()` macro) carries the last marker update.
      Useful for debugging stale markers ("when did the producer
      last see this device?") without joining to `dtus` /
      `notifications`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  schema "dtu_connection_states" do
    # Device this row tracks. Foreign key + on_delete cascade lives
    # in the migration; here we just declare the column.
    belongs_to :device, DtuApp.Devices.Dtu, foreign_key: :device_id, primary_key: true

    field :disconnected, :boolean, default: false
    # `:utc_datetime_usec` for `last_seen_at` to match the
    # `Dtu.last_seen_at` column the producer reads on the
    # disconnect side. The C1 / recency guards compare against
    # `Time.utc_now_usec/0`, which already carries 6-digit
    # microsecond precision.
    field :last_seen_at, :utc_datetime_usec
    # Wall-clock UTC instant the device was last seen as
    # connected. Read by the disconnect-side C1 gate to compute
    # "device was online for >= @recency_seconds". `:second`
    # precision is enough — the C1 gate compares against a
    # 5-minute threshold.
    field :connected_at, :utc_datetime

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Build a changeset from `attrs`. All fields are user-supplied
  except `inserted_at` / `updated_at`, which Ecto's
  `timestamps()` macro fills from the DB clock.
  """
  def changeset(%__MODULE__{} = row, attrs) do
    row
    |> cast(attrs, [:device_id, :disconnected, :last_seen_at, :connected_at])
    |> validate_required([:device_id])
    |> foreign_key_constraint(:device_id)
  end
end
