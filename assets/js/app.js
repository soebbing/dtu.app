// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/dtu_app"
import topbar from "../vendor/topbar"
// Notifications hooks. The `/notifications` LiveView mounts
// `phx-hook="NotificationPermission"` to push the browser's permission
// state to the server; the page itself (and the dashboard) mount
// `phx-hook="Notifications"` to receive `phx:notify` events and fire
// the actual `new Notification(...)`. The hooks are defined as ES
// modules, so they must be imported here — without these imports the
// named hooks resolve to `undefined` in the bundle and the LiveView
// never receives the permission state (or fires notifications).
import {NotificationPermission} from "./notification_permission.js"
import {Notifications} from "./notifications.js"
import {OfflineBanner} from "./offline_banner.js"
import {PushSubscribe} from "./push_subscribe.js"
import {PasskeyFlow} from "./hooks/passkey_flow.js"

// Network Status Hook
//
// Connection-safety contract:
// this hook fires `mounted()` the instant Phoenix mounts the element
// on the client. The first `mounted()` call can land BEFORE the
// underlying LiveView's WebSocket handshake completes (Phoenix's
// SSR → LiveView transition is async). Calling `pushEvent` against
// a not-yet-connected view triggers Phoenix 1.8's
// `unable to push hook event. LiveView not connected` Promise
// rejection, which used to produce a wall of identical console
// errors and (more importantly) keep re-firing every 30 s for the
// lifetime of the page — that wall of errors is what made the page
// appear to take a long while to load.
//
// Two fixes:
//   1. Guard every `pushEvent` call on `this.view.isConnected()`,
//      catch the resulting rejection, and bail silently if the view
//      isn't ready (the dashboard's `network_status_changed`
//      handler is a no-op visual assign anyway, so losing one push
//      is harmless).
//   2. Drop the 30 s periodic re-push. It duplicated the window
//      `online` / `offline` events that already drive
//      handleOnline / handleOffline, and it was the reason the error
//      came back every half-minute.
//
// `getConnectionType()` swallows any per-field throws (older
// browsers expose the Network Information API but throw when you
// read certain fields) so the hook can never throw during `mounted()`.
const NetworkStatus = {
  mounted() {
    this.handleOnline = this.handleOnline.bind(this)
    this.handleOffline = this.handleOffline.bind(this)

    this.updateOnlineStatus()

    window.addEventListener('online', this.handleOnline)
    window.addEventListener('offline', this.handleOffline)

    this.pushStatus()
  },

  destroyed() {
    window.removeEventListener('online', this.handleOnline)
    window.removeEventListener('offline', this.handleOffline)
  },

  safePushEvent(name, payload) {
    const view = this.view
    if (view && typeof view.isConnected === 'function' && view.isConnected()) {
      try {
        const result = this.pushEvent(name, payload)
        if (result && typeof result.catch === 'function') {
          result.catch(() => {})
        }
      } catch (_err) {
        // Synchronous throws from a stale view are swallowed
        // so the page's `handle_event` consumer can take its time
        // to come back online without flooding the console.
      }
    }
  },

  handleOnline() {
    this.el.classList.remove('network-offline', 'network-unstable')
    this.el.classList.add('network-online')
    this.updateIndicator(true)
    this.safePushEvent('network_status_changed', {
      online: true,
      connection_type: this.getConnectionType(),
      timestamp: new Date().toISOString()
    })
  },

  handleOffline() {
    this.el.classList.remove('network-online', 'network-unstable')
    this.el.classList.add('network-offline')
    this.updateIndicator(false)
    this.safePushEvent('network_status_changed', {
      online: false,
      connection_type: this.getConnectionType(),
      timestamp: new Date().toISOString()
    })
  },

  updateOnlineStatus() {
    const isOnline = navigator.onLine
    const currentClass = isOnline ? 'network-online' : 'network-offline'

    this.el.classList.remove('network-online', 'network-offline', 'network-unstable')
    this.el.classList.add(currentClass)
    this.updateIndicator(isOnline)
    this.safePushEvent('network_status_changed', {
      online: isOnline,
      connection_type: this.getConnectionType(),
      timestamp: new Date().toISOString()
    })
  },

  updateIndicator(isOnline) {
    const indicator = this.el.querySelector('[data-network-indicator]')
    if (!indicator) return

    if (isOnline) {
      indicator.classList.remove('bg-red-500', 'bg-yellow-500')
      indicator.classList.add('bg-emerald-500')
      indicator.setAttribute('data-network-status', 'online')
    } else {
      indicator.classList.remove('bg-emerald-500', 'bg-yellow-500')
      indicator.classList.add('bg-red-500')
      indicator.setAttribute('data-network-status', 'offline')
    }
  },

  pushStatus() {
    this.safePushEvent('network_status_changed', {
      online: navigator.onLine,
      connection_type: this.getConnectionType(),
      timestamp: new Date().toISOString()
    })
  },

  getConnectionType() {
    const connection =
      navigator.connection || navigator.mozConnection || navigator.webkitConnection

    if (!connection) return 'unknown'

    let effective_type, downlink, rtt, save_data
    try { effective_type = connection.effectiveType } catch (_err) {}
    try { downlink = connection.downlink } catch (_err) {}
    try { rtt = connection.rtt } catch (_err) {}
    try { save_data = connection.saveData } catch (_err) {}

    return {
      effective_type: effective_type,
      downlink: downlink,
      rtt: rtt,
      save_data: save_data
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {
    ...colocatedHooks,
    NetworkStatus,
    NotificationPermission,
    Notifications,
    OfflineBanner,
    PushSubscribe,
    PasskeyFlow
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// PWA: Register Service Worker
//
// In production Phoenix serves a fingerprinted filename
// (`/service-worker-<digest>.js`); in dev it serves the bare
// `/service-worker.js`. Read the URL from `cache_manifest.json` so
// we always pick up the right path and don't trip on a stale hard-
// coded one after the next `mix phx.digest`.
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    const register = async () => {
      let swUrl = '/service-worker.js'

      try {
        const response = await fetch('/cache_manifest.json', {cache: 'no-store'})
        if (response.ok) {
          const manifest = await response.json()
          swUrl = '/' + (manifest.latest && manifest.latest['service-worker.js']) || swUrl
        }
      } catch (_error) {
        // Fall through to the unhashed path in dev.
      }

      try {
        const registration = await navigator.serviceWorker.register(swUrl)
        console.log('Service Worker registered with scope:', registration.scope)
      } catch (error) {
        console.error('Service Worker registration failed:', error)
      }
    }

    register()
  })
}

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

