// PushSubscribe hook
//
// Mounted on the `/notifications` page (and on the dashboard root
// layout, via `phx-hook="PushSubscribe"`). Responsibilities:
//
//   1. Wait for the user to grant notification permission.
//   2. Once granted, fetch the server's VAPID public key from
//      `GET /push/vapid/public_key`.
//   3. Call `registration.pushManager.subscribe({userVisibleOnly,
//      applicationServerKey})` to obtain a `PushSubscription`.
//   4. POST the subscription to `/push/subscribe` so the server
//      can target this device for native Web Push deliveries.
//
// Why this hook is separate from `NotificationPermission` and
// `Notifications`:
//
//   * `NotificationPermission` only *asks* for permission and
//     reports the result to the server. It does not touch
//     `PushManager` — many users grant permission for in-page
//     notifications but don't need native OS banners.
//   * `Notifications` only *receives* `phx:notify` events for the
//     open tab. It does not handle background (closed-tab) pushes.
//   * This hook owns the *subscription* lifecycle (the
//     `PushManager` call) — the missing third leg of the stool.
//
// iOS note: as of mid-2025 only Safari ≥ 16.4 (PWA added to home
// screen) supports Web Push. We feature-detect `PushManager` before
// any of this runs; on iOS Safari the hook short-circuits with a
// single `console.warn`. Firefox-on-iOS still doesn't support Web
// Push at all — the feature detection catches that too.
//
// CSRF: every fetch to our own endpoints must include the
// `X-CSRF-Token` header. We read it once on mount from the
// `<meta name="csrf-token">` element the root layout renders.

const PushSubscribe = {
  mounted() {
    // Stash the CSRF token on the element itself so we don't
    // re-query the DOM on every push attempt. The token is
    // session-stable — re-renders don't regenerate it.
    this.csrfToken = readCsrfToken()

    // Auto-subscribe path: if the OS permission is already
    // granted (the user previously clicked "Enable" and is now
    // revisiting the page), register this browser with the push
    // service straight away. Otherwise we wait for the
    // NotificationPermission hook to call us via a custom event.
    //
    // We deliberately do *not* auto-subscribe on the dashboard
    // mount; the dashboard passes `data-push="auto"` to opt in.
    // The notifications page always opts in.
    this.auto = this.el.dataset.push === "auto" || this.el.id === "push-subscribe"

    if (this.auto) {
      this.tryAutoSubscribe()
    }

    // Manual trigger from the notifications page: the
    // `NotificationPermission` hook dispatches a `push:enable`
    // custom event after the user clicks the "Enable
    // notifications" button and the OS returns "granted".
    this.handleEnable = (e) => {
      if (e && e.detail && e.detail.permission === "granted") {
        this.tryAutoSubscribe()
      }
    }
    window.addEventListener("push:enable", this.handleEnable)
  },

  destroyed() {
    window.removeEventListener("push:enable", this.handleEnable)
    // We deliberately do NOT unsubscribe on `destroyed()`: the
    // push subscription is owned by the *service worker*, not the
    // page. If the user navigates away from `/notifications` to
    // `/dashboard`, we want the OS-level delivery to keep
    // working. `unsubscribe()` happens only on an explicit
    // "Disable notifications" click — see `unsubscribe()` below.
  },

  // Public API used by the hook's own helpers and by tests.
  async tryAutoSubscribe() {
    try {
      if (typeof window === "undefined" || !("serviceWorker" in navigator)) {
        this.log("warn", "serviceWorker not supported; skipping push subscribe")
        return
      }
      if (typeof window.PushManager === "undefined") {
        this.log(
          "warn",
          "PushManager not supported (iOS Safari < 16.4 or Firefox-iOS); skipping push subscribe"
        )
        return
      }
      if (typeof window.Notification === "undefined") {
        this.log("warn", "Notification API not supported; skipping push subscribe")
        return
      }
      if (window.Notification.permission !== "granted") {
        this.log(
          "log",
          "Notification.permission is not granted (" +
            window.Notification.permission +
            "); skipping push subscribe"
        )
        return
      }

      const registration = await navigator.serviceWorker.ready
      // Re-use an existing subscription if one's already there —
      // `subscribe()` is idempotent on the same VAPID key but a
      // fresh applicationServerKey (after a VAPID rotation) will
      // resolve to a new endpoint. Either way, POSTing the
      // resulting JSON to /push/subscribe is safe (the controller
      // upserts by endpoint).
      let subscription = await registration.pushManager.getSubscription()

      if (!subscription) {
        const response = await fetch("/push/vapid/public_key", {
          headers: {Accept: "application/json"},
          credentials: "same-origin"
        })

        if (!response.ok) {
          this.log(
            "warn",
            "server returned " + response.status + " for /push/vapid/public_key; skipping push subscribe"
          )
          return
        }

        const body = await response.json()
        if (!body || typeof body.public_key !== "string" || body.public_key === "") {
          this.log("warn", "/push/vapid/public_key returned empty public_key; skipping push subscribe")
          return
        }

        // Validate the key shape BEFORE handing it to
        // `urlBase64ToUint8Array` — `atob()` throws
        // "String contains an invalid character" for any non-base64
        // input, and the raw error reaches the console as an
        // unhandled `DOMException`. The VAPID public key per RFC 8292
        // is the 65-byte uncompressed P-256 point (0x04 + 32-byte X +
        // 32-byte Y), which encodes to exactly 87 URL-safe-base64
        // characters. Anything else is either a placeholder, a key
        // that's been truncated by an env-var mishap, or a future
        // point-compressed key — none of which we want to attempt to
        // subscribe with.
        const publicKey = body.public_key
        if (!/^[A-Za-z0-9_-]+$/.test(publicKey) || publicKey.length !== 87) {
          this.log(
            "warn",
            "/push/vapid/public_key returned a malformed public_key " +
              "(len=" +
              publicKey.length +
              ", expected 87 URL-safe-base64 chars); skipping push subscribe. " +
              "Check that the server's VAPID_PUBLIC_KEY env var is a complete keypair."
          )
          return
        }

        subscription = await registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: urlBase64ToUint8Array(publicKey)
        })
        this.log("log", "PushManager.subscribe() resolved")
      } else {
        this.log("log", "re-using existing PushManager subscription")
      }

      await this.postSubscription(subscription)
    } catch (err) {
      this.log("error", "tryAutoSubscribe failed:", err)
    }
  },

  async postSubscription(subscription) {
    if (!subscription) return
    const json = subscription.toJSON()
    const response = await fetch("/push/subscribe", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-CSRF-Token": this.csrfToken || ""
      },
      credentials: "same-origin",
      body: JSON.stringify(json)
    })

    if (response.ok) {
      const result = await response.json().catch(() => null)
      this.log("log", "subscribed OK:", result)
      if (typeof this.pushEvent === "function") {
        // Tell the LiveView so the page can render the "Native
        // push is enabled" badge.
        this.pushEvent("push_subscribed", {endpoint: json.endpoint})
      }
    } else {
      this.log("error", "/push/subscribe failed:", response.status, await response.text())
    }
  },

  async unsubscribe() {
    try {
      if (typeof navigator === "undefined" || !("serviceWorker" in navigator)) return
      const registration = await navigator.serviceWorker.ready
      const subscription = await registration.pushManager.getSubscription()
      if (!subscription) {
        this.log("log", "no active PushManager subscription; nothing to unsubscribe")
        return
      }

      const endpoint = subscription.endpoint
      const ok = await subscription.unsubscribe()
      this.log("log", "PushManager.unsubscribe() returned", ok)

      await fetch("/push/unsubscribe", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": this.csrfToken || ""
        },
        credentials: "same-origin",
        body: JSON.stringify({endpoint: endpoint})
      })
      this.log("log", "server notified of unsubscribe")
    } catch (err) {
      this.log("error", "unsubscribe failed:", err)
    }
  },

  // Diagnostic logger. Mirror the verbose style of
  // `assets/js/notifications.js` so the user can see in DevTools
  // which guard short-circuited the subscribe flow.
  log(level, ...args) {
    if (typeof window === "undefined" || !window.console) return
    const tag = "[PushSubscribe]"
    if (level === "error") window.console.error(tag, ...args)
    else if (level === "warn") window.console.warn(tag, ...args)
    else window.console.log(tag, ...args)
  }
}

// The VAPID spec (RFC 8292) hands the application server key as
// URL-safe base64; the `PushManager.subscribe()` API expects a
// `BufferSource`. This is the canonical conversion helper.
function urlBase64ToUint8Array(b64) {
  const padding = "=".repeat((4 - (b64.length % 4)) % 4)
  const raw = atob((b64 + padding).replace(/-/g, "+").replace(/_/g, "/"))
  const out = new Uint8Array(raw.length)
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i)
  return out
}

function readCsrfToken() {
  if (typeof document === "undefined") return ""
  const meta = document.querySelector("meta[name='csrf-token']")
  return meta ? meta.getAttribute("content") || "" : ""
}

export default PushSubscribe
export {PushSubscribe}
