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
    // initial assign — so we MUST guarantee it lands. Track the first
    // push with a flag, attempt it immediately, and retry once on the
    // next macrotask if the LiveView's WebSocket hasn't joined yet.
    this.initialPushSent = false
    this.pushInitialState()
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

  destroyed() {
    if (this.initialPushTimer) {
      clearTimeout(this.initialPushTimer)
      this.initialPushTimer = null
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

  pushInitialState() {
    if (this.pushState()) {
      this.initialPushSent = true
      return
    }
    // View isn't ready yet. Retry on the next macrotask — by then the
    // WS join reply has been processed and `view.isConnected()` returns
    // true. One retry is enough: subsequent display-mode changes and
    // permission flips go through `pushState()` directly.
    this.initialPushTimer = setTimeout(() => {
      this.initialPushTimer = null
      if (this.initialPushSent) return
      if (this.pushState()) {
        this.initialPushSent = true
      }
      // If the retry also fails, give up silently — the page will
      // remain on the "Checking browser capabilities…" branch and the
      // user can still interact with the form (preferences are saved
      // independently of notification capability).
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
