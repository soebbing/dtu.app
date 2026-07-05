defmodule DtuApp.Repo.Migrations.CreateDtus do
  use Ecto.Migration

  def change do
    create table(:dtus) do
      add :name, :string, null: false
      # Ecto.Enum stores the value as a string.
      add :kind, :string, null: false
      add :mqtt_username, :string, null: false
      add :mqtt_password_hash, :string, null: false
      add :base_topic, :string, null: false, default: "solar"
      add :online, :boolean, null: false, default: false
      add :last_seen_at, :utc_datetime_usec

      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    # Globally unique: the broker resolves a connection to one device by username.
    create unique_index(:dtus, [:mqtt_username], name: :dtus_mqtt_username_index)
    # A user's device names are unique.
    create unique_index(:dtus, [:user_id, :name], name: :dtus_user_id_name_index)
    # Hot path for listing a user's devices.
    create index(:dtus, [:user_id])
  end
end
