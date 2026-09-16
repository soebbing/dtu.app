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
    * `cache_manifest.json`, `manifest`, and `service-worker` must
      all be on the `Plug.Static` allowlist (split between
      `static_paths/0` and `static_match_paths/0`) — otherwise the
      browser requests 404 in production even though the files
      exist on disk.

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

    test "calls self.skipWaiting() BEFORE the precache IIFE", %{sw: sw} do
      # iOS PWA installed + background push: when the backend ships a
      # new SW that fixes a payload-shape bug (or any other reason the
      # server is updated mid-session), iOS may deliver a push to the
      # device while the precache is still running. If we wait for the
      # precache before calling `skipWaiting()`, the *old* SW (still
      # in `waiting` state) handles the push and the user sees the
      # old behaviour — pushes from the freshly-deployed backend are
      # silently dropped until the next app launch.
      #
      # The fix is structural: `self.skipWaiting()` must run
      # synchronously in the install handler body, *outside* the
      # `event.waitUntil(async () => ...)` block that runs the
      # precache. We extract the install handler body by splitting on
      # the listener boundary (the next `addEventListener("activate"`)
      # — regex on the body alone is too brittle because the body
      # contains `});` from inner IIFEs.
      install_start =
        case :binary.match(sw, ~s(self.addEventListener("install")) do
          {pos, _} -> pos
          nil -> flunk("expected addEventListener(\"install\") in service-worker.js")
        end

      activate_start =
        case :binary.match(sw, ~s(self.addEventListener("activate")) do
          {pos, _} -> pos
          nil -> flunk("expected addEventListener(\"activate\") in service-worker.js")
        end

      # The install handler body lives between the install listener
      # open and the activate listener open. Anything past
      # activate_start belongs to the activate handler and shouldn't
      # influence this assertion.
      install_body =
        sw
        |> binary_part(install_start, activate_start - install_start)

      assert install_body =~ ~r/self\.skipWaiting\(\)/,
             "expected install handler to call self.skipWaiting() — without it, " <>
               "iOS background push may be handled by the old SW during slow " <>
               "precaches."

      # The skipWaiting call must happen *before* any await on the
      # precache. We anchor on `await fetchDigestManifest()` — the
      # `await ` prefix excludes the textual reference to
      # `fetchDigestManifest()` in the explanatory comment above
      # the call site.
      {skip_pos, _} =
        :binary.match(install_body, "self.skipWaiting()")

      {precache_pos, _} =
        :binary.match(install_body, "await fetchDigestManifest()")

      assert skip_pos < precache_pos,
             "self.skipWaiting() must run BEFORE the precache's `await " <>
               "fetchDigestManifest()` — otherwise a slow precache delays " <>
               "activation and iOS drops background pushes."
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

    test "cache_manifest.json is on DtuAppWeb.static_paths/0" do
      # The SW (`priv/static/service-worker.js`) and `assets/js/app.js`
      # both fetch `/cache_manifest.json` at runtime to discover the
      # fingerprinted asset URLs. Without this entry, `Plug.Static`
      # 404s the request even though the file exists in `priv/static/`
      # (it's generated by `mix phx.digest`).
      allowlist = DtuAppWeb.static_paths()

      assert "cache_manifest.json" in allowlist,
             "expected cache_manifest.json in static_paths/0 so the SW's " <>
               "runtime fingerprint lookup isn't 404'd. Found: #{inspect(allowlist)}"
    end
  end

  describe "static_match_paths allowlist" do
    test "manifest is on DtuAppWeb.static_match_paths/0" do
      # `Plug.Static`'s `:only` filter matches the first URL segment, and
      # `cache_static_manifest` rewrites `/manifest.webmanifest` to the
      # fingerprinted `/manifest-<digest>.webmanifest`. The rehashed
      # filename has a different first segment, so the `:only` filter
      # 404s it. `only_matching` lets the fingerprinted URL through.
      allowlist = DtuAppWeb.static_match_paths()

      assert "manifest" in allowlist,
             "expected 'manifest' in static_match_paths/0 so the PWA " <>
               "manifest's fingerprinted URL isn't 404'd. Found: #{inspect(allowlist)}"
    end

    test "service-worker is on DtuAppWeb.static_match_paths/0" do
      # Same as the manifest case — the SW itself is served under
      # `/service-worker-<digest>.js` in production, and the un-digested
      # name is in `static_paths/0`, but the fingerprinted URL needs
      # `only_matching` to bypass the `:only` segment check.
      allowlist = DtuAppWeb.static_match_paths()

      assert "service-worker" in allowlist,
             "expected 'service-worker' in static_match_paths/0 so the SW's " <>
               "own fingerprinted URL isn't 404'd. Found: #{inspect(allowlist)}"
    end
  end
end
