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

  Two regressions these tests guard:

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
end
