defmodule DtuApp.Devices.Reading do
  use Ecto.Schema
  import Ecto.Changeset

  schema "readings" do
    field :inverter_serial, :string
    field :ac_power, :float
    field :dc_power, :float
    field :yield_day, :float
    field :yield_total, :float
    field :frequency, :float
    field :temperature, :float
    field :producing, :boolean
    field :reachable, :boolean

    belongs_to :dtu, DtuApp.Devices.Dtu

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(reading, attrs) do
    reading
    |> cast(attrs, [:inverter_serial, :ac_power, :dc_power, :yield_day, :yield_total, :frequency, :temperature, :producing, :reachable, :dtu_id])
    |> validate_required([:inverter_serial, :dtu_id])
  end
end
