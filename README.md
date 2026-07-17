# dtu.app

Self-hosted, multi-tenant solar telemetry for **OpenDTU** and **AhoyDTU** inverters.

dtu.app runs its own embedded MQTT broker, so your DTUs publish directly to it —
no separate Mosquitto, no Home Assistant in the middle. Each user gets an
isolated account, registers their hardware, and watches live + historic
generation in a real-time dashboard. One instance can serve many households.

> Built for the kind of person who already has a Hoymiles inverter on the
> balcony and a spare box to run things on.

---

## Why

OpenDTU and AhoyDTU are great at reading your inverter and exposing it locally,
but turning that into a persistent, queryable, multi-device history you can
check from your phone usually means gluing together Mosquitto + InfluxDB +
Grafana + an auth layer. dtu.app is the single BEAM release that does all of it:

- **Bring-your-own-hardware.** Anything running OpenDTU or AhoyDTU firmware.
- **No extra brokers.** The MQTT server is embedded — point your DTU at it.
- **Multi-tenant by default.** Each user's devices and data are fully isolated.
- **Built for time-series scale.** TimescaleDB hypertables + continuous
  aggregates keep years of readings cheap to store and fast to query.

## Features

- **Embedded MQTT broker** (via [`MqttX`](https://hex.pm/packages/mqttx)) — DTUs
  connect and publish on their own per-device credentials.
- **Dual-format ingestion** — parses OpenDTU's consolidated JSON payloads
  (`{base}/{serial}/realtime/data`) and AhoyDTU's per-metric subtopics
  (`{base}/{name}/ch0/{metric}`) into a unified `Reading` schema.
- **Real-time dashboard** (Phoenix LiveView) — live power, today's yield, and
  peak stats update over WebSockets the moment a reading lands.
- **Historical views** — a day/week/month/year stepper over server-side SVG
  charts (no client chart library), backed by Timescale continuous aggregates.
- **Per-device MQTT credentials** — generated and Argon2-hashed server-side; the
  username is globally unique so a connection resolves to exactly one device.
- **Passwordless auth** — magic-link sign-in (and email confirmation) via
  transactional email through Resend.
- **i18n** — English, German, and French out of the box.

## Tech stack

| Layer        | Choice                                                      |
| ------------ | ----------------------------------------------------------- |
| Language     | Elixir (~1.16) on the BEAM                                  |
| Web          | Phoenix 1.8 + LiveView, served by Bandit                    |
| Realtime     | Embedded MQTT broker (MqttX) over Thousand Island           |
| Database     | PostgreSQL 16 + TimescaleDB (hypertables + caggs)           |
| ORM / schema | Ecto                                                        |
| Auth         | Generated `phx.gen.auth` (magic link) + Argon2              |
| Mail         | Swoosh → Resend API                                         |
| Assets       | Tailwind CSS v4, esbuild, Heroicons                         |
| Tests        | ExUnit (server) + Playwright (browser E2E)                  |

## Architecture

```
                       ┌──────────────┐
   OpenDTU / AhoyDTU   │  DTU hardware │  publishes MQTT telemetry
        ──────────────▶│              │─────────────────────────────┐
                       └──────────────┘                              │
                                                                     ▼
   ┌──────────────────────────────── dtu.app (BEAM release) ────────────────────────────────┐
   │                                                                                        │
   │  MqttX.Server  ──verify creds──▶  Credentials cache (ETS, Argon2)                       │
   │       │  uplink broadcast                                                                │
   │       ▼                                                                                  │
   │  Telemetry GenServer  ──parse OpenDTU / AhoyDTU──▶  Reading  ──insert──▶  Repo           │
   │       │  PubSub (:dtu:reading)                                            │             │
   │       ▼                                                                  ▼             │
   │  DashboardLive (LiveView) ◀── WebSocket ─── Browser             TimescaleDB            │
   │                                                          hypertable + caggs            │
   └────────────────────────────────────────────────────────────────────────────────────────┘
```

**Data flow:** a DTU connects to the embedded broker with its per-device
credentials. Every uplink is broadcast on `Phoenix.PubSub`; the `Telemetry`
GenServer parses the payload (format depends on the device's firmware), writes a
`Reading`, and republishes the parsed reading. The dashboard LiveView is
subscribed and pushes the new value to the browser over the LiveView socket.

**Storage:** `readings` is a TimescaleDB hypertable partitioned by
`inserted_at`, with compression (after 7 days) and retention (1 year) policies.
Three continuous aggregates — `readings_5m`, `readings_hourly`, `readings_daily`
— pre-bucket the data so historical charts never scan raw rows.

**Isolation:** every `Devices` context function is scoped to an owning `User`,
and the broker resolves a connection to a device by username alone — a user can
only ever see or touch their own hardware.

## Quickstart (Docker)

The whole stack — TimescaleDB + the app (HTTP on `:4000`, MQTT on `:1883`) —
runs from `docker compose`.

```sh
git clone <this-repo> dtu.app && cd dtu.app
cp .env.example .env
# generate a secret:  mix phx.gen.secret
# then paste it into .env as SECRET_KEY_BASE

docker compose up -d --build
```

Open <http://localhost:4000>, register, and add your first DTU — the setup
dialog shows the exact MQTT broker address, port, and auto-generated username /
password / base topic to enter in your DTU's MQTT settings.

See [`.env.example`](./.env.example) for every knob. The important ones:

| Variable            | Default          | Purpose                                                       |
| ------------------- | ---------------- | ------------------------------------------------------------- |
| `SECRET_KEY_BASE`   | _(required)_     | Signs cookies / LiveView sockets.                             |
| `PHX_HOST`          | `localhost`      | Public hostname of the **web** app (drives email links).      |
| `PHX_SCHEME`        | `https`          | `http` or `https` — used in generated URLs.                   |
| `PHX_PORT`          | `443`            | Public port; included in links only when non-standard.        |
| `MQTT_HOST`         | _(= `PHX_HOST`)_ | Host shown as the MQTT broker. Set when MQTT is on its own domain. |
| `MQTT_BROKER_PORT`  | `1883`           | Port the embedded broker listens on.                          |
| `RESEND_API_KEY`    | _(empty)_        | Transactional email via Resend. Empty = in-memory (no mail sent). |
| `MAIL_FROM`         | _…localhost_     | Sender address (must be a Resend-verified domain).            |

## Local development

```sh
mix setup         # install deps, set up the dev DB
mix phx.server    # http://localhost:4000
```

You'll need PostgreSQL reachable per `config/dev.exs` (TimescaleDB for the
hypertable/cagg migrations — the `timescale/timescaledb` image works for dev
too). The embedded broker binds `:1883`; the broker is disabled in the test env.

**Tests**

```sh
mix test                                  # ExUnit (server-side)
npm install && npx playwright install     # one-time, for E2E
npx playwright test                       # browser acceptance tests
```

E2E expects a running app on `:4000` against a seeded DB — see
[`test/e2e/README.md`](./test/e2e/README.md) for the full harness and the NixOS
notes.

## Project layout

```
lib/dtu_app/
  accounts/             generated auth (users, tokens, magic-link notifier)
  devices/              Dtu + Reading schemas, the Devices context
  mqtt_broker/          embedded broker, credentials cache, telemetry parser
  emails/               site-styled HTML transactional email layout
lib/dtu_app_web/
  live/dashboard_live.ex   real-time + historical dashboard (incl. SVG charts)
  live/device_live/        DTU CRUD + the post-create setup dialog
priv/repo/
  seeds.exs             demo user + a year of synthetic telemetry
  migrations/           schema + Timescale hypertable / cagg migrations
```

## Status

Early — core ingestion, dashboard, auth, and the Docker deploy story work
end-to-end, but it's a hobby project under active development. Not (yet) a
hardened multi-tenant SaaS: run it for yourself and people you trust, and put it
behind TLS in production.
