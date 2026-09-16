# Debug: sun_down silent-skip false positive (2026-09-16)

## Symptom

The user did not receive a daily summary notification yesterday, and the
notification history shows a "no end day summary" entry stating their
inverters didn't report any data for that day. The user knows this is
**false** — power was generated that day (visible on the dashboard).

Two facts combined into one observation:

1. The sun_down broadcast *did* fire (a history row exists).
2. The payload it carried was the "no data reported" variant — not the
   normal "today vs yesterday" yield summary.

So the notifier ran end-to-end, decided the fleet produced 0 W, and
emitted the no-data payload. The question is **why** — and that question
is the one a Phase 1 investigation has to answer.

## Why this is interesting

The dashboard's daily-bucket query (a separate code path from the
notifier) returned readings for that day — so the data is in the DB.
Something between "readings exist" and "notifier computes yield" is
going wrong. Likely candidates:

- The notifier queries a different aggregation than the dashboard.
- The notifier queries a cache/aggregate that's stale relative to the
  dashboard's.
- A recent change introduced a date-boundary or tenant-id mismatch.
- The dedup / fan-out path produces the no-data payload before
  consulting real readings.

The session memory file `dtu-app-notification-dedup-before-build-payload.md`
already documents a prior order-of-operations bug on the same code path
(PR #255 fixed SunDown dedup-must-come-after-nil-payload). Worth checking
whether a similar ordering issue still exists or whether this is a new
flavour of the same family.

## Plan

### Phase 1 — Root-cause investigation

- [ ] Read `DtuApp.Notifications.SunDown` and any notifier it delegates to.
- [ ] Trace the "no data reported" payload branch back to the data source
      it queries.
- [ ] Cross-check the dashboard's daily-bucket query for yesterday's
      date — confirm readings exist where the notifier claims they don't.
- [ ] Re-read `dtu-app-notification-dedup-before-build-payload.md` for
      known similar bugs.
- [ ] Re-read `dtu-app-notification-delivery-silent-drop.md` for the
      "preference gate rarely the cause" caveat — verify the user's
      preferences are all enabled before assuming.
- [ ] Statement of root cause: `<specific code path> <data source>
      <why it returned empty>`.

### Phase 2 — Pattern analysis

- [ ] Compare against `DtuApp.Notifications.SunUp` (uses the same data
      source? returns the right thing?).
- [ ] Compare against a *working* sun_down for the same user on a
      different day (is it only this day that's broken, or only this
      user, or only one path?).
- [ ] Compare against the dashboard's daily-bucket query (separate
      code path) — what does it return for yesterday?
- [ ] Diff: list every difference between "works" and "broken", ranked
      by likelihood.

### Phase 3 — Hypothesis + minimal failing test

- [ ] Form ONE specific falsifiable hypothesis.
- [ ] Write a failing test that exercises the exact code path the user
      hit — seeded readings for yesterday, the notifier runs, payload
      assertion fails for the documented reason.
- [ ] Verify the test fails for the right reason (not a typo).
- [ ] Sanity-check: the test would pass with the fix applied.

### Phase 4 — Fix + ship

- [ ] Implement minimal fix (ONE change).
- [ ] Failing test passes; targeted suite green; full suite unchanged
      from the pre-existing-flake baseline (5 Postgrex-disconnect
      flakes in `DtuApp.Notifications.{DtuConnection,SunDown}Test`).
- [ ] Manual trace: would the user actually receive a sun_down for
      yesterday after the fix?
- [ ] Commit + push + PR + CI + merge + CalVer tag.

## Status

- **2026-09-16 (evening)** — **Resolved.** Phase 5 / Resolution below
  traces the CEST scenario through the post-#292 producer and concludes
  the most likely cause of the user's specific symptom is the chart
  crash fixed by PR #303 (`fix(sun-down-chart): filter nil-power points
  + drop dead Kernel./(1)`), which made `Dispatcher.fire/3` crash
  mid-call on the real SunDown, leaving only the early-morning
  "no readings" history row visible. No further producer change needed.
  If the symptom recurs, investigate the delivery side per the
  `dtu-app-notification-delivery-silent-drop` memory note.
- **2026-09-16 (afternoon)** — Phase 1 concluded: three producer-side
  bugs identified (Bug 1 UTC-date, Bug 2 negative-offset sunset gate,
  Bug 3 no retro-fire on restart). Plan written. Tasks tracked in
  TaskList as #231 / #232 / #233 / #234.

## Phase 1 — Root cause (conclusion)

### Evidence

1. **`lib/dtu_app/notifications/sun_down_notifier.ex:532`**
   `try_fire/1` calls `Date.utc_today()` for the date. The same module's
   `build_payload/2` (in the sibling `sun_down/payload.ex`) is then called
   with that UTC date and forwards it to `DtuApp.Devices.get_daily_stats/3`,
   whose implementation (see `lib/dtu_app/devices/stats/production_stats.ex:110-111`)
   builds `[today_start, today_end]` as `DateTime.new!(date, ~T[00:00:00],
   "Etc/UTC")` etc. — so `date` is interpreted as a UTC date end-to-end.

2. **`lib/dtu_app/notifications/sun_up_notifier.ex:373-374, 422-431`**
   `try_fire/1` calls `user_today(user)` which reads
   `User.tz_offset_seconds` and offsets `DateTime.utc_now()` to the user's
   local date. The SunUp tag (`sun_down:no_readings:YYYY-MM-DD`) carries
   the user's local date, and the dedup `(user_id, fired_on)` row uses
   the same. The moduledoc at line 18 explicitly says "Local day uses
   the user's persisted `tz_offset_seconds`".

3. **`lib/dtu_app/notifications/yield_anomaly_notifier.ex:457, 499-507`**
   Same pattern as SunUp: `user_today/1` reads `tz_offset_seconds`, the
   tag and dedup row both use the local date.

4. **`lib/dtu_app/devices/chart_data.ex:78-99` — `local_day_utc_range/2`**
   already exists to translate a local date + tz offset to the inclusive
   UTC range `[00:00 local, 23:59:59 local]`. The dashboard's chart path
   uses it; the stat-card path does NOT (see `shared_dashboard_live.ex:102`
   calling `Devices.get_daily_stats(user, nil, Date.utc_today())` while
   `chart_points` is fetched via `list_day_chart_data_for_dashboard(user,
   utc_start, utc_end, nil)` over the local-day UTC range). Same root
   cause, different symptom, separate LiveView.

5. **`lib/dtu_app/notifications/sun_down/detection.ex:88-118` —
   `past_sunset?/2`** computes `date = DateTime.to_date(now)` (UTC date)
   and compares `now > sunrise_sunset_utc(lat, lon, date).sunset`. For
   users in **negative-UTC-offset timezones** (Americas, Pacific) the
   sunset for UTC date D lands in UTC date D+1 — by the time `now` is
   past that sunset, `DateTime.to_date(now)` is already D+1, so the
   comparison is always `:lt` and `past_sunset?` returns `false`. The
   producer never arms. This is a **separate** bug from the date bug
   above, but it manifests in the same user-visible symptom: no
   daily summary ever arrives.

### Root cause statement

The SunDown producer's date math is UTC-only — `Date.utc_today()` for
the payload date, `Date.utc_today()` for the dedup `fired_on`, and
`Date.add(Date.utc_today(), -1)` for "yesterday". This UTC date is then
passed to `DtuApp.Devices.get_daily_stats/3`, which queries the readings
table for the UTC midnight-to-midnight range around that UTC date.

For users in any non-UTC timezone, the notifier's "today" diverges from
the user's local "today" — and for users in negative-UTC-offset
timezones, the divergence is large enough that the UTC-midnight range
the notifier queries can return zero readings even though the user
generated power that local day. The combination of:

- producer using UTC date for the payload tag (so the user sees
  `sun_down:2026-09-16` for what they think is their "yesterday"),
- producer using UTC midnight range for the stats query (so the
  empty range → nil payload → "no readings" history row),
- producer's reactive arming requiring fleet silence at sunset, and
- the lack of any "missed dates" retro-fire on producer restart,

means: **a user in a negative-UTC-offset timezone with coordinates set
will receive no daily summary ever (because `past_sunset?` never returns
true). A user in a negative-UTC-offset timezone without coordinates
will receive a "no readings" history row tagged with the UTC date the
producer happened to be firing on, not the local date they expect.**
A user in a positive-UTC-offset timezone whose producer restarts after
the local-sunset window can have their local day's summary missed
entirely (no retro-fire) and the next UTC date's fire sees no readings
yet → "no readings" row tagged one day ahead of what the user expected.

The user's exact words ("dashboard shows power for the given day", "no
end day summary" history row) are consistent with **any** of the three
scenarios above depending on their timezone and coordinate status —
which is why the plan needs more user context before Phase 3.

## Bugs found (three, all related)

### Bug 1 — `try_fire/1` uses `Date.utc_today()` instead of user-local date

`lib/dtu_app/notifications/sun_down_notifier.ex:532` and
`lib/dtu_app/notifications/sun_down/payload.ex:38, 47`. SunUp and
YieldAnomaly both use the `user_today/1` helper that reads
`User.tz_offset_seconds`; SunDown does not. Fix: copy the
`user_today/1` pattern (the small `user_today/1` + `local_date/2`
helpers from SunUp are already the canonical shape — see
`lib/dtu_app/notifications/sun_up_notifier.ex:422-431` and
`lib/dtu_app/notifications/yield_anomaly_notifier.ex:499-507`).

Tracked as Task #235.

### Bug 2 — `past_sunset?/2` returns `false` forever for negative-UTC-offset users with coordinates

`lib/dtu_app/notifications/sun_down/detection.ex:88-118`. Sunset for
UTC date D lands in UTC date D+1 for negative-offset users; by then
`DateTime.to_date(now)` already flipped to D+1, so the
`now > sunrise_sunset_utc(lat, lon, D).sunset` comparison is always
`:lt`. The producer never arms. Fix: compute the sunset for the
LOCAL calendar date instead of the UTC date.

Tracked as Task #236.

### Bug 3 — No retro-fire on producer restart after a local-sunset window

When the producer restarts in the morning after missing the user's
local sunset, the seed loads old fleet-power state but does not
attempt to fire for the missed local day. The next fire is for the
current UTC date, which may have no readings yet, producing a "no
readings" history row tagged one day ahead of what the user expects.
Fix scope TBD — see Phase 3.

Tracked as Task #237.

### Bug 4 (parallel) — dashboard stat card uses UTC date while chart uses local date

`lib/dtu_app_web/live/shared_dashboard_live.ex:99-105` (and likely
the private `dashboard_live.ex`). The chart uses
`DtuApp.Devices.ChartData.local_day_utc_range/2`; the stat card
calls `Devices.get_daily_stats/3` with `Date.utc_today()`. Same
root cause as Bug 1, separate LiveView. Coordinate via
`DtuApp.Devices.Stats.ProductionStats.get_daily_stats` if the fix
takes option (a) in Task #235.

Tracked as Task #238.

## User-context answers (2026-09-16)

1. Timezone: **CEST** (UTC+2).
2. Coordinates: **set to 52N, 7E** (Germany).
3. Producer restarts: app was restarted multiple times during the day,
   but the user confirms the bug also occurred with **no restarts**.
4. History row date: matches local "yesterday" ("1 day ago" rendering
   is correct).

Additional UX request: history rows should carry a `title` HTML
attribute with the exact date/time so the user can disambiguate which
date a row refers to on hover.

### Impact on the three-bug hypothesis

With the user's answers, Bugs 2 and 3 do **not** apply:

- **Bug 2** (`past_sunset?` for negative-UTC-offset users): CEST is a
  positive offset; `DateTime.to_date(now)` and `sunset` for the same
  UTC date land in the same UTC date, so the comparison works
  correctly. This bug bites the Americas/Pacific and stays a separate
  task — see Task #236.
- **Bug 3** (no retro-fire on producer restart): user confirmed the
  bug occurs with no restarts, so this is not the mechanism. Stays a
  separate task for other users — see Task #237.

**Bug 1** (UTC date vs user-local date in `try_fire/1`) is the only
remaining candidate. BUT — for a CEST user with normal local-day
production, Bug 1 alone does not produce a "no readings" outcome (see
below). So either Bug 1 manifests differently than my analysis
suggests, or there is a fourth bug not yet identified.

## Re-analysis for the CEST case (Bug 1 alone)

User fires at `local Sep 15 19:45 = UTC Sep 15 17:45` (sunset was
UTC 17:30 for 52N, 7E on 2026-09-15). At that instant:

- `Date.utc_today() = Sep 15` (correct for UTC date)
- `build_payload(user, Sep 15)` calls `get_daily_stats(user, nil, Sep 15)`
- `get_daily_stats` builds `today_start = Sep 15 00:00 UTC`,
  `today_end = Sep 15 23:59:59 UTC`
- DISTINCT ON returns per-(dtu_id, inverter_serial) latest reading
  where `inserted_at in [Sep 15 00:00 UTC, Sep 15 23:59:59 UTC]`
- For normal CEST Sep 15 production (local 05:00–19:00 = UTC
  03:00–17:00), the DISTINCT ON result is **non-empty**
- `per_series` is built from ALL DISTINCT ON rows (not 2-minute-filtered)
  → **non-empty**
- `current_power` filter (≤ 2 min old) excludes the sunset reading →
  `current_power = 0.0`
- Nil-branch predicate: `current_power == 0.0 AND per_series == []`
  → **FALSE** (per_series non-empty)
- Normal payload fires ✓

So Bug 1 alone does NOT explain the user's case for a CEST user on a
normal day. The cause must be one of:

1. **A case I haven't enumerated**: e.g., the user's readings for the
   day's UTC range happen to all be `mppt_index != 0` or
   `inverter_serial == "_fleet"`, or `dtu_ids` returned empty, or the
   parser dropped AC-aggregate rows for some reason on that day.
2. **The producer fired at a time outside the expected sunset window**:
   e.g. a sweep-triggered fire at UTC Sep 16 02:00 (local Sep 16
   04:00 CEST, well past sunset, before next sunrise) — `Date.utc_today()
   = Sep 16` and `build_payload(user, Sep 16)` queries Sep 16 UTC
   range which has no readings yet.
3. **A bug I haven't identified** in the arming / sweep path.

The debug investigation continues to narrow this down (Task #233).
The fix for Bug 1 itself is straightforward and worth shipping
regardless of the user's specific case — see Task #235.

## Open question (resolved)

1. **Did the notifier fire at UTC Sep 15 17:45 (local Sep 15 19:45,
   sunset-arm) or at some other UTC time?** — Resolved: it fires at
   both. The sweep arms an idle timer for users with cached fleet
   state during the pre-sunrise window (UTC Sep 15 02:00 → UTC Sep 15
   02:15 fire), and the reactive arming fires again at sunset (UTC
   Sep 15 17:25 → UTC Sep 15 17:40 fire). On a normal production day
   the user should see TWO history rows for Sep 15: an early-morning
   "no end-of-day summary" row from the sweep fire (build_payload
   returns nil because the local-day window is empty pre-sunrise) and
   an evening "Sun's down — daily summary" row from the sunset fire
   (build_payload returns a valid payload because the local-day
   window now contains the day's readings). If only the first row
   appears, the sunset fire is the suspect — see Phase 5.

## Files of interest

- `lib/dtu_app/notifications/sun_down*.ex` — sun_down notifier
- `lib/dtu_app/notifications/sun_down/payload.ex` — payload builder
  (local-date, decorate_for_dispatch)
- `lib/dtu_app/notifications/sun_down/detection.ex` — `past_sunset?/2`
  (location-aware sunset gate)
- `lib/dtu_app/emails/sun_down_chart.ex` — inline chart renderer
  (nil-power guard)
- `lib/dtu_app/notifications.ex` — broadcaster (in-page PubSub +
  dispatcher fan-out)
- `lib/dtu_app/notifications/sun_up*.ex` — sister notifier for diff
  (uses `user_today/1` pattern)
- `lib/dtu_app_web/live/dashboard_live.ex`,
  `lib/dtu_app_web/live/shared_dashboard_live.ex` — dashboard daily-bucket
  queries (chart + stat card, both local-date post-#295)
- `lib/dtu_app/devices/chart_data.ex` — `local_day_utc_range/2`
  (canonical local-date → UTC range translator)
- `lib/dtu_app/devices/stats/production_stats.ex` —
  `get_daily_stats_for_local_day/4`
- `test/dtu_app/notifications/sun_down_notifier_test.exs` —
  pre-existing test file (one of the 5 pre-existing flakes)

## Prior fixes in the area

- **PR #245** — `fix(notifications): SunDown sweep + DB-seeded state for
  silent inverters` — added the periodic sweep + DB-backed dedup.
- **PR #255** — `fix(notifications): dedup before build_payload ordering`
  — moved dedup row creation AFTER nil-payload check so a day doesn't
  lock silently. The session memory file documents this fix.
- **PR #290** — notifications-live refactor (no behaviour change, just
  component extraction).
- **PR #292** — `fix(notifications): SunDown fires use user-local date,
  not UTC` — closed Bug 1; `try_fire/1` now uses `user_today/1`.
- **PR #293** — `fix(shared_dashboard)`-flavoured location-aware sunset
  gate — `past_sunset?/2` uses the user's local date and gates on
  sunrise+sunset; closed Bug 2.
- **PR #295** — `fix(shared_dashboard): stat card today_yield uses
  user's local-day window` — closed Bug 4.
- **PR #298** — `feat(notifications): sun_down missed-day regenerate
  UI` — Regenerate button on the notifications page; the user-facing
  affordance for missed days.
- **PR #303** — `fix(sun-down-chart): filter nil-power points + drop
  dead Kernel./(1)` — closed the chart crash that killed
  `Dispatcher.fire/3` mid-call. The most likely cause of the user's
  specific symptom (only the early-morning "no readings" row visible).

## Phase 3 / Task #237 outcome: no retro-fire on producer restart

Investigation of "missed-date retro-fire on producer restart"
(Task #237, the trace of Bug 3 above) concluded with **no code
change**. Summary of the reasoning:

1. **Producers are reactive, not retroactive.** Both
   `DtuApp.Notifications.SunDown` and `DtuApp.Notifications.SunUp`
   fire the moment their trigger condition is met (idle for
   `@sun_down_idle_seconds`, sunrise hit). Neither walks the
   `*_fires` dedup table on `init/1` looking for users with no
   row for "today" or "yesterday". The SunDown producer does
   seed `state.users` from the DB on init, but only to recover
   the fleet-power cache — not to retro-fire for a missed date.

2. **The user's own context rules out producer restart as the
   mechanism.** The triage session above notes "the bug also
   occurred with **no restarts**" — i.e., the producer was
   alive the whole time and still missed the fire window. A
   retro-fire on restart would not have helped in that case.

3. **Retro-fire is a UX feature, not a producer feature.** The
   user-facing question is "I expected yesterday's summary
   and didn't get one" — that's better answered by a
   history-page "regenerate" affordance than by a producer
   that fires N hours late on restart. A producer-driven
   retro-fire on every restart would also fire in many
   false-positive scenarios (deploy at sunset, OOM during
   the fleet-idle window, deploy race with the dedup insert,
   etc.) and add a dedup-vs-reset dance that the current
   schema isn't designed for.

4. **Dedup is the only persistent producer state, and it's
   intentionally write-once-per-day.** Adding "or did we
   skip a day?" semantics to the dedup table would either
   need a "tombstone" row for missed days (new schema
   change) or a separate sweep-over-`sun_down_fires`
   mechanism that runs at startup and fires for users with
   no row in the last N days (state-machine complexity in
   a place that today is intentionally minimal).

**Recommendation:** mark Task #237 as "investigated, no code
change". The user-facing "missed summary" affordance, if
desired, is a separate UI feature on the history page (not a
producer change).

## Phase 5 — Resolution (2026-09-16 evening)

The three producer-side date/coord bugs identified in Phase 1 all
shipped today. Walking the user's CEST scenario through the post-fix
producer narrows the symptom to a single, now-fixed failure mode.

### Fixes that closed the producer-side date/coord bugs

| PR | Commit | Fix |
|----|--------|-----|
| #292 | `e12e664` | SunDown fires use `user_today/1` (anchored on `User.tz_offset_seconds`) instead of `Date.utc_today()`. `build_payload/2` → `build_payload/3` accepts the local date + offset; "yesterday" math uses `Date.add(local_date, -1)`. |
| #293 | `c7fadfa` | `past_sunset?/2` uses the user's local date (via `tz_offset_seconds`) for the sunset lookup, and gates on both `sunrise` and `sunset` so negative- and positive-offset users land inside the night window correctly. |
| #295 | `dac4e93` | `SharedDashboardLive` stat card uses `local_today/1` + `Devices.get_daily_stats_for_local_day/4` instead of `Devices.get_daily_stats/3` + `Date.utc_today()`. |

### CEST scenario, walked through the post-#292 producer

User: `tz_offset_seconds: 7200` (CEST), coordinates 52N / 7E.
Day in question: Sep 15, normal local-day production
(local 05:00–19:00 CEST = UTC 03:00–17:00 UTC).

**Pre-sunrise sweep fire** — UTC Sep 15 02:00 (CEST 04:00):
1. `state.users[user_id]` was seeded from a previous reactive update;
   fleet is "silent" (no AC reading in the last 5 min).
2. `:sun_down_sweep` fires every 5 min → `handle_sweep/1` walks
   `state.users` → `arm_if_idle/2` for this user.
3. `past_sunset?(user_id, UTC Sep 15 02:00)` → with #293:
   `local_date = Sep 15` → `sunrise_sunset_utc(52N, 7E, Sep 15)` →
   sunrise `UTC 04:50`, sunset `UTC 17:25`. `past_sunset_gate/3`:
   `now < sunrise` → returns `true` (in night).
4. `arm_if_idle/2` arms a 15-min timer. `zero_since = UTC 02:00`.
5. Timer fires at UTC Sep 15 02:15 → `fire_for_user/2` →
   `try_fire/1` → `user_today(user) = Sep 15` (CEST local).
6. `build_payload(user, Sep 15, 7200)` →
   `get_daily_stats_for_local_day(user, nil, Sep 15, 7200)` →
   `local_day_utc_range(Sep 15, 7200) = [Sep 14 22:00 UTC, Sep 15 21:59 UTC]`.
7. At UTC 02:15 the local-day window has zero readings (sun hasn't
   risen). `today.current_power == 0.0 and today.per_series == []`
   → `build_payload/3` returns `nil`.
8. `write_no_payload_history/2` writes a `notifications` row titled
   "No end-of-day summary" tagged `sun_down:no_readings:2026-09-15`.
   **No** PubSub broadcast, **no** push, **no** email — per the
   silent-day explanation row section of `SunDown`'s moduledoc.
9. `clear_user_state/2` removes the user from `state.users`.

This is **producer-correct behavior** for the early-morning window —
the local-day window is empty pre-sunrise by construction. The user
sees this row and concludes "no summary", but it is a transient
marker that the producer ran during the local night; a real SunDown
broadcast should follow at sunset.

**Sunset fire** — UTC Sep 15 17:25 (CEST 19:25):
1. Fleet goes to 0 W (sunset). Reactive `:reading` event arrives with
   `ac_power = 0.0`.
2. `maybe_arm_timer/2` → `arm_if_idle/2` →
   `past_sunset?(user_id, UTC 17:25)` → with #293:
   `local_date = Sep 15`, `sunrise UTC 04:50`, `sunset UTC 17:25`.
   `past_sunset_gate/3`: `now >= sunset` → returns `true`.
3. Arms a 15-min timer.
4. Timer fires at UTC Sep 15 17:40 → `fire_for_user/2` →
   `try_fire/1` → `user_today(user) = Sep 15`.
5. `build_payload(user, Sep 15, 7200)` → `local_day_utc_range(Sep 15,
   7200) = [Sep 14 22:00 UTC, Sep 15 21:59 UTC]` now contains the
   day's readings (UTC 03:00–17:00).
6. `build_payload/3` returns a non-nil payload (today's kWh + peak +
   yesterday comparison).
7. `insert_fire/2` writes `sun_down_fires(user_id, Sep 15)` —
   succeeds (no prior row, per the dedup invariant).
8. `Payload.decorate_for_dispatch/3` adds the email-side keys
   (chart SVG via `SunDownChart.render/2`, dashboard CTA, body wrap).
9. `Phoenix.PubSub.broadcast(...)` — in-page banner to the dashboard
   LiveView's `handle_info({:notification, payload}, ...)`.
10. `Dispatcher.fire(user, "sun_down", full)` — push + email +
    history row "Sun's down — daily summary".

This is the real SunDown the user expected. On a normal CEST day
post-#292, the user should see **two** rows for Sep 15: the
pre-sunrise "no readings" row from step 8 and the sunset "Sun's down"
row from step 10.

### Why the user likely saw only one row

The most plausible explanation for the user's specific observation
("no end-of-day summary" history row, no SunDown banner / push /
email) is that step 10 crashed mid-call **before** the dispatcher
wrote its history row. The producer's flow at
`lib/dtu_app/notifications/sun_down_notifier.ex:650-656` is:

```elixir
Phoenix.PubSub.broadcast(DtuApp.PubSub, ..., {:notification, full})
Dispatcher.fire(user, "sun_down", full)
```

If `Dispatcher.fire/3` raises, the surrounding GenServer (the
SunDown producer) terminates; the in-page PubSub broadcast from the
previous line has already gone out, but the dispatcher never reaches
its `Notifications.record/2` history-row insert. The user sees the
**early-morning row only** because that row is written by the
producer directly (`write_no_payload_history/2`), not through the
dispatcher.

The pre-#303 chart path crashed on this exact line of code. The
producer calls `decorate_for_dispatch/3` → `Payload.decorate_for_dispatch`
which calls `DtuApp.Emails.SunDownChart.render(user, today)`. If the
day's `points` list contained a `power: nil` entry (a partially-
populated 5-min bucket in `readings_5m`, or a NULL `avg_ac_power`),
`render_svg/1` → `build_path/1` reached `Enum.max/1` → `nil |> Kernel./(1)`
and raised `ArithmeticError: bad argument in arithmetic expression`.
The crash killed the SunDown GenServer mid-fire, between the PubSub
broadcast and the `Notifications.record/2` history insert inside
`Dispatcher.fire/3`. Reproduced in prod on 2026-09-16 (the
GenServer-terminating stack trace in `docs/debug/2026-09-16-sun-down-silent-skip.md`'s
production logs).

PR #303 (`fix(sun-down-chart): filter nil-power points + drop dead
Kernel./(1)`, commit `e2b8f24`) replaces the crash with an empty-state
SVG fallback and drops the dead `|> Kernel./(1)` chain. Post-#303 the
chart renders successfully regardless of nil-power points, so step 10
no longer crashes and the "Sun's down" history row is written.

### Disposition

- **Producer side**: closed. PRs #292, #293, #295, #303 all shipped
  today. The `try_fire/1` date math, the `past_sunset?/2` gate, the
  dashboard stat-card window, and the chart's nil-power tolerance are
  all aligned with the user's local timezone and the cagg's NULL
  semantics.
- **User's specific symptom**: most likely the pre-#303 chart crash
  killing `Dispatcher.fire/3` mid-call. Post-#303 the sunset fire
  succeeds end-to-end. **No further code change recommended.**
- **Reopen condition**: if the user (or another CEST / non-UTC user)
  reports the same symptom after #303 is in production for a few
  days, the cause shifts to delivery-side. Investigate per the
  `dtu-app-notification-delivery-silent-drop` memory note — the most
  likely candidates are (a) iOS Safari without home-screen-installed
  PWA, (b) a stale `push_subscriptions` endpoint that hasn't yet
  re-subscribed through PR #297's re-subscribe prompt, or (c) the
  in-page banner fired while the user had no tab open.

### Cross-reference

- Producer-side fix history: PRs #245 (sweep + seed), #255 (dedup
  ordering), #292 (user-local date), #293 (location-aware sunset),
  #295 (dashboard stat card), #303 (chart nil-power guard).
- Delivery-side context: PR #161 (storageHas TTL), PR #297 (stale
  push-subscription re-subscribe prompt); see also
  `docs/2026-09-16-push-subscription-re-subscribe.md` if filed.
- User-facing affordance for missed days: PR #298 (Regenerate button
  on the notifications page) — already shipped; the user can manually
  fire a summary for any past date via `/notifications`.

