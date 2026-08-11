defmodule DtuApp.Devices.DtuError do
  @moduledoc """
  One row per MQTT-side error recorded against a DTU.

  The MQTT telemetry pipeline (`DtuApp.MqttBroker.Telemetry`) inserts a row
  here every time the parser rejects an uplink or a `readings` insert
  fails. The dashboard's edge badge reads the *distinct* message count
  per device (`DtuApp.Devices.count_distinct_dtu_errors/2`), and the
  manage-device page's deep-link expansion panel reads the per-message
  rollup (`DtuApp.Devices.list_dtu_error_groups/2`).

  The composite timeline — every event, ever — isn't read by the UI
  directly; the manage-device panel surfaces "X occurrences · last seen
  Y" per distinct message, which is enough to triage without paging
  through hundreds of identical events.

  ## Pruning

  `DtuApp.Devices.record_dtu_error/2` keeps each device's history bounded
  by `DtuApp.Devices.dtu_error_history_cap/0` (200 rows). Older rows are
  pruned on insert so the table stays small without a separate sweep
  job. A cap-based prune (rather than TTL) is deliberate: a DTU that's
  been misbehaving for a month should still have its oldest error
  visible — the user's *first* encounter with the issue is the most
  diagnostic one, and a TTL would erase it.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "dtu_errors" do
    field :message, :string

    field :inserted_at, :utc_datetime_usec

    belongs_to :dtu, DtuApp.Devices.Dtu, define_field: false
    field :dtu_id, :id
  end

  @doc false
  def changeset(error, attrs) do
    error
    |> Ecto.Changeset.cast(attrs, [:dtu_id, :message])
    |> Ecto.Changeset.validate_required([:dtu_id, :message])
    # The `:utc_datetime_usec` schema type isn't auto-managed by
    # Ecto. The migration's `DEFAULT now()` covers direct inserts, but
    # Ecto-driven inserts from `record_dtu_error/2` use the DB clock
    # via `DtuApp.Time.utc_now_usec/0` so the value lines up exactly
    # with `dtus.last_seen_at` and `readings.inserted_at`.
    |> Ecto.Changeset.put_change(:inserted_at, DtuApp.Time.utc_now_usec())
  end
end
