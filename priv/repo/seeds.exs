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

  # Accumulate today's yield. `readings.yield_day` is in Wh (per OpenDTU /
  # AhoyDTU firmware), so write Wh directly here: power in Watts times
  # duration in hours gives Wh. `get_daily_stats/2` and
  # `list_range_yield_data/4` divide by 1000 before displaying.
  new_yield = acc_yield + ac_power * (interval / 60.0)

  # Force the microsecond field's precision to 6 — `DateTime.new!/2`
  # inherits `Time.new!(...){microsecond: {0, 0}}` precision 0, which
  # Ecto's `:utc_datetime_usec` cast rejects with "expects microsecond
  # precision, got: ~U[...00Z]" (truncate-without-rebuild preserves the
  # 0 precision).
  inserted_at =
    %{DateTime.new!(today, Time.new!(hour, minute, 0)) | microsecond: {0, 6}}

  Repo.insert!(%Reading{
    dtu_id: dtu1.id,
    inverter_serial: "116180123456",
    ac_power: ac_power,
    dc_power: Float.round(ac_power * 1.04, 1),
    yield_day: Float.round(new_yield, 3),
    yield_total: Float.round(1_520_000.0 + new_yield, 3),
    frequency: 50.0,
    temperature: Float.round(25.0 + 15.0 * sine_val, 1),
    producing: ac_power > 2.0,
    reachable: true,
    inserted_at: inserted_at
  })

  new_yield
end)

IO.puts("Successfully seeded today's telemetry readings for #{dtu1.name}.")

# Seed today's readings for a second DTU that polls multiple inverters,
# each with its own per-MPPT DC strings. Used by the dashboard's
# per-inverter / per-MPPT chart breakdown and the e2e tests covering the
# bug where the chart legend showed every series but the per-MPPT lines
# were drawn flat at the X-axis (because the bucketing read
# `ac_power || 0.0` even though per-MPPT rows only carry `dc_power`).
{:ok, dtu3} =
  Devices.create_device(user, %{
    name: "Garage Array",
    kind: "opendtu",
    mqtt_username: "garage-array",
    mqtt_password: "mypassword",
    base_topic: "solar"
  })

IO.puts("Created DTU: #{dtu3.name} (OpenDTU, multi-inverter + multi-MPPT)")

# Two inverters; inverter-1 has two MPPT strings, inverter-2 has one.
# Each 5-min bucket gets one AC row (mppt_index=0) per inverter plus
# one DC row (mppt_index=1 or 2) per string — same sine profile for
# visibility, slightly different magnitudes so the lines actually
# split apart in the chart.
seed_multi_mppt_today = fn ->
  minutes_sequence =
    Stream.iterate(start_minute, &(&1 + interval))
    |> Stream.take_while(&(&1 <= end_minute))

  Enum.reduce(minutes_sequence, %{}, fn minutes, acc ->
    hour = div(minutes, 60)
    minute = rem(minutes, 60)

    t = (minutes - start_minute) / (end_minute - start_minute)
    sine_val = :math.sin(t * :math.pi())
    fluctuation = 1.0 + (:rand.uniform() * 0.1 - 0.05)

    # Inverter 1: AC row with both ac_power and dc_power totals.
    inverter_1_ac = Float.round(580.0 * sine_val * fluctuation, 1)

    inserted_at =
      %{DateTime.new!(today, Time.new!(hour, minute, 0)) | microsecond: {0, 6}}

    Repo.insert!(%Reading{
      dtu_id: dtu3.id,
      inverter_serial: "116180000001",
      inverter_name: "West Roof",
      mppt_index: 0,
      ac_power: inverter_1_ac,
      dc_power: Float.round(inverter_1_ac * 1.04, 1),
      yield_day: 0.0,
      yield_total: 0.0,
      frequency: 50.0,
      temperature: Float.round(25.0 + 15.0 * sine_val, 1),
      producing: inverter_1_ac > 2.0,
      reachable: true,
      inserted_at: inserted_at
    })

    # Inverter 1 — MPPT 1 (East string) — half the AC, dc_power only.
    inverter_1_mppt_1_dc = Float.round(inverter_1_ac * 0.55, 1)

    Repo.insert!(%Reading{
      dtu_id: dtu3.id,
      inverter_serial: "116180000001",
      inverter_name: "West Roof",
      mppt_index: 1,
      ac_power: nil,
      dc_power: inverter_1_mppt_1_dc,
      yield_day: 0.0,
      yield_total: 0.0,
      producing: inverter_1_mppt_1_dc > 2.0,
      reachable: true,
      inserted_at: inserted_at
    })

    # Inverter 1 — MPPT 2 (West string).
    inverter_1_mppt_2_dc = Float.round(inverter_1_ac * 0.45, 1)

    Repo.insert!(%Reading{
      dtu_id: dtu3.id,
      inverter_serial: "116180000001",
      inverter_name: "West Roof",
      mppt_index: 2,
      ac_power: nil,
      dc_power: inverter_1_mppt_2_dc,
      yield_day: 0.0,
      yield_total: 0.0,
      producing: inverter_1_mppt_2_dc > 2.0,
      reachable: true,
      inserted_at: inserted_at
    })

    # Inverter 2: single MPPT — only AC + DC totals, no per-MPPT breakdown.
    inverter_2_ac = Float.round(380.0 * sine_val * fluctuation, 1)

    Repo.insert!(%Reading{
      dtu_id: dtu3.id,
      inverter_serial: "116180000002",
      inverter_name: "East Garage",
      mppt_index: 0,
      ac_power: inverter_2_ac,
      dc_power: Float.round(inverter_2_ac * 1.04, 1),
      yield_day: 0.0,
      yield_total: 0.0,
      frequency: 50.0,
      temperature: Float.round(25.0 + 15.0 * sine_val, 1),
      producing: inverter_2_ac > 2.0,
      reachable: true,
      inserted_at: inserted_at
    })

    acc
  end)
end

seed_multi_mppt_today.()

# One fresh reading per series for the Garage Array. The dashboard's
# `current_power` only sums readings within a 2-minute freshness
# window, so a `now - 30s` timestamp would age out by the time the e2e
# pipeline reaches the test (the pipeline takes ~2 min between seed
# and test run — the Phoenix startup + wait-for-server loop alone is
# 30-60 s). Use 23:55 today instead: it's well past the sine arc's
# last bucket (19:00) so it remains the latest-by-`inserted_at` row
# for every series, and it's always within 2 min of "now" (23:55 is
# always greater than `now - 120s` for any "now" before 23:53 today).
# Same shape as the bucket rows so the chart bucketing picks them up
# as today's points and the line continues across the 23:55 bucket.
live_inserted_at = DateTime.new!(today, ~T[23:55:00], "Etc/UTC")

Repo.insert!(%Reading{
  dtu_id: dtu3.id,
  inverter_serial: "116180000001",
  inverter_name: "West Roof",
  mppt_index: 0,
  ac_power: 480.0,
  dc_power: 499.2,
  yield_day: 0.0,
  yield_total: 0.0,
  frequency: 50.0,
  temperature: 35.0,
  producing: true,
  reachable: true,
  inserted_at: live_inserted_at
})

Repo.insert!(%Reading{
  dtu_id: dtu3.id,
  inverter_serial: "116180000001",
  inverter_name: "West Roof",
  mppt_index: 1,
  ac_power: nil,
  dc_power: 264.0,
  yield_day: 0.0,
  yield_total: 0.0,
  producing: true,
  reachable: true,
  inserted_at: live_inserted_at
})

Repo.insert!(%Reading{
  dtu_id: dtu3.id,
  inverter_serial: "116180000001",
  inverter_name: "West Roof",
  mppt_index: 2,
  ac_power: nil,
  dc_power: 216.0,
  yield_day: 0.0,
  yield_total: 0.0,
  producing: true,
  reachable: true,
  inserted_at: live_inserted_at
})

Repo.insert!(%Reading{
  dtu_id: dtu3.id,
  inverter_serial: "116180000002",
  inverter_name: "East Garage",
  mppt_index: 0,
  ac_power: 320.0,
  dc_power: 332.8,
  yield_day: 0.0,
  yield_total: 0.0,
  frequency: 50.0,
  temperature: 33.0,
  producing: true,
  reachable: true,
  inserted_at: live_inserted_at
})

IO.puts("Successfully seeded today's multi-MPPT readings for #{dtu3.name}.")

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

    # Wh accumulator matching the firmware's `YieldDay` scale — see comment
    # in the today-curve generator above.
    new_yield = acc_yield + ac_power * (interval / 60.0)

    # Force microsecond-precision to 6 — see first reading block for why.
    inserted_at =
      %{DateTime.new!(date, Time.new!(hour, minute, 0)) | microsecond: {0, 6}}

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
  # Wh values for `base_yield_total` — equivalent lifetime cumulative at the
  # start of this historical day (the firmware `YieldTotal` field).
  seed_historical_day.(
    dtu1.id,
    "116180123456",
    past_date,
    1_000_000.0 - day_offset * 10_000,
    multiplier
  )
end

# Seed some historical dates for dtu2 (Balcony) to verify multi-device and total selections work
for day_offset <- [1, 2, 5, 12, 32, 370] do
  past_date = Date.add(today, -day_offset)
  multiplier = 0.4 + :rand.uniform() * 0.4
  # Wh values for `base_yield_total`.
  seed_historical_day.(
    dtu2.id,
    "223344556677",
    past_date,
    200_000.0 - day_offset * 2_000,
    multiplier
  )
end

IO.puts("Successfully seeded historical telemetry readings for all DTUs.")
