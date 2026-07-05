defmodule DtuApp.Repo.Migrations.CreateReadings do
  use Ecto.Migration

  def change do
    create table(:readings) do
      add :inverter_serial, :string, null: false
      add :ac_power, :float
      add :dc_power, :float
      add :yield_day, :float
      add :yield_total, :float
      add :frequency, :float
      add :temperature, :float
      add :producing, :boolean
      add :reachable, :boolean
      add :dtu_id, references(:dtus, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:readings, [:dtu_id, :inserted_at])
    create index(:readings, [:inverter_serial])
  end
end
