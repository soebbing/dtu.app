// Network Status Hook for Phoenix LiveView
// Monitors online/offline status and communicates with LiveView

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

export default NetworkStatus