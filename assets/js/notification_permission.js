// NotificationPermission hook
//
// Mounted on the `/notifications` page. Computes the browser's
// notification capability and pushes the state to the server so
// the template can render the right CTA. Only the server pushes
// the actual `new Notification(...)` — this hook doesn't fire
// any notifications itself; it just enables them.

const NotificationPermission = {
  mounted() {
    // The first push advances the server's `@notification_state` from
    // `%{"state" => "loading"}` to one of the renderable branches
    // (`granted` / `denied` / `default` / `unsupported` / `not_installed`).
    // If this push is lost, the page is stuck on "Checking browser
    // capabilities…" forever — there is no other path that flips the
    // initial assign — so we MUST guarantee it lands.
    //
    // We layer three fallbacks so the push survives every timing edge
    // case we've seen in production:
    //   1. **Immediate attempt** — `view.isConnected()` is normally true
    //      by the time `mounted()` fires, so this is the common path.
    //   2. **Next-macrotask retry** — covers the rare case where the
    //      LiveView socket hasn't joined yet but will have by the next
    //      tick (e.g. when the join reply arrives between `mounted()`
    //      and `setTimeout(0)`).
    //   3. **Polling fallback** — if both above fail, poll every 100ms
    //      for up to 3s. This catches the slow-join case on mobile PWA
    //      cold starts where the WS handshake takes noticeably longer
    //      than a desktop browser. Without this, the user is stuck on
    //      "Checking browser capabilities…" indefinitely.
    //
    // `initialPushSent` is the single source of truth — once the first
    // push lands, all later paths short-circuit and the polling loop
    // tears itself down.
    this.initialPushSent = false
    this.tryInitialPush()
    this.handleDisplayModeChange = () => this.pushState()
    this.handleClick = (e) => this.handleEnableClick(e)
    this.el.addEventListener("click", this.handleClick)

    if (window.matchMedia) {
      const mql = window.matchMedia("(display-mode: standalone)")
      // Safari doesn't support addEventListener on MediaQueryList yet
      if (mql.addEventListener) {
        mql.addEventListener("change", this.handleDisplayModeChange)
      } else if (mql.addListener) {
        mql.addListener(this.handleDisplayModeChange)
      }
    }
  },

  // After a WS reconnect (mobile flaky networks, laptop sleep, …) the
  // server has lost any prior `notification_state` push — the assign is
  // back to `%{"state" => "loading"}`. Re-push so the page transitions
  // out of "Checking browser capabilities…" without a full reload.
  reconnected() {
    this.initialPushSent = false
    this.tryInitialPush()
  },

  destroyed() {
    if (this.initialPushTimer) {
      clearTimeout(this.initialPushTimer)
      this.initialPushTimer = null
    }
    if (this.initialPushInterval) {
      clearInterval(this.initialPushInterval)
      this.initialPushInterval = null
    }
    this.el.removeEventListener("click", this.handleClick)
    if (window.matchMedia) {
      const mql = window.matchMedia("(display-mode: standalone)")
      if (mql.removeEventListener) {
        mql.removeEventListener("change", this.handleDisplayModeChange)
      } else if (mql.removeListener) {
        mql.removeListener(this.handleDisplayModeChange)
      }
    }
  },

  tryInitialPush() {
    if (this.pushState()) {
      this.initialPushSent = true
      return
    }
    // View isn't ready yet. Retry on the next macrotask — by then the
    // WS join reply has been processed and `view.isConnected()` returns
    // true in the common case.
    this.initialPushTimer = setTimeout(() => {
      this.initialPushTimer = null
      if (this.initialPushSent) return
      if (this.pushState()) {
        this.initialPushSent = true
        return
      }
      // Still not ready. Switch to a bounded polling loop so the push
      // eventually lands even when the WS handshake is slow (mobile
      // PWA cold start, iOS Safari low-power mode, etc.). Cap at 30
      // attempts × 100ms = 3s; by then anything beyond a real
      // connection problem and the user will need to reload anyway.
      let attempts = 0
      const MAX_ATTEMPTS = 30
      this.initialPushInterval = setInterval(() => {
        attempts++
        if (this.initialPushSent || attempts >= MAX_ATTEMPTS) {
          if (this.initialPushInterval) {
            clearInterval(this.initialPushInterval)
            this.initialPushInterval = null
          }
          return
        }
        if (this.pushState()) {
          this.initialPushSent = true
          if (this.initialPushInterval) {
            clearInterval(this.initialPushInterval)
            this.initialPushInterval = null
          }
        }
      }, 100)
    }, 0)
  },

  pushState() {
    const installed = this.isInstalledAsPWA()
    const support = this.computeSupport(installed)
    const view = this.view
    if (!view || typeof view.isConnected !== "function" || !view.isConnected()) {
      return false
    }
    try {
      const result = this.pushEvent("notification_state", support)
      if (result && typeof result.catch === "function") {
        result.catch(() => {})
      }
      return true
    } catch (_err) {
      return false
    }
  },

  computeSupport(installed) {
    if (typeof window === "undefined" || !("Notification" in window)) {
      return {state: "unsupported", installed: installed}
    }

    if (!installed) {
      return {state: "not_installed", installed: false}
    }

    const permission = window.Notification.permission
    if (permission === "denied") {
      return {state: "denied", installed: true}
    }

    if (permission === "granted") {
      return {state: "granted", installed: true}
    }

    return {state: "default", installed: true}
  },

  isInstalledAsPWA() {
    // Chrome / Edge / Firefox on desktop & Android
    const standalone = window.matchMedia && window.matchMedia("(display-mode: standalone)").matches
    // iOS Safari
    const iosStandalone = window.navigator && window.navigator.standalone === true
    return Boolean(standalone || iosStandalone)
  },

  handleEnableClick(e) {
    const target = e.target
    if (!(target instanceof Element)) return
    const btn = target.closest("#notifications-enable")
    if (!btn) return
    e.preventDefault()
    if (typeof window.Notification === "undefined") return
    if (typeof window.Notification.requestPermission !== "function") return

    window.Notification.requestPermission().then((permission) => {
      this.pushState()
      // Once the OS grants notification permission, hand off to
      // the `PushSubscribe` hook (also mounted on this page) so it
      // can call `PushManager.subscribe()` and POST the resulting
      // subscription to the server. Without this dispatch the user
      // would still get in-page notifications (via the
      // `Notifications` hook) but no OS banners when the tab is
      // closed. The event is intentionally a custom `window` event
      // (not `pushEvent`) so the hook doesn't need a LiveView
      // round-trip to learn about the permission change.
      if (permission === "granted") {
        window.dispatchEvent(
          new CustomEvent("push:enable", {detail: {permission: permission}})
        )
      }
    })
  }
}

export default NotificationPermission
export {NotificationPermission}
