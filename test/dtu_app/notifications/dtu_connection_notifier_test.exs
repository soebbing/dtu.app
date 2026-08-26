defmodule DtuApp.Notifications.DtuConnectionTest do
  @moduledoc """
  Tests for `DtuApp.Notifications.DtuConnection`.

  This producer used to live in `DashboardLive.handle_info/2` —
  the tests below pin the new server-side GenServer's behaviour:

    1. **`fire on disconnect`** — a broker `:dtu_disconnected` event
       for a *recently-active* device produces a `dtu_connection`
       notification with `event: "dtu_connection"` and the right
       title / body / tag.
    2. **`suppress stale disconnects`** — a disconnect whose
       `last_seen_at` is older than the 5-min recency threshold
       (e.g. a post-deploy reconnect on a device that was already
       dead before the broker restarted) is a quiet no-op.
    3. **`fire on reconnect`** — a broker `:dtu_connected` event
       fires the `:back_online` half of the state change.
    4. **preference gate** — when the user has `notify_dtu_connection
       == false`, the producer itself skips `fire_for_status/2`:
       no in-page PubSub event, no native push, no `notifications`
       history row. Same UX contract as `notify_sun_up` — see the
       moduledoc on `Notifications.SunUp`.
    5. **`suppress duplicate disconnects`** — a burst of
       `:dtu_disconnected` events arriving without an intervening
       `:dtu_connected` produces exactly one `:went_offline`. The
       first event transitions online → offline and fires; the rest
       stay offline → offline and are silent. Mirrors the connect-
       side `disconnected?: true` gate; the DB-backed
       `dtu_connection_states.disconnected` row preserves the
       suppression across producer restarts.
    6. **`persistent dedup`** — a pre-existing `dtu_connection_states`
       row with `disconnected: true` re-hydrates into the in-memory
       cache on `init/1`; the first disconnect after restart stays
       silent (no duplicate notification for a device the user
       already knew was offline).
  """
  use DtuApp.DataCase, async: false

  import DtuApp.AccountsFixtures
  import DtuApp.DevicesFixtures

  alias DtuApp.Devices.Dtu
  alias DtuApp.Notifications
  alias DtuApp.Notifications.DtuConnection
  alias DtuApp.Repo
  alias DtuApp.Time

  @presence_topic DtuConnection.presence_topic()

  setup do
    # The application supervision tree skips the notifier GenServers
    # in `:test` (see `notifier_children/0` in `application.ex`) —
    # they can't share the SQL Sandbox connection that the test
    # process owns. Start a dedicated instance for this test instead,
    # and `Sandbox.allow/3` it so its `Repo.get/2` calls don't race
    # the test owner. The GenServer is stopped when the test exits.
    pid = start_supervised!(DtuConnection)
    Ecto.Adapters.SQL.Sandbox.allow(DtuApp.Repo, self(), pid)
    :ok
  end

  defp touch_last_seen!(%Dtu{} = dtu, offset_seconds) when is_integer(offset_seconds) do
    # `last_seen_at` is typed `:utc_datetime_usec` — Ecto's check
    # rejects writes whose `:microsecond` field is `nil`. Build the
    # timestamp from `DtuApp.Time.utc_now_usec/0` (which already has
    # `{6, N}` precision) and offset it; `DateTime.add/3` preserves the
    # precision field, so the result passes the dump check.
    at =
      Time.utc_now_usec()
      |> DateTime.add(offset_seconds, :second)

    dtu
    |> Ecto.Changeset.change(%{last_seen_at: at})
    |> Repo.update!()
  end

  # Seed the producer's local cache so it believes the given device
  # is currently disconnected, AND was recently active. Required by
  # fix A's gate on the :back_online path: without a prior
  # :dtu_disconnected observed, the producer stays silent on connect.
  # `last_seen_at` defaults to 60s ago so fix B's recency guard
  # passes — without it, the connect-side gate pattern-matches on
  # `last_seen_at: %DateTime{}` and falls through to the silent `_`.
  # Tests that want to verify fix B's stale-reconnect suppression
  # pass `last_seen_offset_seconds` (e.g. -3600 for 1 h old). We
  # talk to the GenServer directly so the test doesn't depend on
  # PubSub round-trip timing.
  defp seed_disconnect!(device_id, last_seen_offset_seconds \\ -60) do
    last_seen_at = DateTime.add(Time.utc_now_usec(), last_seen_offset_seconds, :second)

    :sys.replace_state(DtuConnection, fn state ->
      Map.put(state, device_id, %{
        user_id: nil,
        name: nil,
        last_seen_at: last_seen_at,
        disconnected?: true
      })
    end)
  end

  # Seed the producer's local cache with a `connected_at` timestamp
  # older than @recency_seconds. Required by fix C1's gate: the
  # disconnect side must not fire when the device was online for
  # less than the recency threshold (the existing recency guard
  # looks at `last_seen_at`; the new gate also looks at
  # `connected_at` to ensure prior uptime).
  #
  # `last_seen_at` is stamped at the current time so the
  # post-disconnect reconnect path's recency guard sees a fresh
  # reading — the connect handler reads `last_seen_at` from state
  # (the cache the disconnect path populated), not the DB row.
  # `disconnected?: false` here is intentional: the test models
  # "the device was online for >5 min, then just disconnected" —
  # the producer hasn't observed an offline yet, so the new
  # `not was_disconnected?` gate on the disconnect handler lets
  # the fire through. (Setting `disconnected?: true` would model
  # "the producer already fired for an earlier offline period"
  # — that scenario is covered by the duplicate-suppression tests
  # below.)
  defp seed_connected_at!(device_id, %DateTime{} = at) do
    :sys.replace_state(DtuConnection, fn state ->
      Map.put(state, device_id, %{
        user_id: nil,
        name: nil,
        last_seen_at: Time.utc_now_usec(),
        disconnected?: false,
        connected_at: at
      })
    end)
  end

  describe "fire on disconnect" do
    test "a recently-active device's disconnect produces a dtu_connection notification" do
      user = user_fixture(%{notify_dtu_connection: true})
      dtu = device_fixture(user, %{name: "Test DTU"})
      # Seed the producer's connected-at to >5 min ago so the C1
      # gate (require prior uptime) passes — only the existing
      # recency guard should allow the fire. `last_seen_at` must
      # remain within the 5-min recency window (the existing
      # recently_active?/1 guard), so we set it to 1 min ago.
      seed_connected_at!(dtu.id, DateTime.add(Time.utc_now_usec(), -600, :second))
      touch_last_seen!(dtu, -60)

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_disconnected, "client_1", dtu.id}
      )

      assert_receive {:notification, payload}, 1_000

      assert payload.event == "dtu_connection"
      assert payload.title =~ "offline"
      # `body` is a list of paragraphs (dispatcher's email/layout
      # contract); the inverter name sits in the first paragraph.
      assert is_list(payload.body)
      assert Enum.any?(payload.body, &(&1 =~ "Test DTU"))
      assert payload.tag == "dtu:Test DTU"
      # Email/history extras from the dispatcher's structured payload.
      assert payload.dtu_name == "Test DTU"
      assert payload.status == :went_offline
      assert %DateTime{} = payload.since
    end

    test "a stale disconnect (last_seen_at older than 5 min) does not fire" do
      user = user_fixture(%{notify_dtu_connection: true})
      dtu = device_fixture(user, %{name: "Stale DTU"})

      touch_last_seen!(dtu, -3600)

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_disconnected, "client_1", dtu.id}
      )

      refute_receive {:notification, _payload}, 500
    end

    test "a disconnect after brief uptime (last_seen_at < 5 min old) does not fire (fix C1)" do
      # Inversion of the existing recency guard. The DTU briefly
      # connected (last_seen_at is fresh) and disconnected without
      # ever having been online long enough to call "offline".
      # Without this gate the producer would notify the user that
      # the inverter has "gone offline" when it was actually
      # online for a few seconds — a real-world failure mode
      # during a power-cycle + reconnect storm.
      user = user_fixture(%{notify_dtu_connection: true})
      dtu = device_fixture(user, %{name: "Brief DTU"})

      touch_last_seen!(dtu, -30)

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_disconnected, "client_brief", dtu.id}
      )

      refute_receive {:notification, _payload}, 300
    end
  end

  describe "fire on reconnect" do
    test "a :dtu_connected broadcast produces the :back_online notification" do
      user = user_fixture(%{notify_dtu_connection: true})
      dtu = device_fixture(user, %{name: "Back Online DTU"})

      # Seed the producer's local cache with a prior `:disconnected?`
      # marker so the back-online gate has something to see — without
      # it, the producer can't tell this reconnect from the first
      # sight and stays silent (the gate was added to stop the
      # server-restart N-notification storm). `last_seen_at` is set
      # to 60s ago so fix B's recency guard passes (the connect
      # handler reads `last_seen_at` from the producer's state, not
      # the DB row, before clearing the disconnect marker).
      seed_disconnect!(dtu.id)
      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_connected, "client_2", dtu.id}
      )

      assert_receive {:notification, payload}, 1_000

      assert payload.event == "dtu_connection"
      assert payload.title =~ "back online"
      assert is_list(payload.body)
      assert Enum.any?(payload.body, &(&1 =~ "Back Online DTU"))
      assert payload.tag == "dtu:Back Online DTU"
      assert payload.dtu_name == "Back Online DTU"
      assert payload.status == :back_online
    end

    test "a :dtu_connected broadcast WITHOUT a prior disconnect is silent (no false :back_online)" do
      # This is the core spam-suppression gate (fix A). Without a
      # prior `:dtu_disconnected` observed by the producer, a
      # reconnect is just a reconnect — typically a WiFi blip or
      # a server-restart re-connect, neither of which the user
      # wants to be notified about. The producer's state cache
      # starts empty, so the very first :dtu_connected for any
      # device_id is silent.
      user = user_fixture(%{notify_dtu_connection: true})
      dtu = device_fixture(user, %{name: "Quiet Reconnect DTU"})

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_connected, "client_first", dtu.id}
      )

      refute_receive {:notification, _payload}, 300
    end

    test "a stale reconnect (last_seen_at > 5 min old) is silent (fix B)" do
      # Mirror of the existing recency guard on the disconnect side
      # (fix B). If the device's last_seen_at is older than
      # @recency_seconds, the reconnect is a post-deploy
      # re-attachment from a DTU that was already dead — not news.
      user = user_fixture(%{notify_dtu_connection: true})
      dtu = device_fixture(user, %{name: "Stale Reconnect DTU"})

      # Seed the prior-disconnect marker so fix A's gate passes;
      # only fix B's recency check should suppress the fire. The
      # last_seen_at offset is passed directly into the state
      # because the connect handler reads `last_seen_at` from state
      # (before clearing the marker) — not from the DB row.
      seed_disconnect!(dtu.id, -3600)
      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_connected, "client_stale", dtu.id}
      )

      refute_receive {:notification, _payload}, 300
    end
  end

  describe "preference gating" do
    test "no notification fires when notify_dtu_connection is false (producer-level gate)" do
      # Producer-level preference gate: when the toggle is off, the
      # producer itself skips `fire_for_status/2`, so no in-page
      # PubSub event, no native push, and no `notifications` history
      # row are produced. Same UX contract as `notify_sun_up` — see
      # the moduledoc on `Notifications.SunUp`.
      user = user_fixture(%{notify_dtu_connection: false})
      dtu = device_fixture(user, %{name: "Opt-out DTU"})
      seed_connected_at!(dtu.id, DateTime.add(Time.utc_now_usec(), -600, :second))
      touch_last_seen!(dtu, -60)

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_disconnected, "client_3", dtu.id}
      )

      refute_receive {:notification, _}, 500
    end
  end

  describe "persistent disconnect marker (DB-backed)" do
    test "a pre-existing DB marker is re-hydrated into the in-memory cache after restart" do
      # The whole reason we replaced the in-memory `state` cache with
      # the `dtu_connection_states` row: any GenServer restart (deploy,
      # crash, application restart) used to wipe the
      # `disconnected?: true` marker and let the very next
      # `:dtu_connected` for a device that was already on the broker
      # at boot fire `:back_online` — a duplicate "your inverter is
      # publishing telemetry again" push. The DB row now survives the
      # restart; `init/1` re-hydrates it.
      #
      # We verify the contract by writing the row directly (simulating
      # "the previous process wrote it before crashing") and then
      # restarting the producer — the in-memory cache should pick up
      # the `disconnected?: true` marker.
      user = user_fixture(%{notify_dtu_connection: true})
      dtu = device_fixture(user, %{name: "Hydrate DTU"})

      connected_at = DateTime.add(Time.utc_now(), -600, :second)

      {:ok, _} =
        %DtuApp.Notifications.DtuConnectionState{}
        |> DtuApp.Notifications.DtuConnectionState.changeset(%{
          device_id: dtu.id,
          disconnected: true,
          connected_at: connected_at
        })
        |> DtuApp.Repo.insert(on_conflict: :raise)

      # Restart the producer. `init/1` should re-hydrate the row.
      :ok = stop_supervised(DtuApp.Notifications.DtuConnection)
      :ok = wait_for_unregister(DtuApp.Notifications.DtuConnection, 100)
      pid = start_supervised!({DtuApp.Notifications.DtuConnection, []})
      Ecto.Adapters.SQL.Sandbox.allow(DtuApp.Repo, self(), pid)

      # The cache now carries a `disconnected?: true` entry for this
      # device — verified by `:sys.replace_state` (the existing test
      # pattern). `last_seen_at` is intentionally NOT preloaded on
      # hydrate (see `init/1` comment in `dtu_connection_notifier.ex`),
      # so the connect-side recency guard still falls through to the
      # silent branch — a deliberate trade-off. What we verify here
      # is the `disconnected?: true` and `connected_at` fields are
      # restored.
      state =
        :sys.get_state(DtuApp.Notifications.DtuConnection)

      assert state[dtu.id].disconnected? == true
      assert state[dtu.id].connected_at == connected_at
    end

    test "a disconnect event writes a row to dtu_connection_states" do
      user = user_fixture(%{notify_dtu_connection: true})
      dtu = device_fixture(user, %{name: "Persist DTU"})
      touch_last_seen!(dtu, -60)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_disconnected, "client_persist", dtu.id}
      )

      # Wait for the async `persist_marker/2` write to land. The
      # DB upsert happens on the producer's GenServer process.
      Process.sleep(100)

      assert %DtuApp.Notifications.DtuConnectionState{disconnected: true} =
               DtuApp.Repo.get(DtuApp.Notifications.DtuConnectionState, dtu.id)
    end

    test "a connect event clears the row's disconnected flag" do
      # Mirror of the persist-on-disconnect test. After a
      # `:dtu_connected` event clears the in-memory marker, the DB
      # row should also flip `disconnected` back to `false` so a
      # subsequent restart doesn't fire `:back_online` for a
      # device that was already on the broker.
      user = user_fixture(%{notify_dtu_connection: true})
      dtu = device_fixture(user, %{name: "Reset DTU"})

      touch_last_seen!(dtu, -60)

      # Disconnect (sets marker).
      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_disconnected, "client_reset", dtu.id}
      )

      Process.sleep(50)

      assert %DtuApp.Notifications.DtuConnectionState{disconnected: true} =
               DtuApp.Repo.get(DtuApp.Notifications.DtuConnectionState, dtu.id)

      # Reconnect (clears marker).
      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_connected, "client_reset", dtu.id}
      )

      # Wait for the async `persist_marker/2` write to land. Same
      # rationale as the disconnect half above.
      Process.sleep(100)

      assert %DtuApp.Notifications.DtuConnectionState{disconnected: false} =
               DtuApp.Repo.get(DtuApp.Notifications.DtuConnectionState, dtu.id)
    end
  end

  describe "duplicate disconnect suppression" do
    # The user-facing bug this gates: a burst of broker
    # `:dtu_disconnected` events for the same device, arriving within
    # seconds with no intervening `:dtu_connected`, used to fire
    # `:went_offline` on every single one ("dozens of dtu-is-offline
    # pushes in a row"). The fix is the `not was_disconnected?` gate
    # added to the disconnect handler — fires once per offline period,
    # silent on duplicates within the same period. Mirrors the
    # connect-side `disconnected?: true` gate added in PR #167.

    test "a burst of duplicate :dtu_disconnected events fires :went_offline exactly once" do
      user = user_fixture(%{notify_dtu_connection: true})
      dtu = device_fixture(user, %{name: "Bursty DTU"})

      seed_connected_at!(dtu.id, DateTime.add(Time.utc_now_usec(), -600, :second))
      touch_last_seen!(dtu, -60)

      :ok = Notifications.subscribe(user.id)

      # Five broker disconnect events within ~50 ms — the real-world
      # "broker disconnect storm" pattern reported by users.
      for i <- 1..5 do
        Phoenix.PubSub.broadcast(
          DtuApp.PubSub,
          @presence_topic,
          {:dtu_disconnected, "client_#{i}", dtu.id}
        )
      end

      # The first event transitions online → offline and fires. The
      # remaining four are silent (was_disconnected? was already true
      # when their handlers ran). Drain the mailbox before asserting —
      # `refute_receive` would deadlock waiting for a second message
      # that never comes.
      assert_receive {:notification, payload}, 1_000
      assert payload.event == "dtu_connection"
      assert payload.title =~ "offline"

      refute_receive {:notification, _}, 200
    end

    test ":dtu_disconnected → :dtu_connected → :dtu_disconnected fires twice (one per offline period)" do
      # The duplicate-suppression gate must NOT prevent the SECOND
      # offline notification after a real reconnect cycle. The
      # `:dtu_connected` handler clears the marker, so the next
      # `:dtu_disconnected` observes `was_disconnected? == false` again
      # and fires normally. Pin this so a future fix doesn't
      # over-correct and silence legitimate transitions.
      user = user_fixture(%{notify_dtu_connection: true})
      dtu = device_fixture(user, %{name: "Reconnect DTU"})

      seed_connected_at!(dtu.id, DateTime.add(Time.utc_now_usec(), -600, :second))
      touch_last_seen!(dtu, -60)

      :ok = Notifications.subscribe(user.id)

      # First offline period — should fire.
      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_disconnected, "client_offline_1", dtu.id}
      )

      assert_receive {:notification, payload1}, 1_000
      assert payload1.title =~ "offline"

      # Reconnect — clears the marker. The producer stamps
      # `connected_at` at the current time on connect; bump it
      # back to >5 min ago so the second disconnect's C1
      # (`prior_uptime?`) gate still passes. Models "the device
      # was online long enough to be worth a second offline
      # notification."
      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_connected, "client_reconnect", dtu.id}
      )

      :sys.replace_state(DtuConnection, fn state ->
        Map.update!(
          state,
          dtu.id,
          &Map.put(&1, :connected_at, DateTime.add(Time.utc_now_usec(), -600, :second))
        )
      end)

      # Back-online fires because we observed a disconnect previously.
      assert_receive {:notification, payload2}, 1_000
      assert payload2.title =~ "back online"

      # Second offline period — should fire again, since the marker
      # was cleared by the reconnect above.
      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_disconnected, "client_offline_2", dtu.id}
      )

      assert_receive {:notification, payload3}, 1_000
      assert payload3.title =~ "offline"
    end

    test "a persisted disconnected: true row suppresses the first :dtu_disconnected after restart" do
      # Mirrors the connect-side restart-recovery test in
      # `persistent disconnect marker (DB-backed)`. After a restart,
      # `init/1` re-hydrates the in-memory cache with
      # `disconnected?: true` from the DB row. The first
      # `:dtu_disconnected` event after the restart then sees
      # `was_disconnected? == true` and stays silent — the user
      # doesn't get a duplicate "your inverter has gone offline"
      # notification for a device they already knew was offline.
      user = user_fixture(%{notify_dtu_connection: true})
      dtu = device_fixture(user, %{name: "Persisted Offline DTU"})

      # Simulate "the producer crashed while knowing this device was
      # offline" — write the row directly.
      connected_at = DateTime.add(Time.utc_now_usec(), -600, :second)

      {:ok, _} =
        %DtuApp.Notifications.DtuConnectionState{}
        |> DtuApp.Notifications.DtuConnectionState.changeset(%{
          device_id: dtu.id,
          disconnected: true,
          connected_at: connected_at
        })
        |> DtuApp.Repo.insert(on_conflict: :raise)

      touch_last_seen!(dtu, -60)

      # Restart the producer — `init/1` re-hydrates the marker.
      :ok = stop_supervised(DtuApp.Notifications.DtuConnection)
      :ok = wait_for_unregister(DtuApp.Notifications.DtuConnection, 100)
      pid = start_supervised!({DtuApp.Notifications.DtuConnection, []})
      Ecto.Adapters.SQL.Sandbox.allow(DtuApp.Repo, self(), pid)

      # Sanity-check the hydration picked up the marker.
      state = :sys.get_state(DtuApp.Notifications.DtuConnection)
      assert state[dtu.id].disconnected? == true

      :ok = Notifications.subscribe(user.id)

      # First disconnect after restart — silent. The prior marker says
      # "we already knew this device was offline", so the duplicate
      # gate fires the suppression. (Without the new gate, this would
      # fire — the user's original "dozens of notifications" report.)
      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_disconnected, "client_post_restart", dtu.id}
      )

      refute_receive {:notification, _}, 300
    end
  end

  describe "user locale propagation" do
    # The producer runs as a long-lived GenServer without a request
    # context, so a bare `gettext/1` would default to whatever
    # Gettext was initialized with (≈ "en") regardless of the user's
    # preference. `fire/3` wraps the gettext calls in
    # `Gettext.with_locale/2` against `user.locale` — these tests
    # pin that the in-page PubSub broadcast (and the title/body
    # within it) lands in the user's language.
    #
    # The assertions are locale-aware: rather than pin a specific
    # translation string (which the catalog may legitimately change),
    # we compare the rendered title against `Gettext.gettext/2`
    # queried directly with the same locale. If the catalog later
    # gets a real German translation, the test follows it. If the
    # producer ever regresses to using the wrong locale, the two
    # values diverge and the test fails.
    #
    # `user_fixture/1` only casts `:email` (via register_user/1),
    # so passing `locale: "de"` through the fixture is silently
    # dropped. `with_locale_user/2` updates the locale AFTER the
    # user is registered, so the producer's `safe_get_user/1`
    # returns a User with the requested locale.

    test "a German user's disconnect title matches the German catalog" do
      user = with_locale_user(user_fixture(%{notify_dtu_connection: true}), "de")
      dtu = device_fixture(user, %{name: "Mein Dach"})
      seed_connected_at!(dtu.id, DateTime.add(Time.utc_now_usec(), -600, :second))
      touch_last_seen!(dtu, -60)

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_disconnected, "client_loc", dtu.id}
      )

      assert_receive {:notification, payload}, 1_000

      expected_title =
        Gettext.with_locale(DtuAppWeb.Gettext, "de", fn ->
          Gettext.gettext(DtuAppWeb.Gettext, "DTU went offline")
        end)

      assert payload.title == expected_title
      assert is_list(payload.body)
      assert Enum.any?(payload.body, &(&1 =~ "Mein Dach"))
    end

    test "a French user's disconnect title matches the French catalog" do
      user = with_locale_user(user_fixture(%{notify_dtu_connection: true}), "fr")
      dtu = device_fixture(user, %{name: "Mon toit"})
      seed_connected_at!(dtu.id, DateTime.add(Time.utc_now_usec(), -600, :second))
      touch_last_seen!(dtu, -60)

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_disconnected, "client_loc", dtu.id}
      )

      assert_receive {:notification, payload}, 1_000

      expected_title =
        Gettext.with_locale(DtuAppWeb.Gettext, "fr", fn ->
          Gettext.gettext(DtuAppWeb.Gettext, "DTU went offline")
        end)

      assert payload.title == expected_title
    end

    test "a French user's body uses the French translation for %{name} interpolation" do
      user = with_locale_user(user_fixture(%{notify_dtu_connection: true}), "fr")
      dtu = device_fixture(user, %{name: "Mon toit"})
      seed_connected_at!(dtu.id, DateTime.add(Time.utc_now_usec(), -600, :second))
      touch_last_seen!(dtu, -60)

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_disconnected, "client_loc", dtu.id}
      )

      assert_receive {:notification, payload}, 1_000

      expected_body =
        Gettext.with_locale(DtuAppWeb.Gettext, "fr", fn ->
          Gettext.gettext(
            DtuAppWeb.Gettext,
            "Your inverter %{name} has gone offline.",
            name: "Mon toit"
          )
        end)

      # Body is a list of paragraphs (dispatcher email/layout
      # contract). The single producer-rendered paragraph should
      # land in the first element.
      assert payload.body == [expected_body]
    end

    test "an English user's notification uses the source (English) string" do
      # The English catalog has no translations (every msgstr is
      # empty), so gettext returns the msgid verbatim. The default
      # user already has locale: "en", so this asserts the no-op
      # path stays intact.
      user = user_fixture(%{notify_dtu_connection: true})
      dtu = device_fixture(user, %{name: "Roof inverter"})
      seed_connected_at!(dtu.id, DateTime.add(Time.utc_now_usec(), -600, :second))
      touch_last_seen!(dtu, -60)

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_disconnected, "client_loc", dtu.id}
      )

      assert_receive {:notification, payload}, 1_000

      assert payload.title == "DTU went offline"
      assert is_list(payload.body)
      assert Enum.any?(payload.body, &(&1 =~ "Roof inverter"))
    end
  end

  # `user_fixture/1` only persists `:email` (via the auth changeset),
  # so passing `locale:` through it is a no-op. Update the user
  # directly via the `settings_changeset` so the producer's
  # `safe_get_user/1` returns a User with the requested locale.
  defp with_locale_user(user, locale) do
    {:ok, updated} =
      DtuApp.Accounts.update_user_settings(user, %{"locale" => locale})

    updated
  end

  # Poll the process registry for `name` to be unregistered. Returns
  # `:ok` as soon as `Process.whereis/1` returns `nil`, or `:timeout`
  # after `max_ms`. The named-registry unregister is asynchronous
  # with respect to `GenServer.stop/1`'s return, so a fixed sleep
  # races the supervisor's `start_child` and produces a flaky
  # `{:already_started, …}` failure.
  defp wait_for_unregister(name, max_ms) do
    deadline = System.monotonic_time(:millisecond) + max_ms
    poll_unregister(name, deadline)
  end

  defp poll_unregister(name, deadline) do
    case Process.whereis(name) do
      nil ->
        :ok

      _pid ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(5)
          poll_unregister(name, deadline)
        end
    end
  end
end
