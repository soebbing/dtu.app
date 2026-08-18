// NotificationPermission hook
//
// Mounted on the `/notifications` page. Computes the browser's
// notification capability and pushes the state to the server so
// the template can render the right CTA. Only the server pushes
// the actual `new Notification(...)` — this hook doesn't fire
// any notifications itself; it just enables them.

const NotificationPermission = {
  mounted() {
    this.pushState()
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

  pushState() {
    const installed = this.isInstalledAsPWA()
    const support = this.computeSupport(installed)
    // The hook only mounts on `/notifications` (a LiveView route) so
    // `pushEvent` is normally safe to call directly. We still guard
    // on `view.isConnected()` to avoid the Phoenix 1.8
    // `unable to push hook event. LiveView not connected` rejection
    // if the user navigates away from the page mid-mount (the SSR →
    // LiveView transition is async and the hook can briefly outlive
    // the connect handshake).
    const view = this.view
    if (!view || typeof view.isConnected !== "function" || !view.isConnected()) {
      return
    }
    try {
      const result = this.pushEvent("notification_state", support)
      if (result && typeof result.catch === "function") {
        result.catch(() => {})
      }
    } catch (_err) {
      // The dashboard's handler is no-op, so a missed push is harmless.
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
