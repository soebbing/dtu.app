// dtu.app Service Worker
//
// PWA Tier 2 + Web Push (Option A, Phase 2).
//
// Responsibilities:
//   1. Cache static assets for offline reads (Tier 2 from #71).
//   2. Receive `push` events from the server (VAPID-signed via
//      `web_push_encrypter`) and show the OS notification — this is the
//      path that delivers notifications when the browser tab is
//      *closed*, which the in-page `Notifications` hook can't do.
//   3. Receive `notificationclick` events and route the user back to
//      the relevant dashboard page (carried as `data.url` on the
//      notification payload).
//
// Notes for future maintainers:
//   - This file is *not* bundled by esbuild (see the esbuild config in
//     config/config.exs — the `assets` arg is exactly the entry list).
//     It's served verbatim from priv/static and is fingerprinted by
//     `mix phx.digest`. Keep the surface area small and dependency-free
//     so the SW stays portable across browsers.
//   - Bump the cache name (`dtu-app-v2`, `dtu-app-static-v2`) on
//     backwards-incompatible changes; the `activate` handler will sweep
//     old caches.

const CACHE_NAME = 'dtu-app-v1'
const STATIC_CACHE = 'dtu-app-static-v1'

// Assets to cache immediately on install
const STATIC_ASSETS = [
  '/',
  '/manifest.webmanifest',
  '/images/logo.svg',
  '/images/icon-192.png',
  '/images/icon-512.png',
  '/images/icon-maskable-512.png',
  '/offline.html'
]

// Install event — cache static assets
self.addEventListener('install', (event) => {
  console.log('[Service Worker] Install event triggered')

  event.waitUntil(
    caches.open(STATIC_CACHE)
      .then((cache) => {
        console.log('[Service Worker] Caching static assets')
        return cache.addAll(STATIC_ASSETS)
      })
      .then(() => {
        // Force the waiting service worker to become the active service worker
        return self.skipWaiting()
      })
  )
})

// Activate event — clean up old caches
self.addEventListener('activate', (event) => {
  console.log('[Service Worker] Activate event triggered')

  event.waitUntil(
    caches.keys()
      .then((cacheNames) => {
        return Promise.all(
          cacheNames.map((cacheName) => {
            // Delete old caches that don't match our current cache names
            if (cacheName !== STATIC_CACHE && cacheName !== CACHE_NAME) {
              console.log('[Service Worker] Deleting old cache:', cacheName)
              return caches.delete(cacheName)
            }
          })
        )
      })
      .then(() => {
        // Take control of all pages immediately
        return self.clients.claim()
      })
  )
})

// Fetch event — implement caching strategies
self.addEventListener('fetch', (event) => {
  const { request } = event
  const url = new URL(request.url)

  // Skip non-GET requests
  if (request.method !== 'GET') {
    return
  }

  // Skip cross-origin requests
  if (url.origin !== self.location.origin) {
    return
  }

  // Strategy 1: Cache First for static assets
  if (
    url.pathname.startsWith('/assets/') ||
    url.pathname.startsWith('/images/') ||
    url.pathname.endsWith('.ico') ||
    url.pathname.endsWith('.png') ||
    url.pathname.endsWith('.jpg') ||
    url.pathname.endsWith('.svg') ||
    url.pathname.endsWith('.webmanifest') ||
    url.pathname.endsWith('.css') ||
    url.pathname.endsWith('.js')
  ) {
    event.respondWith(cacheFirstStrategy(request))
    return
  }

  // Strategy 2: Network First for HTML pages and API requests
  event.respondWith(networkFirstStrategy(request))
})

// Cache First: Try cache first, fallback to network
async function cacheFirstStrategy(request) {
  try {
    const cachedResponse = await caches.match(request)

    if (cachedResponse) {
      console.log('[Service Worker] Cache hit:', request.url)
      return cachedResponse
    }

    console.log('[Service Worker] Cache miss, fetching:', request.url)
    const networkResponse = await fetch(request)

    // Cache the new response for future use
    if (networkResponse.ok) {
      const cache = await caches.open(STATIC_CACHE)
      cache.put(request, networkResponse.clone())
    }

    return networkResponse
  } catch (error) {
    console.error('[Service Worker] Cache first failed:', error)
    return await Promise.reject(error)
  }
}

// Network First: Try network first, fallback to cache, then offline page
async function networkFirstStrategy(request) {
  try {
    console.log('[Service Worker] Network first, fetching:', request.url)
    const networkResponse = await fetch(request)

    // Cache successful responses for future offline use
    if (networkResponse.ok) {
      const cache = await caches.open(CACHE_NAME)
      cache.put(request, networkResponse.clone())
    }

    return networkResponse
  } catch (error) {
    console.log('[Service Worker] Network failed, trying cache:', request.url)

    try {
      const cachedResponse = await caches.match(request)

      if (cachedResponse) {
        console.log('[Service Worker] Returning cached version')
        return cachedResponse
      }

      // For HTML requests that aren't cached, show offline page
      if (request.headers.get('accept').includes('text/html')) {
        console.log('[Service Worker] Returning offline page')
        const offlineResponse = await caches.match('/offline.html')
        return offlineResponse || new Response('Offline - No cached version available', {
          status: 503,
          statusText: 'Service Unavailable',
          headers: new Headers({ 'Content-Type': 'text/html' })
        })
      }

      return await Promise.reject(error)
    } catch (cacheError) {
      console.error('[Service Worker] Cache lookup failed:', cacheError)
      return await Promise.reject(cacheError)
    }
  }
}

// ─── Web Push (Phase 2) ────────────────────────────────────────────────────
// The server signs payloads with VAPID (`web_push_encrypter`) and the
// browser delivers them here even when the tab is closed. The payload
// shape is:
//
//   { event: "dtu_connection" | "sun_down" | "test" | ...,
//     title:  String,
//     body:   String,
//     tag:    String,
//     icon:   String (optional URL),
//     url:    String (optional deep link) }
//
// `tag` is used by the OS notification system to coalesce repeats
// (e.g. a flapping DTU reconnecting every 30s only fires one OS
// banner per tag). The in-page `localStorage` dedup in
// `assets/js/notifications.js` is a *separate* layer for the
// page-open case and doesn't apply here — the OS dedupes by tag
// independently of the JS hook.
self.addEventListener('push', (event) => {
  console.log('[Service Worker] Push event received:', event)

  // Default payload — never fire a blank notification if the
  // server sent a malformed body. Treat missing/non-JSON pushes as
  // "DTU went offline" so a misbehaving producer doesn't silently
  // spam an empty banner.
  let payload = {
    title: 'dtu.app',
    body: 'New event from dtu.app',
    tag: 'dtu:generic',
    icon: '/images/icon-192.png',
    url: '/dashboard'
  }

  if (event.data) {
    try {
      const incoming = event.data.json()
      // Whitelist merge: don't trust arbitrary keys from the server
      // (e.g. a leaked auth cookie accidentally serialised into the
      // payload shouldn't end up in `notification.title`).
      if (typeof incoming.title === 'string') payload.title = incoming.title
      if (typeof incoming.body === 'string') payload.body = incoming.body
      if (typeof incoming.tag === 'string') payload.tag = incoming.tag
      if (typeof incoming.url === 'string') payload.url = incoming.url
      if (typeof incoming.icon === 'string') payload.icon = incoming.icon
    } catch (parseErr) {
      console.warn('[Service Worker] Push payload was not JSON, using defaults:', parseErr)
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
      data: payload.url
    })
  )
})

// Click handler — focus an existing tab if the URL is already open,
// otherwise open a new window. This is the path that brings the
// user back to the dashboard after tapping an OS notification.
self.addEventListener('notificationclick', (event) => {
  console.log('[Service Worker] Notification click:', event)

  event.notification.close()

  const targetUrl = (event.notification.data && typeof event.notification.data === 'string')
    ? event.notification.data
    : '/dashboard'

  event.waitUntil(
    clients
      .matchAll({ type: 'window', includeUncontrolled: true })
      .then((windowClients) => {
        // Reuse an existing tab if one's already open at the target URL
        // (or any window — the user can navigate from there). Falls
        // back to `clients.openWindow` for the cold-start case.
        for (const client of windowClients) {
          if ('focus' in client) {
            // Best-effort: try to navigate the existing tab. ignore
            // for non-window clients (shared workers etc).
            try {
              if ('navigate' in client && client.url !== targetUrl) {
                client.navigate(targetUrl)
              }
            } catch (_navErr) {
              // ignore: we'll fall through to focus()
            }
            return client.focus()
          }
        }
        if (clients.openWindow) {
          return clients.openWindow(targetUrl)
        }
      })
  )
})

// Background sync (placeholder for future use)
self.addEventListener('sync', (event) => {
  console.log('[Service Worker] Background sync:', event.tag)
  // Future implementation for syncing data when connection returns
})

// Periodic background sync (placeholder for future use)
self.addEventListener('periodicsync', (event) => {
  console.log('[Service Worker] Periodic sync:', event.tag)
  // Future implementation for periodic data updates
})
