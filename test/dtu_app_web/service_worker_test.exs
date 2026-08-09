defmodule DtuAppWeb.ServiceWorkerTest do
  @moduledoc """
  Pins the PWA service-worker contract.

  Tier-2 PWA (app-shell precache + offline fallback) relies on the
  static `service-worker.js` and the runtime registration in
  `assets/js/app.js`. These tests guard the bits that are easy to
  regress silently:

    * The SW source must contain the install/activate/fetch
      listeners and a digest-manifest-aware precache. Without
      these, an editor reformats the file and the offline shell
      stops loading without a runtime error.
    * The SW must NOT cache `/live/websocket` — caching the
      LiveView socket would silently kill reconnects after the
      first offline window.
    * The SW must NOT cache `/users/*` (magic-link sign-in,
      log-out) — a cached `/users/log-in` POST would log users
      into a stale session.
    * The SW must read `/cache_manifest.json` so it pins the
      fingerprinted URLs that `mix phx.digest` produces; without
      this, every release would serve stale bytes from the prior
      cache because the URLs change.
    * The SW cache-name derivation must read from the SW's own URL
      (`/service-worker-<digest>.js`) so each release gets a
      fresh cache namespace.
    * `assets/js/app.js` must register the SW under
      `navigator.serviceWorker.register(...)`.

  The SW is a static asset and has no Elixir runtime behaviour to
  unit-test, so the assertions are substring/regex matches against
  the file on disk. The cost is the same as the
  `PwaSafeAreaTest` (which reads `app.css`) — keeps the contract
  honest without needing a browser.
  """

  use ExUnit.Case, async: true

  @sw_path "priv/static/service-worker.js"
  @app_js_path "assets/js/app.js"

  setup do
    {:ok, sw} = File.read(@sw_path)
    {:ok, app_js} = File.read(@app_js_path)
    %{sw: sw, app_js: app_js}
  end

  describe "service-worker.js — install handler" do
    test "registers an install listener that precaches the app shell", %{sw: sw} do
      assert sw =~ ~r/self\.addEventListener\(\s*["']install["']/,
             "expected an install listener so the SW pre-warms the cache"

      assert sw =~ ~r/caches\.open\(/,
             "expected install to open a Cache before populating it"
    end

    test "precaches the offline fallback page", %{sw: sw} do
      assert sw =~ ~r/["']\/offline\.html["']/,
             "expected offline.html to be referenced as a precache target"
    end

    test "reads /cache_manifest.json so fingerprinted URLs are pinned",
         %{sw: sw} do
      assert sw =~ ~r/fetch\(["']\/cache_manifest\.json["']/,
             "expected the SW to fetch /cache_manifest.json — without it the " <>
               "fingerprinted asset URLs change on every release and the SW " <>
               "serves stale bytes from the prior cache."
    end
  end

  describe "service-worker.js — activate handler" do
    test "registers an activate listener that prunes stale caches", %{sw: sw} do
      assert sw =~ ~r/self\.addEventListener\(\s*["']activate["']/

      assert sw =~ ~r/caches\.delete\(/,
             "expected the activate listener to delete caches that don't match " <>
               "the current SW version"
    end

    test "derives the cache namespace from the SW's own URL", %{sw: sw} do
      # The trick that makes cache busting automatic: every release
      # produces a new fingerprinted filename, so the SW extracts
      # its digest and uses that as the cache-version suffix.
      assert sw =~ ~r/service-worker-\(\[a-f0-9\]\+\)\\\.js/,
             "expected the SW to extract its own digest from the URL"
    end
  end

  describe "service-worker.js — fetch handler" do
    test "registers a fetch listener that branches on URL/path", %{sw: sw} do
      assert sw =~ ~r/self\.addEventListener\(\s*["']fetch["']/
    end

    test "does NOT cache the LiveView websocket", %{sw: sw} do
      # The LiveView socket is a long-lived WebSocket. Caching it
      # would silently break reconnects after a network blip.
      assert sw =~ ~r/\/live\/websocket/,
             "expected the SW to mention /live/websocket (so it can explicitly bypass it)"
    end

    test "does NOT cache /users/* (auth endpoints)", %{sw: sw} do
      assert sw =~ ~r/url\.pathname\.startsWith\(\s*["']\/users\/["']\)/,
             "expected the SW to bypass /users/* so a cached log-in POST " <>
               "doesn't poison the auth flow"
    end

    test "serves the offline fallback for HTML navigations on cache miss",
         %{sw: sw} do
      assert sw =~ ~r/accept.*text\/html/,
             "expected HTML navigations to fall back to the offline page"
    end
  end

  describe "service-worker.js — anti-patterns" do
    test "does not reference hardcoded unhashed asset paths in the precache",
         %{sw: sw} do
      # The previous version had STATIC_ASSETS = ["/images/logo.svg", ...]
      # which broke as soon as `mix phx.digest` fingerprinted those
      # URLs (every production build would 404 the SW's own precache).
      refute sw =~ ~r/["']\/images\/logo\.svg["']\s*,\s*$/m,
             "the precache list must not hardcode /images/logo.svg — that's " <>
               "fingerprinted to /images/logo-<digest>.svg at build time."
    end
  end

  describe "app.js — service-worker registration" do
    test "registers the SW after the page loads", %{app_js: app_js} do
      assert app_js =~ ~r/navigator\.serviceWorker\.register\(/,
             "expected app.js to call navigator.serviceWorker.register — " <>
               "without it the SW never starts and offline shell never precaches."
    end

    test "looks up the fingerprinted SW URL via /cache_manifest.json",
         %{app_js: app_js} do
      # Production serves /service-worker-<digest>.js; only the
      # unhashed /service-worker.js works in dev. The manifest
      # lookup means we always pick the right path.
      assert app_js =~ ~r/manifest\.latest/,
             "expected app.js to read service-worker.js from manifest.latest"

      assert app_js =~ ~r/cache_manifest\.json/,
             "expected app.js to fetch /cache_manifest.json to discover the " <>
               "fingerprinted SW filename"
    end
  end

  describe "static_paths allowlist" do
    test "service-worker.js is on DtuAppWeb.static_paths/0" do
      # Without this, `mix phx.digest` would not serve the SW file in
      # production (it's not under assets/ or images/).
      allowlist = DtuAppWeb.static_paths()

      assert "service-worker.js" in allowlist,
             "expected service-worker.js in static_paths/0 so the digest " <>
               "pipeline doesn't drop it. Found: #{inspect(allowlist)}"
    end

    test "offline.html is on DtuAppWeb.static_paths/0" do
      allowlist = DtuAppWeb.static_paths()

      assert "offline.html" in allowlist,
             "expected offline.html in static_paths/0 so the SW can serve it " <>
               "as the offline fallback. Found: #{inspect(allowlist)}"
    end
  end
end
