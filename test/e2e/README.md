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

## Running them

The tests assume the app is reachable at `http://localhost:4000` and the DB is
seeded (`test@example.com` / `password123456`, two DTUs, today's curve plus
~1 year of historical readings). The easiest way to get that state is the
docker compose stack:

```sh
# 1. Bring up app + TimescaleDB
cp .env.example .env
#   fill in SECRET_KEY_BASE, e.g.:  mix phx.gen.secret
docker compose up -d --build

# 2. Seed the running app's database (host mix, pointed at the container DB,
#    broker disabled so it doesn't collide on :1883)
MIX_ENV=prod \
DATABASE_URL="ecto://postgres:postgres@localhost:5432/dtu_app_prod" \
MQTT_BROKER_ENABLED=false \
SECRET_KEY_BASE=dummy \
  mix run priv/repo/seeds.exs

# 3. Install Playwright and run the suite
npm install
npx playwright install chromium
npx playwright test
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

`seeds.exs` wipes readings/devices/users before inserting, so re-running step 2
resets the E2E fixture state. Note that DTU CRUD tests create additional
devices, which persist until the next reseed.
