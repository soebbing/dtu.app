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

    // The "test" event bypasses dedup entirely — it's a manual
    // user-driven button click and should always fire so the user
    // can verify their setup. Pre-fix this fell through to
    // `JSON.stringify(payload)` which produced a stable key across
    // clicks, silently swallowing every click after the first.
    if (payload.event !== "test") {
      const dedupKey = computeDedupKey(userId, payload)
      if (storageHas(dedupKey)) return
      storageMark(dedupKey)
    }

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
  // Stable across renders so re-renders don't re-fire. The
  // "test" event never reaches this function (the caller skips
  // dedup for it), but the matcher is defensive in case the
  // caller is changed.
  if (payload.event === "test") {
    return `notified:v1:user:${userId}:test:${Date.now()}`
  }
  if (payload.event === "sun_down") {
    const raw = `sun_down:${payload.date || todayIso()}`
    return `notified:v1:user:${userId}:${raw}`
  }
  if (payload.event === "dtu_offline") {
    const raw = `dtu_offline:${payload.dtu_id}:${payload.inverter_serial}`
    return `notified:v1:user:${userId}:${raw}`
  }
  if (payload.event === "dtu_online") {
    const raw = `dtu_online:${payload.dtu_id}:${payload.inverter_serial}`
    return `notified:v1:user:${userId}:${raw}`
  }
  if (payload.event === "dtu_connection") {
    // The dashboard's broadcast_dtu_connection/3 fires this with a
    // server-rendered `tag` like "dtu:<name>". Use the server tag
    // directly so an offline→online→offline cycle in the same day
    // doesn't get deduped (each transition flips the status field).
    return `notified:v1:user:${userId}:${payload.tag || "dtu_connection"}:${payload.status || ""}`
  }
  // Last-resort: stable JSON of the payload. Stable across re-renders
  // (so the LiveView doesn't refire the same event on every re-render)
  // but unique per distinct payload.
  return `notified:v1:user:${userId}:${payload.tag || "misc"}:${JSON.stringify(payload)}`
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

  // For events the server fills with `title` / `body` / `tag` (e.g.
  // `event: "test"` from the test-notification button, or
  // `event: "dtu_connection"` from `broadcast_dtu_connection/3`),
  // trust the server's fields. The dashboard's `dtu_connection`
  // payload includes a server-rendered `tag` like "dtu:<name>" which
  // we want the OS notification to use verbatim — `misc:<date>` would
  // collide with other generic notifications and break OS-level
  // grouping. Pre-fix this fell through to a hard-coded "dtu.app"
  // title and a JSON-stringified body, which is what users saw when
  // they enabled the test button.
  if (payload.title || payload.body) {
    return {
      title: payload.title || "dtu.app",
      body: payload.body || "",
      tag: payload.tag || `misc:${todayIso()}`
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
