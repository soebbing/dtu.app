// dtu.app Service Worker
// PWA Tier 2: Basic caching strategy for offline functionality

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

// Install event - cache static assets
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

// Activate event - clean up old caches
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

// Fetch event - implement caching strategies
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

// Handle background sync (for future use)
self.addEventListener('sync', (event) => {
  console.log('[Service Worker] Background sync:', event.tag)
  // Future implementation for syncing data when connection returns
})

// Handle push notifications (for future use)
self.addEventListener('push', (event) => {
  console.log('[Service Worker] Push notification received')
  // Future implementation for push notifications
})

// Periodic background sync (for future use)
self.addEventListener('periodicsync', (event) => {
  console.log('[Service Worker] Periodic sync:', event.tag)
  // Future implementation for periodic data updates
})