# Dashboard mount perf profile — 2026-09-01 (multi-inverter + Shelly + cloud)

Measured via `test/dtu_app_web/live/dashboard_mount_profile_test.exs`.
Setup: 3 OpenDTU inverters + 1 Shelly Plus 3EM + user with Decimal coords
(so the cloud-cover band + current-condition card both render), today's
5-min buckets seeded for all four devices. Wall-clock mount in the test
env (sandbox pool of 16 connections): **226 ms cold / 68–95 ms warm**,
but the DB did **188.78 s of cumulative query work across 134 queries**
(3 mounts back-to-back) — the parallel sandbox hides the contention.

This is the **post-PR-#220** profile (PR #220 fixed the per-reading
weather reset; that's not in this number). The numbers below reflect
the current state of the dashboard mount with the recent perf work.

## Query volume by fingerprint (top of 134)

| Fingerprint (first 80 chars)                              | Count | Total time | Max single |
|-----------------------------------------------------------|------:|-----------:|-----------:|
| `SELECT now() AT TIME ZONE 'UTC'`                         |  18   | 18.88 s    | 2.79 s     |
| `SELECT r0."bucket"... FROM readings_5m` (chart points)   |  12   | 16.79 s    | 2.61 s     |
| `SELECT u1."id"... FROM users` (current_scope reload)     |   6   | 14.23 s    | 3.42 s     |
| `SELECT DISTINCT (r0."inserted_at"::date) FROM readings`  |   6   | 13.80 s    | 5.57 s     |
| `SELECT time_bucket(... chart points)` (live tail)        |   7   | 12.54 s    | 2.78 s     |
| `SELECT p0."id"... FROM push_subscriptions`               |   6   | 12.48 s    | 3.75 s     |
| `SELECT DISTINCT ON (r0."dtu_id", r0."inverter_serial")`  |  12   | 11.49 s    | 1.69 s     |
| `SELECT DISTINCT ON (r0."dtu_id", r0."inverter_serial")`  |   6   |  9.34 s    | 2.32 s     |
| `SELECT DISTINCT ON (r0."dtu_id", r0."power_type")`       |   6   |  9.31 s    | 2.36 s     |
| `SELECT d0."id", d0."name"... FROM dtus`                  |   6   |  9.01 s    | 2.20 s     |
| `SELECT DISTINCT ON (r0."dtu_id") r0."inverter_serial"`   |   6   |  9.01 s    | 2.10 s     |
| `SELECT r0."inserted_at", r0."consumption_power"...`      |   7   |  8.85 s    | 2.82 s     |
| `SELECT d0."dtu_id", count(DISTINCT d0."message")`        |   6   |  8.59 s    | 3.16 s     |
| `SELECT r0."dtu_id", r0."inverter_serial"... yield_day`   |   6   |  7.67 s    | 2.30 s     |
| `SELECT DISTINCT ON (... mppt_index)`                      |   6   |  7.34 s    | 1.89 s     |
| `SELECT s0."id"... shared_links`                          |   6   |  6.75 s    | 2.79 s     |
| `SELECT max(r0."yield_total") FROM readings`              |   6   |  6.75 s    | 1.86 s     |
| `SELECT d0."id" FROM dtus WHERE user_id = $1`             |   6   |  5.94 s    | 1.55 s     |

**Mean per-query: 1.41 s, max single: 5.57 s.**

## What's driving the user's "way too slow" complaint

Three layers:

1. **N+1 query expansion under multi-inverter.** The 6× / 12× groups
   are exactly the helpers `impl_get_daily_stats/4`,
   `get_consumption_daily_stats/3`, and `get_net_flow_stats/3` run on
   every mount. Each is 5–7 Repo calls per helper, so a multi-inverter
   + Shelly mount is ~30 Repo calls just for the stat-card numbers —
   and each call is a fresh `readings` row scan. With 3 inverters the
   rows-per-scan grows roughly linearly, and `DISTINCT ON` over a
   per-(dtu_id, inverter_serial) set multiplies the cost.

2. **Per-query latency dominated by PG queue time, not plan work.**
   Mean 1.41 s / max 5.57 s in a sandbox with 16 connections — the
   test pool is way oversubscribed for this load, and the production
   pool of 10 connections is even smaller. Each mount queues behind
   the previous mount's still-running queries.

3. **`now()` and `owned_dtu_ids` are still not memoized per request.**
   18 calls to `SELECT now()` and 6 calls to `SELECT d0."id" FROM dtus
   WHERE user_id = $1` per mount. These are exact-text duplicates and
   are pure functions of the request — they should fire exactly once.

## What's not the bottleneck

* `kickoff_weather_fetch/6` (after PR #220) — runs the Open-Meteo
  HTTP only on fingerprint changes; on a fresh-mount + no input
  change path it does at most one HTTP per 15 minutes. Multi-inverter
  doesn't multiply this; user coords are user-level.
* `readings_5m` continuous-aggregate scans — the chart-points query
  hits the cagg and is cheap per call. The 12-count bucket is from
  re-runs across the 8 time-range branches (`today`, `day`, `week`,
  `month`, `year`, `7d`, `30d`, `ytd`) — but actually no, the test
  only mounts the default `today` view; the 12-count comes from
  `live_tail_bucketed_chart_points/3` running inside both
  `list_day_chart_data_for_dashboard/4` and `list_today_consumption_chart_data/2`
  back-to-back.

## Recommended fixes (by leverage)

### Perf #10 — memoize `DtuApp.Time.utc_now/0` per request

Saves ~18 s of cumulative query time. The function is a single
`SELECT now()` call and is invoked from `DtuApp.Devices`
implementations and the LiveView mount path. Pattern (same as the
existing per-request `TodayDataCache`): key the memoization by
`{request_id, call_kind}` or use a short-TTL ETS row. Drift is fine
within a 10s window for stat displays.

### Perf #11 — memoize `DtuApp.Devices.owned_dtu_ids/2` per request

Saves ~6 s. Called from `impl_get_daily_stats/4`,
`get_consumption_daily_stats/3`, `get_net_flow_stats/3`,
`list_today_consumption_chart_data/2`, `list_net_chart_data/4`, etc.
6× per mount is from the 6 distinct call sites, not duplicated calls
within one site — but each one issues the same `SELECT id FROM dtus
WHERE user_id = $1` query. Thread `dtu_ids` through instead of
re-deriving. Pattern: `assign_dashboard_data/5` computes it once at
the top and passes it down, OR `owned_dtu_ids/2` memoizes in
`:persistent_term` with a per-request cache key.

### Perf #12 — fold `impl_get_daily_stats/4`'s 5 separate `readings` queries into 2

The function issues 5 `Repo.all` calls against `readings`:

1. `latest_ac_readings` (DISTINCT ON dtu_id, inverter_serial, mppt_index=0)
2. `latest_per_series_readings` (DISTINCT ON dtu_id, inverter_serial, mppt_index)
3. `today_yield_per_inverter` (DISTINCT ON dtu_id, inverter_serial, mppt_index=0, yield_day)
4. `total_yield_per_inverter` (GROUP BY dtu_id, inverter_serial, max(yield_total))
5. `per_series_rows` (GROUP BY dtu_id, inverter_serial, inverter_name, max(yield_day))

#1 and #3 have **identical WHERE clauses and identical ORDER BY** —
only the SELECT differs. Merge into one query using two
`max(yield_day) FILTER (WHERE ...)` aggregates or by SELECTing both
`ac_power` and `yield_day` in one DISTINCT ON and splitting in Elixir.

#2 and #5 are related (`yield_day` max per (dtu, serial, name)) — can
share a join.

### Perf #13 — `list_selectable_dates` query plan

Still 5s per call (`SELECT DISTINCT (r0."inserted_at"::date) FROM
readings WHERE dtu_id = ANY(...)`). Same fix as Perf #9 in the prior
profile (bucket via `time_bucket('1 day', inserted_at)` and read from
`readings_5m` instead of raw `readings`).

### Perf #14 — pre-thread `consumption_chart_points` / `net_chart_points` through more helpers

The TodayDataCache (Perf #4) threads `consumption_chart_points` and
`net_chart_points` through `assign_dashboard_data/5` → already fetched
once. But `get_consumption_period_stats/4` (line 2011) still calls
`get_consumption_daily_stats` again in the non-today branches because
the cached points are today-bounded, not period-bounded. Either bound
the cache key to include the period, or fetch separately per branch.

## Expected outcome

After #10+#11+#12, mount query count drops from ~134 → ~60, total DB
time drops from 188s → ~30s, and wall-clock on a 10-connection pool
drops from "way too slow" → ~3-5s. Combined with Perf #4's existing
15s dashboard cache (now `TodayDataCache`), repeat visits are instant.

## Profile harness

`test/dtu_app_web/live/dashboard_mount_profile_test.exs` is a one-off
harness — not a behavioural test, just a `:timer.tc` + Ecto telemetry
instrumentation. Delete once the perf triage is done.

See [[dtu-app-perf-triage-state]] for the prior triage that closed
Perf #1–#5 + #7–#9 and dropped #6.
