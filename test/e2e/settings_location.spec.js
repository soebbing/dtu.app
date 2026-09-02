const { test, expect } = require('@playwright/test');
require('./_setup/global-fixture');

// E2E coverage for the Location section on `/users/settings`.
//
// What we exercise here:
//
//   1. The page renders the Share-location CTA when the seeded user
//      has no stored coords.
//   2. Clicking Share-location with Playwright-pre-granted geolocation
//      permission round-trips through the controller's
//      `update_location` clause (PUT-method-overridden via
//      `Plug.MethodOverride`), persists the coords, and shows the
//      success flash. This is the regression that landed the user on
//      a 404 — the JS-built form was POSTing without a `_method=put`
//      hidden input, so the browser hit a route that didn't exist.
//   3. After a successful set, the page shows the formatted display
//      (`52.52° N, 13.405° E`) plus Update + Clear buttons; the
//      Share-location CTA is gone.
//   4. Clicking Clear posts through `clear_location`, nils both
//      fields, and brings back the Share-location CTA.
//   5. Clicking Share-location with geolocation permission DENIED
//      shows the inline `[data-location-error]` node and does NOT
//      navigate away (the page stays on /users/settings, no 404).
//   6. Clicking Share-location when `navigator.geolocation` is
//      undefined (old browser, insecure context) shows the same
//      inline error and does NOT navigate.
//
// Assumes the app is running on :4000 against a database seeded with
// `mix run priv/repo/seeds.exs` (test@example.com / password123456).

const E2E_EMAIL = 'test@example.com';
const E2E_PASSWORD = 'password123456';

async function waitForPageStable(page) {
  await page.waitForLoadState('domcontentloaded');
  await page.waitForTimeout(500);
}

async function logIn(page) {
  await page.goto('/');
  await page.getByRole('link', { name: 'Sign In' }).click();
  await expect(page).toHaveURL(/\/users\/log-in/, { timeout: 10000 });

  const form = page.locator('#login_form_password');
  await form.locator('input[type="email"]').fill(E2E_EMAIL);
  await form.locator('input[type="password"]').fill(E2E_PASSWORD);

  await form.getByRole('button', { name: /Log in/i }).click();
  await page.waitForURL(/\/dashboard/, { timeout: 15000 });
  await waitForPageStable(page);
}

async function navigateToSettings(page) {
  // The settings page requires sudo mode (re-auth within 20
  // minutes). A fresh login puts us inside that window, so direct
  // navigation works. Use the navbar link rather than a hard-coded
  // URL so the test follows the same path the user does.
  await page.goto('/users/settings');
  await expect(page).toHaveURL(/\/users\/settings/, { timeout: 10000 });
  await waitForPageStable(page);
}

// Each test in this `describe.serial` block mutates the seeded
// user's lat/lon, and the previous test's state would otherwise
// leak forward. Rather than chain the assertions on the previous
// test's outcome (brittle — a failure in test 1 cascades into
// test 2), we explicitly clear coords before each test via the
// same Clear form the user would click. This guarantees every
// test starts from `:unset` regardless of what came before.
async function resetLocationToUnset(page) {
  await navigateToSettings(page);

  // If the Share-location button is visible, the user is already
  // in `:unset` — nothing to do.
  if ((await page.locator('#location-share-btn').count()) > 0) {
    return;
  }

  // Otherwise the Clear form is rendered (we're in `:set`). Click
  // it and wait for the round-trip.
  await Promise.all([
    page.waitForResponse(
      r => r.url().endsWith('/users/settings') && r.request().method() === 'POST',
      { timeout: 15000 }
    ),
    page.locator('#clear_location_form').getByRole('button', { name: /^Clear$/ }).click()
  ]);
}

async function getSuccessFlash(page) {
  // The success flash is rendered by `CoreComponents.flash/1` with
  // `id="flash-info"` (see lib/dtu_app_web/components/core_components.ex).
  // We target it by ID rather than the looser `[role="alert"]`
  // because the settings page also contains hidden error containers
  // (passkey + location) that would otherwise resolve `.first()` to
  // the wrong node.
  const flash = page.locator('#flash-info');
  await flash.waitFor({ state: 'visible', timeout: 15000 });
  return (await flash.textContent()) ?? '';
}

test.describe.serial('Acceptance Tests: Location section on /users/settings', () => {
  // `serial` because every test in this block modifies the same
  // user's lat/lon row. Parallel workers would race on the shared
  // database row — the "Clear after set" test would set Paris
  // coords while the "permission granted" test was waiting on its
  // page load, and the assertion would observe the wrong value.
  // Each test starts from the post-state of the previous one.
  test.beforeEach(async ({ page }) => {
    await logIn(page);
    await expect(page.locator('h1')).toContainText('PV Power Dashboard', { timeout: 10000 });
    // Reset the seeded user's lat/lon to nil so every test starts
    // from the same `:unset` state. See `resetLocationToUnset/1`.
    await resetLocationToUnset(page);
  });

  test('renders the Share-location CTA when the user has no stored coords', async ({
    page,
    context
  }) => {
    await navigateToSettings(page);

    // Seed the user with no coords (the seed file leaves lat/lon
    // nil). The Share-location button is rendered, the display
    // string is NOT.
    await expect(page.locator('#location-share-btn')).toBeVisible();
    await expect(page.locator('#location-update-btn')).toHaveCount(0);
    await expect(page.locator('[data-test="location-display"]')).toHaveCount(0);
    // Suppress the unused-variable warning — `context` here just
    // makes the test signature symmetric with the other tests in
    // this file that use `context` for geolocation mocks.
    void context;
  });

  test('clicking Share-location with permission granted persists coords and shows the flash', async ({
    page,
    context
  }) => {
    // Pre-grant the geolocation permission so the browser does NOT
    // show a prompt (and headless Chromium would otherwise auto-deny
    // it). The seeded coords land at the Brandenburg Gate.
    await context.grantPermissions(['geolocation'], { origin: 'http://localhost:4000' });
    await context.setGeolocation({ latitude: 52.5163, longitude: 13.3777 });

    await navigateToSettings(page);

    // Click and wait for the form POST that the JS builds. The form
    // posts to `/users/settings` with `_method=put` + `action=
    // update_location` + lat/lon — `Plug.MethodOverride` rewrites
    // the POST into a PUT, which lands on `UserSettingsController
    // .update/2` with the `update_location` clause. The browser
    // follows the 303 redirect back to /users/settings.
    //
    // We assert on the POST specifically (not the eventual GET) so
    // a regression where the JS submits without `_method=put` (and
    // the request lands on a 404) fails the test loudly — the POST
    // would still happen, but its response status would be 404.
    await Promise.all([
      page.waitForResponse(
        r => r.url().endsWith('/users/settings') && r.request().method() === 'POST',
        { timeout: 15000 }
      ),
      page.locator('#location-share-btn').click()
    ]);

    // Success flash + new render state.
    const flash = await getSuccessFlash(page);
    expect(flash.toLowerCase()).toContain('location updated');

    // The page now renders the stored coords (4 dp + hemisphere),
    // the Update button (the share button is gone), and the Clear
    // form. The display string format mirrors
    // `UserSettingsHTML.format_location/1` — pin the exact rendered
    // text so a future refactor of the formatter surfaces a
    // deliberate test update.
    await expect(page.locator('[data-test="location-display"]')).toContainText(
      '52.5163° N, 13.3777° E'
    );
    await expect(page.locator('#location-update-btn')).toBeVisible();
    await expect(page.locator('#location-share-btn')).toHaveCount(0);
    await expect(page.locator('#clear_location_form')).toBeVisible();
  });

  test('after a successful set, Clear brings back the Share-location CTA', async ({
    page,
    context
  }) => {
    await context.grantPermissions(['geolocation'], { origin: 'http://localhost:4000' });
    await context.setGeolocation({ latitude: 48.8566, longitude: 2.3522 });

    await navigateToSettings(page);

    // First set the coords.
    await Promise.all([
      page.waitForResponse(
        r => r.url().endsWith('/users/settings') && r.request().method() === 'POST',
        { timeout: 15000 }
      ),
      page.locator('#location-share-btn').click()
    ]);
    await expect(page.locator('[data-test="location-display"]')).toContainText(
      '48.8566° N, 2.3522° E'
    );

    // Now click Clear. The Clear form posts `action=clear_location`
    // through the same `<.form>` component Phoenix renders for the
    // other settings forms (so it carries `_method=put` + CSRF
    // automatically — no JS path, no regression).
    await Promise.all([
      page.waitForResponse(
        r => r.url().endsWith('/users/settings') && r.request().method() === 'POST',
        { timeout: 15000 }
      ),
      page.locator('#clear_location_form').getByRole('button', { name: /^Clear$/ }).click()
    ]);

    const flash = await getSuccessFlash(page);
    expect(flash.toLowerCase()).toContain('location cleared');

    // Back to the unset state.
    await expect(page.locator('#location-share-btn')).toBeVisible();
    await expect(page.locator('#location-update-btn')).toHaveCount(0);
    await expect(page.locator('[data-test="location-display"]')).toHaveCount(0);
  });

  test('denying the permission shows the inline error and does not navigate', async ({
    page,
    context
  }) => {
    // Geolocation is NOT granted. The browser will invoke the
    // error callback (PERMISSION_DENIED) when the user clicks the
    // button. We do not need to interact with the prompt — the
    // headless Chromium path is to auto-deny when no grant has been
    // issued.
    void context;

    await navigateToSettings(page);

    await page.locator('#location-share-btn').click();

    // The inline error node becomes visible.
    const error = page.locator('[data-location-error]');
    await expect(error).toBeVisible({ timeout: 5000 });
    await expect(error).toContainText(/couldn'?t read your location/i);

    // Still on /users/settings, no navigation happened (no 404).
    await expect(page).toHaveURL(/\/users\/settings$/);

    // The share button is re-enabled (not stuck in the disabled
    // loading state) so the user can retry after fixing the
    // browser-side permission.
    await expect(page.locator('#location-share-btn')).toBeEnabled();
  });

  test('a browser without geolocation shows the inline error and does not navigate', async ({
    page,
    context
  }) => {
    // Override `navigator.geolocation` to undefined BEFORE the
    // page scripts run so the JS's `if (!navigator.geolocation)`
    // branch fires.
    void context;

    await navigateToSettings(page);
    await page.addInitScript(() => {
      // eslint-disable-next-line no-undef
      Object.defineProperty(navigator, 'geolocation', { value: undefined, configurable: true });
    });
    // `addInitScript` only affects subsequent navigations — reload
    // the settings page so the override is in place before our
    // script runs.
    await page.reload();
    await waitForPageStable(page);

    await page.locator('#location-share-btn').click();

    const error = page.locator('[data-location-error]');
    await expect(error).toBeVisible({ timeout: 5000 });

    // Still on /users/settings.
    await expect(page).toHaveURL(/\/users\/settings$/);
    await expect(page.locator('#location-share-btn')).toBeEnabled();
  });
});
