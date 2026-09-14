// InstallPromptButton hook
//
// Surfaces the browser's PWA install prompt as a small inline button in
// the navbar (desktop) and the burger menu (mobile). The browser fires
// `beforeinstallprompt` only when the app is installable AND the user
// hasn't already installed/dismissed; we capture the event (preventing
// the browser's own mini-bar), reveal the button, and call
// `event.prompt()` when the user clicks it. After install or
// dismissal we record a 30-day cooldown in localStorage so we don't
// nag the same user again on the next visit.
//
// Why we expose the button ourselves rather than relying on the
// browser's built-in install chip:
//   - The chip appears in the URL bar on Chromium desktop (and in the
//     overflow menu on mobile), which most users miss.
//   - On iOS Safari there's no `beforeinstallprompt` event at all —
//     users have to use "Add to Home Screen" from the share sheet —
//     so the in-app button is the only place we can surface the hint.
//   - A branded button keeps the install path consistent with the
//     rest of the navbar UX.

const COOLDOWN_KEY = "pwa:install-dismissed-at"
const COOLDOWN_MS = 30 * 24 * 60 * 60 * 1000 // 30 days

const InstallPromptButton = {
  mounted() {
    // If the user already installed or dismissed within the cooldown
    // window, leave the button hidden. `bootstrapDeadHooks()` calls
    // `mounted()` for every `[phx-hook]` on the page, so this runs
    // even on non-LiveView pages (e.g. login/register), where the
    // button is harmless to wire up but the dismiss flag still
    // applies if the user revisits after sign-in.
    if (this.isInCooldown()) {
      this.hide()
      return
    }

    this.handleBeforeInstallPrompt = (event) => {
      // The event is cancelable — without `preventDefault()` the
      // browser shows its own mini-infobar on top of our button.
      event.preventDefault()
      this.deferredPrompt = event
      this.show()
    }

    this.handleAppInstalled = () => {
      // Fires on the global window once the user accepts the install
      // prompt and the installation completes. We hide the button
      // permanently (and start the cooldown) — the app is now
      // installed, so re-showing the prompt would be nonsense.
      this.deferredPrompt = null
      this.recordDismissal()
      this.hide()
    }

    this.handleClick = () => {
      if (!this.deferredPrompt) {
        this.hide()
        return
      }

      this.deferredPrompt.prompt()

      // Wait for the user's choice. We don't act on the outcome —
      // both "accepted" and "dismissed" should hide the button and
      // start the cooldown (the user has now seen the prompt and
      // we shouldn't keep re-asking).
      this.deferredPrompt.userChoice.finally(() => {
        this.deferredPrompt = null
        this.recordDismissal()
        this.hide()
      })
    }

    window.addEventListener("beforeinstallprompt", this.handleBeforeInstallPrompt)
    window.addEventListener("appinstalled", this.handleAppInstalled)
    this.el.addEventListener("click", this.handleClick)

    // Start hidden. The `beforeinstallprompt` event will flip us
    // visible if/when the browser decides the app is installable.
    this.hide()
  },

  destroyed() {
    window.removeEventListener("beforeinstallprompt", this.handleBeforeInstallPrompt)
    window.removeEventListener("appinstalled", this.handleAppInstalled)
    if (this.el && this.handleClick) {
      this.el.removeEventListener("click", this.handleClick)
    }
  },

  show() {
    if (!this.el) return
    this.el.hidden = false
  },

  hide() {
    if (!this.el) return
    this.el.hidden = true
  },

  isInCooldown() {
    try {
      const raw = window.localStorage.getItem(COOLDOWN_KEY)
      if (!raw) return false
      const dismissedAt = Number.parseInt(raw, 10)
      if (!Number.isFinite(dismissedAt)) return false
      return Date.now() - dismissedAt < COOLDOWN_MS
    } catch (_) {
      // localStorage can throw in privacy modes / sandboxed iframes.
      // Treat as "not in cooldown" — the worst case is we re-show
      // the prompt a bit too soon, which is preferable to locking
      // the user out entirely.
      return false
    }
  },

  recordDismissal() {
    try {
      window.localStorage.setItem(COOLDOWN_KEY, String(Date.now()))
    } catch (_) {
      // Same privacy-mode caveat as `isInCooldown` — silently no-op.
    }
  },
}

export {InstallPromptButton}
