// dtu.app Service Worker — PWA Tier 2 (app-shell precache)
//
// Goal: when the device has flaky or no connectivity, the app shell
// (HTML, CSS, JS, icons, manifest) still loads from cache so the user
// can open the dashboard and see the last-known values. LiveView
// reconnects on its own once the network returns.
//
// # Cache strategy
//
// 1. **App shell (cache-first)** — `/`, `/manifest.webmanifest`,
//    `/offline.html`, the logo + icons, the bundled `app.css` /
//    `app.js`. These are fingerprinted by `mix phx.digest` so they
//    get unique URLs per release; we look up the fingerprinted path
//    via the runtime `cache_manifest.json` so we never serve stale
//    bytes from a prior release.
//
// 2. **Navigations (network-first, fallback to offline.html)** —
//    the user-facing HTML. We try the network, fall back to the
//    shell's most recent cached HTML, and finally serve the branded
//    `/offline.html` so the app at least renders the "we're
//    offline" UI.
//
// 3. **LiveView websocket (`/live/websocket`) and dynamic endpoints
//    are intentionally not cached** — see `shouldCache()` below.
//
// # Cache invalidation
//
// The cache name is `dtu-app-<version>` where `<version>` is read
// from the SW's own URL (`/service-worker-<digest>.js`). Every
// release produces a fresh SW filename, which means the new SW
// installs alongside the old one with a *different* version, so
// the new `activate` step deletes every stale cache. This avoids
// the classic "users stuck on the old cache because the SW
// filename didn't change" trap.

const APP_SHELL_VERSION = "v3";
const RUNTIME_CACHE = `dtu-app-runtime-${APP_SHELL_VERSION}`;

// Files that don't get fingerprinted by `phx.digest` and are safe to
// hardcode by URL. The Phoenix endpoint serves them at these paths
// even in production (the allowlist in `static_paths/0` keeps them
// out of the digest pipeline so URLs stay stable).
const STABLE_PATHS = [
  "/manifest.webmanifest",
  "/offline.html",
];

// Fetch the digest manifest so we can pin the fingerprinted URLs of
// the bundled CSS / JS / images. Returns an empty object on failure
// (we still want the SW to install and serve the stable pages).
async function fetchDigestManifest() {
  try {
    const response = await fetch("/cache_manifest.json", {
      cache: "no-store",
    });
    if (!response.ok) {
      return {};
    }
    const manifest = await response.json();
    return manifest.latest || {};
  } catch (_error) {
    return {};
  }
}

// Extract the version suffix from the SW's own URL
// (`/service-worker-<digest>.js` → `<digest>`). This is what gives us
// per-release cache names without baking the calver tag into the JS
// source: every release produces a new digest, which means a new
// SW URL, which means a new cache name on activate.
function swVersionFromUrl() {
  try {
    const path = new URL(self.location.href).pathname;
    const match = path.match(/service-worker-([a-f0-9]+)\.js$/);
    return match ? match[1] : APP_SHELL_VERSION;
  } catch (_error) {
    return APP_SHELL_VERSION;
  }
}

self.addEventListener("install", (event) => {
  event.waitUntil(
    (async () => {
      const latest = await fetchDigestManifest();

      // Fingerprinted shell assets. Keys are the un-digested URLs the
      // manifest exposes under `latest`; values are the actual
      // fingerprinted URLs the browser will request.
      const shellUrls = STABLE_PATHS.map((p) => p).concat(
        Object.values(latest).filter((logicalPath) =>
          [
            "assets/css/app.css",
            "assets/js/app.js",
            "favicon.ico",
            "images/icon-192.png",
            "images/icon-512.png",
            "images/icon-maskable-512.png",
            "images/logo.svg",
            "manifest.webmanifest",
            "offline.html",
          ].includes(logicalPath),
        ),
      );

      // Always precache the brand-fresh shell. The page the user
      // sees offline is whatever was last in the runtime cache;
      // precaching the shell here means `/` works straight from
      // the SW install without a prior fetch.
      const cache = await caches.open(RUNTIME_CACHE);
      await Promise.all(
        shellUrls.map(async (url) => {
          try {
            await cache.add(url);
          } catch (_error) {
            // Best-effort: a missing asset shouldn't fail the
            // install — we'd rather have a working SW with a
            // partial shell than none at all.
          }
        }),
      );

      await self.skipWaiting();
    })(),
  );
});

self.addEventListener("activate", (event) => {
  const version = swVersionFromUrl();
  const expectedCaches = new Set([
    `dtu-app-runtime-${version}`,
    // Legacy cache names from the previous static-version scheme —
    // delete on every upgrade so the install above replaces them.
    "dtu-app-v1",
    "dtu-app-v2",
    "dtu-app-static-v1",
    "dtu-app-static-v2",
    `dtu-app-runtime-${APP_SHELL_VERSION}`,
  ]);

  event.waitUntil(
    (async () => {
      const names = await caches.keys();
      await Promise.all(
        names.map((name) => {
          if (!expectedCaches.has(name)) {
            return caches.delete(name);
          }
          return Promise.resolve();
        }),
      );
      await self.clients.claim();
    })(),
  );
});

// Predicate for the cache-first branch. Skip anything that:
//   * isn't a GET (mutations shouldn't be intercepted),
//   * targets a different origin (cross-origin assets bypass the SW),
//   * is the LiveView websocket (`/live/websocket`) — must go to the
//     network so the connection survives across navigations,
//   * is the digest manifest itself — re-fetched on every activate,
//   * looks like an API call (`/api/*`, `/users/log_in`, etc.) —
//     never serve a stale auth response from cache.
function shouldCache(request, url) {
  if (request.method !== "GET") return false;
  if (url.origin !== self.location.origin) return false;
  if (url.pathname.startsWith("/live/websocket")) return false;
  if (url.pathname === "/cache_manifest.json") return false;
  if (url.pathname.startsWith("/api/")) return false;
  if (url.pathname.startsWith("/users/")) return false;
  if (url.pathname.startsWith("/devices/") && !url.pathname.endsWith(".png")) {
    return false;
  }
  return true;
}

// Cache-first for the fingerprinted shell. Fallback to network so a
// fresh release replaces the cached bytes (the cache name change on
// activate purges the old ones anyway, but a stale cache miss in
// the brief window still serves the latest version).
async function cacheFirst(request) {
  const cache = await caches.open(RUNTIME_CACHE);
  const cached = await cache.match(request);
  if (cached) {
    return cached;
  }

  try {
    const response = await fetch(request);
    if (response.ok) {
      cache.put(request, response.clone());
    }
    return response;
  } catch (_error) {
    // Last resort: serve `/offline.html` for HTML navigations, an
    // empty 503 for anything else.
    if (request.headers.get("accept")?.includes("text/html")) {
      const offline = await cache.match("/offline.html");
      if (offline) return offline;
    }
    return new Response("", {status: 503, statusText: "Service Unavailable"});
  }
}

// Network-first for navigations. Cache the live HTML so the offline
// shell has something to show.
async function networkFirst(request) {
  const cache = await caches.open(RUNTIME_CACHE);

  try {
    const response = await fetch(request);
    if (response.ok && response.headers.get("content-type")?.includes("text/html")) {
      cache.put(request, response.clone());
    }
    return response;
  } catch (_error) {
    const cached = await cache.match(request);
    if (cached) return cached;

    const offline = await cache.match("/offline.html");
    if (offline) return offline;

    return new Response("", {status: 503, statusText: "Service Unavailable"});
  }
}

self.addEventListener("fetch", (event) => {
  const {request} = event;
  const url = new URL(request.url);

  if (!shouldCache(request, url)) return;

  // Cache-first for static (fingerprinted) shell assets.
  if (
    url.pathname.startsWith("/assets/") ||
    url.pathname.startsWith("/images/") ||
    STABLE_PATHS.includes(url.pathname)
  ) {
    event.respondWith(cacheFirst(request));
    return;
  }

  // Network-first for navigations (HTML pages and the SW shell).
  if (request.mode === "navigate" || request.headers.get("accept")?.includes("text/html")) {
    event.respondWith(networkFirst(request));
    return;
  }

  // Anything else: pass through. Most GETs are static assets that
  // we already caught above; the rest are best-effort.
});

// `skipWaiting()` (called in install) lets the new SW take over
// immediately. We also expose a manual update channel via
// `message` so the in-app update prompt (UI later) can request
// an immediate skip if the user accepts.
self.addEventListener("message", (event) => {
  if (event.data && event.data.type === "SKIP_WAITING") {
    self.skipWaiting();
  }
});

// ─── Web Push (Option A, Phase 2) ────────────────────────────────────────
// The server signs payloads with VAPID (`web_push_encrypter`) and the
// browser delivers them here even when the tab is closed. This is the
// path that delivers notifications when the user does *not* have the
// dashboard open — the in-page `assets/js/notifications.js` hook only
// fires when there's an active LiveView socket.
//
// Payload contract (whitelist merge — see below):
//
//   { event: "dtu_connection" | "sun_down" | "test" | ...,
//     title:  String,
//     body:   String,
//     tag:    String,        // OS dedup key (see "OS-level dedup")
//     icon:   String (URL),   // optional, defaults to the PWA icon
//     url:    String (URL) }  // optional, deep-link for the click handler
//
// "OS-level dedup": the `tag` field is what the OS uses to coalesce
// repeat banners (e.g. a flapping DTU reconnecting every 30s would
// otherwise spam the user). Without `renotify: true` repeat events
// with the same tag would *silently replace* the previous banner.
// The in-page `assets/js/notifications.js` hook has a separate
// `localStorage` dedup for the page-open case; the two layers don't
// interact.

self.addEventListener("push", (event) => {
  // Default payload — never fire a blank banner if the server sent a
  // malformed body. A misbehaving producer must not silently spam an
  // empty notification.
  let payload = {
    title: "dtu.app",
    body: "New event from dtu.app",
    tag: "dtu:generic",
    icon: "/images/icon-192.png",
    url: "/dashboard",
  };

  if (event.data) {
    try {
      const incoming = event.data.json();

      // Whitelist merge: only copy string-typed, expected keys from
      // the server payload. Without this guard, a leaked auth cookie
      // or other unexpected key would end up in `notification.title`
      // — the OS shows the title in the system-tray / lock-screen,
      // so this is the one place we really don't want garbage.
      if (typeof incoming.title === "string") payload.title = incoming.title;
      if (typeof incoming.body === "string") payload.body = incoming.body;
      if (typeof incoming.tag === "string") payload.tag = incoming.tag;
      if (typeof incoming.url === "string") payload.url = incoming.url;
      if (typeof incoming.icon === "string") payload.icon = incoming.icon;
    } catch (parseErr) {
      console.warn(
        "[Service Worker] Push payload was not JSON, using defaults:",
        parseErr,
      );
    }
  }

  event.waitUntil(
    self.registration.showNotification(payload.title, {
      body: payload.body,
      tag: payload.tag,
      icon: payload.icon,
      // `renotify: true` makes the OS show a fresh banner for each
      // event with the same tag — without it, repeat events with the
      // same tag would silently replace the previous banner.
      renotify: true,
      // Stash the deep link on the notification object itself so
      // `notificationclick` can route the user to the right page.
      data: payload.url,
    }),
  );
});

// Click handler — focus an existing tab if one's already open,
// otherwise open a new window. This is the path that brings the
// user back to the dashboard after tapping an OS notification.
self.addEventListener("notificationclick", (event) => {
  event.notification.close();

  const targetUrl =
    event.notification.data && typeof event.notification.data === "string"
      ? event.notification.data
      : "/dashboard";

  event.waitUntil(
    clients
      .matchAll({ type: "window", includeUncontrolled: true })
      .then((windowClients) => {
        // Reuse an existing tab if one's already open. Falls back to
        // `clients.openWindow` for the cold-start case (no window
        // open). Non-window clients (shared workers etc.) are skipped.
        for (const client of windowClients) {
          if ("focus" in client) {
            // Best-effort: try to navigate the existing tab. ignore
            // for non-window clients.
            try {
              if ("navigate" in client && client.url !== targetUrl) {
                client.navigate(targetUrl);
              }
            } catch (_navErr) {
              // ignore: we'll fall through to focus()
            }
            return client.focus();
          }
        }
        if (clients.openWindow) {
          return clients.openWindow(targetUrl);
        }
      }),
  );
});