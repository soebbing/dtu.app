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

  describe "computeSupport — desktop non-installed falls through to 'default'" do
    # The whole point of the change: a non-installed desktop browser
    # must NOT receive `state: "not_installed"`. Instead it must
    # receive `state: "default"` (with `installed: false`) so the
    # template renders the Enable button. Pre-change this returned
    # `not_installed` regardless of platform and forced every
    # desktop user through the install-PWA wall.
    test "computeSupport returns default for non-installed desktop", %{
      source: source
    } do
      # The `!installed` branch must include a `!this.isMobile()`
      # gate. The most common regression shape is a plain
      # `if (!installed) { return {state: "not_installed", ...} }`
      # without any device check — that's the buggy pre-change
      # behaviour that forced every desktop user through the
      # install-PWA wall. The pin below matches the nested shape:
      # `if (!installed) { ... if (!this.isMobile()) { default } ... }`.
      assert source =~
               ~r/if\s*\(\s*!\s*installed\s*\)\s*\{[\s\S]{0,1000}?if\s*\(\s*!\s*this\.isMobile\(\)\s*\)/,
             "expected computeSupport to gate the desktop short-circuit " <>
               "on `!this.isMobile()` inside the `!installed` branch. A " <>
               "plain `if (!installed) return 'not_installed'` (without " <>
               "the isMobile check) would re-introduce the bug where " <>
               "every non-installed browser — desktop included — gets " <>
               "'not_installed'."
    end

    test "computeSupport still returns not_installed for non-installed mobile", %{
      source: source
    } do
      # Mobile users still need the install advisory (iOS Safari
      # gates notifications behind Add to Home Screen; Android
      # Chrome in a regular tab is unreliable enough that the
      # advisory is the right default). Pin the explicit branch.
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
      # states: unsupported, default, not_installed, denied,
      # granted). The default branch now declares `device:
      # "desktop"` inline rather than via deviceType(), so count
      # is 4 deviceType() references + 1 inline = 5.
      device_returns = Regex.scan(~r/device:\s*this\.deviceType\(\)/, source)

      assert length(device_returns) >= 4,
             "expected computeSupport's state payloads to include " <>
               "`device: this.deviceType()` for every non-default " <>
               "state. Found #{length(device_returns)} references; " <>
               "expected at least 4 (unsupported, denied, granted, " <>
               "and the installed-default branch)."
    end

    test "the desktop non-installed branch carries device: \"desktop\" inline", %{
      source: source
    } do
      assert source =~ ~r/device:\s*["']desktop["']/,
             "expected the desktop short-circuit branch to carry " <>
               "`device: \"desktop\"` literally so the template can " <>
               "render the platform-specific copy."
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
