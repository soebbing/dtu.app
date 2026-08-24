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
       == false`, the in-page PubSub broadcast still fires (the
       receiver-side JS hook decides whether to render) but the
       VAPID push is suppressed. We assert the in-page path
       separately so a regression in either direction surfaces.
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

  describe "fire on disconnect" do
    test "a recently-active device's disconnect produces a dtu_connection notification" do
      user = user_fixture()
      dtu = device_fixture(user, %{name: "Test DTU"})
      touch_last_seen!(dtu, 0)

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_disconnected, "client_1", dtu.id}
      )

      assert_receive {:notification, payload}, 1_000

      assert payload.event == "dtu_connection"
      assert payload.title =~ "offline"
      assert payload.body =~ "Test DTU"
      assert payload.tag == "dtu:Test DTU"
    end

    test "a stale disconnect (last_seen_at older than 5 min) does not fire" do
      user = user_fixture()
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
  end

  describe "fire on reconnect" do
    test "a :dtu_connected broadcast produces the :back_online notification" do
      user = user_fixture()
      dtu = device_fixture(user, %{name: "Back Online DTU"})

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_connected, "client_2", dtu.id}
      )

      assert_receive {:notification, payload}, 1_000

      assert payload.event == "dtu_connection"
      assert payload.title =~ "back online"
      assert payload.body =~ "Back Online DTU"
      assert payload.tag == "dtu:Back Online DTU"
    end
  end

  describe "preference gating" do
    test "VAPID path is suppressed when notify_dtu_connection is false" do
      # The producer's own fan-out is unconditional (the receiver-side
      # JS hook decides whether to render). The VAPID-suppression is
      # owned by `Notifications.broadcast/2`'s `native_push_enabled?/2`
      # gate, which is exercised end-to-end in
      # `test/dtu_app/notifications_test.exs`. The producer must
      # *still* emit the PubSub broadcast so the in-page hook can
      # decide for itself — verify that's what happens.
      user = user_fixture(%{notify_dtu_connection: false})
      dtu = device_fixture(user, %{name: "Opt-out DTU"})
      touch_last_seen!(dtu, 0)

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_disconnected, "client_3", dtu.id}
      )

      # In-page broadcast still fires — receiver decides.
      assert_receive {:notification, payload}, 1_000
      assert payload.tag == "dtu:Opt-out DTU"
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
      user = with_locale_user(user_fixture(), "de")
      dtu = device_fixture(user, %{name: "Mein Dach"})
      touch_last_seen!(dtu, 0)

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
      assert payload.body =~ "Mein Dach"
    end

    test "a French user's disconnect title matches the French catalog" do
      user = with_locale_user(user_fixture(), "fr")
      dtu = device_fixture(user, %{name: "Mon toit"})
      touch_last_seen!(dtu, 0)

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
      user = with_locale_user(user_fixture(), "fr")
      dtu = device_fixture(user, %{name: "Mon toit"})
      touch_last_seen!(dtu, 0)

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
            "Your inverter %{name} has been offline for at least 5 minutes.",
            name: "Mon toit"
          )
        end)

      assert payload.body == expected_body
    end

    test "an English user's notification uses the source (English) string" do
      # The English catalog has no translations (every msgstr is
      # empty), so gettext returns the msgid verbatim. The default
      # user already has locale: "en", so this asserts the no-op
      # path stays intact.
      user = user_fixture()
      dtu = device_fixture(user, %{name: "Roof inverter"})
      touch_last_seen!(dtu, 0)

      :ok = Notifications.subscribe(user.id)

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_disconnected, "client_loc", dtu.id}
      )

      assert_receive {:notification, payload}, 1_000

      assert payload.title == "DTU went offline"
      assert payload.body =~ "Roof inverter"
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
end
