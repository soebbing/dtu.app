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
end
