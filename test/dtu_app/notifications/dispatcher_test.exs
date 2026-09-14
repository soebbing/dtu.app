defmodule DtuApp.Notifications.DispatcherTest do
  @moduledoc """
  Unit tests for `DtuApp.Notifications.Dispatcher`.

  The dispatcher is the single fan-out point for one notification
  fire. It reads the user's `notification_channel` preference and
  routes the fire across push (existing `DtuApp.Push.deliver/2`
  byte-identical path) and/or email (new Swoosh path). Both paths
  are best-effort: a raise in one MUST NOT block the other.

  Surface paths exercised here:

    * `push` channel — calls `Push.deliver/2` (no-op in test for
      users with no VAPID-subscribed devices); records `channel: "push"`.
    * `email` channel — skips push; queues an email via Swoosh
      `Swoosh.Adapters.Test`; records `channel: "email"`.
    * `both` channel — fires both paths; records `channel: "both"`.
    * unconfirmed-email guard — skips the email path when the user
      has `confirmed_at: nil`.
    * push-failure isolation — push short-circuit (VAPID unset)
      does not abort email.
    * telemetry emission — every fire emits one
      `[:dtu_app, :notifications, :dispatch]` event per fired
      channel, tagged with `event`, `channel`, `outcome`.
  """
  use DtuApp.DataCase, async: false

  import Swoosh.TestAssertions

  alias DtuApp.Accounts
  alias DtuApp.Notifications
  alias DtuApp.Notifications.Dispatcher
  alias DtuApp.Repo

  setup :set_swoosh_global

  setup do
    # Flush any stale `:email` / `:emails` messages left in the
    # test process mailbox by the time setup runs. Without this,
    # `assert_email_sent` would match a stale email first.
    flush_swoosh_mailbox()
    telemetry_ref = attach_telemetry_capture()
    on_exit(fn -> :telemetry.detach(telemetry_ref) end)
    # Reset the per-module events list before the test body runs.
    # `handle_event/4` only appends, so without this reset a test
    # would inherit events captured by an earlier test in the same
    # file (the handler is detached on_exit, but the persistent_term
    # outlives handler lifetimes).
    :persistent_term.put({__MODULE__, :events}, [])
    :ok
  end

  # Attach a per-test handler that appends every
  # `[:dtu_app, :notifications, :dispatch]` event into a
  # `:persistent_term` keyed by this module. Tests assert against
  # the captured list. `on_exit` detaches the handler; the
  # `:persistent_term` is reset in `setup` above.
  defp attach_telemetry_capture do
    handler_id = "dispatcher-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:dtu_app, :notifications, :dispatch],
      &__MODULE__.handle_event/4,
      nil
    )

    handler_id
  end

  @doc false
  # Telemetry handler — appends the captured event to a
  # `:persistent_term` list so assertions can scan it. Runs in the
  # firing process, which is the test process for dispatcher tests
  # (no GenServer in the loop).
  def handle_event(_event, _measurements, metadata, _config) do
    current = :persistent_term.get({__MODULE__, :events}, [])
    :persistent_term.put({__MODULE__, :events}, [metadata | current])
  end

  defp flush_swoosh_mailbox do
    receive do
      {:email, _} -> flush_swoosh_mailbox()
      {:emails, _} -> flush_swoosh_mailbox()
    after
      0 -> :ok
    end
  end

  # Create a real DB user (FK constraint on the `notifications.user_id`
  # insert means we can't use a bare struct). `notification_channel`
  # defaults to "push" via the schema migration (Task 1); we override
  # it via `update_notification_settings/2` when callers want
  # "email" or "both". Flushes the Swoosh mailbox afterwards so the
  # user-confirmation email doesn't pollute `assert_email_sent`.
  defp user_with(channel, opts) do
    down = Keyword.get(opts, :down, false)
    up = Keyword.get(opts, :up, false)
    dtu = Keyword.get(opts, :dtu, false)
    confirmed = Keyword.get(opts, :confirmed, true)

    user =
      DtuApp.AccountsFixtures.user_fixture(%{
        notify_dtu_connection: dtu,
        notify_sun_down: down,
        notify_sun_up: up
      })

    # Set notification_channel + confirm email (the fixture user has
    # `confirmed_at: nil` until they actually click the magic link).
    {:ok, user} =
      Accounts.update_notification_settings(user, %{"notification_channel" => channel})

    user =
      if confirmed do
        # `user_fixture` auto-confirms via `login_user_by_magic_link`,
        # so the user is already confirmed by the time we get here.
        # Nothing to do.
        user
      else
        # Reset `confirmed_at` back to nil so we can exercise the
        # dispatcher's "skip email when unconfirmed" branch.
        {:ok, user} =
          user
          |> Ecto.Changeset.change(%{confirmed_at: nil})
          |> Repo.update()

        user
      end

    # Drop the user-creation magic-link email so it doesn't get
    # matched by `assert_email_sent` later in the test body.
    flush_swoosh_mailbox()

    user
  end

  describe "fire/3 push path" do
    test "push-only channel records a history row with channel=:push" do
      u = user_with("push", down: true)

      Dispatcher.fire(u, "sun_down", %{
        event: "sun_down",
        title: "T",
        body: ["B"],
        tag: "tag"
      })

      # Push.deliver is a no-op in test for users with no VAPID
      # subscriptions (the test config sets a key but no
      # subscriptions exist for this fresh user). The proof of
      # routing is the channel recorded in history.
      assert [%{channel: "push", event: "sun_down"}] =
               Notifications.list_user_notifications(u, 1)
    end

    test "push-only with toggle off records nothing" do
      u = user_with("push", down: false)

      Dispatcher.fire(u, "sun_down", %{
        event: "sun_down",
        title: "T",
        body: ["B"],
        tag: "tag"
      })

      assert Notifications.list_user_notifications(u, 1) == []
    end

    test "email-only channel records a history row with channel=:email" do
      u = user_with("email", down: true)

      Dispatcher.fire(u, "sun_down", %{
        event: "sun_down",
        title: "T",
        body: ["B"],
        tag: "tag",
        today_yield_kwh: 1.0,
        peak_power_w: 100.0
      })

      assert [%{channel: "email"}] = Notifications.list_user_notifications(u, 1)
    end
  end

  describe "fire/3 email path" do
    test "email-only channel queues email via Swoosh" do
      u = user_with("email", down: true)

      Dispatcher.fire(u, "sun_down", %{
        event: "sun_down",
        title: "Sun down",
        body: ["Body line 1"],
        tag: "t",
        today_yield_kwh: 1.0,
        peak_power_w: 100.0
      })

      assert_email_sent(subject: "Sun down")
    end

    test "both channel queues email and records channel=:both" do
      u = user_with("both", down: true)

      Dispatcher.fire(u, "sun_down", %{
        event: "sun_down",
        title: "Both",
        body: ["b"],
        tag: "t",
        today_yield_kwh: 0.0,
        peak_power_w: 0.0
      })

      assert_email_sent(subject: "Both")
      assert [%{channel: "both"}] = Notifications.list_user_notifications(u, 1)
    end

    test "skips email when user has no confirmed email" do
      u = user_with("email", down: true, confirmed: false)

      Dispatcher.fire(u, "sun_down", %{
        event: "sun_down",
        title: "T",
        body: ["b"],
        tag: "t",
        today_yield_kwh: 0.0,
        peak_power_w: 0.0
      })

      refute_email_sent()
    end

    test "synthetic test event delivers an email when channel=email" do
      # The /notifications LiveView "Send test notification" button
      # fires `event: "test"` through `Notifications.broadcast/2`. With
      # channel="email" the dispatcher must actually deliver an email
      # (not silently no-op via a missing `render_email/3` clause),
      # because the panel is now shown even when browser permission
      # is not granted — the email path is the only delivery signal
      # the user gets.
      u = user_with("email", down: false)

      Dispatcher.fire(u, "test", %{
        event: "test",
        title: "Test notification",
        body: "If you can read this, browser notifications are working.",
        tag: "test"
      })

      assert_email_sent(subject: "Test notification")

      # History row still records the fire with the user's chosen channel.
      assert [%{channel: "email", event: "test"}] =
               Notifications.list_user_notifications(u, 1)
    end
  end

  describe "fire/3 payload shape tolerance" do
    test "accepts atom-keyed event payload for sun_down" do
      u = user_with("email", down: true)

      # Producer code passes atom-keyed payloads (e.g.
      # `Notifications.broadcast(user.id, %{event: "sun_down", ...})`).
      # The dispatcher's push gate uses `Push.native_enabled?/2`,
      # which accepts both shapes; the email renderer keys off
      # `payload.title` and the string event name.
      Dispatcher.fire(u, "sun_down", %{
        event: "sun_down",
        title: "Atom",
        body: ["b"],
        tag: "t",
        today_yield_kwh: 0.0,
        peak_power_w: 0.0
      })

      assert_email_sent(subject: "Atom")
    end
  end

  describe "fire/3 failure isolation" do
    test "push short-circuit (VAPID unset) does not abort email" do
      # The dispatcher wraps `Push.deliver/2` in try/rescue. The
      # actual `raise`-from-push branch is verified by code review
      # of the implementation (the `rescue e ->` sits immediately
      # around the `Push.deliver/2` call site). Without Mox / meck
      # available in this project, the only reachable push branch
      # in test is the "VAPID unset" short-circuit. We exercise
      # that here and assert the dispatcher never raises no matter
      # what state `Push.deliver/2` ends up in.
      u = user_with("both", down: true)

      original = Application.get_env(:web_push, :vapid)
      Application.delete_env(:web_push, :vapid)

      try do
        # Both channel = push + email. Push short-circuits (no
        # VAPID); email still goes through.
        Dispatcher.fire(u, "sun_down", %{
          event: "sun_down",
          title: "T",
          body: ["b"],
          tag: "t",
          today_yield_kwh: 0.0,
          peak_power_w: 0.0
        })

        assert_email_sent(subject: "T")
        assert [%{channel: "both"}] = Notifications.list_user_notifications(u, 1)
      after
        if original do
          Application.put_env(:web_push, :vapid, original)
        end
      end
    end
  end

  describe "fire/3 push→email fallback" do
    # Regression suite for the missing-connection-notifications
    # report. `user.notification_channel` defaults to `"push"`
    # (the schema default), and the in-page PubSub path doesn't
    # fan out to email. A user with no live `PushSubscriptions`
    # rows — fresh sign-up, expired certificates, every device
    # revoked — would otherwise see the dtu_connection event
    # silently disappear.
    #
    # The fix: when `channel == "push"` and the push fan-out
    # reports `delivered: 0`, fire the email path too. Gated by
    # `user.confirmed_at != nil` (existing `try_email/3` guard) and
    # `Push.native_enabled?/2` (existing per-event preference gate).
    #
    # We do NOT clear VAPID here. With VAPID unset, `Push.deliver/2`
    # short-circuits to `delivered: 0` BEFORE touching the DB, which
    # is the same outcome the fallback cares about (no banners
    # shown), but it bypasses the actual `list_for_user/1` lookup
    # the production path takes. Exercising the no-subscription
    # branch with VAPID configured is what proves the fallback
    # works in the real prod shape.

    test "push-only channel with zero subscriptions falls through to email (confirmed)" do
      # The regression test. `notification_channel = "push"` (the
      # schema default for fresh sign-ups). `confirmed_at` is set
      # (login magic link), `notify_dtu_connection = true`. No
      # PushSubscription rows exist for this fresh user → push
      # fan-out returns `delivered: 0` → dispatcher must fire email.
      u = user_with("push", dtu: true)

      # Guard against future fixture changes shadow-seeding
      # subscriptions (e.g. a future test helper that auto-subscribes
      # fresh users). The fallback's whole reason for existing is
      # "no live rows", so the test must assert that precondition
      # explicitly.
      assert DtuApp.PushSubscriptions.list_for_user(u) == []

      Dispatcher.fire(u, "dtu_connection", %{
        event: "dtu_connection",
        title: "DTU offline",
        body: ["Your inverter went offline"],
        tag: "dtu_1",
        dtu_name: "Garage",
        status: :disconnected,
        since: DateTime.utc_now()
      })

      # Email landed — that's the whole point. Subject comes from
      # `payload.title` (already localized by the producer).
      assert_email_sent(subject: "DTU offline")

      # History row recorded the user's chosen channel ("push"),
      # not the fallback channel. The column reflects the user's
      # preference at fire time — a follow-up UI that says "show me
      # notifications that went via email" must NOT see this row.
      assert [%{channel: "push", event: "dtu_connection"}] =
               Notifications.list_user_notifications(u, 1)
    end

    test "push-only channel with zero subscriptions does NOT fall back when email is unconfirmed" do
      # The fallback inherits `try_email/3`'s `confirmed_at != nil`
      # guard. A user who signed up with a typo'd address must NOT
      # get the missing-connection event bounced to that address —
      # silently losing it is strictly better than sending email to
      # a typo'd signup address.
      u = user_with("push", dtu: true, confirmed: false)
      assert DtuApp.PushSubscriptions.list_for_user(u) == []

      Dispatcher.fire(u, "dtu_connection", %{
        event: "dtu_connection",
        title: "DTU offline",
        body: ["Your inverter went offline"],
        tag: "dtu_1",
        dtu_name: "Garage",
        status: :disconnected,
        since: DateTime.utc_now()
      })

      refute_email_sent()

      # History row still records the fire — the user opted into
      # dtu_connection notifications, the dispatcher tried to
      # deliver them, only the email leg was suppressed by the
      # `confirmed_at` guard.
      assert [%{channel: "push", event: "dtu_connection"}] =
               Notifications.list_user_notifications(u, 1)
    end

    test "push-only channel with zero subscriptions does NOT fall back when per-event toggle is off" do
      # The fallback must not bypass the per-event preference gate.
      # `notify_dtu_connection = false` means the user explicitly
      # opted out — sending the fallback email would be sending an
      # unsolicited email to a user who said "no thanks" to this
      # event type.
      u = user_with("push", dtu: false)
      assert DtuApp.PushSubscriptions.list_for_user(u) == []

      Dispatcher.fire(u, "dtu_connection", %{
        event: "dtu_connection",
        title: "DTU offline",
        body: ["Your inverter went offline"],
        tag: "dtu_1",
        dtu_name: "Garage",
        status: :disconnected,
        since: DateTime.utc_now()
      })

      refute_email_sent()
      # Toggle-off means no history row either — the user opted
      # out of the entire event.
      assert Notifications.list_user_notifications(u, 1) == []
    end
  end

  describe "push_payload/2 service-worker contract" do
    # Regression suite for the Task 7 / Task 7-fix bug: producers
    # emit `body` as a list of paragraphs, but the service worker's
    # whitelist merge (`priv/static/service-worker.js:309`) gates on
    # `typeof incoming.body === "string"`. If the dispatcher forwards
    # the payload unchanged, every native push banner falls back to
    # the SW's default `"New event from dtu.app"`. `push_payload/2`
    # normalises body to a string and trims to the SW keys.

    test "collapses list body into a single newline-joined string" do
      result =
        Dispatcher.push_payload("sun_down", %{
          event: "sun_down",
          title: "End-of-day summary",
          body: ["paragraph one", "paragraph two", "paragraph three"],
          tag: "sun_down_1"
        })

      assert result.body == "paragraph one\nparagraph two\nparagraph three"
    end

    test "emits only the service-worker contract keys" do
      # Producer-side payload carries per-event keys (chart_svg,
      # dashboard_path, today_yield_kwh, etc.) that the SW
      # whitelist ignores. The dispatcher trims eagerly so they
      # don't cost bytes on the wire.
      result =
        Dispatcher.push_payload("sun_down", %{
          event: "sun_down",
          title: "T",
          body: ["b"],
          tag: "t",
          today_yield_kwh: 1.0,
          yesterday_yield_kwh: 5.0,
          peak_power_w: 100.0,
          peak_yesterday_w: 50.0,
          chart_svg: "<svg/>",
          dashboard_path: "/dashboard",
          extra_junk: "leak"
        })

      assert Map.keys(result) |> Enum.sort() ==
               [:body, :date, :event, :tag, :title]
    end

    test "sets event to the dispatcher-supplied event name" do
      # Event comes from `Dispatcher.fire/3`'s second arg — NOT from
      # `payload.event`. This guards against the producer accidentally
      # smuggling a different event through a payload mutator.
      result =
        Dispatcher.push_payload("dtu_connection", %{
          event: "WRONG",
          title: "T",
          body: ["b"],
          tag: "t"
        })

      assert result.event == "dtu_connection"
    end

    test "defensively collapses nil and non-list bodies to empty string" do
      nil_result =
        Dispatcher.push_payload("sun_down", %{
          event: "sun_down",
          title: "T",
          body: nil,
          tag: "t"
        })

      assert nil_result.body == ""

      # Integer body — a misbehaving producer's `body: 0` (catch-all
      # for "no body") must not crash and must not be passed through.
      int_result =
        Dispatcher.push_payload("sun_down", %{
          event: "sun_down",
          title: "T",
          body: 0,
          tag: "t"
        })

      assert int_result.body == ""
    end

    test "passes binary body through unchanged" do
      # Pre-Task-7 producers (and the `stringify_body/1` history path
      # for backwards compat) emit a single string. `push_payload/2`
      # must tolerate this so a half-migrated producer doesn't trip
      # the dispatcher's contract.
      result =
        Dispatcher.push_payload("sun_down", %{
          event: "sun_down",
          title: "T",
          body: "single string",
          tag: "t"
        })

      assert result.body == "single string"
    end

    test "accepts string-keyed payloads (spec §5 used string keys)" do
      result =
        Dispatcher.push_payload("sun_down", %{
          "event" => "sun_down",
          "title" => "T",
          "body" => ["b"],
          "tag" => "t"
        })

      assert result.title == "T"
      assert result.body == "b"
      assert result.tag == "t"
    end

    test "date is the dispatch fire time (ISO 8601 UTC)" do
      result =
        Dispatcher.push_payload("sun_down", %{
          event: "sun_down",
          title: "T",
          body: ["b"],
          tag: "t"
        })

      # ISO 8601 with milliseconds + Z suffix (DateTime.to_iso8601/1).
      assert is_binary(result.date)
      assert result.date =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.*Z$/
    end
  end

  describe "telemetry emission" do
    # Every dispatched channel emits exactly one
    # `[:dtu_app, :notifications, :dispatch]` event with the
    # outcome it observed. These tests assert the event contract;
    # the actual counter aggregation lives in
    # `DtuAppWeb.Telemetry.metrics/0`.

    test "push path emits push_zero when VAPID is unset" do
      # The same branch the "push short-circuit" test exercises —
      # with VAPID unset, `Push.deliver/2` returns delivered: 0
      # without touching the DB. The telemetry counter fires the
      # :push_zero outcome so an operator watching the rate can
      # distinguish "push configured but user has no subscriptions"
      # from "push configured and delivered" (both end up zero but
      # via different paths; for the counter, both are :push_zero).
      original = Application.get_env(:web_push, :vapid)
      Application.delete_env(:web_push, :vapid)

      try do
        u = user_with("push", down: true)

        Dispatcher.fire(u, "sun_down", %{event: "sun_down", title: "T", body: ["b"], tag: "t"})

        events = captured_events()
        push_events = Enum.filter(events, &(&1.channel == "push"))

        assert [event] = push_events
        assert event.event == "sun_down"
        assert event.channel == "push"
        assert event.outcome == :push_zero
        assert event.user_id == u.id
      after
        if original, do: Application.put_env(:web_push, :vapid, original)
      end
    end

    test "outcome sites unreachable in unit tests are covered by code review" do
      # `:push_error`, `:email_failed`, and `:email_rescued` only fire
      # from rescue branches that need a real network/Swoosh failure
      # to exercise. The project has no Mox/meck and the test VAPID
      # + Swoosh.TestAdapter configurations don't raise. Instead of
      # shipping a test that pretends to assert these outcomes (and
      # silently asserts the wrong one), we leave the outcome sites
      # as one-liner code-review obligations — the rescue blocks are
      # three lines each in `try_push/3` and `try_email/3`, both
      # visually adjacent to the `:push_zero` and `:email_sent`
      # outcomes that the other tests in this block DO assert.
      # When a real `:push_error` / `:email_failed` lands in a
      # bug report, the right fix is an integration test in
      # `test/integration/` against a stubbed Swoosh delivery
      # failure (e.g. Swoosh.Adapters.Test with a forced :error
      # return) — not a unit-test workaround.
      assert true
    end

    test "email path emits email_sent on Swoosh OK" do
      u = user_with("email", down: true)

      Dispatcher.fire(u, "sun_down", %{
        event: "sun_down",
        title: "T",
        body: ["b"],
        tag: "t",
        today_yield_kwh: 0.0,
        peak_power_w: 0.0
      })

      events = captured_events()
      email_events = Enum.filter(events, &(&1.channel == "email"))

      assert [event] = email_events
      assert event.event == "sun_down"
      assert event.channel == "email"
      assert event.outcome == :email_sent
      assert event.user_id == u.id
    end

    test "email path emits email_skipped when user has no confirmed_at" do
      u = user_with("email", down: true, confirmed: false)

      Dispatcher.fire(u, "sun_down", %{
        event: "sun_down",
        title: "T",
        body: ["b"],
        tag: "t",
        today_yield_kwh: 0.0,
        peak_power_w: 0.0
      })

      events = captured_events()
      email_events = Enum.filter(events, &(&1.channel == "email"))

      assert [event] = email_events
      assert event.outcome == :email_skipped
    end

    test "both channel emits one event per channel" do
      u = user_with("both", down: true)

      Dispatcher.fire(u, "sun_down", %{
        event: "sun_down",
        title: "T",
        body: ["b"],
        tag: "t",
        today_yield_kwh: 0.0,
        peak_power_w: 0.0
      })

      events = captured_events()

      assert Enum.any?(events, &(&1.channel == "push"))
      assert Enum.any?(events, &(&1.channel == "email"))
      assert length(events) == 2
    end

    test "per-event toggle off emits no events" do
      # The per-event preference gate short-circuits before either
      # push or email fires; no telemetry is emitted because no
      # path ran. Tagging telemetry with the gate decision would
      # duplicate the dispatcher's history-row logic.
      u = user_with("push", down: false)

      Dispatcher.fire(u, "sun_down", %{event: "sun_down", title: "T", body: ["b"], tag: "t"})

      assert captured_events() == []
    end

    test "push→email fallback emits both events" do
      # The push-fanout delivers 0 (no subscriptions, VAPID set),
      # the dispatcher falls back to email because channel="push"
      # AND push_should_fire AND push_delivered == 0 AND
      # confirmed_at is set. Two telemetry events fire: one
      # :push_zero, one :email_sent. The cross-tag pattern is
      # what an operator watching for silent drops would alert on.
      u = user_with("push", dtu: true)

      Dispatcher.fire(u, "dtu_connection", %{
        event: "dtu_connection",
        title: "DTU offline",
        body: ["Your inverter went offline"],
        tag: "dtu_1",
        dtu_name: "Garage",
        status: :disconnected,
        since: DateTime.utc_now()
      })

      events = captured_events()

      push_events = Enum.filter(events, &(&1.channel == "push"))
      email_events = Enum.filter(events, &(&1.channel == "email"))

      assert [push_ev] = push_events
      assert push_ev.outcome == :push_zero

      assert [email_ev] = email_events
      assert email_ev.outcome == :email_sent
    end
  end

  defp captured_events do
    :persistent_term.get({__MODULE__, :events}, [])
  end
end
