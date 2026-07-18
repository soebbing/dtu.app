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

- [ ] **5. Service worker — app-shell precache** — register a SW that precaches
      the HTML shell, CSS, JS, logo, icons; cache-first for assets, network-first
      for navigations. Version the SW on each build for cache invalidation.
- [ ] **6. Offline fallback** — branded "You're offline" banner wired to
      LiveView disconnect + `window offline`.
- [ ] **7. LiveView connection resilience** — tune reconnect/backoff, surface a
      "reconnecting…" indicator (mostly config + a small hook).

## Tier 3 — Medium (real PWA value)

- [ ] **8. Install prompt UI** — capture `beforeinstallprompt`, show our own
      "Install dtu.app" button in the navbar/settings.
- [ ] **9. Stale-data badge** — show "updated N min ago" when reopened/offline.
- [ ] **10. App shortcuts** — manifest `shortcuts`: Dashboard, Devices, Add DTU.
- [ ] **11. Push notifications** (deferred) — Web Push (VAPID) for "DTU offline"
      / daily yield. Most work; needs a push service + backend job.

## Tier 4 — Medium-hard (polish, defer)

- [ ] **12. Background sync** — replay queued offline actions via SW `sync`.
      Low value while the app is mostly read-only live views.
- [ ] **13. Share target** — low relevance for a telemetry dashboard. Skip.
