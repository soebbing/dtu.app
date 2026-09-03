defmodule DtuApp.Notifications.YieldAnomalyTest do
  @moduledoc """
  Tests for `DtuApp.Notifications.YieldAnomaly`.

  The producer fires once per user per local day when the fleet
  collapses mid-day for longer than `@default_collapse_seconds`.
  Tests pin the following properties:

    1. **fire on collapse** — broadcasting a fleet-zero
       reading while we're in the sun-up window arms a
       timer; the timer firing produces a `yield_anomaly`
       notification with an alert-tone title.
    2. **dedup within the same day** — a second
       mid-day collapse does NOT re-fire.
    3. **suppress outside the sun window** — a zero reading
       at night does NOT arm a timer (that's `SunDown`'s
       job).
    4. **suppress when no lat/lon** — a user without captured
       geographic coords is treated as "undefined sun window"
       → no fire (conservative).
    5. **opt-out path** — when `notify_yield_anomaly == false`,
       the fire is suppressed entirely.
    6. **production resumes → timer cleared** — a non-zero
       reading before the timer fires cancels the pending
       timer (no false alert on transient blips).
    7. **migrated User column** — `User.notify_yield_anomaly`
       defaults to `false` so existing users don't silently
       start receiving the new notification on deploy.
  """

  use DtuApp.DataCase, async: false

  import Ecto.Query
  import DtuApp.AccountsFixtures
  import DtuApp.DevicesFixtures

  alias DtuApp.Notifications
  alias DtuApp.Notifications.YieldAnomaly
  alias DtuApp.Notifications.YieldAnomalyFire

  @reading_topic YieldAnomaly.reading_topic()

  # Berlin — used wherever a coord makes SunCalc return a real
  # sunrise/sunset window. Tests that need a different coord
  # call `set_location/3` directly.
  @berlin_lat Decimal.new("52.520008")
  @berlin_lon Decimal.new("13.404954")

  # The user_fixture path runs through `register_user →
  # login_user_by_magic_link → update_notification_settings`,
  # which doesn't accept `:latitude` / `:longitude`. Apply the
  # coords directly via `Ecto.Changeset.change/2` + `Repo.update/1`
  # so we don't need a second fixture indirection just for the
  # geo fields.
  defp set_location(user, lat, lon) do
    user
    |> Ecto.Changeset.change(%{latitude: lat, longitude: lon})
    |> Repo.update!()
  end

  defp set_berlin_location(user), do: set_location(user, @berlin_lat, @berlin_lon)

  setup do
    # The application supervision tree skips the notifier
    # GenServers in `:test` (see `notifier_children/0` in
    # `application.ex`) — they can't share the SQL Sandbox
    # connection that the test process owns. Start a dedicated
    # instance for this test instead, and `Sandbox.allow/3` it
    # so its `Repo.get/2` calls don't race the test owner.
    pid = start_supervised!({YieldAnomaly, []})
    Ecto.Adapters.SQL.Sandbox.allow(DtuApp.Repo, self(), pid)

    # Drive the collapse-window timer to fire fast so the
    # tests don't have to sleep 15 minutes per scenario.
    # Values are in milliseconds (matches `Process.send_after/3`).
    Application.put_env(:dtu_app, :yield_anomaly_collapse_ms, 50)

    on_exit(fn ->
      Application.delete_env(:dtu_app, :yield_anomaly_collapse_ms)
      Application.delete_env(:dtu_app, :yield_anomaly_offset_seconds)
      Application.delete_env(:dtu_app, :yield_anomaly_now)
    end)

    :ok
  end

  describe "fire on collapse" do
    test "broadcasts a yield_anomaly notification when the fleet collapses mid-day" do
      # Berlin Sep 2: sunrise ≈ 04:25 UTC, sunset ≈ 18:53 UTC.
      # The producer's user_today + SunCalc path is what gates
      # the window — we set the "now" override to 14:00 UTC,
      # comfortably between sunrise and sunset.
      Application.put_env(:dtu_app, :yield_anomaly_offset_seconds, 0)
      Application.put_env(:dtu_app, :yield_anomaly_now, ~U[2026-09-02 14:00:00.000000Z])

      user =
        user_fixture(%{notify_yield_anomaly: true})
        |> set_berlin_location()

      dtu = device_fixture(user, %{name: "Collapse DTU"})
      :ok = Notifications.subscribe(user.id)

      # First wake the fleet briefly, then collapse it. The
      # collapse arming only kicks in once the fleet sum drops
      # below the 5 W threshold.
      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 200.0}}
      )

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 0.0}}
      )

      # 50ms collapse_ms + headroom for the timer message to dispatch.
      assert_receive {:notification, payload}, 1_000

      assert payload.event == "yield_anomaly"
      # Tone is alert, not playful — production stalled.
      assert payload.title =~ "Production" or payload.title =~ "stalled"
      assert is_list(payload.body)
      assert Enum.any?(payload.body, &(&1 =~ "15 minutes" or &1 =~ "panels"))
      assert payload.tag =~ "yield_anomaly:"

      # Dedup row inserted for the user's local date. With
      # tz_offset_seconds = 0 the local date is the UTC date.
      assert Repo.exists?(
               from f in YieldAnomalyFire,
                 where: f.user_id == ^user.id and f.fired_on == ^~D[2026-09-02]
             )
    end

    test "a second mid-day collapse in the same day does not re-fire" do
      Application.put_env(:dtu_app, :yield_anomaly_offset_seconds, 0)
      Application.put_env(:dtu_app, :yield_anomaly_now, ~U[2026-09-02 14:30:00.000000Z])

      user =
        user_fixture(%{notify_yield_anomaly: true})
        |> set_berlin_location()

      dtu = device_fixture(user)

      :ok = Notifications.subscribe(user.id)

      # First collapse — fires.
      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 0.0}}
      )

      assert_receive {:notification, _}, 1_000

      # Wipe the cached state by collapsing + waking again.
      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 300.0}}
      )

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 0.0}}
      )

      # Second collapse — no second fire. Drain the mailbox
      # of any stale messages before asserting.
      refute_receive {:notification, _}, 500
    end
  end

  describe "suppress outside the sun window" do
    test "a zero reading at night does NOT fire (SunDown owns this)" do
      # 23:30 UTC in Berlin in September is well past sunset
      # (~18:53 UTC) and just before the next sunrise
      # (~04:25 UTC). The producer is supposed to skip this.
      Application.put_env(:dtu_app, :yield_anomaly_offset_seconds, 0)
      Application.put_env(:dtu_app, :yield_anomaly_now, ~U[2026-09-02 23:30:00.000000Z])

      user =
        user_fixture(%{notify_yield_anomaly: true})
        |> set_berlin_location()

      dtu = device_fixture(user)

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 0.0}}
      )

      # Wait past the collapse window — if a fire were going
      # to happen, it would have happened by now.
      refute_receive {:notification, _}, 500

      # No dedup row either.
      assert Repo.one(from(f in YieldAnomalyFire, where: f.user_id == ^user.id, select: count())) ==
               0
    end
  end

  describe "suppress when no lat/lon" do
    test "a user without captured geographic coords is treated as undefined window" do
      Application.put_env(:dtu_app, :yield_anomaly_offset_seconds, 0)
      Application.put_env(:dtu_app, :yield_anomaly_now, ~U[2026-09-02 14:00:00.000000Z])

      # Note: no lat/lon set. SunCalc returns {nil, nil} which
      # the producer treats as "undefined → skip".
      user = user_fixture(%{notify_yield_anomaly: true})
      dtu = device_fixture(user)

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 0.0}}
      )

      refute_receive {:notification, _}, 500
    end
  end

  describe "opt-out path" do
    test "when notify_yield_anomaly is false, no notification fires" do
      Application.put_env(:dtu_app, :yield_anomaly_offset_seconds, 0)
      Application.put_env(:dtu_app, :yield_anomaly_now, ~U[2026-09-02 14:00:00.000000Z])

      # Toggle OFF — same setup as the "fire" test but with
      # notify_yield_anomaly: false (the default).
      user =
        user_fixture()
        |> set_berlin_location()

      dtu = device_fixture(user)

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 0.0}}
      )

      refute_receive {:notification, _}, 500

      # And no dedup row.
      assert Repo.one(from(f in YieldAnomalyFire, where: f.user_id == ^user.id, select: count())) ==
               0
    end
  end

  describe "production resumes before timer fires" do
    test "a non-zero reading cancels the pending collapse timer (no false alert)" do
      Application.put_env(:dtu_app, :yield_anomaly_collapse_ms, 100)
      Application.put_env(:dtu_app, :yield_anomaly_offset_seconds, 0)
      Application.put_env(:dtu_app, :yield_anomaly_now, ~U[2026-09-02 14:00:00.000000Z])

      user =
        user_fixture(%{notify_yield_anomaly: true})
        |> set_berlin_location()

      dtu = device_fixture(user)

      :ok = Notifications.subscribe(user.id)

      # Collapse → arm 100ms timer.
      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 0.0}}
      )

      # Wake the fleet again before the 100ms timer fires.
      Process.sleep(40)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 400.0}}
      )

      # The 100ms window expires — no notification.
      Process.sleep(150)
      refute_receive {:notification, _}, 100
    end
  end

  describe "polar fallback in sun_window_for/2" do
    test "polar night at the user's location → undefined → no fire" do
      # South pole / polar night — SunCalc returns {nil, …}.
      # Use the southern winter solstice (June 21) at a
      # high-southern-latitude location to make the test
      # robust. (Berlin wouldn't go polar — only the
      # southernmost latitudes do.)
      Application.put_env(:dtu_app, :yield_anomaly_offset_seconds, 0)
      Application.put_env(:dtu_app, :yield_anomaly_now, ~U[2026-06-21 14:00:00.000000Z])

      user =
        user_fixture(%{notify_yield_anomaly: true})
        |> set_location(Decimal.new("-89.99"), Decimal.new("0.0"))

      dtu = device_fixture(user)
      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 0.0}}
      )

      refute_receive {:notification, _}, 500
    end
  end

  describe "migrated User column" do
    test "User.notify_yield_anomaly defaults to false" do
      user = unconfirmed_user_fixture()
      assert user.notify_yield_anomaly == false
    end
  end
end
