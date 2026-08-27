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
    # push is lost, the page is stuck on the loading branch forever;
    # the "Send test notification" button still appears for users
    # with `notification_channel in ["email", "both"]` (because the
    # dispatcher's email path is independent of browser permission).
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
      # The test-notification card is gated on `notification_state_granted?
      # || email_capable?`. `register_and_log_in_user` leaves
      # `notification_channel` at the schema default ("push"), and the
      # initial mount renders `notification_state = "loading"` (not
      # `"granted"`), so neither branch fires — the card must NOT be
      # in the initial render.
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

    test "notification_state default + non-installed desktop renders the Enable CTA", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/notifications")

      # A desktop user in a regular (non-PWA) tab visits the page for
      # the first time. `Notification.permission === "default"` — the
      # user has never been asked. The JS hook falls through to the
      # permission check (now unconditional on desktop after the
      # auto-detect refactor) and reports `state: "default"` with
      # `installed: false, device: "desktop"`. The template renders
      # the Enable button so the user can grant permission in one
      # click. Pre-refactor this payload was also fired for
      # already-granted desktop users (which was the bug — they saw
      # the Enable CTA instead of the test button). Now it's only
      # fired when permission is genuinely `"default"`.
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

    test "notification_state granted on non-installed desktop renders the test button (auto-detect)",
         %{
           conn: conn
         } do
      {:ok, view, _html} = live(conn, ~p"/notifications")

      # A desktop user who previously granted notification permission
      # in a regular (non-PWA) tab visits the page. `Notification.permission`
      # already says `"granted"` — no need to click Enable. The JS
      # hook reads the permission state regardless of `installed` on
      # desktop (only mobile keeps the install-required gate, because
      # iOS Safari only fires notifications from an installed PWA)
      # and pushes `{state: "granted", installed: false, device:
      # "desktop"}`. The template renders the granted branch with
      # the test button, so the user can verify their setup without
      # re-prompting the OS. This is the auto-detect path the
      # pre-refactor short-circuit was hiding.
      render_hook(
        view,
        "notification_state",
        %{state: "granted", installed: false, device: "desktop"}
      )

      assert render(view) =~ "Notifications are enabled"
      assert render(view) =~ "Send test notification"
      # No push subscription was created, so the desktop hint about
      # keeping the tab open should render (the user opted into
      # tab-open delivery by NOT installing the PWA).
      assert render(view) =~ "Keep this tab open"
      refute render(view) =~ "Notifications are available, but not yet enabled"
      refute render(view) =~ "Enable notifications"
      refute render(view) =~ "Install this site as a PWA first"
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

    test "notification_state granted on non-installed mobile shows the iOS-tab hint, not the misleading 'native push is on' badge",
         %{
           conn: conn,
           scope: scope
         } do
      # Pre-fix the granted branch unconditionally rendered "Native
      # push is on for this device" whenever `has_push_subscriptions`
      # was true. On iOS the push subscription lives on the server
      # (granted from the home-screen PWA), so the badge is
      # technically correct *and* misleading: open the same site in
      # a regular Safari tab and `new Notification(...)` silently
      # no-ops — only the home-screen app fires OS notifications.
      # The hook now also pushes `installed` so the template can
      # surface this edge case.
      DtuApp.PushSubscriptions.upsert(scope.user, %{
        "endpoint" => "https://fcm.googleapis.com/fcm/send/abc",
        "p256dh" => "BNcRdreALRFXTkOOUHK1",
        "auth" => "tBHItJI5svbpez7KI4CCXg"
      })

      {:ok, view, _html} = live(conn, ~p"/notifications")

      render_hook(
        view,
        "notification_state",
        %{state: "granted", installed: false, device: "mobile"}
      )

      assert render(view) =~ "Notifications are enabled"
      # The misleading "Native push is on" line is replaced with
      # the iOS-tab hint that explains where notifications actually
      # fire from.
      assert render(view) =~ "home-screen app"
      refute render(view) =~ "Native push is on for this device"
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

  describe "Test notification panel — channel-aware gating" do
    # The "Send test notification" panel is now visible whenever the
    # user has at least one working delivery path:
    #
    #   * browser permission `granted` → fires a system notification
    #     (existing behaviour);
    #   * `notification_channel in ["email", "both"]` → the dispatcher's
    #     email path delivers the test, even with no browser permission.
    #
    # Push-only users without browser permission still see the panel
    # hidden — there's no other channel that can deliver the test for
    # them, so showing it would be a click that silently no-ops.
    setup :register_and_log_in_user

    test "channel=email + permission=default reveals the panel", %{conn: conn, user: user} do
      import Ecto.Query

      _ =
        DtuApp.Repo.update_all(
          from(u in DtuApp.Accounts.User, where: u.id == ^user.id),
          set: [notification_channel: "email"]
        )

      {:ok, view, _html} = live(conn, ~p"/notifications")
      # `default` is the JS hook's value when the user hasn't responded
      # to the permission prompt yet — the typical "I clicked the page
      # but never said yes/no" state.
      render_hook(view, "notification_state", %{state: "default", installed: true})

      assert render(view) =~ "Send test notification"
    end

    test "channel=both + permission=denied reveals the panel", %{conn: conn, user: user} do
      import Ecto.Query

      _ =
        DtuApp.Repo.update_all(
          from(u in DtuApp.Accounts.User, where: u.id == ^user.id),
          set: [notification_channel: "both"]
        )

      {:ok, view, _html} = live(conn, ~p"/notifications")
      render_hook(view, "notification_state", %{state: "denied", installed: true})

      # `denied` means the user explicitly rejected the OS prompt — the
      # browser path is gone for good. With "both" channel the email
      # path is still available, so the panel must show.
      assert render(view) =~ "Send test notification"
    end

    test "channel=push + permission=default hides the panel (no working path)", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/notifications")
      render_hook(view, "notification_state", %{state: "default", installed: true})

      refute render(view) =~ "Send test notification"
    end

    test "channel=push + permission=granted still reveals the panel", %{conn: conn} do
      # Existing behaviour preserved — push-only user with permission
      # granted sees the panel and the click fires a system notification.
      {:ok, view, _html} = live(conn, ~p"/notifications")
      render_hook(view, "notification_state", %{state: "granted", installed: true})

      assert render(view) =~ "Send test notification"
    end
  end

  describe "Channel-chip selector" do
    # Renders the "Deliver via: Notification | Email | Both" segmented
    # control beneath the three notification checkboxes. The form
    # already accepts `notification_channel` via the extended
    # `notification_settings_changeset/2` (Task 1); these tests pin
    # the server-rendered contract so a future regression on the
    # LiveView form doesn't silently drop the new field.

    setup :register_and_log_in_user

    test "renders three radio chips with the channel labels", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/notifications")

      assert html =~ "Deliver via"
      assert html =~ "Pick how you want to receive the notifications above"
      # Each chip's visible label is the radio's sibling `<span>`.
      assert html =~ ~s(value="push")
      assert html =~ ~s(value="email")
      assert html =~ ~s(value="both")
    end

    test "default notification_channel is push (the schema default)", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/notifications")

      # The push chip is the schema default; the rendered `checked`
      # attribute must reflect it so the form opens with the right
      # selection on first visit.
      assert html =~ ~s(name="user\[notification_channel\]")
    end

    test "email channel renders the amber warning when the user is not confirmed", %{
      conn: conn,
      user: user
    } do
      # `user_fixture/0` (used by `register_and_log_in_user`) confirms
      # the user via the magic-link path, so we have to clear
      # `confirmed_at` via the raw repo to reach the unconfirmed
      # branch of the template. Same with `notification_channel`:
      # the save handler rebuilds the form from the in-memory user
      # struct (not the freshly-returned DB struct), so a
      # `render_submit/1` round-trip would not change the form's
      # `:notification_channel` value. Seed both fields directly.
      import Ecto.Query

      _ =
        DtuApp.Repo.update_all(
          from(u in DtuApp.Accounts.User, where: u.id == ^user.id),
          set: [confirmed_at: nil, notification_channel: "email"]
        )

      {:ok, _view, html} = live(conn, ~p"/notifications")

      # `=~` does not decode HTML entities, so the apostrophe in
      # "isn't" comes through as `&#39;`. Use a substring that
      # doesn't cross the apostrophe.
      assert html =~ "your email address isn"
      assert html =~ "Visit account settings"
    end
  end

  describe "Test notification button" do
    # The /notifications page lets the user fire a synthetic notification
    # via the `test_notification` phx-click handler. The button is gated
    # by `notification_state_granted? || email_capable?` (browser
    # permission OR `notification_channel in ["email", "both"]`),
    # so the render path is gated client-side — but the server-side
    # `handle_event("test_notification", ...)` is always available and
    # just fires `Notifications.broadcast/2` (which routes via the
    # dispatcher's normal channel logic: push for "push"/"both", email
    # for "email"/"both"). The tests below pin the server contract: that
    # the broadcast reaches the per-user topic the LiveView subscribed
    # to in mount/3, so the JS hook receives a `notify` push_event and
    # renders the system `new Notification(...)`.

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

  describe "Notification history section" do
    # The /notifications page persists a row per broadcast via
    # `DtuApp.Notifications.broadcast/2` and renders them in a
    # paginated list at the bottom of the page. Tests below cover:
    #   * Empty-state copy when the user has no history yet.
    #   * Per-row rendering (title / body / event tag / relative time
    #     / delete button).
    #   * Pagination via `set_history_page` (>50 rows).
    #   * Per-row delete handler (`delete_notification`).
    #   * Clear-all handler (`clear_all_notifications`).
    #   * Live-refresh: a `broadcast/2` that lands while the page is
    #     open is picked up without a manual reload.
    setup :register_and_log_in_user

    test "renders the empty-state copy when no notifications exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/notifications")

      assert html =~ "Recent notifications"
      assert html =~ "No notifications yet"
    end

    test "renders existing notifications with title, body and event tag", %{
      user: user,
      conn: conn
    } do
      {:ok, n} =
        Notifications.record(user, %{
          event: "sun_down",
          title: "Sun's down",
          body: "Today: 12.4 kWh",
          tag: "sun_down",
          payload: %{}
        })

      {:ok, _view, html} = live(conn, ~p"/notifications")

      assert html =~ "Recent notifications"
      assert html =~ "Sun&#39;s down"
      assert html =~ "Today: 12.4 kWh"
      assert html =~ "sun_down"
      assert html =~ "notification-row-#{n.id}"
    end

    test "per-row delete button removes the notification", %{user: user, conn: conn} do
      {:ok, n} =
        Notifications.record(user, %{
          event: "test",
          title: "To delete",
          body: "b",
          tag: "test",
          payload: %{}
        })

      {:ok, view, _html} = live(conn, ~p"/notifications")
      assert render(view) =~ "notification-row-#{n.id}"

      view
      |> element("#notification-row-#{n.id} button[phx-click=delete_notification]")
      |> render_click()

      refute render(view) =~ "notification-row-#{n.id}"
      assert Notifications.list_user_notifications(user, 1, 10) == []
    end

    test "clear-all button wipes the user's history", %{user: user, conn: conn} do
      for tag <- ["a", "b", "c"] do
        Notifications.record(user, %{
          event: "test",
          title: "title-#{tag}",
          body: "b",
          tag: tag,
          payload: %{}
        })
      end

      {:ok, view, html} = live(conn, ~p"/notifications")
      assert html =~ "title-a"
      assert html =~ "title-b"
      assert html =~ "title-c"

      view
      |> element("button[phx-click=clear_all_notifications]")
      |> render_click()

      assert Notifications.list_user_notifications(user, 1, 10) == []
      assert render(view) =~ "No notifications yet"
    end

    test "another user's history is never visible", %{user: user, conn: conn} do
      other = user_fixture()

      Notifications.record(other, %{
        event: "test",
        title: "other user only",
        body: "b",
        tag: "test",
        payload: %{}
      })

      {:ok, _view, html} = live(conn, ~p"/notifications")
      refute html =~ "other user only"
      assert html =~ "No notifications yet"

      _ = user
    end

    test "paginates with Previous / Next controls", %{user: user, conn: conn} do
      # 75 records ⇒ 2 pages at 50/page.
      for i <- 1..75 do
        {:ok, n} =
          Notifications.record(user, %{
            event: "test",
            title: "row #{i}",
            body: "b",
            tag: "n-#{i}",
            payload: %{}
          })

        # Force distinct delivered_at so the page 1 / page 2 split is
        # deterministic.
        touch_notification(n, DateTime.add(DtuApp.Time.utc_now(), -i * 10, :second))
      end

      {:ok, view, html} = live(conn, ~p"/notifications")
      assert html =~ "Page 1 of 2"
      # Page 1 shows "row 1" (newest), page 2 would show "row 51+".
      assert html =~ "row 1"
      refute html =~ "row 51"

      view
      |> element("button[phx-click=set_history_page][phx-value-page='2']")
      |> render_click()

      assert render(view) =~ "Page 2 of 2"
      assert render(view) =~ "row 51"
      refute render(view) =~ "row 1"
    end
  end

  defp touch_notification(n, dt) do
    alias DtuApp.Notifications.Notification
    import Ecto.Query

    {1, _} =
      DtuApp.Repo.update_all(
        from(r in Notification, where: r.id == ^n.id),
        set: [delivered_at: dt]
      )

    n
  end
end
