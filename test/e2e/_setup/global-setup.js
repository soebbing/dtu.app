// Playwright `globalSetup` script.
//
// Runs once before any test file. It re-seeds the database via
// `mix run priv/repo/seeds.exs` so the e2e tests can rely on the
// seeded fixtures (test@example.com / password123456, three DTUs,
// today's sine arc + a year of historical readings).
//
// Why a global setup rather than a separate `beforeAll` in each
// spec file:
//   * The seed wipes + reloads every Reading, Dtu, and User, so
//     running it from one place guarantees the test suite starts
//     from a clean state regardless of how many tests have already
//     mutated the DB.
//   * The seed takes ~10 s to run (it inserts ~6,000 rows). Running
//     it once globally is much faster than per-test reseeding.
//   * We want the seed to use the same environment variables as the
//     test runner (DATABASE_URL, MIX_ENV, etc.), so it lives next
//     to the spec files and shells out to the host's `mix`.
//
// This is wired in via `playwright.config.js`'s `globalSetup` field.
// To skip the reseed (e.g. when iterating on a single test), set
// `E2E_SKIP_SEED=1` in the environment.

const { spawnSync } = require('node:child_process');
const path = require('node:path');

// The seed script lives at `priv/repo/seeds.exs` in the repo root.
// This script sits at `test/e2e/_setup/global-setup.js`, so the root
// is three levels up from `__dirname`.
const REPO_ROOT = path.resolve(__dirname, '..', '..', '..');

function log(message) {
  console.log(`[e2e-setup] ${message}`);
}

function runSeed() {
  log('Re-seeding the database via `mix run priv/repo/seeds.exs`...');

  // Inherit the parent env and add anything the seed needs. The
  // defaults below assume the standard `docker compose` stack
  // (`localhost:5432`, `dtu_app_prod`, broker disabled so the
  // listener doesn't collide with the running app on :1883).
  const env = {
    ...process.env,
    MQTT_BROKER_ENABLED: 'false',
    DATABASE_URL:
      process.env.DATABASE_URL ||
      'ecto://postgres:postgres@localhost:5432/dtu_app_prod',
    SECRET_KEY_BASE: process.env.SECRET_KEY_BASE || 'e2e_test_only',
    VAPID_PUBLIC_KEY: process.env.VAPID_PUBLIC_KEY || 'e2e_test_only',
    VAPID_PRIVATE_KEY: process.env.VAPID_PRIVATE_KEY || 'e2e_test_only',
    VAPID_SUBJECT: process.env.VAPID_SUBJECT || 'mailto:e2e@example.com',
    MIX_ENV: process.env.MIX_ENV || 'prod',
  };

  const result = spawnSync(
    'mix',
    ['run', 'priv/repo/seeds.exs'],
    { cwd: REPO_ROOT, env, stdio: 'inherit' }
  );

  if (result.status !== 0) {
    throw new Error(
      `Seed failed with exit code ${result.status}. ` +
      `See the seed output above for the underlying error.`
    );
  }

  log('Seed complete.');
}

module.exports = async function globalSetup() {
  if (process.env.E2E_SKIP_SEED === '1') {
    log('E2E_SKIP_SEED=1; skipping reseed.');
    return;
  }

  runSeed();
};
