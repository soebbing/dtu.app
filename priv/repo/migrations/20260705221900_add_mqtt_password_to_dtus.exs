defmodule DtuApp.Repo.Migrations.AddMqttPasswordToDtus do
  use Ecto.Migration

  def change do
    alter table(:dtus) do
      add :mqtt_password, :string
    end
  end
end
