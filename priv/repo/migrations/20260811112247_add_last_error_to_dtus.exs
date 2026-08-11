defmodule DtuApp.Repo.Migrations.AddLastErrorToDtus do
  @moduledoc """
  Add `last_error` / `last_error_at` columns to `dtus`.

  The MQTT telemetry pipeline can hit several classes of bad input from a
  real-world DTU (malformed JSON, unknown topic, base-topic mismatch on a
  Shelly, DB-side validation failures on a reading row, …). Today they're
  all logged but never surfaced — a device that has been silently failing
  to publish for hours looks identical to one that's happy.

  These two columns carry the *most recent* error for each device so the
  dashboard and the device-list LiveView can show it as a bubble / fill.
  See `DtuApp.MqttBroker.Telemetry.record_dtu_error/2` for the writer and
  the LiveView changes that read it.

  Reversible: `down/0` drops both columns. Existing rows get NULLs — the
  conditional render in the LiveViews is invisible until something writes,
  so the migration itself is non-disruptive.
  """

  use Ecto.Migration

  def change do
    alter table(:dtus) do
      add :last_error, :text
      add :last_error_at, :utc_datetime_usec
    end
  end
end
