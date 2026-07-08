defmodule DtuApp.Devices.Reading do
  use Ecto.Schema
  import Ecto.Changeset

  # `readings` is a TimescaleDB hypertable with a composite primary key
  # (dtu_id, inverter_serial, inserted_at) — no serial `id`.
  @primary_key false
  schema "readings" do
    field :inverter_serial, :string, primary_key: true
    field :ac_power, :float
    field :dc_power, :float
    field :yield_day, :float
    field :yield_total, :float
    field :frequency, :float
    field :temperature, :float
    field :producing, :boolean
    field :reachable, :boolean

    field :inserted_at, :utc_datetime, primary_key: true

    belongs_to :dtu, DtuApp.Devices.Dtu, define_field: false
    field :dtu_id, :id, primary_key: true
  end

  @doc false
  def changeset(reading, attrs) do
    reading
    |> cast(attrs, [
      :inverter_serial,
      :ac_power,
      :dc_power,
      :yield_day,
      :yield_total,
      :frequency,
      :temperature,
      :producing,
      :reachable,
      :dtu_id,
      :inserted_at
    ])
    |> validate_required([:inverter_serial, :dtu_id])
    # `readings` has no auto-managed timestamps; default the hypertable time
    # column to "now" when the caller didn't supply one.
    |> maybe_default_inserted_at()
  end

  defp maybe_default_inserted_at(changeset) do
    case get_field(changeset, :inserted_at) do
      nil -> put_change(changeset, :inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))
      _ -> changeset
    end
  end
end
