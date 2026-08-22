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
    // Strategy: start a bounded polling loop (100ms tick, 30 attempts,
    // 3s cap). Each tick calls pushState(), which calls LiveView's
    // `pushEvent` and attaches a `.then()` resolver/rejecter. The
    // resolver tears down the loop on server ack; the rejecter leaves
    // it running for the next tick. This is the critical bit — the
    // hook's public surface is `pushEvent(...)`, which internally
    // calls `view.pushHookEvent(...)`. That view method checks the
    // channel state and rejects asynchronously with "unable to push
    // hook event. LiveView not connected" when the channel isn't
    // joined yet, so a synchronous try/catch can't distinguish "push
    // succeeded" from "push was lost". (Earlier versions of this
    // hook tried to pre-check `this.view.isConnected()` — but
    // `this.view` is not exposed on Phoenix LiveView's hook class,
    // so the guard was always truthy and pushEvent was never called.)
    // The polling loop also **tracks in-flight** pushes via
    // `initialPushPending` so we don't pile up overlapping pushes
    // while waiting for the server to ack a previous attempt.
    //
    // `initialPushSent` is the single source of truth for "did the
    // server ack?" — it can only be flipped by the pushEvent Promise's
    // resolver, which proves the round-trip completed.
    console.log("[NotificationPermission] mounted; starting push polling")
    this.initialPushSent = false
    this.initialPushPending = false
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
    this.initialPushPending = false
    this.tryInitialPush()
  },

  destroyed() {
    this.teardownInitialPushTimers()
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
    // We can't trust pushState()'s return value as a "did the push
    // land?" signal — LiveView's pushEvent rejects asynchronously
    // when the socket isn't ready, and a rejected Promise returns
    // `true` from a synchronous try/catch (the rejection lands later
    // via the microtask queue). The previous versions of this hook
    // used that false-positive to stop polling after a single failed
    // attempt, leaving the page stuck on "Checking browser
    // capabilities…" indefinitely.
    //
    // The fix: always start a bounded polling loop on mount. Each
    // iteration calls pushState(), which attaches a `.then()` to the
    // pushEvent Promise; only the **resolver** tears the loop down,
    // which proves the server actually received the event. The
    // rejection handler is silent — the next interval tick just
    // tries again. Hard cap at MAX_ATTEMPTS × INTERVAL_MS so a real
    // connection problem doesn't leave the loop running forever.
    console.log("[NotificationPermission] tryInitialPush: starting polling loop")
    let attempts = 0
    const MAX_ATTEMPTS = 30
    const INTERVAL_MS = 100
    this.initialPushInterval = setInterval(() => {
      attempts++
      if (attempts >= MAX_ATTEMPTS) {
        console.log("[NotificationPermission] polling exhausted (30 × 100ms)")
        this.teardownInitialPushTimers()
        return
      }
      if (!this.initialPushPending) {
        this.pushState()
      }
    }, INTERVAL_MS)
  },

  pushState() {
    const support = this.computeSupport()
    // No `this.view.isConnected()` pre-check — `this.view` is not a
    // property on Phoenix LiveView hooks. The public surface is
    // `this.pushEvent(...)`, which calls `__view().pushHookEvent(...)`
    // internally; that method checks `channel.canPush()` and rejects
    // with "unable to push hook event. LiveView not connected" if the
    // socket/channel isn't ready. Track the returned Promise: resolve
    // = server acked, reject = lost, retry on next tick.
    try {
      const result = this.pushEvent("notification_state", support)
      console.log(
        "[NotificationPermission] pushEvent sent; support=" +
          JSON.stringify(support) +
          " result-type=" +
          (result && typeof result.then === "function" ? "Promise" : typeof result),
      )
      if (result && typeof result.then === "function") {
        // Mark a push in-flight so the polling loop doesn't pile up
        // overlapping pushes while we wait for the server ack.
        // `initialPushPending` is cleared in both the resolver and
        // the rejection handler — either way the round-trip is over
        // and we're free to try again on the next interval tick.
        this.initialPushPending = true
        result.then(
          (resp) => {
            console.log("[NotificationPermission] pushEvent resolved:", resp)
            this.initialPushSent = true
            this.initialPushPending = false
            this.teardownInitialPushTimers()
          },
          (err) => {
            console.log(
              "[NotificationPermission] pushEvent rejected:",
              err && err.message,
            )
            // Rejection (Phoenix 1.8's "unable to push hook event.
            // LiveView not connected"). Leave the polling loop
            // running; the next tick will try again.
            this.initialPushPending = false
          },
        )
      }
      return true
    } catch (_err) {
      console.log("[NotificationPermission] pushEvent threw synchronously:", _err)
      return false
    }
  },

  teardownInitialPushTimers() {
    if (this.initialPushTimer) {
      clearTimeout(this.initialPushTimer)
      this.initialPushTimer = null
    }
    if (this.initialPushInterval) {
      clearInterval(this.initialPushInterval)
      this.initialPushInterval = null
    }
  },

  computeSupport() {
    // The PWA-install gate is iOS-only. iOS Safari (and Firefox-iOS)
    // refuse to expose `Notification.requestPermission` until the
    // site is added to the home screen and reopened from there — in
    // a regular Safari tab the API is *defined* but
    // `new Notification()` silently no-ops, which would look like
    // the OS-bug. For everyone else (desktop Chrome/Firefox/Edge,
    // Android Chrome) the API works fine in a regular tab, and
    // refusing to show the Enable CTA there is paternalistic.
    //
    // Conflating "not installed as PWA" with "can't grant
    // permission" used to send desktop users to the `not_installed`
    // branch where the Enable button is hidden — they could only
    // grant by installing first, which many users don't want to (or
    // can't, e.g. Chrome on Linux without Chromium Web Store
    // install support). Now only iOS triggers `not_installed`.
    if (typeof window === "undefined" || !("Notification" in window)) {
      return {state: "unsupported"}
    }

    if (this.isIOS() && !this.isInstalledAsPWA()) {
      return {state: "not_installed"}
    }

    const permission = window.Notification.permission
    if (permission === "denied") {
      return {state: "denied"}
    }

    if (permission === "granted") {
      return {state: "granted"}
    }

    return {state: "default"}
  },

  isIOS() {
    // Same UA check used by `assets/js/notifications.js`. iOS Safari
    // up through mid-2025 hides the Web Notification API behind
    // home-screen-installed PWA. iPad in desktop-class mode shows up
    // as MacIntel + touch points; that branch is included so an iPad
    // with a Magic Keyboard doesn't slip through.
    if (typeof navigator === "undefined") return false
    return /iPad|iPhone|iPod/.test(navigator.userAgent || "") ||
      (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1)
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
