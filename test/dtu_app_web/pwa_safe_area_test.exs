defmodule DtuAppWeb.PwaSafeAreaTest do
  @moduledoc """
  Pins the iOS PWA safe-area CSS rule.

  On iOS in standalone (Home Screen install) mode, the viewport meta
  uses `viewport-fit=cover` and `apple-mobile-web-app-status-bar-style`
  is `black-translucent`, so the status bar is rendered ON TOP of the
  page content rather than pushing it down. The navbar (and the rest of
  the top of the page) MUST add `padding-top: env(safe-area-inset-top)`
  to stay visible above the status bar — otherwise the time/battery
  indicators sit on top of the navbar.

  The fix uses `@supports (padding-top: env(safe-area-inset-top))` as a
  feature-query gate (rather than `@media (display-mode: standalone)`,
  which iOS Safari sometimes fails to match right after launching from a
  Home Screen icon). `@supports` is the standard, reliable gate: only
  browsers that understand `env()` get the padding, and the fallback
  value `1.5rem` covers iPhones that report a slightly smaller safe
  area inset.
  """

  use ExUnit.Case, async: true

  # The CSS lives at `assets/css/app.css` in dev mode. In `:test` Mix
  # doesn't bundle it into `_build/test/.../priv/static/assets/`, so
  # reading the file from `:code.priv_dir/1` works only in release
  # builds. For the test we read the source file directly.
  @css_path "assets/css/app.css"

  test "navbar uses env(safe-area-inset-top) so the iOS status bar doesn't overlap it" do
    css = File.read!(@css_path)

    assert css =~ ~r/@supports\s*\(\s*padding-top:\s*env\(safe-area-inset-top\)\s*\)/,
           "expected `@supports (padding-top: env(safe-area-inset-top))` gate — " <>
             "without it, browsers that don't support env() would get the " <>
             "fallback padding applied unconditionally. Found:\n#{css}"

    assert css =~ ~r/header\.sticky\s*\{\s*padding-top:\s*env\(safe-area-inset-top,\s*1\.5rem\)/,
           "expected `header.sticky { padding-top: env(safe-area-inset-top, 1.5rem) }` " <>
             "so the navbar clears the iOS status bar / notch."
  end

  test "navbar does not gate safe-area on @media (display-mode: standalone)" do
    # The previous fix used `@media (display-mode: standalone)` to gate
    # the safe-area padding. iOS Safari is unreliable about matching
    # that media query right after launching from a Home Screen icon
    # (the moment when the navbar is most likely to be hidden behind
    # the status bar). Use `@supports` instead — it's based on the
    # presence of the env() function, not on the display mode, so it
    # works the moment the page renders.
    css = File.read!(@css_path)

    # Match an actual `@media (display-mode: standalone)` rule, NOT
    # the prose reference inside the CSS comment that documents the
    # bug. Require a `{` before the rule so the prose mention in the
    # comment doesn't match.
    refute css =~
             ~r/^\s*@media[^{]*display-mode:\s*standalone[^{]*\{\s*[^}]*safe-area-inset-top/ms,
           "the safe-area rule should not be gated on " <>
             "`@media (display-mode: standalone)` — that's the " <>
             "original cause of this bug. Use `@supports` instead."
  end
end
