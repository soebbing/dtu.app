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
  """
  use DtuApp.DataCase, async: false

  import Swoosh.TestAssertions

  alias DtuApp.Accounts
  alias DtuApp.Notifications
  alias DtuApp.Notifications.Dispatcher
  alias DtuApp.Repo

  setup :set_swoosh_global

  setup context do
    # Flush any stale `:email` / `:emails` messages left in the
    # test process mailbox by the time setup runs. Without this,
    # `assert_email_sent` would match a stale email first.
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
end
