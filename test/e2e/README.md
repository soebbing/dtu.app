# End-to-End (Playwright) tests

Browser acceptance tests driven by Playwright against the running Phoenix app.
These are separate from the ExUnit suite (`mix test`) — they need a live server
and a seeded database.

## What they cover

- `login_dashboard.spec.js` — auth flow, dashboard landing, full DTU CRUD
  (create → setup dialog → edit → delete) over the device LiveView.
- `dtu_setup_dialog.spec.js` — the post-create setup dialog and its
  localization (English / German / French).
- `dashboard_historical.spec.js` — the WIP dashboard: Today production curve +
  stat cards, the granularity stepper (Day/Week/Month/Year) swapping stat cards
  and chart title, the prev/next stepper hitting the empty state past the data
  horizon, and the DTU switcher filtering between a single device and Total.
- `dashboard_range_presets.spec.js` — the new unified preset toolbar
  (1D / 7D / 30D / YTD / Custom) at the top of the dashboard: default
  state lands on 1D with the historical stepper hidden, each preset
  click updates the chart title, the stepper only reveals itself on
  the Custom preset, and clicking back to 1D restores the live view.
- `dashboard_yesterday_overlay.spec.js` — the day-comparison overlay
  (dashed "yesterday" ghost behind today's solid curve). Confirmed
  default 1D view, asserts 7D must not render the `data-ghost`
  path or the legend entry, and a round-trip 1D → 7D → 1D
  preserves the structure.
- `dashboard_multi_device.spec.js` — multi-device behaviour: the DTU switcher
  lists every device plus the Total button, switching between devices narrows
  the chart to that device's inverters and updates the fleet-Total line, the
  "Today's Total Yield" stat card changes per selection, a device with no
  today data renders the empty-chart placeholder with zero stats, and the
  filter applies to historical Day view too.
- `dashboard_multi_mppt.spec.js` — the per-inverter / per-MPPT breakdown:
  the "Current Generation" stat card reflects the AC aggregate of every
  polled inverter (the bug where a multi-MPPT DTU showed 0 W while
  producing), and the chart legend's per-MPPT lines actually draw
  instead of staying flat at the X-axis.
- `dashboard_savings_card.spec.js` — the "Saved this period" card: hidden
  when the user hasn't set an energy rate, non-zero at €0.32/kWh and
  €0.08/kWh with the seeded daily yield, scales with the configured rate,
  and disappears again when the rate is cleared. Regression for the
  "savings card always shows 0" unit-confusion bug.
- `settings_kwh_price.spec.js` — the energy-rate (kWh price) field on
  `/users/settings`: persists a valid value, clears the field without
  surfacing Ecto's "is invalid" error, and rejects out-of-range values.

## Running them

The tests assume the app is reachable at `http://localhost:4000` and the DB is
seeded (`test@example.com` / `password123456`, three DTUs, today's curve plus
~1 year of historical readings). The seed also creates per-locale users
`test-de@example.com` and `test-fr@example.com` (same password) for the
localized acceptance tests in `dtu_setup_dialog.spec.js`, since the
`User.locale` priority introduced in PR #151 makes the post-login page
render in the user's stored language rather than the browser's Accept-Language. A `globalSetup` script at
`test/e2e/_setup/global-setup.js` re-seeds the database via
`mix run priv/repo/seeds.exs` automatically before the suite runs, so you
don't have to remember to do it manually. The easiest way to get the rest of
the stack up is the docker compose setup:

```sh
# 1. Bring up app + TimescaleDB
cp .env.example .env
#   fill in SECRET_KEY_BASE, e.g.:  mix phx.gen.secret
docker compose up -d --build

# 2. Install Playwright and run the suite (the global setup re-seeds
#    the database automatically — no manual `mix run priv/repo/seeds.exs`
#    step needed).
npm install
npx playwright install chromium
npx playwright test
```

If you want to seed manually (e.g. to inspect the fixtures in a REPL):

```sh
MIX_ENV=prod \
DATABASE_URL="ecto://postgres:postgres@localhost:5432/dtu_app_prod" \
MQTT_BROKER_ENABLED=false \
SECRET_KEY_BASE=dummy \
  mix run priv/repo/seeds.exs
```

Skip the auto-reseed when iterating on a single test against an
already-seeded DB:

```sh
E2E_SKIP_SEED=1 npx playwright test test/e2e/dashboard_multi_device.spec.js
```

### NixOS note

The Playwright-bundled Chromium is linked for generic Linux and will not run on
NixOS ("NixOS cannot run dynamically linked executables …"). Point Playwright at
the host's Chrome instead:

```sh
PLAYWRIGHT_CHROME="$(which google-chrome)" npx playwright test
```

(`PLAYWRIGHT_CHROME` is wired into `playwright.config.js` as `launchOptions.executablePath`.)

## Re-seeding between runs

`seeds.exs` wipes readings/devices/users before inserting, so the global setup
gives every test run a fresh fixture state. Note that DTU CRUD tests create
additional devices, which persist until the next reseed.
