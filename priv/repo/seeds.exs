# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

alias DtuApp.Repo
alias DtuApp.Accounts.User
alias DtuApp.Devices
alias DtuApp.Devices.Reading

# Clean up existing data to prevent conflict when reseeding
Repo.delete_all(Reading)
Repo.delete_all(Devices.Dtu)
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

# Seed today's readings for the Roof Inverter to populate the dashboard chart
today = Date.utc_today()
# 06:00
start_minute = 6 * 60
# 19:00
end_minute = 19 * 60
# 15 minutes
interval = 15

# Calculate sequence of minutes
minutes_sequence =
  Stream.iterate(start_minute, &(&1 + interval))
  |> Stream.take_while(&(&1 <= end_minute))

Enum.reduce(minutes_sequence, 0.0, fn minutes, acc_yield ->
  hour = div(minutes, 60)
  minute = rem(minutes, 60)

  # Sine profile matching solar arc (06:00 to 19:00 = 780 minutes span)
  t = (minutes - start_minute) / (end_minute - start_minute)
  sine_val = :math.sin(t * :math.pi())

  # Add slight random fluctuation (+/- 5%) to represent cloud passings
  fluctuation = 1.0 + (:rand.uniform() * 0.1 - 0.05)
  ac_power = Float.round(580.0 * sine_val * fluctuation, 1)

  # Accumulate today's yield in kWh (power * hours)
  new_yield = acc_yield + ac_power * (interval / 60.0) / 1000.0

  inserted_at =
    DateTime.new!(today, Time.new!(hour, minute, 0))
    |> DateTime.truncate(:second)

  Repo.insert!(%Reading{
    dtu_id: dtu1.id,
    inverter_serial: "116180123456",
    ac_power: ac_power,
    dc_power: Float.round(ac_power * 1.04, 1),
    yield_day: Float.round(new_yield, 3),
    yield_total: Float.round(1520.0 + new_yield, 3),
    frequency: 50.0,
    temperature: Float.round(25.0 + 15.0 * sine_val, 1),
    producing: ac_power > 2.0,
    reachable: true,
    inserted_at: inserted_at
  })

  new_yield
end)

IO.puts("Successfully seeded today's telemetry readings for #{dtu1.name}.")

# Helper to seed historical days
seed_historical_day = fn dtu_id, serial, date, base_yield_total, max_power_multiplier ->
  # 06:00
  start_minute = 6 * 60
  # 19:00
  end_minute = 19 * 60
  # 30 minutes for faster seeding
  interval = 30

  minutes_sequence =
    Stream.iterate(start_minute, &(&1 + interval))
    |> Stream.take_while(&(&1 <= end_minute))

  Enum.reduce(minutes_sequence, 0.0, fn minutes, acc_yield ->
    hour = div(minutes, 60)
    minute = rem(minutes, 60)

    t = (minutes - start_minute) / (end_minute - start_minute)
    sine_val = :math.sin(t * :math.pi())

    fluctuation = 1.0 + (:rand.uniform() * 0.1 - 0.05)
    ac_power = Float.round(580.0 * sine_val * fluctuation * max_power_multiplier, 1)

    new_yield = acc_yield + ac_power * (interval / 60.0) / 1000.0

    inserted_at =
      DateTime.new!(date, Time.new!(hour, minute, 0))
      |> DateTime.truncate(:second)

    Repo.insert!(%Reading{
      dtu_id: dtu_id,
      inverter_serial: serial,
      ac_power: ac_power,
      dc_power: Float.round(ac_power * 1.04, 1),
      yield_day: Float.round(new_yield, 3),
      yield_total: Float.round(base_yield_total + new_yield, 3),
      frequency: 50.0,
      temperature: Float.round(25.0 + 15.0 * sine_val, 1),
      producing: ac_power > 2.0,
      reachable: true,
      inserted_at: inserted_at
    })

    new_yield
  end)
end

# Seed some historical dates for dtu1
for day_offset <- [1, 2, 3, 4, 5, 6, 7, 10, 15, 30, 45, 90, 365, 380] do
  past_date = Date.add(today, -day_offset)
  # Vary weather multiplier slightly for diversity
  multiplier = 0.5 + :rand.uniform() * 0.5
  seed_historical_day.(dtu1.id, "116180123456", past_date, 1000.0 - day_offset * 10, multiplier)
end

# Seed some historical dates for dtu2 (Balcony) to verify multi-device and total selections work
for day_offset <- [1, 2, 5, 12, 32, 370] do
  past_date = Date.add(today, -day_offset)
  multiplier = 0.4 + :rand.uniform() * 0.4
  seed_historical_day.(dtu2.id, "223344556677", past_date, 200.0 - day_offset * 2, multiplier)
end

IO.puts("Successfully seeded historical telemetry readings for all DTUs.")
