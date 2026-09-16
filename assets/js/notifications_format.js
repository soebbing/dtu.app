// Pure formatting helpers for the `Notifications` hook.
//
// Extracted from `assets/js/notifications.js` so they can be unit-
// tested without a browser. The hook lifecycle (`mounted` /
// `destroyed` / dedup against localStorage / `new Notification(...)`
// firing) stays in the hook file; only the stateless, input→output
// formatters live here. `node --test assets/js/notifications_format.test.js`
// runs the suite.

// Format the producer-side payload into the `{title, body, tag}`
// shape the browser's `Notification` constructor consumes. The
// `tag` drives OS-level coalescing — two notifications sharing a
// tag replace each other rather than stack.
//
// `sun_down` is the only event whose tag was previously derived
// from the browser's wall clock (`new Date().toISOString()`). That
// was a bug: the server already provides a user-local date in
// `payload.date` (computed via the user's `tz_offset_seconds`), so
// the tag should mirror that — otherwise a user on a positive UTC
// offset sees their daily banner split across two OS tags whenever
// the producer fires in the early local hours.
export function formatPayload(payload) {
  if (payload.event === "sun_down") {
    const yieldDiff = compare(payload.today_yield_kwh, payload.today_yield_yesterday_kwh, "kWh")
    const peakDiff = compare(payload.peak_power_w, payload.peak_power_yesterday_w, "W")
    return {
      title: "Sun's down — daily summary",
      body: `Today: ${formatNum(payload.today_yield_kwh)} kWh${yieldDiff}, peak ${formatNum(payload.peak_power_w)} W${peakDiff}.`,
      tag: `sun_down:${payload.date || todayIso()}`
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
  //
  // `body` from the producer side is a list of paragraphs (per the
  // dispatcher's email/layout contract). The browser's
  // `Notification` constructor expects a string, so we join the
  // list with newlines for the OS-level banner — same visual as
  // the email renderer.
  if (payload.title || payload.body) {
    return {
      title: payload.title || "dtu.app",
      body: bodyToString(payload.body),
      tag: payload.tag || `misc:${todayIso()}`
    }
  }

  return {
    title: "dtu.app",
    body: JSON.stringify(payload),
    tag: `misc:${todayIso()}`
  }
}

// Browser UTC date in `YYYY-MM-DD`. Used as a fallback when the
// server didn't supply a user-local `date` field — `sun_down` and
// `sun_up` payloads always carry one, but generic events (the
// last-resort branch in `formatPayload`) don't, and for those the
// browser's UTC date is the best the hook has. NOT used for the
// user-facing `sun_down` tag.
export function todayIso() {
  return new Date().toISOString().slice(0, 10)
}

// Coerce the producer-supplied `body` into the string shape the
// browser's `Notification` constructor expects. The producer sends
// a list of paragraphs (matching the email/layout contract); we
// join with newlines for the OS-level banner. Anything else
// (string, null, undefined) falls back to "" so the field is
// always a string when handed to the Notification constructor.
function bodyToString(body) {
  if (Array.isArray(body)) return body.filter((s) => typeof s === "string").join("\n")
  if (typeof body === "string") return body
  return ""
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
