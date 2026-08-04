// Notifications hook
//
// Mounted on the root layout (or any page that wants to receive
// notifications). Listens for `notify` events from the LiveView
// and fires the actual `new Notification(...)` after dedup against
// localStorage. The server-side scheduler/dashboard fills the
// payload; this hook just formats and dedups.
//
// Dedup keys are namespaced per user (server-provided) so we
// don't conflict across accounts on a shared device.

// Notification firing hook. Mounted on every page that should
// receive notifications. The server pushes events with a
// payload; we format the title/body and dedup against localStorage.
const Notifications = {
  mounted() {
    this.handleNotify = (e) => this.handleNotify(e)
    window.addEventListener("phx:notify", this.handleNotify)
  },

  destroyed() {
    window.removeEventListener("phx:notify", this.handleNotify)
  },

  handleNotify(e) {
    const payload = (e.detail || {})[0]
    if (!payload || typeof payload !== "object") return
    if (typeof window.Notification === "undefined") return
    if (window.Notification.permission !== "granted") return

    const userId = this.el.dataset.userId || "0"
    const dedupKey = computeDedupKey(userId, payload)
    if (storageHas(dedupKey)) return
    storageMark(dedupKey)

    const {title, body, tag} = formatPayload(payload)
    try {
      const n = new window.Notification(title, {
        body: body,
        tag: tag,
        icon: "/images/icon-192.png",
        renotify: true
      })
      n.onclick = () => {
        try {
          window.focus()
        } catch (_err) {
          // ignore: page may not be focused
        }
      }
    } catch (_err) {
      // Some browsers throw on `new Notification(...)` when the
      // permission is revoked between the check and the call.
      // Swallow — the next push_event will retry.
    }
  }
}

function computeDedupKey(userId, payload) {
  // Stable across renders so re-renders don't re-fire.
  let raw
  if (payload.event === "sun_down") {
    raw = `sun_down:${payload.date || todayIso()}`
  } else if (payload.event === "dtu_offline") {
    raw = `dtu_offline:${payload.dtu_id}:${payload.inverter_serial}`
  } else if (payload.event === "dtu_online") {
    raw = `dtu_online:${payload.dtu_id}:${payload.inverter_serial}`
  } else {
    raw = JSON.stringify(payload)
  }
  return `notified:v1:user:${userId}:${raw}`
}

function storageHas(key) {
  try {
    return window.localStorage.getItem(key) !== null
  } catch (_err) {
    return false
  }
}

function storageMark(key) {
  try {
    window.localStorage.setItem(key, new Date().toISOString())
  } catch (_err) {
    // ignore: storage may be disabled
  }
}

function todayIso() {
  return new Date().toISOString().slice(0, 10)
}

function formatPayload(payload) {
  if (payload.event === "sun_down") {
    const yieldDiff = compare(payload.today_yield_kwh, payload.today_yield_yesterday_kwh, "kWh")
    const peakDiff = compare(payload.peak_power_w, payload.peak_power_yesterday_w, "W")
    return {
      title: "Sun's down — daily summary",
      body: `Today: ${formatNum(payload.today_yield_kwh)} kWh${yieldDiff}, peak ${formatNum(payload.peak_power_w)} W${peakDiff}.`,
      tag: `sun_down:${todayIso()}`
    }
  }

  if (payload.event === "dtu_offline") {
    return {
      title: `${payload.inverter_name || "Inverter"} went offline`,
      body: `Lost connection to ${payload.inverter_name || "(unnamed inverter)"}${payload.dtu_name ? " on " + payload.dtu_name : ""}.`,
      tag: `dtu_offline:${payload.dtu_id}:${payload.inverter_serial}`
    }
  }

  if (payload.event === "dtu_online") {
    return {
      title: `${payload.inverter_name || "Inverter"} is back online`,
      body: `Reconnected to ${payload.inverter_name || "(unnamed inverter)"}${payload.dtu_name ? " on " + payload.dtu_name : ""}.`,
      tag: `dtu_online:${payload.dtu_id}:${payload.inverter_serial}`
    }
  }

  return {
    title: "dtu.app",
    body: JSON.stringify(payload),
    tag: `misc:${todayIso()}`
  }
}

function compare(today, yesterday, unit) {
  if (yesterday === null || yesterday === undefined) return ""
  if (today === yesterday) return " (same as yesterday)"
  const diff = today - yesterday
  const sign = diff > 0 ? "+" : ""
  return ` (${sign}${formatNum(diff)} ${unit} vs yesterday)`
}

function formatNum(n) {
  if (n === null || n === undefined) return "—"
  if (typeof n !== "number") return String(n)
  return n.toFixed(1)
}

export default Notifications
export {Notifications}
