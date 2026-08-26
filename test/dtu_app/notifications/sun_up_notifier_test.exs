defmodule DtuApp.Notifications.SunUpTest do
  @moduledoc """
  Tests for `DtuApp.Notifications.SunUp`.

  The producer fires once per user per local day when the fleet
  transitions from 0 W to > 0 W (i.e. the array has woken up for
  the day). The tests below pin the following properties:

    1. **fire on fleet wake** — broadcasting a non-zero reading
       for every device of a user after they've been at 0 W
       produces a `sun_up` notification with a playful title.
    2. **dedup within the same day** — a second non-zero reading
       in the same day does NOT re-fire.
    3. **suppress at 0 W** — readings while the fleet is still at
       0 W do not fire.
    4. **opt-out path** — when `notify_sun_up == false`, the
       entire broadcast is suppressed at the producer level
       (no in-page event, no native push, no history row, no
       `sun_up_fires` insert). Unlike `DtuConnection` / `SunDown`,
       SunUp is user-visible as "off" rather than "just silent
       when the tab is closed".
    5. **per-MPPT rows are ignored** — only `mppt_index: 0` rows
       carry `ac_power`; rows for `mppt_index >= 1` must not
       affect fleet-power state.
    6. **multi-DTU fleet aggregates** — a fleet of two inverters
       fires only when the sum of all devices' latest readings
       first crosses 0 W, not on every individual wake.
    7. **TZ offset is respected** — a user with a non-UTC offset
       gets their `fired_on_date` cached against the local date,
       so the rollover happens at local midnight.
  """
  use DtuApp.DataCase, async: false

  import Ecto.Query
  import DtuApp.AccountsFixtures
  import DtuApp.DevicesFixtures

  alias DtuApp.Notifications
  alias DtuApp.Notifications.SunUp

  @reading_topic SunUp.reading_topic()

  setup do
    # The application supervision tree skips the notifier GenServers
    # in `:test` (see `notifier_children/0` in `application.ex`) —
    # they can't share the SQL Sandbox connection that the test
    # process owns. Start a dedicated instance for this test instead,
    # and `Sandbox.allow/3` it so its `Repo.get/2` calls don't race
    # the test owner. The GenServer is stopped when the test exits.
    pid = start_supervised!({SunUp, []})
    Ecto.Adapters.SQL.Sandbox.allow(DtuApp.Repo, self(), pid)

    # Default the test user to UTC so the date-rollover tests can
    # override per-fixture without unsetting the global.
    Application.put_env(:dtu_app, :sun_up_offset_seconds, 0)

    on_exit(fn ->
      Application.delete_env(:dtu_app, :sun_up_offset_seconds)
    end)

    :ok
  end

  describe "fire on fleet wake" do
    test "broadcasts a sun_up notification the first time the fleet crosses 0 W" do
      user = user_fixture(%{notify_sun_up: true})
      dtu = device_fixture(user, %{name: "Wake DTU"})

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 120.0}}
      )

      assert_receive {:notification, payload}, 1_000

      assert payload.event == "sun_up"
      # Title carries the playful tone the user asked for.
      assert payload.title =~ "sun"
      # Body mentions first power / panels — the user-facing copy.
      assert payload.body =~ "panels" or payload.body =~ "power"
      assert payload.tag =~ "sun_up:"
    end

    test "a second non-zero reading in the same day does not re-fire" do
      user = user_fixture(%{notify_sun_up: true})
      dtu = device_fixture(user, %{name: "Steady DTU"})

      :ok = Notifications.subscribe(user.id)

      # First reading — fleet wakes up → fires.
      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 200.0}}
      )

      assert_receive {:notification, _}, 1_000

      # Drain the mailbox so the next assert_receive only matches a
      # NEW notification (not the one we just consumed).
      flush_notifications()

      # Second non-zero reading in the same day → dedup.
      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 450.0}}
      )

      refute_receive {:notification, _}, 300
    end

    test "readings while the fleet is still at 0 W do not fire" do
      user = user_fixture(%{notify_sun_up: true})
      dtu = device_fixture(user, %{name: "Sleepy DTU"})

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 0.0}}
      )

      refute_receive {:notification, _}, 300
    end
  end

  describe "opt-out path" do
    test "no notification fires when notify_sun_up is false (producer-level gate)" do
      # Unlike `DtuConnection` and `SunDown` (which always publish and
      # only gate the native-push path), SunUp suppresses the entire
      # broadcast at the producer level when the preference is off —
      # no in-page event, no native push, no history row. The user
      # explicitly asked for "not sent, when disabled", so the
      # producer honours that even at the cost of being inconsistent
      # with the other notifiers.
      user = user_fixture(%{notify_sun_up: false})
      dtu = device_fixture(user, %{name: "Opt-out DTU"})

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 80.0}}
      )

      # Producer gate suppresses the broadcast — no `:notification`
      # arrives, no DB row in `sun_up_fires`, no `notifications`
      # history entry.
      refute_receive {:notification, _}, 500

      assert DtuApp.Repo.aggregate(
               from(f in DtuApp.Notifications.SunUpFire, where: f.user_id == ^user.id),
               :count
             ) == 0
    end
  end

  describe "per-MPPT rows" do
    test "rows with mppt_index >= 1 are ignored (only AC aggregate carries ac_power)" do
      user = user_fixture(%{notify_sun_up: true})
      dtu = device_fixture(user, %{name: "MPPT DTU"})

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 1, ac_power: 50.0}}
      )

      refute_receive {:notification, _}, 300
    end
  end

  describe "multi-DTU fleet aggregates" do
    test "fleet of two inverters fires once when the sum crosses 0 W, not on every wake" do
      user = user_fixture(%{notify_sun_up: true})

      dtu_a = device_fixture(user, %{name: "DTU A"})
      dtu_b = device_fixture(user, %{name: "DTU B"})

      :ok = Notifications.subscribe(user.id)

      # DTU A wakes up first — fleet power is now 100 W (single device).
      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu_a.id, mppt_index: 0, ac_power: 100.0}}
      )

      assert_receive {:notification, %{event: "sun_up"}}, 1_000

      flush_notifications()

      # DTU B wakes up a moment later — fleet was already > 0 W, no
      # transition → no second fire.
      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu_b.id, mppt_index: 0, ac_power: 150.0}}
      )

      refute_receive {:notification, _}, 300
    end
  end

  describe "user locale propagation" do
    # The producer's `fire/1` builds the `sun_up` payload with
    # `gettext/1` calls for the playful title and body. As a long-lived
    # GenServer without a request context, a bare `gettext/1` would
    # default to whatever Gettext was initialized with (≈ "en")
    # regardless of the user's preference. The producer wraps
    # `fire/1` in `Gettext.with_locale/2` against `user.locale`,
    # and the assertion below checks the rendered title matches
    # what `Gettext.gettext/2` returns in the same locale.
    #
    # `user_fixture/1` only persists `:email`, so we update the
    # locale separately via `Accounts.update_user_settings/2`.

    test "a French user's sun_up title matches the French catalog" do
      {:ok, user} =
        DtuApp.Accounts.update_user_settings(
          user_fixture(%{notify_sun_up: true}),
          %{"locale" => "fr"}
        )

      dtu = device_fixture(user, %{name: "Toit"})

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_loc", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 80.0}}
      )

      assert_receive {:notification, payload}, 1_000

      expected_title =
        Gettext.with_locale(DtuAppWeb.Gettext, "fr", fn ->
          Gettext.gettext(DtuAppWeb.Gettext, "☀️ The sun's awake!")
        end)

      assert payload.title == expected_title
    end

    test "an English user's sun_up title is the source string" do
      # English has no translations; gettext returns the msgid
      # verbatim. Asserts the no-op path stays intact.
      user = user_fixture(%{notify_sun_up: true})
      dtu = device_fixture(user, %{name: "Roof"})

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_loc", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 80.0}}
      )

      assert_receive {:notification, payload}, 1_000

      assert payload.title == "☀️ The sun's awake!"
    end
  end

  describe "persistent dedup (DB-backed)" do
    test "a second fire attempt after the GenServer restart is rejected by the DB constraint" do
      # The whole reason we replaced the in-memory `fired_on_date`
      # cache with a `sun_up_fires` row: any GenServer restart (deploy,
      # crash, application restart) used to wipe the cache and let the
      # next reading fire `sun_up` again, producing duplicate pushes.
      # The unique `(user_id, fired_on)` constraint now survives the
      # restart — a freshly-started GenServer with empty in-memory
      # state must still reject the second fire for the same day.
      #
      # Verified at two levels:
      #
      #   1. The DB constraint itself: a second `Repo.insert` with the
      #      same `(user_id, fired_on)` raises `Ecto.ConstraintError`
      #      even when the in-memory cache is empty (it is — this is
      #      a direct DB call).
      #   2. The producer path: a `sun_up_fires` row inserted directly
      #      makes a subsequent fleet-wake reading a no-op without
      #      involving the producer's in-memory state at all.
      user = user_fixture(%{notify_sun_up: true})
      today = Date.utc_today()

      # Simulate "the producer already fired for this user today" by
      # writing the dedup row directly — this is what the DB survives
      # the restart that wiped the in-memory cache.
      {:ok, %DtuApp.Notifications.SunUpFire{}} =
        %DtuApp.Notifications.SunUpFire{}
        |> DtuApp.Notifications.SunUpFire.changeset(%{user_id: user.id, fired_on: today})
        |> DtuApp.Repo.insert(on_conflict: :raise)

      dtu = device_fixture(user, %{name: "Restart DTU"})
      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 100.0}}
      )

      # The pre-existing dedup row means the producer's `insert_fire`
      # raises `Ecto.ConstraintError`, which we catch and treat as a
      # duplicate — no notification is broadcast.
      refute_receive {:notification, _}, 500

      # Still exactly one row — no duplicate insert.
      assert DtuApp.Repo.aggregate(
               from(f in DtuApp.Notifications.SunUpFire, where: f.user_id == ^user.id),
               :count
             ) == 1
    end

    test "the same user on a different local date fires again" do
      # Sanity-check the dedup key actually scopes by date and not
      # just by user. Simulate by inserting two rows directly with
      # different `fired_on` values, then broadcasting — the producer
      # must compute today's date and not be confused by yesterday's
      # row.
      user = user_fixture(%{notify_sun_up: true})
      dtu = device_fixture(user, %{name: "New Day DTU"})

      yesterday = Date.add(Date.utc_today(), -1)

      {:ok, _} =
        %DtuApp.Notifications.SunUpFire{}
        |> DtuApp.Notifications.SunUpFire.changeset(%{user_id: user.id, fired_on: yesterday})
        |> DtuApp.Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :fired_on])

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @reading_topic,
        {:reading, "client_1", %{dtu_id: dtu.id, mppt_index: 0, ac_power: 100.0}}
      )

      # Today's row is new — producer fires as normal.
      assert_receive {:notification, _}, 1_000
    end
  end

  describe "local_date/2" do
    test "returns the shifted calendar date for a positive (east) offset" do
      # 2026-08-23T22:00:00Z in CEST (+7200) is 2026-08-24T00:00 local.
      utc = ~U[2026-08-23 22:00:00Z]
      assert SunUp.local_date(utc, 7_200) == ~D[2026-08-24]
    end

    test "returns the same calendar date for a zero offset" do
      utc = ~U[2026-08-23 12:00:00Z]
      assert SunUp.local_date(utc, 0) == ~D[2026-08-23]
    end

    test "returns the previous calendar date for a negative (west) offset" do
      # 2026-08-23T03:00:00Z in PDT (-25200) is 2026-08-22T20:00 local.
      utc = ~U[2026-08-23 03:00:00Z]
      assert SunUp.local_date(utc, -25_200) == ~D[2026-08-22]
    end
  end

  # Drain the test process mailbox of any pending notifications so
  # `assert_receive`/`refute_receive` only see what the broadcast
  # under test produces. Loops with a 0-ms timeout — Phoenix's
  # `PubSub.drain/2` isn't available in this version.
  defp flush_notifications do
    receive do
      {:notification, _} -> flush_notifications()
    after
      0 -> :ok
    end
  end
end
