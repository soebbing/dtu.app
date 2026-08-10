defmodule DtuAppWeb.PushSubscribeJsTest do
  @moduledoc """
  Contract tests for `assets/js/push_subscribe.js`.

  The `PushSubscribe` hook (mounted on `/notifications`) owns the
  VAPID push-subscription lifecycle. The hook is plain JS without a
  unit-test harness, so the tests below read the source file as text
  and assert the invariants that keep the user-visible flow working.

  Five regressions these tests guard:

    1. The hook must POST to `/push/subscribe` (not any other path).
       A typo here would silently 404 every subscription attempt
       without surfacing in the UI — the user would see "granted" in
       the panel but never receive native push.

    2. The POST body must include the full nested
       `PushSubscription#toJSON()` shape (endpoint + keys.p256dh +
       keys.auth). Pre-fix a stripped body would 400 from the
       controller and the hook would log a confusing "subscribe
       failed" without telling the user why.

    3. The hook must include the CSRF token via `X-CSRF-Token` from
       `<meta name="csrf-token">`. Without that header the
       `:protect_from_forgery` plug rejects the POST and the user
       sees no error in the panel.

    4. The hook must feature-detect `PushManager` and gracefully
       skip on iOS Safari < 16.4 / Firefox-iOS — these browsers
       grant `Notification.permission = "granted"` but don't
       implement Web Push. Without the guard the
       `PushManager.subscribe` call throws and the user sees
       "Native push failed" in the console even though their browser
       is technically behaving correctly.

    5. The hook must NOT call `subscription.unsubscribe()` from its
       `destroyed()` callback. The push subscription is owned by
       the *service worker*, not the page; auto-unsubscribing on
       hook destroy would silently revoke every native push
       subscription the moment the user navigates away from
       `/notifications` — and they'd have no UI to re-enable it
       short of waiting for the page to reload.

  The tests are substring/regex matches against the source on
  disk. Same pattern as `NotificationsJsTest`,
  `DtuAppWeb.PwaSafeAreaTest`, and `ServiceWorkerTest`.
  """

  use ExUnit.Case, async: true

  @js_path "assets/js/push_subscribe.js"

  setup do
    {:ok, source} = File.read(@js_path)
    %{source: source}
  end

  describe "endpoint + body shape" do
    test "posts to /push/subscribe (not a typo'd path)", %{source: source} do
      assert source =~ ~r/fetch\(\s*["']\/push\/subscribe["']/,
             "expected the hook to POST /push/subscribe exactly"
    end

    test "serializes the full PushSubscription#toJSON() shape", %{source: source} do
      # The hook reads `subscription.toJSON()` directly — which gives
      # `{endpoint, keys: {p256dh, auth}, expirationTime}`. We
      # specifically need `keys.p256dh` and `keys.auth` to round-trip
      # because `RFC 8291` payload encryption requires both.
      assert source =~ ~r/subscription\.toJSON\(\)/,
             "expected the hook to call subscription.toJSON() to capture endpoint + keys"

      assert source =~ ~r/JSON\.stringify\(json\)/,
             "expected the hook to JSON.stringify the subscription before posting"
    end
  end

  describe "CSRF token header" do
    test "reads the csrf token from <meta name='csrf-token'>", %{source: source} do
      # The token is session-stable and exposed by the root layout
      # (`<meta name="csrf-token" content={get_csrf_token()} />`).
      # The hook reads it once on mount.
      assert source =~ ~r/<meta\s+name=['"]csrf-token['"]/,
             "expected the hook to read the csrf token from <meta name=\"csrf-token\">"
    end

    test "sends X-CSRF-Token on every fetch call", %{source: source} do
      # Both `/push/subscribe` and `/push/unsubscribe` need the
      # header — `:protect_from_forgery` rejects the POST otherwise.
      assert source =~ ~r/["']X-CSRF-Token["']/,
             "expected X-CSRF-Token header on fetch calls"
    end
  end

  describe "feature detection" do
    test "guards on PushManager undefined", %{source: source} do
      # iOS Safari < 16.4 and Firefox-iOS don't implement Web Push.
      # They DO define `Notification` (and `Notification.permission`
      # can be `"granted"`), so the only safe check is
      # `typeof PushManager === "undefined"`.
      assert source =~ ~r/PushManager\s*===?\s*["']undefined["']/,
             "expected a typeof PushManager === \"undefined\" guard so iOS < 16.4 / Firefox-iOS skip cleanly"
    end

    test "guards on Notification.permission != granted", %{source: source} do
      # The hook auto-subscribes only when the OS has granted
      # permission. Without this guard the hook would attempt
      # `PushManager.subscribe()` for every visit, even before the
      # user has clicked Enable.
      assert source =~ ~r/Notification\.permission\s*[!=]==?\s*["']granted["']/,
             "expected a Notification.permission guard before subscribing"
    end
  end

  describe "VAPID public key handling" do
    test "fetches the public key from /push/vapid/public_key", %{source: source} do
      assert source =~ ~r/fetch\(\s*["']\/push\/vapid\/public_key["']/,
             "expected the hook to GET /push/vapid/public_key"
    end

    test "converts URL-safe base64 to a Uint8Array for applicationServerKey", %{source: source} do
      # The VAPID spec hands the application server key as URL-safe
      # base64; the PushManager.subscribe() API expects a BufferSource.
      assert source =~ ~r/urlBase64ToUint8Array/,
             "expected the hook to base64-decode the public key before handing it to PushManager"
    end

    test "sets userVisibleOnly: true (RFC 8030 §4.1 requires it)", %{source: source} do
      # Web Push requires every push subscription to be
      # `userVisibleOnly: true` — silent pushes are forbidden. A
      # `false` value here would throw on every subscribe.
      assert source =~ ~r/userVisibleOnly:\s*true/,
             "expected userVisibleOnly: true on the PushManager.subscribe call"
    end
  end

  describe "lifecycle invariants" do
    test "destroyed() does NOT call subscription.unsubscribe()", %{source: source} do
      # The push subscription is owned by the service worker, not the
      # page. Auto-unsubscribing on hook destroy would silently revoke
      # native push the moment the user navigates away — and they'd
      # have no UI to re-enable it short of reloading the page.
      #
      # We extract the `destroyed()` body and assert it doesn't
      # *invoke* a method named `unsubscribe`. We accept the word in
      # comments (the source explicitly explains *why* the hook
      # doesn't auto-unsubscribe) but reject `.unsubscribe(` (an
      # actual method call).
      destroyed_block =
        Regex.run(~r/destroyed\(\)\s*\{([\s\S]*?)\n\s*\},?/, source, capture: :all_but_first)
        |> List.first()

      assert is_binary(destroyed_block),
             "expected to find a destroyed() block in the source"

      refute destroyed_block =~ ~r/\.unsubscribe\s*\(/,
             "destroyed() must NOT call .unsubscribe() — push is owned by the SW, not the page"
    end

    test "exposes a public unsubscribe() function for explicit disable", %{source: source} do
      # The "Disable notifications" UI (or a future /push/unsubscribe
      # call) needs a way to actually revoke the subscription.
      # Mirror the destroy-invariance: an explicit `unsubscribe()`
      # method must exist for that flow.
      assert source =~ ~r/async\s+unsubscribe\s*\(\s*\)/,
             "expected an explicit unsubscribe() method the hook or a future 'Disable' button can call"
    end
  end

  describe "diagnostic logging" do
    test "logs every interesting state transition under a [PushSubscribe] tag", %{source: source} do
      # Like `assets/js/notifications.js`, this hook has a long
      # history of silent failures (iOS detection, permission gates,
      # feature detection, CSRF token). Verbose logging is the only
      # way the user can see in DevTools which guard short-circuited
      # the click.
      assert source =~ ~r/\[PushSubscribe\]/,
             "expected diagnostic logs tagged [PushSubscribe]"
    end
  end
end
