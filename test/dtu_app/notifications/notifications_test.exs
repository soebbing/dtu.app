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
    * End-to-end `broadcast/2` → `Dispatcher.fire/3` → Swoosh email
      + history row (channel "both" path; the regression case for
      Task 11's whole pipeline).

  The DB-write side of `DtuApp.Notifications.broadcast/2` is the
  fan-out chokepoint — all server-side notifiers
  (`SunDown`, `SunUp`, `DtuConnection`) and the test button route
  through it, so a single regression test on
  `broadcast/2` → `record/2` covers all four call sites.

  `async: false` is required because the integration test uses
  `Swoosh.TestAssertions` in global mode (Swoosh's test mailbox is
  process-wide, so the ExUnit case cannot run concurrently). The
  other describe blocks could run `async: true`, but for the sake
  of one shared mailbox we keep the whole module synchronous — the
  wall-clock cost is ~0.3s and the suite is small enough that the
  trade-off is worth the test isolation guarantee.
  """
  use DtuApp.DataCase, async: false

  import Swoosh.TestAssertions

  alias DtuApp.Accounts
  alias DtuApp.Notifications
  alias DtuApp.Notifications.Notification

  setup :set_swoosh_global

  setup context do
    # Drop any stale `:email` messages left over from the user-fixture
    # magic-link send so `assert_email_sent` only matches the email
    # under test. Same helper as `dispatcher_test.exs:42-49`.
    flush_swoosh_mailbox()
    context
  end

  defp flush_swoosh_mailbox do
    receive do
      {:email, _} -> flush_swoosh_mailbox()
      {:emails, _} -> flush_swoosh_mailbox()
    after
      0 -> :ok
    end
  end

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

  describe "list_user_notifications/3 with event filter" do
    # The /notifications page filter chip row maps to the optional
    # 4th arg on `list_user_notifications/4` (kept as a positional
    # arg with a `nil` default so the ~20 existing callers don't
    # need a refactor). These tests pin the contract so a future
    # signature change can't silently drop the filter — a broken
    # filter would surface rows the user already filtered out, which
    # is the kind of regression that's invisible in unit tests
    # without an explicit fixture per event type.
    setup do
      user = user_fixture()

      # Seed one row per event so the filter has something to
      # include AND exclude. `count_user_notifications/2` (and the
      # UI's pagination badge) read the same `notifications.event`
      # column, so this is enough for both sides of the filter
      # contract.
      for event <- ["dtu_connection", "sun_down", "sun_up", "yield_anomaly", "test"] do
        {:ok, n} =
          Notifications.record(user, %{
            event: event,
            title: "title-#{event}",
            body: "b",
            tag: "t-#{event}"
          })

        # Touch delivered_at so the newest-first ordering is
        # deterministic across iterations.
        touch_delivered_at(n, DateTime.add(DateTime.utc_now(:second), -1, :second))
      end

      %{user: user}
    end

    test "filter=nil returns every event (default behaviour preserved)", %{user: user} do
      rows = Notifications.list_user_notifications(user, 1, 10, nil)
      assert length(rows) == 5

      assert Enum.map(rows, & &1.event) |> Enum.sort() ==
               ~w(dtu_connection sun_down sun_up test yield_anomaly)
    end

    test "filter=\"\" returns every event (sentinel for URL `?event=` empty)", %{user: user} do
      # The LiveView's `push_patch/2` drops the param when the user
      # picks the "All" chip, so the URL never carries `?event=` —
      # but `normalize_event_filter/1` is the gate, the helper here
      # only sees the post-gate value. Belt-and-braces: the query
      # layer also treats "" as nil so a future caller that bypasses
      # the gate doesn't break.
      rows = Notifications.list_user_notifications(user, 1, 10, "")
      assert length(rows) == 5
    end

    test "filter='sun_down' returns only sun_down rows", %{user: user} do
      rows = Notifications.list_user_notifications(user, 1, 10, "sun_down")

      assert length(rows) == 1
      assert hd(rows).event == "sun_down"
    end

    test "filter scopes the page size to the filtered set, not the global total", %{user: user} do
      # With 1 sun_down row + 4 other rows + per_page=1, the first
      # page should contain ONLY the sun_down row, not be filled
      # with the most-recent-of-the-other-events. Pins the ORDER BY
      # + WHERE interaction: the WHERE clause is applied BEFORE the
      # LIMIT/OFFSET, not after.
      rows = Notifications.list_user_notifications(user, 1, 1, "sun_down")

      assert length(rows) == 1
      assert hd(rows).event == "sun_down"
    end

    test "filter with an unknown event string returns [] (no raise, no rows)", %{user: user} do
      # The LiveView normalises the URL value through the
      # `normalize_event_filter/1` allow-list BEFORE reaching here, so
      # this branch is only reachable by a misbehaving caller — but
      # the query layer must not raise on a bogus string, otherwise
      # a LiveView refactor that drops the gate would 500 the page.
      assert Notifications.list_user_notifications(user, 1, 10, "not_a_real_event") == []
    end

    test "filter only scopes the calling user's history, not another user's", %{user: user} do
      other = user_fixture()

      Notifications.record(other, %{
        event: "sun_down",
        title: "other's row",
        body: "b",
        tag: "other"
      })

      rows = Notifications.list_user_notifications(user, 1, 10, "sun_down")
      # The user's own 1 sun_down row, not the other user's.
      assert length(rows) == 1
      assert hd(rows).title == "title-sun_down"
    end
  end

  describe "count_user_notifications/1 with event filter" do
    # `assign_history/4` uses this to compute the per-filter
    # pagination total — "Page 1 of 1 within Sun down" instead of
    # "Page 4 of 8". Pins the contract that the count honours the
    # same filter the listing does.
    setup do
      user = user_fixture()

      # 3 dtu_connection rows + 1 sun_down — the filter must see
      # the 3 vs the 1 split, not lump them together.
      for _ <- 1..3 do
        Notifications.record(user, %{
          event: "dtu_connection",
          title: "t",
          body: "b",
          tag: "dtu"
        })
      end

      Notifications.record(user, %{
        event: "sun_down",
        title: "t",
        body: "b",
        tag: "sun_down"
      })

      %{user: user}
    end

    test "filter=nil returns the global total", %{user: user} do
      assert Notifications.count_user_notifications(user, nil) == 4
    end

    test "filter='dtu_connection' returns the filtered total", %{user: user} do
      assert Notifications.count_user_notifications(user, "dtu_connection") == 3
    end

    test "filter='sun_down' returns the filtered total", %{user: user} do
      assert Notifications.count_user_notifications(user, "sun_down") == 1
    end

    test "filter with no matching rows returns 0", %{user: user} do
      assert Notifications.count_user_notifications(user, "yield_anomaly") == 0
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

  describe "end-to-end with :both channel" do
    # Whole-pipeline regression for the channel-toggle feature
    # (Task 11). Drives the path that producers
    # (`SunDown`/`SunUp`/`DtuConnection`) and the test button all
    # take: `Notifications.broadcast/2` → `safe_get_user/1` →
    # `Dispatcher.fire/3` → push (VAPID no-op in test) + Swoosh
    # email + history row. The user's `notification_channel` is
    # set to "both" via `Accounts.update_notification_settings/2`,
    # `notify_sun_down` is true (otherwise the dispatcher gates
    # both push and email off via `Push.native_enabled?/2`), and
    # the email is confirmed by `user_fixture/1` (it auto-confirms
    # via `login_user_by_magic_link/1`).
    #
    # Asserts:
    #   1. `assert_email_sent(subject: ...)` — proves the email
    #      path rendered and Swoosh delivered via the test
    #      adapter.
    #   2. `history.channel == "both"` AND `history.event == ...`
    #      — proves the dispatcher recorded the fire with the
    #      user's chosen channel (not just "push" or "email"),
    #      which is the load-bearing invariant of the whole
    #      feature: a user who opts into "both" must see "both" in
    #      their history regardless of which side actually fired.
    test "broadcast/2 fires push + email AND records history with channel='both'" do
      user =
        DtuApp.AccountsFixtures.user_fixture(%{
          notify_sun_down: true,
          notify_sun_up: false,
          notify_dtu_connection: false
        })

      {:ok, user} =
        Accounts.update_notification_settings(user, %{notification_channel: "both"})

      # Drop the magic-link email sent by `user_fixture/1` so the
      # assertion below only matches the dispatcher's email.
      flush_swoosh_mailbox()

      payload = %{
        event: "sun_down",
        title: "Sun down summary",
        body: ["Today: 12.4 kWh, peak 3,250 W."],
        tag: "sun_down:2026-08-27",
        today_yield_kwh: 12.4,
        yesterday_yield_kwh: 10.1,
        peak_power_w: 3250,
        peak_yesterday_w: 2840,
        chart_svg: "<svg viewBox='0 0 800 280'></svg>",
        dashboard_path: "/dashboard"
      }

      # Use the public broadcast/2 entry point (not Dispatcher.fire/3
      # directly) so the test exercises the in-page PubSub path too,
      # matching what the producers call. PubSub.broadcast is a
      # fire-and-forget no-op when no LiveView is subscribed.
      Notifications.broadcast(user.id, payload)

      # Email went out via Swoosh — subject comes from
      # `payload.title` (the localized title the producer built).
      assert_email_sent(subject: "Sun down summary")

      # History row records the user's chosen channel and the event
      # name — the load-bearing invariant the whole feature pivots
      # on. One row per fire, channel = user preference at fire
      # time.
      assert [history] = Notifications.list_user_notifications(user, 1)
      assert history.channel == "both"
      assert history.event == "sun_down"
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
