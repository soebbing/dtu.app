const { test, expect } = require('@playwright/test');
require('./_setup/global-fixture');

// E2E coverage for the energy-rate (kWh price) field on `/users/settings`.
//
// Two regressions are guarded here:
//   * Surfaces "invalid value" on every submit. Root cause: an
//     empty form submission landed on the Ecto cast
//     `{"is invalid", [type: :integer, validation: :cast]}` error
//     because the settings_changeset/2 hard-coded the `:invalid`
//     atom for the empty / non-numeric branch. The fix maps empty
//     / non-numeric input to `nil`, so the field is silently
//     cleared.
//   * Never shows the currently stored value. The settings
//     template only matched `Ecto.Changeset.fetch_field/2`'s
//     `:changes` arm; on a fresh GET the settings_changeset/2
//     helper always sets a change (even when the user submits
//     nothing), so `fetch_field/2` returned `{:changes, nil}` and
//     the input rendered empty forever. The fix reads `:data`
//     first so the user's actual stored rate pre-renders.
//
// What we exercise here:
//   1. Typing a valid €/kWh and saving persists the value and
//      shows the success flash.
//   2. Clearing the field and saving does NOT surface "invalid
//      value" — it shows the success flash and the value is
//      cleared.
//   3. After saving, navigating away and back, the field
//      prefills with the stored rate (the prefill fix).
//   4. After clearing the stored rate, navigating away and back,
//      the field is empty.
//
// The dashboard's "savings block hidden when rate is nil"
// behavior is exercised separately by
// `dashboard_savings_card.spec.js` (it has its own login flow
// and per-test rate-reset setup).
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
  // The settings page requires sudo mode (re-auth within 20 minutes).
  // A fresh login puts us inside that window, so direct navigation
  // works. Use the navbar link rather than a hard-coded URL so the
  // test follows the same path the user does.
  await page.goto('/users/settings');
  await expect(page).toHaveURL(/\/users\/settings/, { timeout: 10000 });
  await waitForPageStable(page);
}

async function fillEnergyRateAndSubmit(page, value) {
  // The form posts a top-level `euros_per_kwh` field on the
  // `#update_settings` form. The input has id="euros_per_kwh".
  const input = page.locator('#euros_per_kwh');
  await input.fill(value);

  // The form is a regular HTML POST (not LiveView), so submit and
  // wait for the round-trip to complete. We can't `waitForURL` here
  // because the form posts back to the same page we're already on
  // (`/users/settings`) — `waitForURL` would resolve immediately
  // and we'd race the 303-redirected GET.
  //
  // Waiting on the POST response guarantees the form was accepted
  // before the test moves on; the subsequent redirect + GET + flash
  // render is then awaited by `getSuccessFlash` polling for the
  // flash locator.
  //
  // The button is a bare `<button>` (no explicit `type` attribute,
  // which defaults to `submit` inside a form), so we identify it by
  // its label "Save Settings" — that's the only button on
  // /users/settings with that text and the email/password forms use
  // different labels.
  const form = page.locator('#update_settings');
  await Promise.all([
    page.waitForResponse(
      r => r.url().endsWith('/users/settings') && r.request().method() === 'POST',
      { timeout: 15000 }
    ),
    form.getByRole('button', { name: /Save Settings/i }).click()
  ]);
}

async function getSuccessFlash(page) {
  // The success flash is rendered by `CoreComponents.flash/1` with
  // `id="flash-info"` (see lib/dtu_app_web/components/core_components.ex).
  // We target it by ID rather than the looser `[role="alert"]` because
  // the settings page also contains a hidden passkey error container
  // (`<div data-passkey-error hidden role="alert">`) that would
  // otherwise be `.first()` — hidden elements have `role="alert"`
  // too, so the broad selector resolves to the wrong node and the
  // waitFor(visible) times out.
  const flash = page.locator('#flash-info');
  await flash.waitFor({ state: 'visible', timeout: 15000 });
  return (await flash.textContent()) ?? '';
}

test.describe('Acceptance Tests: Energy rate (kWh price) on /users/settings', () => {
  test.beforeEach(async ({ page }) => {
    await logIn(page);
    await expect(page.locator('h1')).toContainText('PV Power Dashboard', { timeout: 10000 });
  });

  test('persists a valid €/kWh value and shows the success flash', async ({ page }) => {
    await navigateToSettings(page);

    await fillEnergyRateAndSubmit(page, '0.32');

    // After successful save the page is back on /users/settings with
    // the success flash visible. The flash text is the source-of-
    // truth message for "did my save stick?" — see the prefill
    // tests below for what the input field looks like after a
    // round-trip.
    const flash = await getSuccessFlash(page);
    expect(flash.toLowerCase()).toContain('settings updated');
  });

  test('page reloads with the stored €/kWh value prefilled', async ({ page }) => {
    // Pre-fix: the settings template only matched
    // `Ecto.Changeset.fetch_field/2`'s `:changes` arm, which the
    // settings_changeset/2 helper always populates (even on a GET
    // with no params — the empty-input branch produces
    // `cents = nil`). That meant `fetch_field/2` returned
    // `{:changes, nil}` and the input rendered empty forever.
    //
    // Save a rate, navigate away (so we definitely rebuild the
    // changeset from a fresh GET), navigate back — the field
    // must show the stored value.
    await navigateToSettings(page);
    await fillEnergyRateAndSubmit(page, '0.45');

    await page.goto('/dashboard');
    await expect(page).toHaveURL(/\/dashboard/, { timeout: 10000 });
    await waitForPageStable(page);

    await navigateToSettings(page);

    await expect(page.locator('#euros_per_kwh')).toHaveValue('0.45');
  });

  test('clearing the stored rate leaves the input empty on reload', async ({ page }) => {
    // Companion to the "prefilled" test: clearing the rate and
    // navigating away then back must render an empty input. The
    // empty-input branch of the settings_changeset/2 maps to nil,
    // the field is cleared in the DB, and the template renders an
    // empty `value=""` attribute (the "0.32" placeholder stays
    // visible). Confirms the round-trip.
    await navigateToSettings(page);
    await fillEnergyRateAndSubmit(page, '0.55');
    await expect(page.locator('#euros_per_kwh')).toHaveValue('0.55');

    // Now clear it.
    await fillEnergyRateAndSubmit(page, '');

    await page.goto('/dashboard');
    await waitForPageStable(page);
    await navigateToSettings(page);

    await expect(page.locator('#euros_per_kwh')).toHaveValue('');
  });

  test('clearing the field does NOT show "is invalid" — it clears the rate', async ({ page }) => {
    await navigateToSettings(page);

    // Now submit a blank form. The regression we guard against:
    // this used to surface the Ecto "is invalid" error and the user
    // saw "invalid value" on every blank submit.
    await fillEnergyRateAndSubmit(page, '');

    // No "is invalid" error message anywhere on the page.
    await expect(page.locator('text=/is invalid/i')).toHaveCount(0);

    // The success flash is shown — the field was silently cleared.
    const flash = await getSuccessFlash(page);
    expect(flash.toLowerCase()).toContain('settings updated');
  });

  // We deliberately do NOT exercise sub-cent values (e.g. "0.001")
  // at the e2e level. The HTML5 input has min=0.01 and step=0.01,
  // and the browser blocks submission of any value below 0.01 with
  // its own native "Please enter a valid value" prompt — which is
  // a different layer than the Ecto cast error we're fixing, and
  // is well-covered by the ExUnit tests in accounts_test.exs.
  // The e2e suite here stays focused on the original bug: an empty
  // or non-numeric value must NOT surface the Ecto "is invalid"
  // message at the server boundary.
});
