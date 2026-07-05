# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

alias DtuApp.Repo
alias DtuApp.Accounts.User
alias DtuApp.Devices

# Clean up existing data to prevent conflict when reseeding
Repo.delete_all(DtuApp.Devices.Dtu)
Repo.delete_all(User)

# Register example user
{:ok, user} =
  %User{}
  |> User.email_changeset(%{email: "test@example.com"})
  |> User.password_changeset(%{password: "password123456"})
  |> User.confirm_changeset()
  |> Repo.insert()

IO.puts("Created user: #{user.email}")

# Register example DTUs
{:ok, dtu1} =
  Devices.create_device(user, %{
    name: "Roof Inverter",
    kind: "opendtu",
    mqtt_username: "roof-inverter",
    mqtt_password: "mypassword",
    base_topic: "solar"
  })

IO.puts("Created DTU: #{dtu1.name} (OpenDTU)")

{:ok, dtu2} =
  Devices.create_device(user, %{
    name: "Balcony Inverter",
    kind: "ahoydtu",
    mqtt_username: "balcony-inverter",
    mqtt_password: "mypassword",
    base_topic: "inverter"
  })

IO.puts("Created DTU: #{dtu2.name} (AhoyDTU)")
