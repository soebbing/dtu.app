// OfflineBanner hook
//
// Mounted on the `<.offline_banner />` component in the root layout.
// Toggles the banner's `data-offline` attribute in response to the
// browser's `online` and `offline` window events, plus the initial
// `navigator.onLine` value.
//
// This banner is intentionally separate from LiveView's
// `phx-disconnected` flash ("Attempting to reconnect") — the flash
// covers transient WebSocket blips, this banner covers the case where
// the browser itself has no connectivity. Showing it on every WS blip
// would be too noisy.

const OfflineBanner = {
  mounted() {
    this.handleOnline = () => this.setOffline(false)
    this.handleOffline = () => this.setOffline(true)

    window.addEventListener("online", this.handleOnline)
    window.addEventListener("offline", this.handleOffline)

    // Reflect the current state. `navigator.onLine` is a heuristic —
    // it only tells us the network interface is up, not whether we
    // can actually reach the server — but it's the standard signal
    // for this UX.
    this.setOffline(!navigator.onLine)
  },

  destroyed() {
    window.removeEventListener("online", this.handleOnline)
    window.removeEventListener("offline", this.handleOffline)
  },

  setOffline(offline) {
    this.el.dataset.offline = offline ? "true" : "false"
  },
}

export {OfflineBanner}
