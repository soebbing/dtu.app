# Dashboard mount perf profile — 2026-08-31

Measured via `test/dtu_app_web/live/dashboard_mount_profile_test.exs`.
Setup: 3 OpenDTU inverters + 1 Shelly Plus 3EM, today's 5-min
buckets seeded for all four devices. Wall-clock mount in the test
env (sandbox pool of 16 connections): **1.2s**, but the DB did
**134.46s of cumulative query work across 103 queries** — the
parallel sandbox hides the contention.

## Query volume by fingerprint

| Fingerprint (first 80 chars) | Count | Total time | Max single |
|---|---:|---:|---:|
| `SELECT now() AT TIME ZONE 'UTC'` | **41** | 35.57s | 3.94s |
| `SELECT id FROM dtus WHERE user_id = $1` | **22** | 18.39s | 2.65s |
| `SELECT time_bucket(... chart points)` | 4 | 10.89s | 5.42s |
| `SELECT DISTINCT (inserted_at::date) FROM readings WHERE dtu_id = ANY(...)` | 2 | 10.11s | 9.13s |
| `SELECT r0."bucket"... FROM readings_5m` | 4 | 7.71s | 3.87s |
| `SELECT r0."inserted_at", r0."consumption_power"...` | 4 | 7.67s | 4.81s |
| `SELECT p0."id"... push_subscriptions` | 2 | 5.49s | 4.51s |
| `SELECT DISTINCT ON (r0."dtu_id", r0."power_type")` | 2 | 5.29s | 4.73s |
| `SELECT DISTINCT ON (r0."dtu_id", r0."inverter_serial") r0."yield_day"` | 4 | 4.54s | 1.81s |
| `SELECT DISTINCT ON (r0."dtu_id") r0."inverter_serial"...` | 2 | 4.27s | 3.7s |
| `SELECT d0."dtu_id", count(DISTINCT d0."message")` (dtu_errors) | 2 | 4.00s | 3.29s |
| `SELECT s0."id"... shared_links` | 2 | 3.74s | 3.30s |
| `SELECT DISTINCT ON (r0."dtu_id", r0."inverter_serial") r0."inverter_serial"...` | 2 | 3.32s | 2.76s |
| `SELECT u1."id"... users` | 2 | 3.29s | 2.18s |
| `SELECT DISTINCT ON (... mppt_index)` | 2 | 2.82s | 2.30s |
| `SELECT r0."dtu_id", max(r0."yield_day")` | 2 | 2.51s | 1.60s |
| `SELECT max(r0."yield_total") FROM readings` | 2 | 2.50s | 1.54s |
| `SELECT d0."id", d0."name"... FROM dtus` | 2 | 2.35s | 1.47s |

**Mean per-query: 1.31s, max single: 9.13s.**

## Where the 30s comes from

Two compounding effects:

1. **Massive N+1 calls.** `now()` and `owned_dtu_ids` are not
   memoized within a single mount — they're called from dozens of
   helper functions, each issuing its own round-trip. 41 + 22 = **63
   of 103 queries are duplicate, exact-text matches** of a call that
   could be served from one query.
2. **Per-query latency is high.** 1.3s mean suggests the DB is
   touching compressed chunks without an index path, or the
   connection-pool checkout latency is dominating. On a 10-connection
   production pool, 103 queries with mean 1.3s = ~13s of pure DB
   time, plus pool contention. That matches the reported 30s.

## Recommended fixes (by leverage)

### Perf #7: cache `DtuApp.Time.utc_now/0` per request

Saves ~35s of query time. The function is pure (returns the DB
clock) and called 41× per mount. Memoize once per LiveView mount via
`:persistent_term` or a process dict keyed by mount id, TTL ~10s.

The drift risk is small: a mounted LiveView lives for seconds-to-minutes,
so a 10s cache is safe. The `Time.utc_now_usec/0` variant for
microsecond precision stays uncached (each reading write gets a fresh
value) — see `Reading.changeset/2`.

### Perf #8: cache `DtuApp.Devices.owned_dtu_ids/2` per request

Saves ~18s. Called 22× per mount from `get_daily_stats`,
`get_consumption_daily_stats`, `list_today_consumption_chart_data`,
`list_net_chart_data`, etc. Same memoization pattern: compute once
at top of `assign_dashboard_data/5` and thread through (or cache by
`{user.id, dtu_id}` key with short TTL).

### Perf #9: investigate `list_selectable_dates` query plan

Still 5s per call even after Perf #2's 5-year bound. Likely missing
index on `(dtu_id, inserted_at)` in the readings hypertable, OR the
`DISTINCT (inserted_at::date)` doesn't use the chunk-exclusion
shortcut we expected. Needs `EXPLAIN ANALYZE` on a representative
dataset. Possible cheap fix: bucket the dates server-side via
`time_bucket('1 day', inserted_at)` and read from `readings_5m` instead
of raw `readings`.

### Lower priority

- **Perf #5 (start_async)** — moves ~1-2s of non-critical work off
  the critical path. Real win after #7/#8/#9 land.
- **Perf #6 (readings_latest_5m cagg)** — low leverage; the
  today-chunk DISTINCT ON is already cheap per call.
- **Perf #4 (15s dashboard cache)** — biggest leverage for repeat
  visits, not first mount. Worthwhile after #7/#8/#9.

## Expected outcome

After #7+#8+#9, mount query count drops from 103 to ~38 (only the
actually-different queries remain), query time drops from 134s to
~13s, and the wall-clock on a 10-connection production pool drops
from ~30s to ~3-5s. Combined with #4, repeat visits hit ~0s.

## Profile harness

`test/dtu_app_web/live/dashboard_mount_profile_test.exs` is a one-off
harness — not a behavioural test, just a `:timer.tc` + Ecto telemetry
instrumentation. Delete once the perf triage is done.