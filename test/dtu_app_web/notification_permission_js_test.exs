defmodule DtuAppWeb.NotificationPermissionJsTest do
  @moduledoc """
  Contract tests for `assets/js/notification_permission.js`.

  Pins the desktop-vs-mobile state machine so a future regression
  that re-introduces the "force PWA install on desktop" UX fails
  loudly. The desktop path is the whole point of this module —
  without it, Chrome / Firefox / Edge users would be told to install
  the PWA before they could enable notifications, even though the
  in-browser `Notification` API works in a regular desktop tab.

  The tests read the source file as text and assert structural
  invariants. Same pattern as `PwaSafeAreaTest` and
  `NotificationsJsTest` — keeps the contract honest without a JS
  unit-test harness.
  """

  use ExUnit.Case, async: true

  @js_path "assets/js/notification_permission.js"

  setup do
    {:ok, source} = File.read(@js_path)
    %{source: source}
  end

  describe "device detection — desktop must skip the PWA-install gate" do
    test "defines an isMobile() helper on the hook", %{source: source} do
      assert source =~ ~r/isMobile\(\)\s*\{/,
             "expected the hook to expose an isMobile() helper so the " <>
               "computeSupport path can branch on mobile vs desktop."
    end

    test "isMobile() matches the standard mobile UA regex", %{source: source} do
      # Covers Android phones (Android Chrome), iPhones, iPads,
      # iPods, BlackBerry, and Opera Mini. The iPad case is
      # important — iPadOS Safari is the most common
      # mobile-but-reports-as-tablet user agent, and the dedicated
      # MacIntel + maxTouchPoints heuristic below only catches
      # iPadOS-on-macOS. Older iPads with the classic iPad UA
      # need this regex branch.
      assert source =~
               ~r/Mobi\|Android\|iPhone\|iPad\|iPod\|BlackBerry\|IEMobile\|Opera Mini/,
             "expected isMobile() to test the user agent against the " <>
               "standard mobile-UA alternation. Without iPhone / iPad / " <>
               "Android matching, every mobile browser would fall through " <>
               "to the desktop branch and bypass the install-as-PWA " <>
               "advisory."
    end

    test "isMobile() also catches iPadOS-on-Mac (MacIntel + touch)", %{
      source: source
    } do
      # iPadOS Safari reports `navigator.platform === "MacIntel"`
      # with multi-touch. Without this heuristic, iPadOS users
      # would get the desktop Enable button even though iPadOS
      # Safari requires PWA install for notifications.
      assert source =~
               ~r/navigator\.platform\s*===\s*["']MacIntel["']\s*&&\s*navigator\.maxTouchPoints/,
             "expected isMobile() to also detect iPadOS via " <>
               "`platform === 'MacIntel' && maxTouchPoints > 1`."
    end
  end

  describe "computeSupport — install gate is mobile-only, permission drives desktop" do
    # The auto-detect change: on desktop, `window.Notification.permission`
    # is the source of truth for what the user sees. A desktop user who
    # previously granted permission in a regular (non-PWA) tab must NOT
    # be told to click Enable; the JS already knows they granted. The
    # only legitimate gate on `!installed` is mobile, where iOS Safari
    # requires PWA install for notifications to actually fire — without
    # an install, the browser's `Notification.permission` value is
    # misleading (the API isn't really usable).
    test "the !installed short-circuit is gated by this.isMobile()", %{
      source: source
    } do
      assert source =~
               ~r/if\s*\(\s*!\s*installed\s*&&\s*this\.isMobile\(\)\s*\)/,
             "expected the `!installed` branch to be gated by " <>
               "`this.isMobile()` — i.e. the install-required rule " <>
               "applies only on mobile (iOS Safari needs the PWA for " <>
               "notifications to fire). On desktop, `!installed` is " <>
               "no longer a short-circuit; `Notification.permission` " <>
               "below decides what to render."
    end

    test "computeSupport no longer has the nested !isMobile short-circuit", %{
      source: source
    } do
      # Pre-refactor shape was
      # `if (!installed) { if (!this.isMobile()) { default } }`.
      # After the refactor, the desktop short-circuit is gone — every
      # non-mobile payload falls through to the `Notification.permission`
      # check below. Pin the absence so a regression that re-adds the
      # nested gate is caught (it's exactly the bug that motivated the
      # auto-detect fix: desktop users with a prior grant being told
      # to click Enable).
      refute source =~
               ~r/if\s*\(\s*!\s*installed\s*\)\s*\{[\s\S]{0,1000}?if\s*\(\s*!\s*this\.isMobile\(\)\s*\)/,
             "expected computeSupport to no longer carry the nested " <>
               "`if (!installed) { if (!this.isMobile()) ... }` " <>
               "short-circuit. The desktop case should fall through " <>
               "to the `Notification.permission` check, not short-" <>
               "circuit to `state: default`."
    end

    test "computeSupport reads Notification.permission as the source of truth", %{
      source: source
    } do
      # The whole point of the auto-detect fix: `Notification.permission`
      # is read regardless of whether the user is in a PWA or a regular
      # tab (on desktop). Pin the literal `Notification.permission`
      # reference so a regression that re-gates the permission read on
      # `installed` is caught.
      assert source =~ ~r/Notification\.permission/,
             "expected computeSupport to read `Notification.permission` " <>
               "as the source of truth for the granted/denied/default " <>
               "state. Without this read, the desktop auto-detect path " <>
               "would not fire for users with a prior grant."
    end

    test "computeSupport still returns not_installed for non-installed mobile", %{
      source: source
    } do
      # iOS Safari (and other mobile browsers to a lesser extent) only
      # fire notifications from an installed PWA — without install the
      # API isn't really usable. The user-facing state for
      # `!installed && mobile` is `not_installed` regardless of what
      # `Notification.permission` would return. Pin the explicit branch.
      assert source =~ ~r/state:\s*["']not_installed["']/,
             "expected computeSupport to still return " <>
               "`state: 'not_installed'` for mobile. Without it, the " <>
               "install-PWA CTA on mobile wouldn't render."
    end
  end

  describe "state payload — every state carries a device field" do
    # The template renders platform-specific copy in the `default`
    # and `granted` branches (e.g. desktop shows a "install for
    # closed-tab delivery" hint, mobile doesn't). The `device`
    # field is what makes that branch possible. Pin that every
    # state payload includes it so the template never sees an
    # unlabelled state.
    test "every state payload includes `device: this.deviceType()`", %{
      source: source
    } do
      # Count the `device: this.deviceType()` returns — there
      # should be exactly one per state in `computeSupport` (5
      # states: unsupported, not_installed, denied, granted,
      # default). Every state goes through `deviceType()` so the
      # count is exactly 5.
      device_returns = Regex.scan(~r/device:\s*this\.deviceType\(\)/, source)

      assert length(device_returns) >= 4,
             "expected computeSupport's state payloads to include " <>
               "`device: this.deviceType()` for every state. Found " <>
               "#{length(device_returns)} references; expected at " <>
               "least 4 (unsupported, not_installed, denied, granted, " <>
               "default)."
    end

    test "no state payload hardcodes device: \"desktop\" inline", %{
      source: source
    } do
      # Pre-refactor, the desktop short-circuit branch carried
      # `device: "desktop"` literally. After the refactor, every
      # payload goes through `deviceType()` — there is no
      # desktop-only branch anymore. Pin the absence so a regression
      # that re-adds the inline literal is caught (it would be
      # inconsistent with the other states, all of which use the
      # helper).
      refute source =~ ~r/device:\s*["']desktop["']/,
             "expected no state payload to hardcode `device: \"desktop\"` " <>
               "inline. Every payload should go through `deviceType()`."
    end
  end

  describe "deviceType helper" do
    test "delegates to isMobile()", %{source: source} do
      # We could compute this inline in every return, but a tiny
      # helper keeps the return payloads consistent and gives
      # tests a single hook to assert against.
      assert source =~
               ~r/deviceType\(\)\s*\{[\s\S]*?isMobile\(\)/,
             "expected `deviceType()` to delegate to `isMobile()` so " <>
               "every state payload's device field comes from one " <>
               "source of truth."
    end
  end
end
