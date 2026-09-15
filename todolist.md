# PWA — make dtu.app installable and app-like

Goal: a real Progressive Web App — installable, with an app shell that loads
instantly and degrades gracefully offline. Tier 1 first (the essentials that
trigger "Install app"); then reliability/offline; then deeper PWA features.

Codebase notes driving the plan:
- Phoenix LiveView: the dashboard updates over WebSocket, so the static HTML /
  CSS / JS shell is small, stable, and ideal for precaching.
- Static files live in `priv/static/` and are served at `/`. `static_paths/0`
  (`lib/dtu_app_web.ex`) is an **allowlist** — new top-level files (manifest,
  service worker) must be added there.
- Prod runs behind TLS (required for service workers + push); localhost is
  exempt so dev works too.

---

## Tier 1 — Easy (PWA essentials)

- [x] **1. Web App Manifest** — `priv/static/manifest.webmanifest`, linked via
      `<link rel="manifest">` in the head. Name `dtu.app`, theme/background
      colors (emerald `#10b981` / zinc-950 `#09090b`), `display: standalone`,
      `start_url: /`, `scope: /`. Add `manifest.webmanifest` to `static_paths/0`.
- [x] **2. App icons (192 / 512 / maskable)** — generate PNGs from
      `priv/static/images/logo.svg`, reference in the manifest. Maskable variant
      for correct Android home-screen tile.
- [x] **3. Install `<meta>` + touch icon** — head metadata: `theme-color`,
      `apple-mobile-web-app-capable`, `apple-mobile-web-app-status-bar-style`,
      `<link rel="apple-touch-icon">` for iOS home screen.
- [x] **4. Standalone-display polish** — safe-area insets for the notch,
      confirm sticky nav. (Nav is already sticky.)

## Tier 2 — Easy–Medium (offline + reliability)

- [x] **5. Service worker — app-shell precache** — register a SW that precaches
      the HTML shell, CSS, JS, logo, icons; cache-first for assets, network-first
      for navigations. Version the SW on each build for cache invalidation.
      *(shipped via #71, hardened via #111; canonical source
      `priv/static/service-worker.js`.)*
- [x] **6. Offline fallback** — branded "You're offline" banner wired to
      LiveView disconnect + `window offline`.
      *(shipped via #46, polished via #258; `priv/static/offline.html` +
      `<.offline_banner>` + `assets/js/offline_banner.js`.)*
- [x] **7. LiveView connection resilience** — tune reconnect/backoff, surface a
      "reconnecting…" indicator (mostly config + a small hook).
      *(shipped via #258 — `phx-disconnected` flashes in `layouts.ex`,
      `StaleDataBadge` listening to `phx:connected`/`phx:disconnected`,
      `longpoll: [window_ms: 30_000]` per #244.)*

## Tier 3 — Medium (real PWA value)

- [ ] **8. Install prompt UI** — capture `beforeinstallprompt`, show our own
      "Install dtu.app" button in the navbar/settings.
- [ ] **9. Stale-data badge** — show "updated N min ago" when reopened/offline.
- [ ] **10. App shortcuts** — manifest `shortcuts`: Dashboard, Devices, Add DTU.
- [x] **11. Push notifications** — Web Push (VAPID) for "DTU offline" / daily
      yield. Shipped via #82 (`feat(notifications): native Web Push (VAPID)`).
      `DtuApp.Push` module + `push_subscribe.js` hook + SW `push` /
      `notificationclick` handlers + `/push/vapid/public_key` + `/push/subscribe`
      + `/push/unsubscribe` controller. Payload contract: whitelist merge in the
      SW (`priv/static/service-worker.js:308-312`) guards against garbage in
      `notification.title`. OS-level dedup via `tag`.

## Tier 4 — Medium-hard (polish, defer)

- [ ] **12. Background sync** — replay queued offline actions via SW `sync`.
      Low value while the app is mostly read-only live views.
- [ ] **13. Share target** — low relevance for a telemetry dashboard. Skip.
