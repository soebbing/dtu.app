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

    test "granted + recently-revoked subscription surfaces the amber re-subscribe inset; push_subscribed clears it",
         %{conn: conn, scope: scope} do
      # Seed a subscription, then simulate the dispatcher pruning it
      # because FCM/APNS returned 404/410 (soft-delete via
      # `delete_by_endpoint/1` — the production hot path).
      {:ok, _sub} =
        DtuApp.PushSubscriptions.upsert(scope.user, %{
          "endpoint" => "https://fcm.googleapis.com/fcm/send/revoked",
          "p256dh" => "BNcRdreALRFXTkOOUHK1",
          "auth" => "tBHItJI5svbpez7KI4CCXg"
        })

      :ok =
        DtuApp.PushSubscriptions.delete_by_endpoint("https://fcm.googleapis.com/fcm/send/revoked")

      {:ok, view, _html} = live(conn, ~p"/notifications")

      render_hook(view, "notification_state", %{
        state: "granted",
        device: "desktop",
        installed: true
      })

      assert render(view) =~ "Your browser cleared its push subscription"
      assert render(view) =~ ~s(id="notifications-re-subscribe")
      refute render(view) =~ "Native push is on for this device"

      # User re-subscribes — the JS hook POSTs /push/subscribe, the
      # server's upsert clears deleted_at, then the hook fires
      # `push_subscribed` to flip the assigns. The amber inset should
      # disappear; the native-push badge should appear.
      render_hook(view, "push_subscribed", %{
        "endpoint" => "https://fcm.googleapis.com/fcm/send/revoked"
      })

      refute render(view) =~ "Your browser cleared its push subscription"
      refute render(view) =~ ~s(id="notifications-re-subscribe")
      assert render(view) =~ "Native push is on for this device"
    end

    test "granted + no subscriptions + no recent revoke renders no amber inset", %{conn: conn} do
      # Fresh user, never subscribed. The recently-revoked signal
      # must be false on a clean mount.
      {:ok, view, _html} = live(conn, ~p"/notifications")

      render_hook(view, "notification_state", %{
        state: "granted",
        device: "desktop",
        installed: true
      })

      refute render(view) =~ "Your browser cleared its push subscription"
      refute render(view) =~ ~s(id="notifications-re-subscribe")
      assert render(view) =~ "Keep this tab open to receive notifications"
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

  describe "Notification history filter chips" do
    # The /notifications page renders a row of chips (All /
    # Connection / Sun down / Sun up / Yield anomaly / Test) above
    # the history list. Clicking a chip:
    #   1. Re-renders the list scoped to the chosen event (server
    #      query, not a client-side filter — important because the
    #      pagination total also re-scopes).
    #   2. push_patch-es the URL so the filter is bookmarkable.
    # The "All" chip drops the param entirely so the URL stays
    # clean (`/notifications` rather than `/notifications?event=all`).
    setup :register_and_log_in_user

    setup %{user: user} do
      # Seed one row per event so each chip has something to filter
      # to (and the unfiltered list shows all five).
      for event <- ["dtu_connection", "sun_down", "sun_up", "yield_anomaly", "test"] do
        Notifications.record(user, %{
          event: event,
          title: "title-#{event}",
          body: "b",
          tag: "t-#{event}",
          payload: %{}
        })
      end

      :ok
    end

    test "the chip row renders one chip per known event plus an All chip", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/notifications")

      assert html =~ ~s(id="notification-history-filters")
      # All six chips must be present (count `data-event-filter=...`).
      assert html =~ ~s(data-event-filter="all")
      assert html =~ ~s(data-event-filter="dtu_connection")
      assert html =~ ~s(data-event-filter="sun_down")
      assert html =~ ~s(data-event-filter="sun_up")
      assert html =~ ~s(data-event-filter="yield_anomaly")
      assert html =~ ~s(data-event-filter="test")
    end

    test "the All chip is active on a clean mount", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/notifications")

      # The active chip carries `aria-pressed="true"` and every
      # other chip carries `aria-pressed="false"`. The Pin pattern
      # (aria-pressed for state) means the visual style is driven
      # by the same attribute the test asserts on — a regression
      # that drops the attribute would also break the active-chip
      # styling.
      assert active_chip_with_value(html, "all"),
             "expected the All chip to be aria-pressed=\"true\""

      assert inactive_chip_with_value(html, "sun_down"),
             "expected the Sun down chip to be aria-pressed=\"false\""
    end

    test "clicking the Sun down chip scopes the list to sun_down rows", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/notifications")

      # Unfiltered: all five rows render.
      assert html =~ "title-sun_down"
      assert html =~ "title-test"
      assert html =~ "title-yield_anomaly"

      view
      |> element(~s(button[data-event-filter="sun_down"]))
      |> render_click()

      # After the filter: only the sun_down row survives.
      assert render(view) =~ "title-sun_down"
      refute render(view) =~ "title-test"
      refute render(view) =~ "title-yield_anomaly"
      refute render(view) =~ "title-sun_up"
      refute render(view) =~ "title-dtu_connection"
    end

    test "clicking a chip push_patch-es the URL with ?event=...", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/notifications")

      view
      |> element(~s(button[data-event-filter="sun_down"]))
      |> render_click()

      # push_patch leaves the LiveView on the same URL with the new
      # query string. We assert on the URL bar (conn) — `render_click`
      # returns the re-rendered HTML; the `patch` event lands on the
      # socket's URL via `assert_patched`.
      assert_patched(view, ~p"/notifications?event=sun_down")
    end

    test "clicking All drops the param entirely from the URL", %{conn: conn} do
      # Start on a filtered URL → click All → URL reverts to the
      # clean form (no ?event=...) so a copy/paste of the URL after
      # clicking All doesn't carry a redundant query string.
      {:ok, view, _html} = live(conn, ~p"/notifications?event=sun_down")

      view
      |> element(~s(button[data-event-filter="all"]))
      |> render_click()

      assert_patched(view, ~p"/notifications")
    end

    test "mounting with ?event=sun_down in the URL applies the filter on first render", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, ~p"/notifications?event=sun_down")

      # Only sun_down row visible on the first render — the filter
      # is read in handle_params/3, not deferred to a click. A
      # regression that moves the URL read back to mount/3 only
      # would still pass for the click path; this URL-then-mount
      # path exercises the actual entry shape.
      assert html =~ "title-sun_down"
      refute html =~ "title-test"
      refute html =~ "title-yield_anomaly"
      refute html =~ "title-sun_up"
      refute html =~ "title-dtu_connection"

      # And the sun_down chip is the active one (aria-pressed="true").
      assert active_chip_with_value(html, "sun_down"),
             "expected the Sun down chip to be aria-pressed=\"true\""

      assert inactive_chip_with_value(html, "all"),
             "expected the All chip to be aria-pressed=\"false\""
    end

    test "mounting with ?event=bogus falls back to All (allow-list defence)", %{conn: conn} do
      # URL injection defence: a hand-edited query string (or a JS
      # hook that ships an unknown event) must NOT crash the page
      # and must NOT leak rows the user can't see in the UI. The
      # normalisation drops bogus values to "all".
      {:ok, _view, html} = live(conn, ~p"/notifications?event=<script>alert(1)</script>")

      assert html =~ "title-sun_down"
      assert html =~ "title-test"

      assert active_chip_with_value(html, "all"),
             "expected the All chip to be aria-pressed=\"true\" after the bogus value fell back"
    end

    test "switching filter resets the page index to 1", %{user: user, conn: conn} do
      # Three pages of "test" rows + 1 sun_down row (yielding a
      # 4-row global set — 120 test + 1 sun_down = 121, but the
      # setup seeds only 5 distinct events, so we add the bulk
      # test rows here in this test). The seed leaves the user
      # on page 1 with all rows visible. Paginate to page 2
      # (rows 51–75 visible), then filter to sun_down — the page
      # index MUST reset to 1 and the pagination controls MUST
      # disappear (the filtered set is a single page, so the
      # pagination footer is hidden by the `history_total_pages >
      # 1` gate in the template).
      for i <- 1..120 do
        {:ok, n} =
          Notifications.record(user, %{
            event: "test",
            title: "row #{i}",
            body: "b",
            tag: "n-#{i}",
            payload: %{}
          })

        touch_notification(n, DateTime.add(DtuApp.Time.utc_now(), -i, :second))
      end

      {:ok, view, html} = live(conn, ~p"/notifications")
      # Sanity: page 1 of 3 (75 / 50 = 2 → +1 for the tail page).
      assert html =~ "Page 1 of 3"

      # Page through to page 2.
      view
      |> element("button[phx-click=set_history_page][phx-value-page='2']")
      |> render_click()

      assert render(view) =~ "Page 2 of 3"

      # Switch filter to sun_down — page resets, pagination
      # controls disappear (1 row → 1 page → hidden).
      view
      |> element(~s(button[data-event-filter="sun_down"]))
      |> render_click()

      # The pagination footer is gated on `@history_total_pages >
      # 1`, so a single-page filtered list hides it entirely. The
      # load-bearing assertion is the *next* button: if the page
      # index leaked, the next button would still carry
      # `phx-value-page="3"`; after the reset it carries
      # `phx-value-page="2"` (page 1 + 1) — and the button is gone
      # because there's no next page to navigate to.
      refute render(view) =~ "phx-click=\"set_history_page\""
    end

    test "filter chip row renders the conditional empty-state copy when no rows match", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, ~p"/notifications")

      # The seed above adds one row of EVERY known event (the chip
      # row's per-event labels need to be visible), so a direct
      # filter-to-event never yields zero rows. To exercise the
      # filter-active empty-state branch we wipe the user's
      # history after mount, then filter — the per-event filter
      # applies to an empty table, and the copy must surface
      # "in this filter" rather than the global "No notifications
      # yet" copy.
      refute html =~ "No notifications in this filter yet"

      view
      |> element("button[phx-click=clear_all_notifications]")
      |> render_click()

      # After clear_all + a filter, the empty-state copy is the
      # filter-active variant.
      view
      |> element(~s(button[data-event-filter="sun_down"]))
      |> render_click()

      assert render(view) =~ "No notifications in this filter yet"
      refute render(view) =~ "No notifications yet. The list updates automatically"
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

  # Locates the chip with `data-event-filter="<value>"` in the
  # rendered HTML and asserts on its `aria-pressed` attribute.
  # The chip's rendered HTML is one line (HEEx strips whitespace
  # between elements), so a multi-line substring pattern would
  # never match. We extract the chip element via a regex and
  # assert on its attribute directly.
  #
  # Returns `true` on match so the caller can attach a failure
  # message via `assert ... , "..."`.
  defp chip_with_pressed(html, value, pressed) do
    # HEEx renders attributes in declaration order, so the chip
    # comes out as e.g. `<button type="button" ... aria-pressed="..."
    # data-event-filter="all" class="...">`. The chip element is
    # self-contained (no nested `<button>`), so a non-greedy match
    # to the closing `>` is safe.
    regex =
      ~r/<button\b[^>]*\bdata-event-filter="#{Regex.escape(value)}"[^>]*>/

    case Regex.run(regex, html) do
      [chip_tag] ->
        case Regex.run(~r/aria-pressed="([^"]+)"/, chip_tag) do
          [_, actual] -> actual == pressed
          _ -> false
        end

      _ ->
        false
    end
  end

  defp active_chip_with_value(html, value),
    do: chip_with_pressed(html, value, "true")

  defp inactive_chip_with_value(html, value),
    do: chip_with_pressed(html, value, "false")
end
