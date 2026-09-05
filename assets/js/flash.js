// Flash auto-dismiss hook.
//
// Mounted on every `CoreComponents.flash/1` container. Starts a
// 10 s (configurable via `data-timeout-ms`) timer that dismisses
// the toast by hiding it AND clearing the server-side flash entry
// (`pushEvent("lv:clear-flash", {key: kind})`), so the next render
// doesn't re-show it. Hovering or keyboard-focusing the toast
// pauses the timer; leaving restarts it.
//
// Why both hide AND pushEvent? The existing `phx-click` handler on
// the same div already does this (`JS.push("lv:clear-flash", ...)
// |> JS.hide(...)`), so the timer-driven dismiss mirrors it for
// consistency. Without the `pushEvent`, the flash would re-appear
// on the next LiveView render — the DOM hide is purely cosmetic.
//
// The timer is purely client-side: if the tab is backgrounded or
// closed before the timeout fires, no dismissal happens. That's
// intentional — the server is not in the loop until 10 s has
// elapsed, which keeps a 10 s "are you reading this?" window
// truly client-side and avoids needless WebSocket round-trips.

const Flash = {
  mounted() {
    this.kind = this.el.dataset.kind || ""
    this.timeoutMs = parseInt(this.el.dataset.timeoutMs || "10000", 10)

    this.boundPause = () => this.pause()
    this.boundResume = () => this.resume()

    this.timer = null
    this.startTimer()

    this.el.addEventListener("mouseenter", this.boundPause)
    this.el.addEventListener("mouseleave", this.boundResume)
    this.el.addEventListener("focusin", this.boundPause)
    this.el.addEventListener("focusout", this.boundResume)
  },

  destroyed() {
    if (this.timer) {
      clearTimeout(this.timer)
      this.timer = null
    }
    this.el.removeEventListener("mouseenter", this.boundPause)
    this.el.removeEventListener("mouseleave", this.boundResume)
    this.el.removeEventListener("focusin", this.boundPause)
    this.el.removeEventListener("focusout", this.boundResume)
  },

  startTimer() {
    if (this.timer) clearTimeout(this.timer)
    this.timer = setTimeout(() => this.dismiss(), this.timeoutMs)
  },

  pause() {
    if (this.timer) {
      clearTimeout(this.timer)
      this.timer = null
    }
  },

  resume() {
    if (!this.timer) this.startTimer()
  },

  dismiss() {
    if (this.timer) {
      clearTimeout(this.timer)
      this.timer = null
    }
    // Hide the DOM node immediately so the user sees the toast
    // disappear, even if the WebSocket round-trip to clear the
    // server-side flash lags (e.g. on a slow reconnect).
    this.el.hidden = true

    if (this.kind) {
      try {
        const result = this.pushEvent("lv:clear-flash", {key: this.kind})
        if (result && typeof result.catch === "function") {
          result.catch(() => {})
        }
      } catch (_err) {
        // LiveView may not be connected yet (e.g. during the
        // initial mount race). The DOM is already hidden, so the
        // server-side stale flash will get cleaned up the next
        // time the user navigates or triggers a render.
      }
    }
  }
}

export default Flash
export {Flash}
