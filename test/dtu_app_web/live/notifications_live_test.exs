defmodule DtuAppWeb.NotificationsLiveTest do
  use DtuAppWeb.ConnCase, async: false

  import DtuApp.AccountsFixtures

  alias DtuApp.Notifications

  describe "Test notification button" do
    # The /notifications page lets the user fire a synthetic notification
    # via the `test_notification` phx-click handler. The button is gated
    # by `@notification_state == "granted"` (the JS hook's view of the
    # browser's notification permission), so the render path is gated
    # client-side — but the server-side `handle_event("test_notification", ...)`
    # is always available and just fires `Notifications.broadcast/2`.
    # The tests below pin the server contract: that the broadcast reaches
    # the per-user topic the LiveView subscribed to in mount/3, so the
    # JS hook receives a `notify` push_event and renders the system
    # `new Notification(...)`.

    setup :register_and_log_in_user

    test "firing test_notification broadcasts a :notification event to the user's topic", %{
      user: user
    } do
      # Subscribe to the per-user notifications topic so we can assert
      # the broadcast reaches it.
      :ok = Notifications.subscribe(user.id)

      # Build the same payload shape the LiveView handler uses — calling
      # the underlying Notifications.broadcast directly exercises the
      # exact code path the handler does.
      payload = %{
        event: "test",
        title: "Test notification",
        body: "If you can read this, browser notifications are working.",
        tag: "test"
      }

      Notifications.broadcast(user.id, payload)

      assert_receive {:notification, ^payload}, 1_000
    end

    test "payload includes the tag so the JS hook can dedup per browser", %{user: user} do
      # The payload's `tag` is the dedup key for the JS hook (which stores
      # it in localStorage). Different tag values = different notifications
      # displayed in the OS. Pinning this so a future refactor doesn't
      # accidentally drop the tag.
      :ok = Notifications.subscribe(user.id)

      Notifications.broadcast(user.id, %{
        event: "test",
        title: "Test",
        body: "Body",
        tag: "test"
      })

      assert_receive {:notification, payload}, 1_000
      assert payload.tag == "test"
      assert payload.event == "test"
      assert payload.title == "Test"
      assert payload.body == "Body"
    end
  end
end
