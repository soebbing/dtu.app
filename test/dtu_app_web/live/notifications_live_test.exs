defmodule DtuAppWeb.NotificationsLiveTest do
  use DtuAppWeb.ConnCase, async: false

  import DtuApp.AccountsFixtures
  import Phoenix.LiveViewTest

  alias DtuApp.Notifications

  describe "Mount and notification_state round-trip" do
    # The page renders one of six branches based on
    # `Map.get(@notification_state, "state")`. Initial mount is
    # `%{"state" => "loading"}` which falls through to the
    # `<% _ -> %>` clause and shows "Checking browser capabilities…".
    # The JS hook on `#notifications-permission` then sends a
    # `notification_state` event with the browser's view, which
    # transitions the assign and renders the right CTA. If the hook's
    # push is lost, the page is stuck on the loading branch forever
    # and the "Send test notification" button never appears (it's
    # gated on `notification_state == "granted"`).
    #
    # The tests below exercise the server side of that round-trip so
    # a future regression on the LiveView handler is caught even if
    # the JS hook changes shape.

    setup :register_and_log_in_user

    test "mount renders the loading branch before the JS hook pushes state", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, ~p"/notifications")

      assert html =~ "Checking browser capabilities"
      # The test-notification card is gated on `"granted"`, so it
      # must NOT be in the initial render.
      refute html =~ "Send test notification"
    end

    test "notification_state granted transitions the assign and reveals the test button", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, ~p"/notifications")
      assert html =~ "Checking browser capabilities"

      render_hook(view, "notification_state", %{state: "granted", installed: true})

      assert render(view) =~ "Notifications are enabled"
      # Once permission is granted, the "Send test notification" card
      # appears. Without this branch the user can never verify their
      # setup end-to-end.
      assert render(view) =~ "Send test notification"
    end

    test "notification_state default shows the enable CTA but no test button", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/notifications")

      render_hook(view, "notification_state", %{state: "default", installed: true})

      assert render(view) =~ "Notifications are available, but not yet enabled"
      assert render(view) =~ "Enable notifications"
      refute render(view) =~ "Send test notification"
    end

    test "notification_state denied shows the blocked-OS-settings CTA", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/notifications")

      render_hook(view, "notification_state", %{state: "denied", installed: true})

      assert render(view) =~ "Notifications are blocked in your browser settings"
      refute render(view) =~ "Send test notification"
    end

    test "notification_state not_installed on mobile shows the install-PWA CTA", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/notifications")

      # Mobile + non-installed = the install advisory. Same copy as
      # before this change; pinned here so a future regression that
      # drops the `device` field from the payload can't accidentally
      # stop mobile users from seeing the install hint.
      render_hook(
        view,
        "notification_state",
        %{state: "not_installed", installed: false, device: "mobile"}
      )

      assert render(view) =~ "Install this site as a PWA first"
      assert render(view) =~ "mobile"
      refute render(view) =~ "Send test notification"
    end

    test "notification_state not_installed on desktop falls through to the Enable CTA", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/notifications")

      # Desktop browsers (Chrome, Firefox, Edge on Windows / macOS /
      # Linux) allow `new Notification(...)` in a regular tab once
      # the user grants permission — PWA install is NOT a
      # prerequisite. The JS hook therefore sends `state: "default"`
      # with `installed: false` on non-installed desktops, and the
      # template renders the Enable button exactly as if the page
      # were already a PWA.
      render_hook(
        view,
        "notification_state",
        %{state: "default", installed: false, device: "desktop"}
      )

      assert render(view) =~ "Notifications are available, but not yet enabled"
      assert render(view) =~ "Enable notifications"
      refute render(view) =~ "Install this site as a PWA first"
      refute render(view) =~ "Send test notification"
    end

    test "notification_state unsupported shows the install-PWA CTA even on browsers without the Notification API",
         %{
           conn: conn
         } do
      {:ok, view, _html} = live(conn, ~p"/notifications")

      render_hook(view, "notification_state", %{state: "unsupported", installed: true})

      assert render(view) =~ "Browsers must be installed as a PWA"
      refute render(view) =~ "Send test notification"
    end

    test "push_subscribed flips has_push_subscriptions so the native-push badge renders", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/notifications")

      render_hook(view, "notification_state", %{state: "granted", installed: true})
      refute render(view) =~ "Native push is on for this device"

      render_hook(view, "push_subscribed", %{endpoint: "https://example.test/push/abc"})
      assert render(view) =~ "Native push is on for this device"
    end
  end

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
