defmodule DtuAppWeb.FlashJsTest do
  @moduledoc """
  Contract tests for `assets/js/flash.js`.

  The `<.flash>` component now auto-dismisses after 10 s via a
  `Flash` JS hook (mounted on every flash container). Hovering or
  keyboard-focusing the toast pauses the timer; leaving restarts
  it. Dismissing hides the DOM AND pushes
  `lv:clear-flash` with the right key so the server-side flash
  entry is cleared too — without the push, the toast would
  re-appear on the next LiveView render.

  Same harness as `DtuAppWeb.NotificationsJsTest`: substring/regex
  checks against the source on disk, so we can lock the
  invariants down without a JS unit-test framework. A real
  Playwright e2e (`test/e2e/flash_autodismiss.spec.js`) covers
  the timer actually firing in a browser.

  Invariants enforced below:

    1. The hook MUST register mouseenter/mouseleave AND
       focusin/focusout listeners — without all four, keyboard
       users can't pause the timer.
    2. The hook MUST pause on enter/focus and resume on
       leave/blur. Pre-fix candidates got the listeners right but
       called `startTimer()` on resume without checking the timer
       was already cleared, which restarted a stale timer and
       fired `dismiss()` too early.
    3. `dismiss()` MUST both hide the element (`this.el.hidden`)
       AND push `lv:clear-flash` with `{key: <kind>}`. The DOM
       hide is purely cosmetic; without the pushEvent the server
       re-renders the same toast.
    4. The hook MUST read the kind from `data-kind` (not the
       element id), so callers can use a custom id
       (`<.flash id="welcome-back">`) without breaking
       dismiss. Pre-fix the hook hard-coded `kind = "info"`.
    5. The hook MUST default the timeout to 10 000 ms but honor a
       `data-timeout-ms` override so tests / niche UI can shorten
       or lengthen it without touching the source.
    6. `destroyed()` MUST clear the pending timer — without it,
       a re-rendered flash element would leak a timer that fires
       `dismiss()` on a node the DOM no longer owns.
  """

  use ExUnit.Case, async: true

  @js_path "assets/js/flash.js"
  @js_app_path "assets/js/app.js"

  setup do
    {:ok, source} = File.read(@js_path)
    {:ok, app_js} = File.read(@js_app_path)
    %{source: source, app_js: app_js}
  end

  describe "pause/resume wiring" do
    test "binds mouseenter / mouseleave / focusin / focusout listeners", %{source: source} do
      for event <- ~w(mouseenter mouseleave focusin focusout) do
        assert source =~ ~r/addEventListener\(["']#{event}["']/,
               "expected Flash hook to listen for `#{event}` so " <>
                 "hovering or focusing the toast can pause the timer."
      end
    end

    test "pauses on enter/focus and resumes on leave/blur", %{source: source} do
      # The bound handlers must call pause() on enter/focus and
      # resume() on leave/blur. We accept either direct calls or
      # indirection through a method, but the four listener
      # bindings must invoke the matching helpers.
      assert source =~ ~r/mouseenter["'],\s*this\.boundPause/,
             "mouseenter should call pause()"

      assert source =~ ~r/mouseleave["'],\s*this\.boundResume/,
             "mouseleave should call resume()"

      assert source =~ ~r/focusin["'],\s*this\.boundPause/,
             "focusin should call pause()"

      assert source =~ ~r/focusout["'],\s*this\.boundResume/,
             "focusout should call resume()"
    end

    test "resume() doesn't restart an already-running timer", %{source: source} do
      # resume() must short-circuit when `this.timer` is truthy;
      # otherwise re-entering the toast while a timer is mid-fire
      # would queue a *second* dismiss. The original draft called
      # startTimer() unconditionally, double-firing.
      assert source =~
               ~r/resume\(\)\s*\{[\s\S]*?if\s*\(\s*!?this\.timer\s*\)\s*this\.startTimer\(\)/,
             "resume() should only restart the timer if no timer is currently armed"
    end
  end

  describe "dismiss() clears the server-side flash" do
    test "pushes lv:clear-flash with the kind read from data-kind", %{source: source} do
      assert source =~ ~r/pushEvent\(\s*["']lv:clear-flash["']/,
             "dismiss() must pushEvent(\"lv:clear-flash\", ...) so " <>
               "the server-side flash entry is cleared"

      assert source =~ ~r/dataset\.kind/,
             "the hook must read the kind from data-kind (so callers can use a custom id)"
    end

    test "hides the element so the toast disappears immediately", %{source: source} do
      assert source =~ ~r/this\.el\.hidden\s*=\s*true/,
             "dismiss() must set `this.el.hidden = true` for instant visual disappearance"
    end

    test "guards pushEvent against a disconnected LiveView", %{source: source} do
      # The first `mounted()` can race the LiveView handshake
      # (Phoenix's SSR → LiveView transition). pushEvent throws
      # synchronously when the view isn't connected, so the
      # dismiss handler must wrap it in try/catch — the DOM is
      # already hidden at that point and the server will clear
      # the flash on the next render anyway.
      assert source =~ ~r/try\s*\{[\s\S]*?pushEvent\(\s*["']lv:clear-flash["']/,
             "pushEvent must be wrapped in try/catch"

      assert source =~ ~r/}\s*catch\s*\(_err\)/,
             "pushEvent catch must swallow the throw"
    end
  end

  describe "configurable timeout" do
    test "defaults to 10000 ms but honors data-timeout-ms override", %{source: source} do
      assert source =~ ~r/parseInt\(this\.el\.dataset\.timeoutMs\s*\|\|\s*["']10000["']/,
             "the hook must default to 10000ms but honor a data-timeout-ms override"
    end
  end

  describe "lifecycle hygiene" do
    test "destroyed() clears the pending timer", %{source: source} do
      # Without this, a re-render that swaps the flash element
      # would leave the old timer armed. When the old timer
      # fires, dismiss() runs against a node that's no longer in
      # the DOM and pushEvent sends against a no-longer-attached
      # hook.
      assert source =~ ~r/destroyed\(\)\s*\{[\s\S]*?clearTimeout\(this\.timer\)/,
             "destroyed() must clearTimeout(this.timer)"
    end

    test "destroyed() removes all four listeners it added", %{source: source} do
      # Symmetry with mounted() — leaked listeners would accumulate
      # across remounts.
      destroyed_block =
        source
        |> String.split(~r/destroyed\(\)\s*\{/)
        |> Enum.at(1)
        |> String.split(~r/^  \}/, parts: 2)
        |> List.first()

      for event <- ~w(mouseenter mouseleave focusin focusout) do
        assert destroyed_block =~ ~r/removeEventListener\(["']#{event}["']/,
               "destroyed() must remove the `#{event}` listener to avoid leaks"
      end
    end
  end

  describe "hook registration" do
    test "app.js imports the Flash hook", %{app_js: app_js} do
      # A missing import would mean `Flash` resolves to
      # `undefined` in the bundle and the LiveView's
      # `[phx-hook="Flash"]` element never gets a `mounted()`
      # call — every other assertion above would describe a
      # hook that never runs.
      assert app_js =~ ~r/import\s*\{\s*Flash\s*\}\s*from\s*["']\.\/flash\.js["']/,
             "Flash hook must be imported in assets/js/app.js"
    end

    test "app.js registers Flash in the Hooks map", %{app_js: app_js} do
      # Even with the import present, a missing entry in the
      # `Hooks` object means LiveSocket never wires the element
      # to the hook module. Both the import AND the registration
      # are required.
      assert app_js =~ ~r/Hooks\s*=\s*\{[\s\S]*?Flash\s*,/,
             "Flash must be listed in the Hooks map exported to LiveSocket"
    end

    test "<.flash> component wires the Flash hook onto its container", %{app_js: _} do
      # Component-side wiring: the `<.flash>` outer div must
      # carry `phx-hook="Flash"` and `data-kind` so the hook
      # knows which flash key to clear on dismiss. Without
      # these, the hook is mounted nowhere and auto-dismiss
      # never fires.
      source = File.read!("lib/dtu_app_web/components/core_components.ex")

      assert source =~ ~r/phx-hook="Flash"/,
             "CoreComponents.flash/1 must add phx-hook=\"Flash\" to its container div"

      assert source =~ ~r/data-kind=\{@kind\}/,
             "CoreComponents.flash/1 must pass data-kind={@kind} so the hook can clear the right flash key"

      assert source =~ ~r/data-timeout-ms="10000"/,
             "CoreComponents.flash/1 must declare a 10 s timeout"
    end
  end
end
