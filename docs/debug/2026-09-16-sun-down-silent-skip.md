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

- **2026-09-16** — Plan written. Phase 1 in progress, narrowed to a single
  suspect: the notifier uses `Date.utc_today()` for the date and the
  dedup `fired_on`, but every other producer (SunUp, YieldAnomaly) uses
  the user's `tz_offset_seconds` via a local-date `user_today/1` helper.
  Tasks tracked in TaskList as #231 / #232 / #233 / #234.

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

## Open question (still narrowing)

1. Did the notifier fire at UTC Sep 15 17:45 (local Sep 15 19:45,
   sunset-arm) or at some other UTC time? The answer hinges on
   whether the producer's reactive arming fired correctly or whether
   the sweep kicked in at a different time.

## Files of interest

- `lib/dtu_app/notifications/sun_down*.ex` — sun_down notifier
- `lib/dtu_app/notifications.ex` — dispatcher / broadcast layer
- `lib/dtu_app/notifications/sun_up*.ex` — sister notifier for diff
- `lib/dtu_app_web/live/dashboard_live.ex` — dashboard's daily-bucket
  query (the "working" comparison path)
- `test/dtu_app/notifications/sun_down_notifier_test.exs` — pre-existing
  test file (one of the 5 pre-existing flakes)

## Prior fixes in the area

- **PR #245** — `fix(notifications): SunDown sweep + DB-seeded state for
  silent inverters` — added the periodic sweep + DB-backed dedup.
- **PR #255** — `fix(notifications): dedup before build_payload ordering`
  — moved dedup row creation AFTER nil-payload check so a day doesn't
  lock silently. The session memory file documents this fix.
- **PR #290** — notifications-live refactor (no behaviour change, just
  component extraction).

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

