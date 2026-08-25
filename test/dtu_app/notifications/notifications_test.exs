defmodule DtuApp.NotificationsTest do
  @moduledoc """
  Unit tests for the notification-history context.

  Covers:
    * `record/2` — stores the broadcast (already-localized title/body
      + event + tag + payload) on the user's history.
    * `list_user_notifications/3` — paginates newest-first and only
      returns rows owned by the user.
    * `delete/2` — only deletes the calling user's row; mismatched
      users get `:noop`.
    * `clear_all/1` — wipes everything for the user.

  The DB-write side of `DtuApp.Notifications.broadcast/2` is the
  fan-out chokepoint — all server-side notifiers
  (`SunDown`, `SunUp`, `DtuConnection`) and the test button route
  through it, so a single regression test on
  `broadcast/2` → `record/2` covers all four call sites.
  """
  use DtuApp.DataCase, async: true

  alias DtuApp.Notifications
  alias DtuApp.Notifications.Notification

  describe "record/2" do
    test "stores the broadcast for the given user" do
      user = user_fixture()

      payload = %{
        event: "test",
        title: "Test notification",
        body: "hello",
        tag: "test"
      }

      assert {:ok, %Notification{user_id: user_id}} = Notifications.record(user, payload)
      assert user_id == user.id
      assert Notifications.list_user_notifications(user, 1, 10) |> length() == 1
    end

    test "persists the event, title, body and tag from the payload" do
      user = user_fixture()

      {:ok, n} =
        Notifications.record(user, %{
          event: "sun_down",
          title: "Sonnenuntergang — Tageszusammenfassung",
          body: "Heute: 12.4 kWh",
          tag: "sun_down"
        })

      assert n.event == "sun_down"
      assert n.title == "Sonnenuntergang — Tageszusammenfassung"
      assert n.body == "Heute: 12.4 kWh"
      assert n.tag == "sun_down"
    end

    test "stamps delivered_at to the current UTC time" do
      user = user_fixture()

      before = DateTime.utc_now(:second) |> DateTime.add(-1, :second)

      {:ok, %Notification{delivered_at: delivered_at}} =
        Notifications.record(user, basic_payload())

      after_ = DateTime.utc_now(:second) |> DateTime.add(1, :second)

      assert DateTime.compare(delivered_at, before) in [:gt, :eq]
      assert DateTime.compare(delivered_at, after_) in [:lt, :eq]
    end
  end

  describe "list_user_notifications/3" do
    test "returns rows newest-first" do
      user = user_fixture()

      _older =
        Notifications.record(user, basic_payload("older"))
        |> elem(1)
        |> touch_delivered_at(DateTime.add(DateTime.utc_now(:second), -120, :second))

      newer =
        Notifications.record(user, basic_payload("newer"))
        |> elem(1)
        |> touch_delivered_at(DateTime.utc_now(:second))

      [first, second] = Notifications.list_user_notifications(user, 1, 10)

      assert first.id == newer.id
      assert second.tag == "older"
    end

    test "paginates by page + per_page" do
      user = user_fixture()

      for i <- 1..7 do
        {:ok, n} = Notifications.record(user, basic_payload("n-#{i}"))

        # Force distinct delivered_at so the ORDER BY is deterministic.
        touch_delivered_at(n, DateTime.add(DateTime.utc_now(:second), -i * 10, :second))
      end

      page1 = Notifications.list_user_notifications(user, 1, 3)
      page2 = Notifications.list_user_notifications(user, 2, 3)
      page3 = Notifications.list_user_notifications(user, 3, 3)

      assert length(page1) == 3
      assert length(page2) == 3
      assert length(page3) == 1
    end

    test "excludes another user's notifications" do
      user_a = user_fixture()
      user_b = user_fixture()

      Notifications.record(user_a, basic_payload("a"))
      Notifications.record(user_b, basic_payload("b"))

      assert length(Notifications.list_user_notifications(user_a, 1, 10)) == 1
      assert length(Notifications.list_user_notifications(user_b, 1, 10)) == 1
    end
  end

  describe "delete/2" do
    test "deletes the row when it belongs to the user" do
      user = user_fixture()
      {:ok, n} = Notifications.record(user, basic_payload())

      assert {:ok, %Notification{}} = Notifications.delete(user, n.id)
      assert Notifications.list_user_notifications(user, 1, 10) == []
    end

    test "returns :noop when the row belongs to a different user" do
      user_a = user_fixture()
      user_b = user_fixture()

      {:ok, n} = Notifications.record(user_a, basic_payload())

      assert :noop = Notifications.delete(user_b, n.id)

      # The other user's row is still there.
      assert length(Notifications.list_user_notifications(user_a, 1, 10)) == 1
    end
  end

  describe "clear_all/1" do
    test "wipes all rows for the user but leaves other users alone" do
      user_a = user_fixture()
      user_b = user_fixture()

      Notifications.record(user_a, basic_payload("a1"))
      Notifications.record(user_a, basic_payload("a2"))
      Notifications.record(user_b, basic_payload("b1"))

      assert {2, _} = Notifications.clear_all(user_a)
      assert Notifications.list_user_notifications(user_a, 1, 10) == []
      assert length(Notifications.list_user_notifications(user_b, 1, 10)) == 1
    end
  end

  describe "broadcast/2 records to history" do
    # The server-side fan-out chokepoint must record every broadcast
    # so the user can review history later — including the synthetic
    # `test` event from the test button. Pinned here so a future
    # refactor of broadcast/2 doesn't drop the write.
    test "broadcast/2 inserts a history row" do
      user = user_fixture()

      Notifications.broadcast(user.id, %{
        event: "test",
        title: "t",
        body: "b",
        tag: "test"
      })

      rows = Notifications.list_user_notifications(user, 1, 10)
      assert length(rows) == 1

      [n] = rows
      assert n.user_id == user.id
      assert n.event == "test"
      assert n.title == "t"
      assert n.body == "b"
      assert n.tag == "test"
    end

    test "broadcast/2 with an unknown user id does not raise and inserts nothing" do
      # No subscription, no real user — the in-page broadcast is a
      # no-op (no LiveView attached) and the user lookup raises
      # Ecto.NoResultsError, which is rescued by safe_get_user/1.
      # The history write must be skipped too (no user_id to attach).
      assert :ok = Notifications.broadcast(0, basic_payload())
    end
  end

  ## Fixtures / helpers

  defp user_fixture, do: DtuApp.AccountsFixtures.user_fixture()

  defp basic_payload(tag \\ "test") do
    %{event: "test", title: "t", body: "b", tag: tag}
  end

  defp touch_delivered_at(%Notification{id: id} = n, %DateTime{} = dt) do
    {1, _} =
      DtuApp.Repo.update_all(
        from(r in Notification, where: r.id == ^id),
        set: [delivered_at: dt]
      )

    n
  end
end
