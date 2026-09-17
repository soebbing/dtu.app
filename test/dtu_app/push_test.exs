defmodule DtuApp.PushTest do
  @moduledoc """
  Unit tests for `DtuApp.Push`.

  Surface paths exercised here:

    1. **`public_key/0`** — the VAPID public key exposed by
       `DtuApp.Push` (which the `/push/vapid/public_key` controller
       hands back to the browser for `PushManager.subscribe()`).
       Verified to return the configured value, or `nil` when VAPID
       isn't configured.

    2. **`deliver/2`** — the fan-out. Without VAPID keys configured,
       `deliver/2` is a quiet no-op; the in-page PubSub path keeps
       working and the server logs no warnings. The per-row `:ok`
       / `:error` paths (HTTP 200, 404, 410, transport failure) are
       covered by the dispatcher in conjunction with `web_push`,
       which has its own test suite in `deps/web_push/test/`.

    3. **`native_enabled?/2`** — per-event preference gate lifted
       out of `DtuApp.Notifications` so both push and email
       dispatchers can ask the same question. Mirrors the old
       `native_push_enabled?/2` clauses byte-for-byte.

  We don't mock `WebPush.send/3` here — the VAPID-config-aware
  branches are deterministic, and adding a mocking dependency just
  for this would be more friction than it's worth. The end-to-end
  path (HTTP success / 404 / 410 / transport) is verified by the
  integration with `web_push`'s own tests.
  """

  # The `WebPush.send/3` call-site assertions (TTL + Urgency opts) live
  # in `describe "WebPush.send call-site"` and are string/regex matches
  # against `lib/dtu_app/push.ex` on disk — same pattern as
  # `DtuAppWeb.ServiceWorkerTest`. We don't mock `WebPush` because Meck
  # isn't in the dep tree, and the call-site itself is the contract we
  # care about: a future refactor that drops the explicit opts would
  # re-introduce the iOS background-push drop.
  @push_path "lib/dtu_app/push.ex"

  use ExUnit.Case, async: false

  alias DtuApp.Accounts.User
  alias DtuApp.Push

  defp user_with(opts \\ []) do
    %User{
      notify_dtu_connection: Keyword.get(opts, :dtu, false),
      notify_sun_down: Keyword.get(opts, :down, false),
      notify_sun_up: Keyword.get(opts, :up, false)
    }
  end

  describe "public_key/0" do
    test "returns nil when no VAPID config is set" do
      # Snapshot, clear, assert, restore — so we don't leak a cleared
      # config into other tests in the same run.
      original = Application.get_env(:web_push, :vapid)
      Application.delete_env(:web_push, :vapid)

      try do
        assert Push.public_key() == nil
      after
        if original do
          Application.put_env(:web_push, :vapid, original)
        end
      end
    end

    test "returns the configured public key when VAPID is set" do
      original = Application.get_env(:web_push, :vapid)

      Application.put_env(:web_push, :vapid, %{
        public_key: "BTestPublicKey",
        private_key: "TestPrivateKey",
        subject: "mailto:test@example.com"
      })

      try do
        assert Push.public_key() == "BTestPublicKey"
      after
        if original do
          Application.put_env(:web_push, :vapid, original)
        else
          Application.delete_env(:web_push, :vapid)
        end
      end
    end

    test "treats an empty public_key string as not-configured" do
      # The runtime.exs default for unset vars is "" (empty string).
      # Treat it as "no VAPID" rather than trying to send with a
      # zero-length key — that's a config bug, not a valid deployment.
      original = Application.get_env(:web_push, :vapid)

      Application.put_env(:web_push, :vapid, %{
        public_key: "",
        private_key: "TestPrivateKey",
        subject: "mailto:test@example.com"
      })

      try do
        assert Push.public_key() == nil
      after
        if original do
          Application.put_env(:web_push, :vapid, original)
        else
          Application.delete_env(:web_push, :vapid)
        end
      end
    end

    test "accepts a keyword-list VAPID config (regression for web_push 0.1's Keyword.get/3 crash)" do
      # `web_push` 0.1's `Vapid.config!/0` only matches keyword
      # lists; our `config/runtime.exs` writes the VAPID keys as
      # a keyword list (the only shape that makes `web_push`
      # happy). Our wrapper must therefore also accept the
      # keyword-list shape — otherwise switching the runtime
      # config to the shape `web_push` expects would silently
      # disable push delivery (the dispatcher would short-
      # circuit on `public_key/0 == nil`).
      original = Application.get_env(:web_push, :vapid)

      Application.put_env(
        :web_push,
        :vapid,
        public_key: "BKeywordListShape",
        private_key: "TestPrivateKey",
        subject: "mailto:test@example.com"
      )

      try do
        assert Push.public_key() == "BKeywordListShape"
      after
        if original do
          Application.put_env(:web_push, :vapid, original)
        else
          Application.delete_env(:web_push, :vapid)
        end
      end
    end

    test "keyword-list VAPID with empty public_key still returns nil" do
      # Same defensive guard as the map variant: an empty string
      # in the `:public_key` slot means "operator forgot to set
      # the env var", not "valid deployment".
      original = Application.get_env(:web_push, :vapid)

      Application.put_env(
        :web_push,
        :vapid,
        public_key: "",
        private_key: "TestPrivateKey",
        subject: "mailto:test@example.com"
      )

      try do
        assert Push.public_key() == nil
      after
        if original do
          Application.put_env(:web_push, :vapid, original)
        else
          Application.delete_env(:web_push, :vapid)
        end
      end
    end
  end

  describe "deliver/2" do
    test "is a quiet no-op when VAPID isn't configured" do
      # The most important property of `deliver/2`: it never raises.
      # A misconfigured deployment (no VAPID keys) must keep the
      # in-page notification path working and silently skip the
      # web-push fan-out. Otherwise a freshly-deployed server would
      # log noisy errors every time a DTU went offline.
      #
      # Return contract: `deliver/2` reports
      # `{:ok, %{attempted: N, delivered: M}}` even when short-
      # circuiting. The zero-stats shape is what the dispatcher
      # keys on for the push→email fallback (`channel: "push"` user
      # with no live subscriptions) — it must look identical to
      # "no banners shown because no VAPID keys" so the fallback
      # path can't distinguish them.
      original = Application.get_env(:web_push, :vapid)
      Application.delete_env(:web_push, :vapid)

      try do
        # We use a no-arg `User` struct; `deliver/2` short-circuits
        # before reaching `PushSubscriptions.list_for_user/1`, so the
        # user isn't even looked up.
        fake_user = %DtuApp.Accounts.User{id: 0}

        assert {:ok, %{attempted: 0, delivered: 0}} =
                 Push.deliver(fake_user, %{event: "test", title: "x", body: "y"})
      after
        if original do
          Application.put_env(:web_push, :vapid, original)
        end
      end
    end

    test "deliver_many/2 is also a no-op when VAPID isn't configured" do
      # Same return contract as `deliver/2` — even with an empty
      # list and VAPID unset, the caller gets a zero-stats tuple so
      # the dispatcher's "channel=push + delivered=0 → fall back to
      # email" logic stays uniform.
      original = Application.get_env(:web_push, :vapid)
      Application.delete_env(:web_push, :vapid)

      try do
        assert {:ok, %{attempted: 0, delivered: 0}} =
                 Push.deliver_many([], %{event: "test"})
      after
        if original do
          Application.put_env(:web_push, :vapid, original)
        else
          Application.delete_env(:web_push, :vapid)
        end
      end
    end
  end

  describe "send_to/2 log lines (silent-drop investigation)" do
    # The structured `[push] gone …` / `[push] failed …` log lines
    # are the operator's only signal that a push delivery failed
    # (per-subscription errors don't bubble up to the caller of
    # `deliver/2`). Verify they're not emitted when the fan-out is
    # already short-circuited (VAPID unset) — they belong to the
    # actual delivery path, not the no-op path.

    test "no [push] gone / [push] failed log lines when VAPID isn't configured" do
      original = Application.get_env(:web_push, :vapid)
      Application.delete_env(:web_push, :vapid)

      try do
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            Push.deliver_many(
              [
                %DtuApp.PushSubscriptions.PushSubscription{
                  id: 1,
                  user_id: 7,
                  endpoint: "https://fcm.googleapis.com/fcm/send/secret-token?gcm=true",
                  p256dh: "x",
                  auth: "y"
                }
              ],
              %{event: "sun_up"}
            )
          end)

        # `deliver_many/2` short-circuits before `send_to/2`, so the
        # structured `[push] gone` / `[push] failed` lines never
        # appear. This guards against accidentally emitting log
        # noise even when push delivery is disabled.
        refute log =~ "[push] gone"
        refute log =~ "[push] failed"
        refute log =~ "secret-token"
      after
        if original do
          Application.put_env(:web_push, :vapid, original)
        else
          Application.delete_env(:web_push, :vapid)
        end
      end
    end
  end

  describe "native_enabled?/2" do
    test "string-keyed event matches notify_* fields" do
      u = user_with(dtu: true, down: false, up: true)
      assert Push.native_enabled?(u, %{"event" => "dtu_connection"})
      refute Push.native_enabled?(u, %{"event" => "sun_down"})
      assert Push.native_enabled?(u, %{"event" => "sun_up"})
    end

    test "atom-keyed event matches notify_* fields" do
      u = user_with(dtu: false, down: true, up: false)
      assert Push.native_enabled?(u, %{event: :sun_down})
      refute Push.native_enabled?(u, %{event: :dtu_connection})
    end

    test "unknown event passes through" do
      assert Push.native_enabled?(user_with(), %{"event" => "test"})
    end

    test "malformed payload passes through" do
      assert Push.native_enabled?(user_with(), %{})
    end
  end

  describe "WebPush.send call-site (iOS background-push contract)" do
    # The whole point of native Web Push (vs. in-page PubSub) is
    # background delivery — a user with the PWA installed but the
    # tab closed expects a banner on the lock screen. iOS APNs is
    # the most common push service for this app's users; it
    # interprets the `Urgency` and `TTL` headers very specifically:
    #
    #   * `Urgency: high`  → wake-up notification (sound + banner
    #                        even when the device is locked).
    #                        `normal` is rate-limited and coalesced.
    #   * `TTL: 24h`       → past this, APNs drops the push. Shorter
    #                        TTL = "deliver only if I'm online right
    #                        now". We want background delivery, so
    #                        24h is the upper bound that still
    #                        aligns with user expectation.
    #
    # `web_push` library defaults happen to match these values
    # (TTL=86_400, Urgency="normal" — the latter is *not* what we
    # want), but the call site is what a future maintainer reads.
    # Assert the call site is explicit so a refactor can't silently
    # drop an opt back to the library default.

    setup do
      {:ok, src} = File.read(@push_path)
      %{src: src}
    end

    test "send_to/2 calls WebPush.send with an explicit ttl: 86_400", %{src: src} do
      assert src =~ ~r/WebPush\.send\([\s\S]*?ttl:\s*86_400[\s\S]*?\)/,
             "expected WebPush.send/3 call site to pass ttl: 86_400 explicitly. " <>
               "Without it, a library default change silently shortens or extends " <>
               "the push TTL, breaking the 24h user expectation."
    end

    test "send_to/2 calls WebPush.send with an explicit urgency: \"high\"", %{src: src} do
      # iOS APNs treats `Urgency: high` as a wake-up push (sound +
      # banner even when the device is locked). `normal` is
      # rate-limited and coalesced, which silently breaks the
      # background-delivery contract for users who installed the
      # PWA specifically to get lock-screen banners.
      assert src =~ ~r/WebPush\.send\([\s\S]*?urgency:\s*["']high["'][\s\S]*?\)/,
             "expected WebPush.send/3 call site to pass urgency: \"high\" explicitly. " <>
               "The web_push library default is \"normal\", which iOS APNs rate-limits " <>
               "and coalesces — that's exactly the silent-drop behaviour this fix targets."
    end

    test "send_to/2 keeps the third argument as an opts keyword list (not a map)", %{src: src} do
      # Sanity-check: opts must be a keyword list (or a literal call
      # without wrapping brackets — Elixir treats the trailing
      # `key: value` pairs as the call's keyword args). A map would
      # still compile but would silently drop the urgency key
      # (atom vs string) and break the test above without breaking
      # production — so we anchor on the keyword-list syntax
      # (`payload,` followed by `ttl:`) to make sure the call shape
      # is right.
      #
      # The shape under test:
      #
      #   WebPush.send(
      #     PushSubscription.to_web_push(sub),
      #     payload,
      #     ttl: 86_400,
      #     urgency: "high"
      #   )
      assert src =~ ~r/payload,[\s\S]*?ttl:\s*86_400,[\s\S]*?urgency:\s*["']high["']/,
             "expected WebPush.send/3 third arg to be the keyword list " <>
               "`ttl: 86_400, urgency: \"high\"`. A future refactor that " <>
               "drops the keyword list shape (e.g. passing a map) would silently drop the opts."
    end
  end
end
