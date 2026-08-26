defmodule DtuAppWeb.NotificationsJsTest do
  @moduledoc """
  Contract tests for `assets/js/notifications.js`.

  The `Notifications` JS hook (mounted on `/notifications` and
  `/dashboard`) is the actual consumer of `phx:notify` push events:
  it formats the server's payload into a browser `Notification` and
  dedups via `localStorage` so the same event doesn't re-fire on
  re-renders. The hook has no Elixir unit-test harness, so the
  tests below read the source file as text and assert the
  invariants that keep the user-visible flow working.

  Four regressions these tests guard:

    1. The "test" event must NOT be deduped. The `/notifications`
       page exposes a "Send test notification" button the user
       clicks deliberately to verify their setup; every click must
       fire a real `new Notification(...)`. Pre-fix, the dedup
       branch's `else` clause did `JSON.stringify(payload)` which
       produced a stable key across identical clicks, silently
       swallowing every click after the first.

    2. The `formatPayload` function must honor server-provided
       `title` / `body` / `tag` for unknown events. Pre-fix it
       fell through to a hard-coded `"dtu.app"` title and a
       `JSON.stringify(payload)` body, so the test button rendered
       as "dtu.app" with a JSON payload instead of the friendly
       "Test notification" / "If you can read this..." message.
       Same root cause affected the dashboard's
       `dtu_connection` events.

    3. The `handleNotify` hook must read the payload via
       `e.detail` (the object), not `e.detail[0]` (the first
       enumerable key as a string). Pre-fix, the hook read
       `(e.detail || {})[0]` which on a plain object returned the
       first key like `"event"`. The next
       `typeof payload !== "object"` guard then short-circuited
       the whole handler, so no system notification ever fired
       since the hook was first written. This is the bug that
       survived PR #73.

    4. The hook must log every interesting state transition
       (event received, payload extracted, permission check,
       dedup hit, Notification result) under a `[Notifications]`
       console tag. This hook has had three silent failures in a
       row. Without diagnostic logging, the only way to find the
       next bug is to add logging after the fact, push, and ask
       the user to retest. Logging at the source means the user
       can see in DevTools exactly which guard short-circuited
       the click and report back the concrete error.

  The tests are substring/regex matches against the source on
  disk. Same pattern as `PwaSafeAreaTest` and `ServiceWorkerTest`
  — keeps the contract honest without needing a JS unit-test
  harness.
  """

  use ExUnit.Case, async: true

  @js_path "assets/js/notifications.js"
  @bundled_path "priv/static/assets/js/app.js"

  setup do
    {:ok, source} = File.read(@js_path)
    bundled = if File.exists?(@bundled_path), do: File.read!(@bundled_path), else: ""
    %{source: source, bundled: bundled}
  end

  describe "handleNotify — the test event must always fire" do
    test "skips dedup for payload.event === 'test'", %{source: source} do
      # The whole point of the test button is that the user
      # deliberately re-clicks it to verify their setup. Dedup
      # would defeat the purpose — pre-fix, the second click was
      # silently swallowed because the dedup key was stable.
      assert source =~ ~r/if\s*\(\s*payload\.event\s*!==\s*["']test["']\s*\)\s*\{/,
             "expected `handleNotify` to skip the dedup branch for the " <>
               "`test` event so re-clicks always fire."
    end

    test "doesn't call storageMark for the test event", %{source: source} do
      # `storageMark` writes the dedup key. If the source calls
      # it inside the `handleNotify` body without a guard, the
      # test event still gets a (unique) key, but more importantly
      # the existing test in `notifications_live_test.exs` pins
      # that the test button always fires — the handler must not
      # short-circuit the click on a `localStorage.getItem(...)`
      # hit. We assert that the dedup call sits inside the
      # `if (payload.event !== 'test')` block, not at the top
      # of the handler.
      assert source =~
               ~r/if\s*\(\s*payload\.event\s*!==\s*["']test["']\s*\)\s*\{[\s\S]*?storageMark/s,
             "expected `storageMark` to be gated by the `event !== 'test'` " <>
               "check so the test event skips dedup entirely."
    end
  end

  describe "handleNotify — payload extraction (regression for the silent-swallow bug)" do
    # LiveView's server-push pipeline does
    # `dispatchEvent(window, "phx:notify", { detail: payload })`,
    # so `e.detail` IS the payload object — not an array of
    # payloads. Pre-fix the hook read `(e.detail || {})[0]`, which
    # on a plain object returned the first enumerable KEY as a
    # string (e.g. `"event"` for the test payload). The next
    # guard `typeof payload !== "object"` then short-circuited the
    # whole handler, so no system notification ever fired — the
    # user only saw the server-side `:info` flash from
    # `handle_event("test_notification", ...)`.
    #
    # The fix is one line: `e.detail` (not `e.detail[0]`). These
    # tests pin both the corrected extraction AND the absence of
    # the buggy `e.detail[0]` pattern, so a future refactor that
    # re-introduces the bug fails the test loudly.

    test "extracts payload via `e.detail` (not `e.detail[0]`)", %{source: source} do
      assert source =~ ~r/const\s+payload\s*=\s*e\.detail\s*\|\|\s*\{\s*\}\s*$/m,
             "expected `handleNotify` to extract the payload via `e.detail` " <>
               "(LiveView's `dispatchEvent` puts the payload there directly). " <>
               "Pre-fix the code read `e.detail[0]` which returned the first " <>
               "enumerable key as a string and the next `typeof payload !== " <>
               "'object'` guard then silently returned."
    end

    test "does not read `e.detail[0]` in code (the broken array-style extraction)", %{
      source: source
    } do
      # Strip `//` and `/* */` comments so the regression guard only
      # catches *code* references to `e.detail[0]`. The moddoc and
      # the bug-history comment in the source both mention
      # `e.detail[0]` by name — those should not trigger the
      # regression guard, only actual `obj[0]` reads on `e.detail`.
      code_only =
        source
        |> String.replace(~r/\/\*[\s\S]*?\*\//, "")
        |> String.replace(~r|\/\/[^\n]*|, "")

      refute code_only =~ ~r/e\.detail\s*\[\s*0\s*\]/,
             "`e.detail[0]` reads the first enumerable KEY on a plain object " <>
               "(e.g. \"event\" for the test payload) as a string. The next " <>
               "`typeof payload !== 'object'` guard then silently returns. " <>
               "This is the bug that prevented any system notification " <>
               "from firing since the hook was first written."
    end

    test "the bundled app.js also drops the e.detail[0] bug (in code)", %{bundled: bundled} do
      if bundled == "" do
        IO.puts("bundle not built — skipping (priv/static/assets/js/app.js missing)")
      else
        # The minified bundle has no comments to strip — it should
        # not contain `e.detail[0]` at all.
        refute bundled =~ ~r/e\.detail\s*\[\s*0\s*\]/,
               "expected the minified bundle to drop the e.detail[0] bug. " <>
                 "Re-run `mix esbuild dtu_app` to refresh the bundle."
      end
    end
  end

  describe "formatPayload — must honor server-provided title/body" do
    test "honors payload.title for events outside the hard-coded taxonomy", %{source: source} do
      # The test-notification button (and the dashboard's
      # `dtu_connection` events) ship a server-rendered
      # `title` / `body` / `tag` payload. Pre-fix the hook only
      # knew about `sun_down` / `dtu_offline` / `dtu_online` and
      # fell through to a hard-coded `"dtu.app"` title with a
      # `JSON.stringify(payload)` body, so the test button
      # rendered as "dtu.app" instead of "Test notification".
      assert source =~ ~r/if\s*\(\s*payload\.title\s*\|\|\s*payload\.body\s*\)\s*\{/,
             "expected `formatPayload` to trust server-provided " <>
               "title/body when present (for the test button and the " <>
               "dashboard's dtu_connection events)."
    end

    test "server-supplied title is preferred over the hard-coded 'dtu.app'", %{source: source} do
      # After the new branch is taken, the returned object's
      # `title` must be the server's title, not the hard-coded
      # fallback. This is what users see in the OS notification
      # banner.
      assert source =~ ~r/title:\s*payload\.title\s*\|\|\s*["']dtu\.app["']/,
             "expected `formatPayload`'s fallback branch to use the " <>
               "server's title verbatim."
    end

    test "server-supplied tag is used for OS-level grouping", %{source: source} do
      # The server's `tag` is what the OS uses to coalesce
      # multiple notifications into one (e.g. the dashboard's
      # `dtu:<name>` tag groups all state changes for the same
      # inverter). Pre-fix the fallthrough used `misc:<date>`
      # which broke OS-level grouping.
      assert source =~ ~r/tag:\s*payload\.tag\s*\|\|\s*`misc:/,
             "expected `formatPayload` to honor the server's tag " <>
               "for OS-level notification grouping."
    end
  end

  describe "computeDedupKey — must handle every event the server fires" do
    test "matches `test` events with a unique key (defense in depth)", %{source: source} do
      # `handleNotify` skips dedup for `test`, but the function
      # itself still has a `test` branch so callers that route
      # the event through dedup don't crash with a generic
      # JSON-stringified key. The test key is unique-per-call
      # (`Date.now()`) which is fine because no caller is
      # supposed to reach this branch.
      assert source =~
               ~r/payload\.event\s*===\s*["']test["'][\s\S]*?notified:v1:user:\$\{userId\}:test:/,
             "expected `computeDedupKey` to have an explicit " <>
               "`test` branch with a unique-per-call key."
    end

    test "matches `sun_down` events with date-keyed dedup", %{source: source} do
      assert source =~ ~r/sun_down[\s\S]*?sun_down:\$\{payload\.date\s*\|\|\s*todayIso\(\)\}/,
             "expected `computeDedupKey` to dedup `sun_down` events " <>
               "by date so the same day's summary fires once."
    end

    test "matches `sun_up` events with the server-provided tag", %{source: source} do
      # Sun-up also fires once per local day (the server tags it
      # `sun_up:<iso-date>` in the user's local TZ). Falling
      # through to the JSON-stringify fallback would hash the
      # identical body string and accidentally dedup the next
      # morning's sun-up — pinning an explicit branch here so
      # the producer's per-day tag is honoured.
      assert source =~
               ~r/sun_up[\s\S]*?sun_up:\$\{payload\.tag\s*\|\|\s*`sun_up:\$\{todayIso\(\)\}`\}/,
             "expected `computeDedupKey` to dedup `sun_up` events " <>
               "by the server-provided `tag` (per-user local day)."
    end

    test "matches `dtu_offline` / `dtu_online` events by dtu_id+inverter_serial", %{
      source: source
    } do
      # Pin that the offline/online handlers each have their own
      # dedup key — sharing a key would coalesce "offline" and
      # "back online" into one event when the user toggles both.
      assert source =~
               ~r/dtu_offline[\s\S]*?dtu_offline:\$\{payload\.dtu_id\}:\$\{payload\.inverter_serial\}/,
             "expected dtu_offline dedup key by dtu_id+inverter_serial"

      assert source =~
               ~r/dtu_online[\s\S]*?dtu_online:\$\{payload\.dtu_id\}:\$\{payload\.inverter_serial\}/,
             "expected dtu_online dedup key by dtu_id+inverter_serial"
    end

    test "matches `dtu_connection` events by tag+status (server-provided)", %{source: source} do
      # The dashboard's `broadcast_dtu_connection/3` fires
      # `event: "dtu_connection"` with a server-rendered `tag`
      # like "dtu:<name>". We need a stable key that doesn't
      # coalesce offline→online→offline (a transient blip +
      # recovery) into one event.
      assert source =~
               ~r/dtu_connection[\s\S]*?notified:v1:user:\$\{userId\}:\$\{payload\.tag\s*\|\|/,
             "expected `computeDedupKey` to use the server's tag " <>
               "for dtu_connection events"
    end
  end

  describe "dedup TTL — entries must expire so the next real event fires" do
    test "storageHas reads the timestamp and compares against a TTL", %{source: source} do
      # Pre-fix `storageHas` returned `localStorage.getItem(key) !== null`,
      # which meant once any (tag, status) pair fired, the slot was
      # burned for the lifetime of the browser's storage. The user's
      # history table filled up while banners stopped landing. Pin that
      # the function now parses the timestamp and expires entries.
      assert source =~ ~r/function\s+storageHas[\s\S]*?Date\.parse/s,
             "expected `storageHas` to parse the stored timestamp"

      assert source =~ ~r/storageHas\([^)]*ttlMs[\s\S]*?Date\.now\(\)\s*-\s*stamped\s*<\s*ttlMs/s,
             "expected `storageHas` to compare Date.now() against the TTL"
    end

    test "the dedup call site passes a TTL (5 minutes) to storageHas", %{source: source} do
      # The 5-minute window covers reconnect storms and LiveView
      # re-mounts on `nav` without masking the next genuine event
      # # (which would only fire minutes/hours later for sun-up and
      # # sun-down, and minutes later for dtu_connection at the
      # # earliest). Pin the TTL value so it can't drift to "0" (=
      # # permanently off) or to "infinity" (= no dedup at all).
      assert source =~ ~r/storageHas\(\s*dedupKey\s*,\s*5\s*\*\s*60\s*\*\s*1000\s*\)/,
             "expected `handleNotify` to pass a 5-minute TTL to `storageHas`"
    end
  end

  describe "bundled app.js — fix must reach the browser" do
    # `mix esbuild dtu_app` runs in the asset build pipeline; the
    # bundle is what the browser actually loads. These tests run
    # after the asset is built (the e2e pipeline builds it as
    # part of `mix assets.deploy`). They guard against a refactor
    # that updates the source but forgets to rebuild, or vice
    # versa.
    @tag :bundled
    test "the new 'test' bypass lands in app.js", %{bundled: bundled} do
      if bundled == "" do
        IO.puts("bundle not built — skipping (#{@bundled_path} missing)")
      else
        assert bundled =~ ~r/if\s*\(\s*[a-zA-Z_]+\.event\s*!==\s*["']test["']\s*\)\s*\{/,
               "expected the bundled app.js to contain the `if (event !== 'test')` " <>
                 "guard. Run `mix esbuild dtu_app` to refresh the bundle."
      end
    end
  end

  describe "diagnostic logging — required to debug future notification issues" do
    # This hook has had three silent failures in a row (e.detail[0]
    # extraction, missing formatPayload branches, missing dedup
    # bypass). Without `console.log`s the user has no way to tell
    # whether the event reached the hook, whether the payload is
    # well-formed, or whether the dedup branch swallowed the event.
    # Open DevTools → Console to see the live trace.
    test "logs the phx:notify event with the [Notifications] tag", %{source: source} do
      assert source =~ ~r/console\.log\(\s*["']\[Notifications\]\s*phx:notify\s*received/,
             "expected handleNotify to log the incoming event for diagnostic " <>
               "tracing. Without it the user has no way to see whether the " <>
               "event reached the hook at all."
    end

    test "logs the extracted payload", %{source: source} do
      assert source =~ ~r/console\.log\(\s*["']\[Notifications\]\s*payload\s*extracted/,
             "expected handleNotify to log the payload after extraction. " <>
               "Pin whether the e.detail extraction is returning the right object."
    end

    test "logs the permission state when it isn't granted", %{source: source} do
      assert source =~
               ~r/console\.warn\(\s*\n?\s*["']\[Notifications\]\s*aborting:\s*Notification\.permission/,
             "expected handleNotify to log Notification.permission when the " <>
               "permission check fails. The user needs this to distinguish " <>
               "between 'permission denied' and 'hook didn't fire'."
    end

    test "logs the dedup-hit reason", %{source: source} do
      assert source =~ ~r/console\.log\(\s*["']\[Notifications\]\s*aborting:\s*dedup\s*hit/,
             "expected handleNotify to log dedup hits. Pin whether the test " <>
               "event was eaten by the dedup branch (which it shouldn't be)."
    end

    test "logs the new Notification result", %{source: source} do
      assert source =~ ~r/console\.log\(\s*["']\[Notifications\]\s*Notification\s*created\s*OK/,
             "expected handleNotify to log the result of new Notification(). " <>
               "Pin whether the browser actually accepted the call."
    end
  end

  describe "iOS detection (PWA must be Add to Home Screen to receive notifications)" do
    # iOS Safari + Firefox-iOS gate the Web Notifications API behind
    # the "Add to Home Screen" PWA install. A regular browser tab
    # has the API *defined* but `new Notification()` no-ops, and
    # `Notification.permission` is unreliable. Without this
    # detection the user sees the in-app flash and assumes the
    # server is broken — when in fact they just need to install
    # the PWA.
    test "defines an isIOS() helper on the hook", %{source: source} do
      assert source =~ ~r/isIOS\(\)\s*\{/,
             "expected the hook to expose an isIOS() helper so the " <>
               "diagnostic output can warn iOS users specifically."
    end

    test "isIOS() matches iPad / iPhone / iPod user agents", %{source: source} do
      assert source =~ ~r/iPad\|iPhone\|iPod/,
             "expected isIOS() to detect iPad / iPhone / iPod user agents."
    end

    test "isIOS() also matches iPad-on-macOS (MacIntel + multi-touch)", %{source: source} do
      # iPad running macOS in compatibility mode reports
      # `navigator.platform === "MacIntel"` with multiple touch
      # points. The dual-flag check catches that.
      assert source =~
               ~r/navigator\.platform\s*===\s*["']MacIntel["']\s*&&\s*navigator\.maxTouchPoints/,
             "expected isIOS() to also catch iPad-on-macOS via the " <>
               "MacIntel + maxTouchPoints heuristic."
    end

    test "defines an isInstalledPWA() helper on the hook", %{source: source} do
      # `display-mode: standalone` is the cross-browser check; the
      # `navigator.standalone === true` fallback covers older
      # iOS Safari which doesn't support the media query.
      assert source =~
               ~r/isInstalledPWA\(\)\s*\{[\s\S]*?matchMedia\(\s*["']\(display-mode:\s*standalone\)["']\)/,
             "expected isInstalledPWA() to detect a PWA via " <>
               "`display-mode: standalone`."

      assert source =~ ~r/navigator\.standalone\s*===\s*true/,
             "expected isInstalledPWA() to also check navigator.standalone " <>
               "for iOS Safari which doesn't support the display-mode " <>
               "media query in older versions."
    end

    test "logs an iOS-specific warning when the user is on iOS without the PWA installed", %{
      source: source
    } do
      assert source =~ ~r/isIOS\(\)\s*&&\s*!this\.isInstalledPWA\(\)/,
             "expected the hook to gate the iOS warning on (iOS && !installed) " <>
               "so non-iOS users don't see it."

      assert source =~ ~r/console\.warn\([\s\S]*?iOS[\s\S]*?installed via Add to Home Screen/,
             "expected the iOS warning to mention 'Add to Home Screen' so the " <>
               "user knows what to do. Without that hint they wouldn't know the " <>
               "OS-level notifications API is gated behind the home-screen install."
    end
  end
end
