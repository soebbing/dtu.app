# dtu.app — Current State of the Application

> A documentation snapshot written so that another agent could recreate a
> similar application from scratch. It captures the *what*, the *why*, and
> the *how it gets shipped*, as observed in this repository on 2026-08-18.
> The application is a small but full-stack Elixir/Phoenix project — read
> this end-to-end before planning any rebuild.

---

## 1. Goal and positioning

`dtu.app` is a **self-hosted, multi-tenant solar telemetry service** for
owners of **OpenDTU** and **AhoyDTU** inverters (the open-source firmware
projects for Hoymiles micro-inverters and similar), plus optional
**Shelly Plus 3EM (Gen3+)** energy meters.

The pitch in one line: it is the single BEAM release that replaces the
"glue Mosquitto + InfluxDB + Grafana + auth layer" stack that an OpenDTU
user would otherwise assemble themselves.

- **Bring your own hardware**: any device running OpenDTU or AhoyDTU
  firmware, or a Shelly Plus 3EM meter.
- **No separate broker**: an embedded MQTT broker (started in the same
  release) accepts uplinks directly — `dtu.app` *is* the broker.
- **Multi-tenant**: every user has an isolated account with isolated
  devices and readings; one release can serve many households.
- **Time-series scale**: TimescaleDB hypertables + continuous aggregates
  keep years of readings cheap to store and fast to query.
- **Self-hosted-first** deployment story via Docker Compose, with TLS
  termination expected to come from a reverse proxy (Traefik/Caddy/nginx).

It is described by the maintainers as "early / hobby project under
active development" — not a hardened multi-tenant SaaS. The application
is meant to be run by individuals or trusted peers, not by anonymous
strangers.

---

## 2. Feature surface

### 2.1 Embedded MQTT broker

- An MQTT broker runs inside the same release so DTUs can publish
  directly to `dtu.app`. There is no separate Mosquitto in front.
- Powered by the [`mqttx`](https://hex.pm/packages/mqttx) Hex package
  sitting on top of Thousand Island for the transport.
- Default listen port `:1883` (plain TCP). TLS termination is expected
  upstream; the compose file references wrapping on `:8883` via Traefik.
- Only enabled in `:dev` and `:prod` — explicitly disabled in `:test`
  so the test suite never binds the broker port.
- The broker is configurable via env: `MQTT_BROKER_ENABLED` (default
  `true`), `MQTT_BROKER_PORT` (default `1883`).
- Transport-level knobs (configured in `config :dtu_app, :mqtt_broker`):
  - `server_keep_alive: 30` seconds — overrides client keepalive so
    DTUs behind NAT/proxies stay alive.
  - `receive_maximum: 100` — capped inflight per client.
  - `max_packet_size: 256_000` bytes — generous limit for any
    realistic telemetry payload.

### 2.2 Per-device MQTT credentials and authentication

- A `Dtu` record owns one pair of credentials (`mqtt_username`,
  `mqtt_password`); the password is Argon2-hashed before storage.
- `mqtt_username` is **globally unique**: an MQTT connection is
  resolved to a single device by username alone — no `client_id`
  trust, no per-tenant credential collision possible.
- On `CONNECT`, the broker verifies the (username, Argon2) pair via
  a GenServer-backed ETS cache (`DtuApp.MqttBroker.Credentials`):
  - ETS table `:mqtt_credentials` (`username => password_hash`),
  - ETS table `:mqtt_devices` (`username => %{id, user_id, kind,
    base_topic, name}`),
  - Populated on broker boot; updated in place via `refresh/1`
    after every `Dtu` create/edit and `drop/1` after every delete.
  - `Argon2.no_user_verify/0` is called on a missed username match
    so the wall-clock cost of a missing user equals the cost of a
    matching one — constant-time auth path.
- Supported `kind` values: `:opendtu`, `:ahoydtu`, `:shelly3em`.
  Each carries its own default base topic
  (`solar` / `inverter` / `shellies/shellyplus3em`).
- The user-facing create dialog generates the username/password
  automatically (random hex strings), then displays the credentials
  plus broker host/port/base-topic in a "Post-create setup dialog"
  modal that the user copies into their DTU's MQTT settings.

### 2.3 Dual-format telemetry ingestion

- One in-process parser (`DtuApp.MqttBroker.Telemetry`, a GenServer)
  consumes uplinks published by the broker over `Phoenix.PubSub`
  topic `dtu:uplink`. There are three parsers, one per `kind`:

**OpenDTU** (consolidated JSON + per-MPPT per-field topics)

```
{base}/{inverter_serial}/realtime/data           # consolidated JSON
{base}/{inverter_serial}/name                    # inverter friendly name
{base}/{inverter_serial}/[0-9]/{field}           # per-channel metric
{base}/{inverter_serial}/status/producing        # 0 | 1
{base}/{inverter_serial}/status/reachable        # 0 | 1
```

- `realtime/data` carries the AC-side aggregate (`mppt_index = 0`
  row), which holds the inverter's actual AC output, today's yield,
  lifetime yield, frequency, temperature, producing/reachable
  flags. One `readings` row per uplink.
- Per-MPPT DC inputs (`[serial]/1/power`, `[serial]/2/power`, …) are
  buffered per `(serial, channel)` and flushed whenever any
  recognised field lands. Recognised per-field metrics: `power`,
  `yieldday`, `yieldtotal` (everything else drops with a debug log).
- `{serial}/name` retroactively updates `readings.inverter_name` for
  every existing row of that `(dtu_id, serial)` — making the new
  friendly name appear in the chart legend immediately.
- `{serial}/status/{producing|reachable}` patches the latest
  reading for that inverter in place rather than producing a new
  row every flag change.

**AhoyDTU** (numeric-per-metric + JSON layout + fleet-total topic)

```
{base}/{inverter_name}/ch{0..6}/{Metric}        # numeric scalar
{base}/{inverter_name}/ch{0..6}                 # JSON of metrics
{base}/total                                    # JSON fleet total
{base}/total/{Metric}                           # numeric fleet total
```

- AhoyDTU scatters one metric per uplink (`P_AC`, `P_DC`,
  `YieldDay`, `YieldTotal`, `F_AC`, `Temp`, `producing`,
  `reachable`), so the parser buffers per `(name, channel)` and
  flushes a row whenever any recognised metric arrives (this was a
  bugfix: a `temperature`-only uplink used to be silently dropped).
- `ch0` is the AC aggregate; `ch1..6` are per-MPPT DC inputs.
  The parser **deliberately drops `YieldDay`/`YieldTotal` from
  per-MPPT rows** because AhoyDTU's ch1+ch2 are sub-totals already
  summed into ch0 — keeping them would double-count.
- `{base}/total` is parsed into a row keyed by `inverter_serial =
  "_fleet"` carrying `YieldDay` (Wh, verbatim) and `YieldTotal`
  (kWh, normalised to Wh at the boundary via `cast_ahoy_yield/1`).
  The dashboard prefers this row over per-inverter sums so the
  firmware-aggregated value reaches the user verbatim.
- `cast_ahoy_yield/1` is the single boundary where AhoyDTU's kWh
  lifetime counter is normalised to Wh; everything downstream of
  the parser is unit-uniform with OpenDTU.

**Shelly Plus 3EM (Gen3+)** (consolidated JSON)

```
{base}/status/em:0                              # JSON, em component
{base}/online                                   # retained LWT
```

- The 3EM publishes one JSON object per uplink on `status/em:0`,
  with nested per-phase energy under `a_energy.total`,
  `b_energy.total`, `c_energy.total`. The parser sums the
  per-phase active power defensively (`total_act_power` primary,
  per-phase fallback) and the per-phase `*.energy.total` lifetime
  counters into a single `consumption_power` / `consumption_energy_total`.
- Voltage / current / freq / pf are dropped to keep the schema lean.
- Persisted with `power_type = "consumption"` so it never collides
  with a `production` row from an inverter.
- Both single-segment (`shellies`) and multi-segment
  (`shellies/shellyplus3em`) base topic prefixes are accepted.
- Topic-mismatch is logged at warning and surfaced to the user as
  the most actionable of all the error paths (the symptom — "device
  shows online but no values" — is impossible to diagnose from logs
  alone, and the fix is concrete: change the Shelly's MQTT prefix).

### 2.4 Unified `Reading` schema and storage

- A single `DtuApp.Devices.Reading` schema persists every parsed
  sample (regardless of device kind).
- Composite primary key: `(dtu_id, inverter_serial, mppt_index,
  inserted_at)` — *no serial `id`*. The PK exists only because
  TimescaleDB requires the partitioning column to be in every unique
  index; the app never round-trips a reading by id.
- Fields stored:
  - Production rows: `inverter_serial`, `mppt_index`,
    `inverter_name`, `ac_power`, `dc_power`, `yield_day`,
    `yield_total`, `frequency`, `temperature`, `producing`,
    `reachable`, plus `dtu_id` (FK), `inserted_at` (PK), and
    `power_type = "production"` (default).
  - Consumption rows: replace the above AC fields with
    `consumption_power`, `consumption_energy_day`,
    `consumption_energy_total`, plus `power_type = "consumption"`.
  - `inverter_name` is the friendly label from either the
    `{serial}/name` topic or a user edit; nullable until either
    fires.
- `inserted_at` is `:utc_datetime_usec` (microsecond precision). The
  parser uses the database clock (`SELECT now() AT TIME ZONE 'UTC'`
  via `DtuApp.Time.utc_now_usec/0`) so the value that gets bucketed
  matches the value the dashboard compares against. On PK collision
  (same `(dtu_id, inverter_serial, mppt_index, inserted_at)`), the
  parser bumps `inserted_at` by 1 µs, up to 1 ms of attempts.
- The table is a TimescaleDB **hypertable** keyed on `inserted_at`:
  - Chunk time interval: 7 days.
  - Compression policy: 7 days after insert (segmented by `dtu_id`).
  - Retention policy: 365 days.
  - Three **continuous aggregates**: `readings_5m`,
    `readings_hourly`, `readings_daily` — each `WITH NO DATA` at
    create time and refreshed by policies that union recent raw
    rows. The dashboard *prefers the aggregates when feasible* but
    many stat-card queries still hit `readings` directly because
    `MAX(yield_day)` over a day is cheap enough and lets the
    existing `get_daily_stats/3` stay simple.
- Companion migration sets `DEFAULT now()` on every timestamp
  column so any direct `INSERT` that doesn't supply a value still
  gets the DB clock.

### 2.5 Dashboard (Phoenix LiveView)

- The `DtuAppWeb.DashboardLive` LiveView mounts at `/dashboard` and
  carries the home-screen experience.
- Subscribes (when connected) to:
  - `dtu:reading` (`Telemetry.subscribe/0`) — every parsed reading
    pushes an immediate re-render,
  - `dtu:status` (`Telemetry.subscribe_status/0`) — `:dtu_seen`
    re-streams the device list,
  - `dtu:presence` (`Broker.subscribe_presence/0`) — CONNECT /
    DISCONNECT events,
  - `dtu:timezone` — colocated JS hook pushes the user's UTC offset
    via `push_event/3` / PubSub so day boundaries render in their
    local timezone,
  - per-user `user:notification:<id>` — receives `:notification`
    events fanned from `DtuApp.Notifications.broadcast/2` and
    forwards them to the page's `phx-hook="Notifications"` sink.
- View modes:
  - **Today** (live, auto-refreshing): one stat-card row for
    production (`Current Generation`, `Today's Total Yield`, `Peak
    Generation`) and one row for the optional consumption side
    (`Current Consumption`, `Today's Consumption`, `Peak
    Consumption`); a net-flow row (`Net flow now`, `Exported
    today`, `Imported today`, `Peak export`, `Peak import`) shows
    up only when the user has a Shelly; a savings card (`Saved
    today`) when the user has set a €/kWh rate.
  - **Historical stepper**: granularity `day` / `week` / `month` /
    `year` driven by `time_range` / `selected_period` assigns. Prev/
    next/calendar navigation. Each granularity has its own stat-card
    layout: day = `{total_yield, peak_power, avg_power}`, week/
    month/year = `{period_total, period_avg, period_peak, peak_date}`.
  - **DTU switcher**: aggregate across all user devices or
    narrow to one specific device. Internally represented as
    `selected_dtu_id :: nil | pos_integer` where `nil` means "all
    devices", the literal `"total"` coming from the UI is mapped to
    `nil`. Affects the chart legend and every stat card.
- Charts are **server-rendered SVG** (no Chart.js, no D3). The data
  bucketing is pure Elixir and happens in
  `DtuApp.Devices.list_day_chart_data/4` (5-minute buckets per
  `(dtu_id, inverter_serial, mppt_index, inverter_name)` series).
  Y-axis labels render `format_number/2` so a German user gets
  `1.234,5` and a French user gets `1 234,5`.
- The dashboard also owns:
  - **Today's total yield**: when AhoyDTU's `{base}/total` row
    exists, prefer it; otherwise fall back to per-inverter sums
    restricted to `mppt_index = 0` to avoid double-counting ch0 +
    ch1 + ch2.
  - **Lifetime total yield** (same logic).
  - **Net flow** (`production - consumption`): per-bucket mean on
    each side so a Shelly's ~10 readings per 5-min window and a
    Hoymiles's 1 reading per window both contribute a single
    household figure. `clamp_household_draw/1` floors the Shelly's
    signed `total_act_power` at ≥ 0 W for every visible surface.
  - **Per-device peak power** per (inverter, MPPT) series for the
    legend, computed from the freshest readings within the
    "two-minute freshness" window.
- TZ-aware stat reads: every query that filters by day windows is
  built from the user's offset using
  `DtuApp.Devices.local_day_utc_range/2`.

### 2.6 Devices management (`/devices`)

- `DtuAppWeb.DeviceLive.Index` is the Live, in-browser CRUD page.
- Streams the device list using LiveView streams (cheap
  re-renders on `:dtu_seen` / `:dtu_error` events).
- Per-row controls:
  - Edit name / kind via in-line form.
  - **Details** link opens `DeviceLive.Details` (its own LiveView
    so the heavy live-topic subscription doesn't slow down the
    index).
  - Delete with confirm modal.
- Online indicator on each row is derived:
  `Dtu.online?(dtu, now)` returns true iff `now -
  dtus.last_seen_at < 300 s`. Every MQTT uplink (and CONNECT /
  DISCONNECT) touches `last_seen_at`, so a DTU that stays TCP-
  connected but stops publishing still flips to "offline" within
  five minutes.
- An **expansion panel** under any device row surfaces the
  per-device error history (last 48 hours, distinct message count
  with last-seen timestamp and occurrence count). The panel is
  bookmarkable via `?expand=<dtu_id>` and survives refresh.
  Bad-`expand` ids silently collapse to "no panel" rather than
  404 (an id that isn't the user's device is rejected before
  querying).
- The **post-create setup dialog** opens the first time a device
  is added and shows the broker host/port/username/password
  /base-topic the user must enter in the DTU's MQTT settings.

### 2.7 Device details (`/devices/:id/details`)

- Live view of every MQTT topic + payload the device is publishing,
  including topics the parser doesn't interpret — built from
  `DtuApp.MqttBroker.TopicRegistry.get_topics_for/1`.
- Subscribes to `dtu:topics` so each uplink re-fetches the device's
  snapshot without a full-page reload.
- Topic tree renders as nested `<details>` elements, one per path
  segment. JSON payloads pretty-print in a collapsible `<pre>`.
- A "Copy as JSON" button pushes the topic map as a JSON
  document via `push_event/3` and writes it to the clipboard from
  a colocated JS hook — on-demand (not baked into the DOM, so the
  steady-state render stays light).
- A second column reuses `DtuApp.Devices.list_dtu_error_groups/1`
  (the same rollup the index's expansion panel uses), filtered to
  the same device. Errors within the last 48 h are listed with
  occurrence count and last-seen relative time.
- The Topic Registry itself:
  - ETS-backed `:public` table keyed on `dtu_id`, value is
    `%{topic => {payload, received_at}}`.
  - Per-DTU FIFO eviction at 200 topics (so a misbehaving
    firmware doesn't OOM the BEAM).
  - Per-payload truncation at 4 KB with a trailing `…`.
  - Prune tick every 60 s drops entries older than 300 s
    (matches the online-offline threshold).
  - Subscribes to `dtu:uplink` independently from the parser —
    a slow parser never back-pressures the live-topic capture.

### 2.8 Notifications & Web Push

- The `/notifications` page (a LiveView, `NotificationsLive`)
  exposes:
  - `notify_dtu_connection` (browser notification when an
    inverter's online state changes),
  - `notify_sun_down` (end-of-day summary comparing today's yield
    + peak vs. yesterday),
  - a "Send test notification" button (only enabled when
    permission state is `granted`).
- Two delivery paths:
  - **In-page**: `DtuAppWeb.UserNotifications.broadcast/2`
    publishes to `user:notification:<id>`; the dashboard's
    colocated `Notifications` JS hook receives it, calls
    `new Notification(...)` after deduplicating by `tag` in
    `localStorage`.
  - **Native**: `DtuApp.Push.deliver/2` looks up every
    `push_subscriptions` row for the user, signs (VAPID, RFC
    8292), encrypts (AES-128-GCM, RFC 8291), and POSTs via
    Finch to the user's push service (FCM, Mozilla autopush,
    Apple). HTTP 404/410 (`{:error, :gone}`) deletes the row;
    other errors log and continue.
- The transport is the `web_push` Hex package + a dedicated
  `DtuAppWeb.WebPushFinch` pool (started in the Application
  supervisor) so a slow push service can never back up
  unrelated HTTP work.
- A `bin/gen-vapid` script generates a VAPID keypair and writes
  it idempotently into `.env` — `--force` is required to
  overwrite because rotating VAPID keys invalidates every
  browser `PushManager.subscribe()` for the origin and silently
  breaks notifications until users re-enable them.
- All three env vars (`VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`,
  `VAPID_SUBJECT`) are required in `:prod`; in `:dev` the
  runtime generates an ephemeral keypair on every boot and logs
  it so the developer doesn't have to provision keys just to
  test the OS-banner path.
- Helper: `DtuApp.Notifications.broadcast/2` is the fan-out
  point. Both paths are no-ops if there's nothing to deliver —
  the in-page broadcast is a no-op when no LiveView is
  subscribed; the web-push path skips when the user has no
  `push_subscriptions`.

### 2.9 Service worker / PWA

- A `priv/static/service-worker.js` is fingerprinted by `mix
  phx.digest` and *intentionally not bundled by esbuild* — kept
  dependency-free and portable across browsers.
- It owns three concerns:
  1. **Tier-2 static cache** for offline reads.
  2. **Push event handling**: receives VAPID-signed push payloads
     from the server and shows the OS banner.
  3. **notificationclick**: routes the user back to the
     dashboard via `data.url` carried on the payload.
- The root layout registers a `manifest.webmanifest`,
  `apple-touch-icon`, and theme-color metadata; the navbar ships
  a glassmorphic header with a `<details>`-driven burger menu
  on mobile and a layout-aware nav on desktop, plus an
  `<OfflineBanner>` that flips on `data-offline` driven by
  `navigator.onLine`.

### 2.10 Internationalisation

- Gettext PO files under `priv/gettext/{en,de,fr,default.pot,
  errors.pot}`.
- `DtuAppWeb.Plugs.Locale` lives in the `:browser` pipeline and
  the `live_session :current_scope`, reading the locale from the
  `Gettext` backend so all UI strings round-trip through
  `gettext/1` / `ngettext/4`.
- Number formatting is locale-aware via
  `DtuApp.Devices.format_number/3`:
  - `en` → `1,234.5`
  - `de` → `1.234,5`
  - `fr` → `1 234,5` (NBSP per AFNOR/DIN 5008)
- Savings formatting (`format_savings/2`) follows the same locale
  conventions with `€` after the number.

### 2.11 Account, settings, magic-link login

- Authentication is the canonical `phx.gen.auth` flavour: magic
  link via email, Argon2 password option as a fallback.
- Account fields:
  - `email`, `hashed_password`, `confirmed_at`
  - `authenticated_at` (used by `sudo_mode?/2`)
  - `notify_dtu_connection`, `notify_sun_down`
    (boolean toggles added by `20260804100000_add_notification_settings_to_users`)
  - `cents_per_kwh` (integer-cent energy rate for the dashboard
    savings card; added by `20260806000000_add_cents_per_kwh_to_users`)
- Magic-link tokens carry both kinds of tokens used by
  `phx.gen.auth` (login, session, change-email). Three
  transactional emails go through Swoosh:
  1. Magic-link login email.
  2. Email-change confirmation.
  3. New-user confirmation / first-login fallback.
- Delivery modes (picked in order of precedence at runtime):
  1. **Resend API** (`RESEND_API_KEY` set) — `Swoosh.Adapters.Resend`.
  2. **Mailpit SMTP** (`MAIL_DELIVERY=mailpit`) — local SMTP capture
     on `:1025` with a web UI at `:8025` for inspecting emails.
  3. **In-memory** (neither set) — `Swoosh.Adapters.Local`; emails
     are swallowed and the magic-link URL is reachable from the
     server logs / IEx session.
- `DtuApp.Time.utc_now/0` (DB-clock seconds) and
  `utc_now_usec/0` (microseconds) back all token expiry checks,
  so a drifted app clock can't accidentally expire valid tokens.
- Settings page (`/users/settings`) — email change, energy rate
  (`cents_per_kwh`), logout.

### 2.12 Database time invariants

- Every persisted timestamp is written from the database clock via
  `DtuApp.Time.utc_now/0` / `utc_now_usec/0`, not the application
  container's clock.
- Why:
  - Multi-container / multi-host deployments can't be sure every
    container's wall clock agrees.
  - Time-windowed queries (`token.inserted_at < ^cutoff`,
    `readings.inserted_at >= ^from`, etc.) round-trip through
    Postgres. If the write side used the app clock and the read
    side used the DB clock (`now()`), a few minutes of drift
    would mis-classify freshly-issued magic links as "expired"
    or flip a DTU's online badge minutes early / late.
- The companion migration sets `DEFAULT now()` on every
  timestamp column so any direct `INSERT` that omits the value
  still gets the DB clock.

### 2.13 Errors and observability

- Per-device `dtus.last_error` / `dtus.last_error_at` columns
  capture the most recent user-visible error.
- A separate `dtu_errors` table records the full per-message
  history, capped at 200 rows per device (FIFO prune) so the
  table stays bounded.
- A 48-hour recency window filters what's shown in the dashboard
  edge-badge / expansion panel (`dtu_error_recency_seconds`).
- All errors pass through `DtuApp.MqttBroker.Telemetry.record_dtu_error/2`
  which writes the message, fans a `:dtu_error` PubSub event so
  subscribed LiveViews re-stream the affected device row
  immediately.
- The unknown-topic paths downgrade to `Logger.info` with the
  topic + payload bytes so the developer can grep logs and see
  exactly what the firmware sent. These do *not* pollute the
  user-facing error list (an "unused topic" is not an error —
  it's just a future firmware feature we don't parse yet).
- `telemetry_metrics` + `telemetry_poller` + `Phoenix.LiveDashboard`
  provide the BEAM-telemetry hookup for live performance
  inspection in dev (gated behind `:dev_routes`).

---

## 3. Tech stack

| Layer        | Choice                                                          |
| ------------ | --------------------------------------------------------------- |
| Language     | Elixir 1.16.2 / OTP 26.2.2                                      |
| Web          | Phoenix 1.8 + LiveView 1.2, served by Bandit                    |
| Realtime     | Embedded MQTT broker (MqttX) over Thousand Island               |
| Database     | PostgreSQL 16 + TimescaleDB (hypertables + caggs)               |
| ORM / schema | Ecto 3.13 + Ecto SQL                                            |
| Auth         | `phx.gen.auth` (magic link + Argon2 password)                    |
| Mail         | Swoosh → Resend / SMTP (Mailpit) / Local                         |
| Web Push     | `web_push` (VAPID/AES-128-GCM) + `finch`                        |
| Realtime UI  | LiveView streams; colocated JS hooks via `Phoenix.LiveView.ColocatedHook` |
| Assets       | Tailwind CSS v4, esbuild (`0.25.4`), Heroicons v2               |
| Tests        | ExUnit (server) + Playwright (`@playwright/test`) for E2E       |
| Schedules    | manual (`:one_for_one` Application supervisor — no Quantum / Oban in this codebase today) |

---

## 4. Application architecture (one paragraph each)

**Supervision tree (`DtuApp.Application`)** is a `:one_for_one`
supervisor. Children, in start order:

1. `DtuAppWeb.Telemetry` — BEAM telemetry supervisor + poller.
2. `DtuApp.Repo` — Ecto connection pool.
3. `DNSCluster` — only when `dns_cluster_query` is configured
   (cluster query). In dev it's `:ignore`.
4. `Phoenix.PubSub` named `DtuApp.PubSub` — the single PubSub for
   every cross-process message in the system (uplinks, readings,
   status, presence, per-user notifications, timezones, topic
   snapshots).
5. `Finch, name: DtuAppWeb.WebPushFinch` — dedicated HTTP pool
   for web-push traffic.
6. (Conditional on `mqtt_broker.enabled`) `DtuApp.MqttBroker.Credentials`
   GenServer + `MqttX.Server` named `DtuApp.MqttBroker.Broker`.
7. `DtuApp.MqttBroker.Telemetry` — parser GenServer; must start
   *after* PubSub so it can subscribe on init.
8. `DtuApp.MqttBroker.TopicRegistry` — independent parser
   companion that subscribes to `dtu:uplink` for the device-details
   page; parallel subscription path so a slow parser never
   back-pressures live-topic capture.
9. `DtuAppWeb.Endpoint` — Bandit / Phoenix endpoint, last.

**Data flow for a live reading**:

1. The DTU opens an MQTT connection to `:1883` with its Argon2-
   hashed credentials.
2. The broker's `handle_connect/3` (in `DtuApp.MqttBroker.Broker`)
   resolves the username to a `Dtu` via the ETS-backed
   `Credentials` cache, subscribes its own process to
   `dtu:downlink:<client_id>`, and broadcasts `:dtu_connected`.
3. On each `PUBLISH`, `handle_publish/4` re-broadcasts on
   `dtu:uplink` with the parsed client_id and the authenticated
   device info.
4. `DtuApp.MqttBroker.Telemetry` (the parser) consumes the
   uplink, routes it to the appropriate parser by `kind`,
   converts the payload to a `Reading` (or `buffer → flush`
   round), inserts via `DtuApp.Devices.create_reading/1`, then
   broadcasts a `:reading` event on `dtu:reading`.
5. `DashboardLive` (subscribed to `dtu:reading`) receives the
   event and re-renders the affected stat / chart point within a
   few hundred ms.
6. `TopicRegistry` (also subscribed to `dtu:uplink`) records the
   payload against its per-DTU topic map and broadcasts a
   `:topic_seen` so the device-details LiveView (if open) can
   refresh.
7. The Telemetry parser also calls `touch_last_seen/1`, which
   updates `dtus.last_seen_at` to the DB clock and broadcasts a
   `:dtu_seen` so subscribed device lists re-render the online
   indicator.
8. Native Push delivery (when configured): parallel to all of the
   above, `DtuApp.Notifications.broadcast/2` fans events onto
   per-user PubSub topics + `DtuApp.Push.deliver/2` POSTs VAPID-
   signed, AES-encrypted payloads to the push services.

**Multi-tenant isolation**: every `DtuApp.Devices` function is
scoped to an owning `%User{}`; `mqtt_broker.Credentials.verify/2`
resolves a connection to a device by username alone and the
broker carries the device's `user_id` through to the parser. There
is no cross-tenant data path — every read and every write
originates from `current_scope.user`.

**Time invariants**: see §2.12. Every persisted timestamp uses the
DB clock; every "fresh / stale" judgement uses the same clock.

---

## 5. Local development

### 5.1 Prerequisites

- **Erlang/OTP 26.2.2** and **Elixir 1.16.2**. The CI uses
  `erlef/setup-beam@v1` to pin these; locally, asdf or kiex
  works fine.
- **Node.js 20** (the CI uses `actions/setup-node@v4`).
- **PostgreSQL 16 with TimescaleDB**, either:
  - the `timescale/timescaledb:latest-pg16` container from compose
    (recommended for parity with prod), or
  - a system Postgres with the TimescaleDB extension loaded — needed
    because two migrations call `create_hypertable/2` and friends.
- **Mailpit** is optional; the compose file ships it as a sidecar,
  but plain `mix phx.server` works against the in-memory mailer.

### 5.2 Bring-up

```sh
mix setup          # deps.get + ecto.setup + assets.setup + assets.build
mix phx.server     # http://localhost:4000
```

`mix setup` runs:

- `mix deps.get`
- `mix ecto.setup` (create + migrate + seed)
- `mix assets.setup` (tailwind + esbuild install if missing)
- `mix assets.build`

`mix ecto.reset` is the hard reset (`drop` + `setup`).

If you don't have TimescaleDB locally, the `timescale/timescaledb:latest-pg16`
container is the easiest source of truth. It works in dev too.

### 5.3 Capturing email locally

The Docker Compose stack ships a Mailpit sidecar; the
in-memory mailer is the default otherwise. To capture magic-link
emails during local dev:

```sh
docker compose up -d mailpit
MAIL_DELIVERY=mailpit SMTP_RELAY=localhost SMTP_PORT=1025 \
  mix phx.server
```

Then open <http://localhost:8025> to inspect the captured email.
`MAIL_FROM` can be anything you like — Mailpit accepts
everything.

### 5.4 Asset pipeline

- **esbuild** (`0.25.4`) bundles `assets/js/app.js` and its
  collaborators (`notifications.js`, `push_subscribe.js`,
  `offline_banner.js`, `notification_permission.js`) into
  `priv/static/assets/js`.
- **Tailwind v4** (`4.3.0`) compiles `assets/css/app.css` →
  `priv/static/assets/css/app.css`. The CSS uses the
  `@import "tailwindcss" source(none); @source …;` form (no
  `tailwind.config.js`).
- **Heroicons v2.2.0** — vendored as `assets/vendor/heroicons.js`,
  rendered via `<.icon name="hero-…" />` (`core_components.ex`).
- LiveReload watches:
  `priv/static/(?!uploads/).*\.(js|css|png|…)` and `lib/dtu_app_web/{controllers,live,components}/.*`.

### 5.5 Local MQTT broker

- The broker binds `:1883` on `127.0.0.1` automatically when
  `mix phx.server` is running in `:dev`.
- `MQTT_HOST` (env) overrides the address shown to users in the
  device setup modal — useful when MQTT runs on a different host
  than the web app.

---

## 6. Testing strategy

### 6.1 ExUnit (server-side)

- `mix test` — runs the `Ecto.Adapters.SQL.Sandbox` Pool, with
  `argon2_elixir` cost dropped (`t_cost: 1, m_cost: 8`) so
  password hashing tests don't take seconds each.
- `:test` disables the MQTT broker (`config :dtu_app, :mqtt_broker,
  enabled: false`) so nothing binds `:1883` during tests.
- Mailer is `Swoosh.Adapters.Test` in `:test` so no emails are
  sent.
- Sandbox-friendly fixtures live in `test/support/fixtures` (users,
  devices).
- `start_supervised!/1` for processes under test; `Process.monitor/1`
  + `assert_receive {:DOWN, …, :normal}` for awaiting termination
  instead of `Process.sleep/1`.
- ExUnit files live alongside the modules they cover:
  `test/dtu_app/{accounts,devices,mqtt_broker,push,push_subscriptions,time}_test.exs`
  and `test/dtu_app_web/{controllers,live,plugs,components}/...`.

### 6.2 Playwright (browser E2E)

- Driven by `@playwright/test`. Config at `playwright.config.js`.
- Targets **Chromium** by default; honours `PLAYWRIGHT_CHROME`
  for NixOS where Playwright's bundled Chromium can't run.
- `testDir: ./test/e2e`, fully parallel, retries = 2 in CI.
- A `globalSetup` (`test/e2e/_setup/global-setup.js`) re-seeds
  via `mix run priv/repo/seeds.exs` once before any spec runs.
  Set `E2E_SKIP_SEED=1` to skip when iterating against an
  already-seeded DB.
- Tests assume the app is reachable at `http://localhost:4000`
  with the seeded credentials (`test@example.com` /
  `password123456`), three DTUs (Roof Inverter / Balcony /
  Garage Array), today's sine arc + historical readings from
  ~1 year back.
- Specs cover:
  - `login_dashboard.spec.js` — auth + dashboard landing +
    full DTU CRUD.
  - `dtu_setup_dialog.spec.js` — post-create setup dialog +
    localisation.
  - `dashboard_historical.spec.js` — Today / Day / Week / Month /
    Year stepper + DTU switcher.
  - `dashboard_multi_device.spec.js` — multi-device behaviour.
  - `dashboard_multi_mppt.spec.js` — per-inverter / per-MPPT chart
    breakdown (regression test for "chart lines flat at X-axis").
  - `dashboard_savings_card.spec.js` — `/users/settings` energy
    rate + the savings card (regression for unit-confusion bug).
  - `settings_kwh_price.spec.js` — same surface; persists / clears
    / rejects.
  - `notifications.spec.js` — `/notifications` page + permission
    state UI.
  - `magic_link.spec.js` — magic-link login flow via Mailpit's
    JSON API.
- Always run with the Phoenix server already up — the global
  setup only re-seeds, it does not boot the app.

### 6.3 Pre-commit

```sh
mix precommit      # compile --warnings-as-errors + deps.unlock --unused + format + test
```

This is the CI's local-equivalent sanity check.

---

## 7. Delivery / CI / deployment

### 7.1 GitHub Actions — CI (`.github/workflows/ci.yml`)

- Triggers on `push:branches:main` and `pull_request:branches:main`.
- Two jobs: `test` and `build-docker`.
- `test` job spins up two service containers on the runner:
  - `timescale/timescaledb:latest-pg16` on `:5432`,
  - `axllent/mailpit:latest` on `:1025` (SMTP) and `:8025` (UI).
- Steps:
  1. Checkout + `erlef/setup-beam@v1` (Elixir 1.16.2 / OTP 26.2.2).
  2. Cache `deps`/`_build` keyed on `mix.lock`.
  3. `mix deps.get`.
  4. `mix format --check-formatted`.
  5. `mix compile --warnings-as-errors` (`MIX_ENV=test`).
  6. `mix test`.
  7. Node 20 setup + cache `~/.cache/ms-playwright`.
  8. `npm ci`.
  9. `npx playwright install --with-deps chromium`.
  10. `mix assets.deploy` (compile + minify tailwind/esbuild +
      `phx.digest`).
  11. Boot the prod-mode Phoenix server (`PORT=4000 mix
      phx.server`) into `phx.log`, wait up to 60 s on
      `http://localhost:4000`.
  12. `npm run test:e2e` (Playwright).
  13. On failure: dump `phx.log` + upload `playwright-report/`
      artifact (30-day retention).
- `build-docker` runs only when `test` succeeded; builds the
  multi-stage Dockerfile (no `push`) and uploads a `.tar`
  artifact for 7 days.

### 7.2 Release pipeline

- `.github/workflows/release.yml` — triggers on `tags: *`.
  Builds the Dockerfile, pushes to `ghcr.io/<owner>/dtu-app`
  with both `${{ github.ref_name }}` and `latest` tags, then
  creates a GitHub Release with auto-generated notes.
- `RELEASE_VERSION` is baked into the image at build time (ARG)
  and surfaces as the `@version` assign in the footer.
- `.github/workflows/release-dispatch.yml` — a `workflow_dispatch`
  maintainer workflow that:
  1. Validates the calver `YYYY-MM-DD-N` tag (optionally
     prefixed with `v`).
  2. Refuses to proceed if the tag already exists on the remote.
  3. Authenticates with a `RELEASE_TOKEN` PAT (not
     `GITHUB_TOKEN`, because GitHub suppresses events triggered
     by the workflow's own token) and pushes the tag, which
     causes `release.yml` to run.
- Calver format: `v2026-07-26-1` (the leading `v` is optional).

### 7.3 Docker — local development (`docker-compose.yml`)

Three services, with a named volume for Postgres and one for
Mailpit data:

```yaml
db:        timescale/timescaledb:latest-pg16  (:5432)
mailpit:   axllent/mailpit:latest              (:1025 SMTP, :8025 UI)
app:       built from ./Dockerfile             (:4000 HTTP, :1883 MQTT)
```

The `app` service depends on both `db` and `mailpit` via
`condition: service_healthy`. The release image runs migrations
on every start (the `rel/docker-entrypoint.sh` retries 10× over
30 s before giving up).

### 7.4 Docker — production-style (`docker-compose.production.yml`)

Pulls the image from GHCR (default tag `:latest`, overridable via
`IMAGE_TAG=v2026-07-26-1`):

```yaml
db:        timescale/timescaledb:latest-pg16
app:       ghcr.io/<owner>/dtu-app:${IMAGE_TAG:-latest}
```

- No host port mapping — the reverse proxy reaches the app on the
  `internal` bridge network. Commented-out `1883:1883` for setups
  where DTUs reach the broker directly.
- Behind TLS (Traefik / Caddy / nginx / cloud LB). `PHX_SCHEME=https`
  + `PHX_PORT=443` are the conventional values when fronted by a
  TLS terminator.

### 7.5 Dockerfile (multi-stage release)

- **Builder stage** (`hexpm/elixir:1.16.2-erlang-26.2.1-alpine-3.19.1`):
  - Installs `build-base git curl ca-certificates`.
  - `mix deps.get --only $MIX_ENV` with `MIX_ENV=prod`.
  - Copies `config/config.exs` + `config/prod.exs` for dep
    compilation, then `mix deps.compile`.
  - Copies `priv`/`lib`, runs `mix compile --warnings-as-errors`.
  - Copies `assets`, runs `mix assets.deploy`.
  - Copies `config/runtime.exs` (runtime config doesn't require
    recompile).
  - `ARG RELEASE_VERSION="dev"` → `ENV RELEASE_VERSION=…` for the
    runtime footer; CI overrides this to the git tag.
  - `mix release` produces `_build/prod/rel/dtu_app`.

- **Runtime stage** (`alpine:3.19.1`):
  - Installs `libstdc++ openssl ncurses-libs ca-certificates`.
  - Copies only the final release.
  - Copies `rel/docker-entrypoint.sh` (chmod 0755).
  - Runs as `USER nobody`.
  - `ENV HOME=/app`.
  - `ENTRYPOINT ["/app/docker-entrypoint.sh"]`.

The entrypoint runs `DtuApp.Release.migrate` (which calls
`Ecto.Migrator.with_repo/2`) up to 10 times with 3 s sleep, then
`exec /app/bin/dtu_app start`. This pattern reconciles schema
on every container start (first boot or restart) without
needing a separate command override.

### 7.6 Environment variables (essential)

| Var                       | Required in prod? | Purpose                                                        |
| ------------------------- | ----------------- | -------------------------------------------------------------- |
| `SECRET_KEY_BASE`         | yes               | Cookies / LiveView sockets / Guardian. `mix phx.gen.secret`.    |
| `PHX_HOST`                | yes               | Public hostname of the web app — drives URL generation.        |
| `PHX_SCHEME`              | no (default `https`) | `http` (local) / `https` (prod). Drives URL generation.     |
| `PHX_PORT`                | no (default `443`) | Public port; only included in URLs when non-standard.         |
| `DATABASE_URL`            | yes               | `ecto://USER:PASS@HOST/DB`.                                    |
| `POOL_SIZE`               | no (default `10`) | DB pool size.                                                  |
| `MQTT_BROKER_ENABLED`     | no (default `true`) | Toggle the embedded broker. `:test` overrides this to false. |
| `MQTT_BROKER_PORT`        | no (default `1883`) | Broker listen port.                                          |
| `MQTT_HOST`               | no                | DNS alias shown as broker host in device setup modal.          |
| `RESEND_API_KEY`          | optional          | Resend transactional email when set.                           |
| `MAIL_DELIVERY=mailpit`   | optional          | Route via Mailpit (dev/staging).                              |
| `SMTP_RELAY/PORT/DOMAIN`  | dev               | Mailpit connection settings.                                   |
| `MAIL_FROM`               | yes (prod)        | Sender address; must be on a Resend-verified domain in prod.   |
| `VAPID_PUBLIC_KEY`        | yes (prod)        | Web Push public key. `bin/gen-vapid`.                          |
| `VAPID_PRIVATE_KEY`       | yes (prod)        | Web Push private key. `bin/gen-vapid`.                         |
| `VAPID_SUBJECT`           | yes (prod)        | `mailto:` or `https:` URL — RFC 8292 §2 requires it.           |
| `RELEASE_VERSION`         | build-time        | Git tag baked into the image; the in-app footer renders this.  |
| `DNS_CLUSTER_QUERY`       | optional          | DNS-based Node clustering (`<env>.internal` libcluster query). |
| `ECTO_IPV6`               | optional (`true`/`1`) | Use IPv6 for the DB pool.                                  |

The `DtuApp.Mailer` adapter is selected in
`config/runtime.exs`:
1. `RESEND_API_KEY` non-empty → `Swoosh.Adapters.Resend`.
2. `MAIL_DELIVERY=mailpit` → `Swoosh.Adapters.SMTP` (pointed at
   the SMTP_RELAY env).
3. Neither → `Swoosh.Adapters.Local` (in-memory, magic-link URL
   in the logs).

---

## 8. Database schema (relational)

Beyond the TimescaleDB-managed `readings` hypertable:

- `users` — magic-link auth, `phx.gen.auth` shape. Notable
  fields: `cents_per_kwh` (integer-cent rate), `notify_*`,
  `confirmed_at`, `authenticated_at`.
- `dtus` — physical DTU records. Notable columns:
  - `mqtt_username` (unique index),
  - `mqtt_password_hash` (Argon2),
  - `kind` (Ecto.Enum: `:opendtu`, `:ahoydtu`, `:shelly3em`),
  - `base_topic` (string, default varies by kind),
  - `last_seen_at` (`:utc_datetime_usec`) — derived online status,
  - `last_error`, `last_error_at` — most recent surfaced error.
  - One row → many readings; row also uniquely tagged with
    `(user_id, name)` so each user can have e.g. two "Roof
    Inverter" devices without collision.
- `users_tokens` — `phx.gen.auth` token table; contexts
  (`session`, `login`, `change:email`).
- `dtu_errors` — append-only per-message error history, capped at
  200 rows per device via FIFO prune.
- `push_subscriptions` — Web Push subscription rows. The
  browser's `PushSubscription#toJSON()` payload is persisted
  verbatim minus `expirationTime`. Globally unique `endpoint`
  is the natural primary key for upsert; `(user_id, endpoint)`
  is what `PushSubscriptions.delete/2` matches against.

Migrations of note (chronological order, listed by intent):

1. `20260705190700_create_users_auth_tables.exs` — auth tables
   (`phx.gen.auth`).
2. `20260705190905_create_dtus.exs` — `dtus`.
3. `20260705201000_create_readings.exs` — `readings` (with `id`).
4. `20260705221900_add_mqtt_password_to_dtus.exs` — early-stage
   credential column.
5. `20260708190019_enable_timescaledb.exs` — `CREATE EXTENSION
   timescaledb`.
6. `20260708190041_readings_to_hypertable.exs` — drop `id`,
   redefine PK as `(dtu_id, inverter_serial, inserted_at)`,
   `create_hypertable`, add compression (segment `dtu_id`, order
   `inserted_at DESC`) and 1-year retention.
7. `20260708190115_create_readings_continuous_aggregates.exs` —
   `readings_5m`, `readings_hourly`, `readings_daily` + refresh
   policies.
8. `20260728231359_widen_readings_timestamp_precision_to_microseconds.exs`
   — microsecond precision.
9. `20260730175546_add_inverter_name_and_mppt_index_to_readings.exs`
   — friendly name + per-MPPT rows.
10. `20260801222530_set_db_clock_defaults_for_time_columns.exs` —
    `DEFAULT now()` on every timestamp column.
11. `20260803090000_drop_online_from_dtus.exs` — drop the stored
    `online` boolean; liveness is now derived from
    `last_seen_at`.
12. `20260804100000_add_notification_settings_to_users.exs` —
    notification preference toggles.
13. `20260806000000_add_cents_per_kwh_to_users.exs` — energy
    rate.
14. `20260807190000_add_consumption_columns_to_readings.exs` —
    Shelly consumption rows.
15. `20260810125848_create_push_subscriptions.exs` — push
    subscriptions.
16. `20260811112247_add_last_error_to_dtus.exs` — per-device
    latest error columns.
17. `20260811142032_create_dtu_errors.exs` — per-device error
    history.

---

## 9. Module layout (recap)

```
lib/dtu_app/
  application.ex              OTP supervisor, conditional MQTT broker
  mailer.ex                   Swoosh adapter glue
  repo.ex                     Ecto.Repo
  release.ex                  DtuApp.Release.migrate/rollback
  time.ex                     DB-clock helpers (utc_now/utc_now_usec)
  accounts.ex                 Generated auth context
  accounts/
    user.ex                   User schema + changesets
    user_token.ex             Token schema + verify queries
    user_notifier.ex          Swoosh emails (login / update instructions)
    scope.ex                  phx.gen.auth Scope
  devices.ex                  DTU/Reading contexts (all user-scoped)
  devices/
    dtu.ex                    DTU schema, online?/2, default-base-topic
    reading.ex                Reading schema (composite-PK)
    dtu_error.ex              dtu_errors row schema
  mqtt_broker/
    broker.ex                 MqttX.Server impl, uplink broadcast
    credentials.ex            ETS-backed Argon2 cache
    telemetry.ex              Parser GenServer (OpenDTU/AhoyDTU/Shelly)
    topic_registry.ex         Live topic snapshot (ETS + 60 s prune)
  notifications.ex            Per-user PubSub + Web Push fan-out
  push.ex                     Web Push dispatcher (VAPID, AES-128-GCM)
  push_subscriptions.ex       PushSubscription CRUD
  push_subscriptions/
    push_subscription.ex      PushSubscription schema
  emails/
    layout.ex                 Site-styled HTML email layout

lib/dtu_app_web/
  endpoint.ex                 Bandit / Phoenix endpoint
  router.ex                   Browser + push_api + magic-link + dashboard pipes
  telemetry.ex                BEAM telemetry supervisor + metric defs
  user_auth.ex                fetch_current_scope/require_auth/redirect_if_user_is_authenticated
  gettext.ex                  Gettext backend
  components/
    core_components.ex        <.input>, <.icon>, <.button>, …
    layouts.ex                Layouts.app + theme toggle
    layouts/root.html.heex    App shell, navbar, offline banner, footer
    network_status_indicator.ex
    offline_banner.ex
  plugs/
    locale.ex                 Gettext locale negotiation
  controllers/
    page_controller.ex        /, /imprint, /privacy
    user_registration_controller.ex
    user_session_controller.ex
    user_settings_controller.ex
    push_controller.ex        Web Push subscribe/unsubscribe
    …
  live/
    dashboard_live.ex         The main dashboard LV (today + stepper)
    device_live/index.ex      CRUD page
    device_live/details.ex    Live topic tree
    notifications_live.ex     Notification preferences page

assets/
  css/app.css                 Tailwind v4 entry
  js/app.js                   esbuild entry; registers LiveSocket hooks
  js/notifications.js         In-page `Notification` API hook
  js/push_subscribe.js        PushManager / Subscribe / Unsubscribe
  js/notification_permission.js
  js/offline_banner.js        Tracks navigator.onLine
  vendor/heroicons.js, vendor/topbar.js
  service-worker.js           PWA + push listener (not bundled)

priv/repo/
  migrations/                 (17 migrations; see §8)
  seeds.exs                   Demo user + 3 DTUs + sine-arc readings

priv/gettext/
  en, de, fr, default.pot, errors.pot

rel/
  docker-entrypoint.sh        Run migrations, then exec the release

bin/
  gen-vapid                   Generate VAPID keypair, write to .env

test/
  test_helper.exs
  support/conn_case.ex, data_case.ex, fixtures/*
  dtu_app/{accounts,devices,mqtt_broker,push,push_subscriptions,time}_test.exs
  dtu_app_web/{controllers,live,plugs,components}/...
  e2e/*.spec.js, e2e/README.md, e2e/_setup/global-setup.js

playwright.config.js
.github/workflows/
  ci.yml, release.yml, release-dispatch.yml
```

---

## 10. Known constraints / things the next maintainer should know

- The README is unapologetic that this is "Early … hobby project
  under active development". The `:prod` `force_ssl` config
  excludes `localhost` and `127.0.0.1`, but in any non-local
  deployment you must front it with TLS (Traefik/Caddy/nginx/ELB).
- Multi-tenancy is by convention, not enforced by row-level
  security: every context function takes a `%User{}` and adds
  the ownership predicate. A future hardening step might add
  Postgres RLS policies.
- `:test` disables the broker and uses argon2 fast costs + sandbox
  pool. The test harness is therefore fast (<10 s typically) and
  side-effect-free.
- The dashboard's "savings" card is the only place
  `cents_per_kwh` is read. Set it to nil to hide the card.
- The savings formatting helper is a tiny inline `format_savings/2`
  on `DtuApp.Devices`; number formatting is the inline
  `format_number/3` next door. They both read the current Gettext
  locale so their outputs render correctly across en/de/fr.
- `:dtu_seen` is broadcast on every uplink; `DeviceLive.Index`
  re-streams the device list to flip the online indicator
  within one publish interval. There is no periodic sweep.
- The Pruning of `dtu_errors` is an in-transaction DELETE
  immediately after the insert. Worst-case behaviour: ~200 rows
  per device, no separate sweep job needed.
- The notifications scheduler (sun-down push, end-of-day summary)
  is a *future* capability referenced in the `DtuApp.Notifications`
  moduledoc; the only events exercised end-to-end today are
  `:dtu_connection` and the manual "test" event from the
  notifications page.
- VAPID key rotation *invalidates every browser subscription* —
  the `bin/gen-vapid` script refuses to overwrite without
  `--force` and prints a warning to that effect.
- The repo's MQTT broker uses `MqttX` (a relatively niche Hex
  package); the embedded broker is the central architectural
  decision and the application depends on it directly. Rebuilding
  this app against a different embedded broker (e.g. EMQX-in-Elixir,
  VerneMQ-in-Erlang, or a Mosquitto sidecar) requires touching
  `DtuApp.MqttBroker.{Broker,Credentials,Telemetry,TopicRegistry}`.
- The CI runs `:test` and the full Playwright suite against a
  `:prod`-mode Phoenix server (`PORT=4000 mix phx.server`).
  That means the prod runtime is exercised in CI on every push —
  including the Swoosh adapter selection, the PubSub topology,
  and the asset digest pipeline.

---

*End of state-of-application document. Total scope covered: goal,
features (broker, dual-format ingestion, storage, dashboard,
devices, notifications, errors, time invariants, schema,
i18n, PWA), architecture, layout, dev workflow, testing,
CI/CD, Docker deployment, env vars, schema, constraints.*
