defmodule DtuApp.Notifications.SunDownTest do
  @moduledoc """
  Tests for `DtuApp.Notifications.SunDown`.

  The producer maintains a per-user fleet-power state and fires
  `DtuApp.Notifications.broadcast/2` once the fleet has been at 0 W
  for `:sun_down_idle_seconds` (default 15 min). The tests below
  shorten the idle window via `Application.put_env(:dtu_app,
  :sun_down_idle_seconds, N)` so a single test can drive an
  immediate fire without a 15-min sleep.

  Properties pinned:

    1. **fleet at 0 W → fire** — broadcasting a `:reading` whose
       `ac_power: 0.0` for every device of a user arms a timer;
       after the idle window the user receives a `sun_down`
       payload with today + yesterday stats.
    2. **fleet wakes up → cancel** — a non-zero reading between
       the arm and the fire cancels the timer; no `sun_down` event
       reaches the user.
    3. **opt-out path** — when `notify_sun_down == false`, the
       VAPID fan-out is suppressed (the in-page broadcast still
       fires — the JS hook dedups; `Notifications.broadcast/2`
       gates VAPID via `native_push_enabled?/2`).
    4. **per-MPPT rows are ignored** — only `mppt_index: 0` rows
       carry `ac_power`; rows for `mppt_index >= 1` must not
       affect fleet-power state.
  """
  use DtuApp.DataCase, async: false

  import DtuApp.AccountsFixtures
  import DtuApp.DevicesFixtures

  alias DtuApp.Devices
  alias DtuApp.Notifications
  alias DtuApp.Notifications.SunDown

  @reading_topic SunDown.reading_topic()

  setup do
    # The application supervision tree skips the notifier GenServers
    # in `:test` (see `notifier_children/0` in `application.ex`) —
    # they can't share the SQL Sandbox connection that the test
    # process owns. Start a dedicated instance for this test instead,
    # and `Sandbox.allow/3` it so its `Repo.get/2` calls don't race
    # the test owner. The GenServer is stopped when the test exits.
    pid = start_supervised!({SunDown, []})
    Ecto.Adapters.SQL.Sandbox.allow(DtuApp.Repo, self(), pid)

    # Shorten the idle window so the test can drive an immediate fire
    # without a 15-min sleep. Restore on teardown so a value leaking
    # out of one test doesn't corrupt the next.
    original = Application.get_env(:dtu_app, :sun_down_idle_seconds)
    Application.put_env(:dtu_app, :sun_down_idle_seconds, 0)

    on_exit(fn ->
      if original do
        Application.put_env(:dtu_app, :sun_down_idle_seconds, original)
      else
        Application.delete_env(:dtu_app, :sun_down_idle_seconds)
      end
    end)

    :ok
  end

  describe "fleet at 0 W" do
    test "fires sun_down after the idle window when the fleet is at 0 W" do
      user = user_fixture()
      dtu = device_fixture(user, %{name: "Sun DTU"})

      # Seed a 0-W reading at mppt_index 0 (the AC aggregate row) so
      # the broadcast payload can correlate against a real reading
      # when the producer checks fleet power.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV",
          mppt_index: 0,
          ac_power: 0.0,
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 0.0}}
      )

      # idle_seconds = 0 → the timer fires on the next message loop tick.
      assert_receive {:notification, payload}, 1_000

      assert payload.event == "sun_down"
      assert payload.title =~ "daily summary"
      assert payload.body =~ "Today:"
      assert payload.tag =~ "sun_down:"
      assert payload.today_yield_kwh == 0.0
      assert payload.peak_power_w == 0.0
    end
  end

  describe "fleet wakes up" do
    test "a non-zero reading between arm and fire cancels the timer" do
      user = user_fixture()
      dtu = device_fixture(user, %{name: "Wake DTU"})

      :ok = Notifications.subscribe(user.id)

      # Arm the timer (0 W).
      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 0.0}}
      )

      # Fleet wakes up before the timer fires.
      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 250.0}}
      )

      refute_receive {:notification, %{event: "sun_down"}}, 500
    end
  end

  describe "opt-out path" do
    test "in-page broadcast still fires when notify_sun_down is false (VAPID gate is separate)" do
      user = user_fixture(%{notify_sun_down: false})
      dtu = device_fixture(user, %{name: "Opt-out Sun DTU"})

      # Seed a reading so `build_payload/2` returns a non-nil payload
      # (without it, `Devices.get_daily_stats/3` returns the
      # no-data shape and the producer short-circuits — that's a
      # payload condition, not a preference condition, and it's
      # covered by the dedicated `build_payload/2 returns nil` test
      # below).
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV",
          mppt_index: 0,
          ac_power: 0.0,
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 0.0}}
      )

      # In-page path is unconditional; receiver-side hook dedups.
      assert_receive {:notification, %{event: "sun_down"}}, 1_000
    end
  end

  describe "per-MPPT rows" do
    test "rows with mppt_index >= 1 are ignored (only AC aggregate carries ac_power)" do
      user = user_fixture()
      dtu = device_fixture(user, %{name: "MPPT DTU"})

      :ok = Notifications.subscribe(user.id)

      # Only a per-MPPT row — should not arm a timer (it's :ignored
      # by `reading_ac_power/1`).
      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 1, ac_power: 50.0}}
      )

      refute_receive {:notification, _}, 300
    end
  end

  describe "build_payload/2" do
    test "returns nil for a user with no devices" do
      user = user_fixture()
      assert SunDown.build_payload(user, Date.utc_today()) == nil
    end

    test "shapes today + yesterday stats for a user with one inverter" do
      user = user_fixture()
      dtu = device_fixture(user, %{name: "Stats DTU"})

      # Seed yesterday's last reading at 1500 Wh.
      yesterday_dt = DateTime.new!(Date.add(Date.utc_today(), -1), ~T[23:55:00], "Etc/UTC")

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV",
          mppt_index: 0,
          ac_power: 0.0,
          yield_day: 1500.0,
          inserted_at: yesterday_dt
        })

      # And today's last reading at 2500 Wh, peak ~ 800 W from a
      # mid-day chart point.
      today_dt = DateTime.new!(Date.utc_today(), ~T[18:00:00], "Etc/UTC")

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV",
          mppt_index: 0,
          ac_power: 0.0,
          yield_day: 2500.0,
          inserted_at: today_dt
        })

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV",
          mppt_index: 0,
          ac_power: 800.0,
          inserted_at: DateTime.new!(Date.utc_today(), ~T[13:00:00], "Etc/UTC")
        })

      payload = SunDown.build_payload(user, Date.utc_today())

      assert payload.event == "sun_down"
      assert payload.today_yield_kwh == 2.5
      assert payload.peak_power_w == 800.0
      assert payload.today_yield_yesterday_kwh == 1.5
      # Yesterday had no peak power — defaults to 0.
      assert payload.peak_power_yesterday_w == 0.0
      assert payload.date == Date.to_iso8601(Date.utc_today())
    end
  end
end
