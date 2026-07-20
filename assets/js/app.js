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

// Network Status Hook
const NetworkStatus = {
  mounted() {
    this.handleOnline = this.handleOnline.bind(this)
    this.handleOffline = this.handleOffline.bind(this)

    // Set initial online status
    this.updateOnlineStatus()

    // Listen for online/offline events
    window.addEventListener('online', this.handleOnline)
    window.addEventListener('offline', this.handleOffline)

    // Periodic status check (every 30 seconds)
    this.interval = setInterval(() => this.updateOnlineStatus(), 30000)

    // Initial status push to server
    this.pushStatus()
  },

  destroyed() {
    window.removeEventListener('online', this.handleOnline)
    window.removeEventListener('offline', this.handleOffline)
    if (this.interval) {
      clearInterval(this.interval)
    }
  },

  handleOnline() {
    console.log('[NetworkStatus] Connection restored')
    this.pushStatus()
    this.notifyServer(true)
    this.el.classList.remove('network-offline', 'network-unstable')
    this.el.classList.add('network-online')
  },

  handleOffline() {
    console.log('[NetworkStatus] Connection lost')
    this.pushStatus()
    this.notifyServer(false)
    this.el.classList.remove('network-online', 'network-unstable')
    this.el.classList.add('network-offline')
  },

  updateOnlineStatus() {
    const isOnline = navigator.onLine
    const currentClass = isOnline ? 'network-online' : 'network-offline'

    // Remove all network status classes
    this.el.classList.remove('network-online', 'network-offline', 'network-unstable')
    this.el.classList.add(currentClass)

    // Update visual indicator
    this.updateIndicator(isOnline)

    this.pushStatus()
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
    this.pushEvent('network_status_changed', {
      online: navigator.onLine,
      connection_type: this.getConnectionType(),
      timestamp: new Date().toISOString()
    })
  },

  notifyServer(isOnline) {
    // Send a message to the LiveView process
    this.pushEvent('network_status_changed', {
      online: isOnline,
      connection_type: this.getConnectionType(),
      timestamp: new Date().toISOString()
    })
  },

  getConnectionType() {
    const connection = navigator.connection || navigator.mozConnection || navigator.webkitConnection

    if (!connection) return 'unknown'

    return {
      effective_type: connection.effectiveType, // 'slow-2g', '2g', '3g', '4g'
      downlink: connection.downlink, // approximate bandwidth in Mbps
      rtt: connection.rtt, // round-trip time in ms
      save_data: connection.saveData // data saver mode
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {
    ...colocatedHooks,
    NetworkStatus
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
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/service-worker.js')
      .then((registration) => {
        console.log('Service Worker registered with scope:', registration.scope)
      })
      .catch((error) => {
        console.error('Service Worker registration failed:', error)
      })
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

