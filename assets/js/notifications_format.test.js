// Pure-function unit tests for `formatPayload`.
//
// `formatPayload` formats a server-pushed notification payload into
// the shape the browser's `Notification` constructor consumes
// (title / body / tag). The tag drives OS-level coalescing — when
// two notifications share a tag, the OS replaces the older one
// instead of stacking.
//
// The bug these tests pin: for `sun_down` events, `formatPayload`
// was rebuilding `tag` from `new Date().toISOString().slice(0, 10)`
// (the browser's UTC date) instead of using the server's
// `payload.date` (which honours the user's `tz_offset_seconds`). For
// a user on a positive UTC offset, the two disagreed by a day —
// so the OS-level coalescing split what should have been one banner.
//
// Run with: `node --test assets/js/notifications_format.test.js`
import { test } from "node:test"
import assert from "node:assert/strict"
import { formatPayload } from "./notifications_format.js"

// `sun_down` payloads always carry `date` (server-computed user-local
// ISO yyyy-mm-dd) — the hook should use that for the tag, not the
// browser's wall clock.
test("sun_down: tag uses payload.date (user-local), not the browser's UTC date", () => {
  // Simulate a CEST user on 2026-09-16 local — server payload says
  // `date: "2026-09-16"` because tz_offset_seconds shifts the local
  // day. The browser's `new Date()` for the same instant is still
  // `2026-09-15` UTC (early hours CEST), so a `todayIso()`-derived
  // tag would be one day off.
  const payload = {
    event: "sun_down",
    date: "2026-09-16",
    today_yield_kwh: 1.5,
    today_yield_yesterday_kwh: 1.0,
    peak_power_w: 150.0,
    peak_power_yesterday_w: 100.0,
  }

  const { tag } = formatPayload(payload)

  assert.equal(tag, "sun_down:2026-09-16")
})

// Belt-and-braces: the tag should mirror whatever `payload.date` is,
// even if it's not the server's "today" — a Regenerate request for a
// past local date must keep the same OS-coalescing key the daily
// producer would have used.
test("sun_down: tag mirrors payload.date even for back-dated regenerate", () => {
  const payload = {
    event: "sun_down",
    date: "2026-09-10",
    today_yield_kwh: 2.0,
    today_yield_yesterday_kwh: 1.5,
    peak_power_w: 200.0,
    peak_power_yesterday_w: 150.0,
  }

  const { tag } = formatPayload(payload)

  assert.equal(tag, "sun_down:2026-09-10")
})

// Regression guard for the dtu_offline branch — must still namespace
// by device identity, not date. (Ensures the refactor didn't break
// the other event types.)
test("dtu_offline: tag is namespaced by dtu_id + inverter_serial", () => {
  const payload = {
    event: "dtu_offline",
    dtu_id: 42,
    inverter_serial: "INV-A",
    inverter_name: "Garage",
  }

  const { tag } = formatPayload(payload)

  assert.equal(tag, "dtu_offline:42:INV-A")
})
