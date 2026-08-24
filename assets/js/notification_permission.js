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
    const installed = this.isInstalledAsPWA()
    const support = this.computeSupport(installed)
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

  computeSupport(installed) {
    if (typeof window === "undefined" || !("Notification" in window)) {
      return {state: "unsupported", installed: installed, device: this.deviceType()}
    }

    if (!installed) {
      // On desktop browsers (Chrome / Firefox / Edge on Windows /
      // macOS / Linux) the Web Notifications API works in a regular
      // tab once the user grants permission — PWA install is NOT a
      // prerequisite. iOS Safari (and Firefox-iOS) gate the API
      // behind Add to Home Screen, and mobile browsers in general
      // are unreliable without install, so we still send
      // `not_installed` there.
      if (!this.isMobile()) {
        return {state: "default", installed: false, device: "desktop"}
      }
      return {state: "not_installed", installed: false, device: "mobile"}
    }

    const permission = window.Notification.permission
    if (permission === "denied") {
      return {state: "denied", installed: true, device: this.deviceType()}
    }

    if (permission === "granted") {
      return {state: "granted", installed: true, device: this.deviceType()}
    }

    return {state: "default", installed: true, device: this.deviceType()}
  },

  deviceType() {
    return this.isMobile() ? "mobile" : "desktop"
  },

  isMobile() {
    // UA-based detection — UA covers iOS / iPadOS / Android / etc.
    // without depending on pointer/hover heuristics (a touchscreen
    // laptop running Windows is still a desktop). The MacIntel +
    // maxTouchPoints branch catches iPadOS, which reports as Mac
    // with multi-touch.
    if (typeof navigator === "undefined") return false
    const ua = navigator.userAgent || ""
    if (/Mobi|Android|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(ua)) {
      return true
    }
    if (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1) {
      return true
    }
    return false
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
