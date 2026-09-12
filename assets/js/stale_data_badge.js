// StaleDataBadge hook
//
// Tracks the freshness of the dashboard's data and surfaces it as
// a small inline badge near the top of the layout. The "freshness"
// is computed from three orthogonal signals:
//
//   - **Server liveness** — any `phx:notify` event (LiveView
//     broadcasts these when the dispatcher pushes a notification,
//     or when the dashboard re-renders), or the native
//     `phx:connected` event after a reconnect, counts as a
//     "tick". The hook doesn't read the payload — it just stamps
//     the timestamp.
//
//   - **LiveView socket state** — `phx:disconnected` flips the
//     badge to "disconnected" (different from offline: the
//     browser is online, but the live socket dropped).
//
//   - **Browser network state** — `online` / `offline` window
//     events flip the badge to "offline" (no connectivity at
//     all; the cached SW-served HTML is showing).
//
// The badge re-renders its relative timestamp on a 30 s interval
// so "Updated 12s ago" stays accurate even without a fresh tick.
// The interval is local — no server round-trip — so it's free.

const TICK_INTERVAL_MS = 30 * 1000
const STALE_THRESHOLD_MS = 60 * 1000 // > 60s = stale
const VERY_STALE_THRESHOLD_MS = 5 * 60 * 1000 // > 5min = very stale

const StaleDataBadge = {
  mounted() {
    this.lastTickAt = Date.now()
    this.freshness = "fresh" // one of: fresh | stale | very_stale | offline | disconnected
    this.offline = false
    this.disconnected = false

    this.handleOnline = () => {
      this.offline = false
      this.markTick()
      this.render()
    }

    this.handleOffline = () => {
      this.offline = true
      this.render()
    }

    this.handleConnected = () => {
      this.disconnected = false
      this.markTick()
      this.render()
    }

    this.handleDisconnected = () => {
      this.disconnected = true
      this.render()
    }

    this.handleNotify = () => {
      this.markTick()
      this.render()
    }

    window.addEventListener("online", this.handleOnline)
    window.addEventListener("offline", this.handleOffline)
    window.addEventListener("phx:connected", this.handleConnected)
    window.addEventListener("phx:disconnected", this.handleDisconnected)
    window.addEventListener("phx:notify", this.handleNotify)

    // Periodically re-render so the relative time stays accurate
    // even without a fresh tick. Cleared on `destroyed`.
    this.tickInterval = window.setInterval(() => this.render(), TICK_INTERVAL_MS)

    this.render()
  },

  destroyed() {
    window.removeEventListener("online", this.handleOnline)
    window.removeEventListener("offline", this.handleOffline)
    window.removeEventListener("phx:connected", this.handleConnected)
    window.removeEventListener("phx:disconnected", this.handleDisconnected)
    window.removeEventListener("phx:notify", this.handleNotify)
    if (this.tickInterval) {
      window.clearInterval(this.tickInterval)
      this.tickInterval = null
    }
  },

  markTick() {
    this.lastTickAt = Date.now()
  },

  // Compute the current freshness state from the cached signals.
  // We deliberately don't read `navigator.onLine` here — it's a
  // heuristic (interface up ≠ reachable), and the explicit
  // `online`/`offline` events are the source of truth for this
  // hook.
  computeFreshness() {
    if (this.offline) return "offline"
    if (this.disconnected) return "disconnected"

    const ageMs = Date.now() - this.lastTickAt
    if (ageMs < STALE_THRESHOLD_MS) return "fresh"
    if (ageMs < VERY_STALE_THRESHOLD_MS) return "stale"
    return "very_stale"
  },

  formatAge(ms) {
    const seconds = Math.floor(ms / 1000)
    if (seconds < 60) return `${seconds}s`
    const minutes = Math.floor(seconds / 60)
    if (minutes < 60) return `${minutes}m`
    const hours = Math.floor(minutes / 60)
    return `${hours}h`
  },

  render() {
    if (!this.el) return

    this.freshness = this.computeFreshness()
    const ageMs = Date.now() - this.lastTickAt
    const ageStr = this.formatAge(ageMs)

    this.el.dataset.freshness = this.freshness
    this.el.dataset.lastTick = String(this.lastTickAt)

    const labelEl = this.el.querySelector("[data-stale-badge-label]")
    if (labelEl) {
      labelEl.textContent = this.labelFor(this.freshness, ageStr)
    }
  },

  labelFor(freshness, ageStr) {
    switch (freshness) {
      case "offline":
        return "Offline — showing last known data"
      case "disconnected":
        return "Reconnecting — showing last known data"
      case "very_stale":
        return `Stale — last update ${ageStr} ago`
      case "stale":
        return `Updated ${ageStr} ago`
      case "fresh":
      default:
        return `Updated ${ageStr} ago`
    }
  },
}

export {StaleDataBadge}
