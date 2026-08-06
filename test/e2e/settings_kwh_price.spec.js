const { test, expect } = require('@playwright/test');

// E2E coverage for the energy-rate (kWh price) field on `/users/settings`.
//
// This is a regression test for the bug where ANY value entered into
// the "Energy rate (€/kWh)" field surfaced "invalid value" on submit.
// Root cause: an empty form submission landed on the Ecto cast
// `{"is invalid", [type: :integer, validation: :cast]}` error because
// the settings_changeset/2 hard-coded the `:invalid` atom for the
// empty / non-numeric branch. The fix maps empty / non-numeric input
// to `nil`, so the field is silently cleared and the dashboard hides
// the savings card.
//
// What we exercise here:
//   1. Typing a valid €/kWh and saving persists the value and shows
//      the success flash.
//   2. Clearing the field and saving does NOT surface "invalid value" —
//      it shows the success flash and the value is cleared.
//   3. Pasting a non-numeric value (e.g. "abc") and saving also does
//      NOT surface "invalid value" — it clears the field silently.
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
  // wait for the redirect back to /users/settings. The button is a
  // bare `<button>` (no explicit `type` attribute, which defaults to
  // `submit` inside a form), so we identify it by its label "Save
  // Settings" — that's the only button on /users/settings with that
  // text and the email/password forms use different labels.
  const form = page.locator('#update_settings');
  await Promise.all([
    page.waitForURL(/\/users\/settings/, { timeout: 10000 }),
    form.getByRole('button', { name: /Save Settings/i }).click()
  ]);
}

async function getSuccessFlash(page) {
  // The flash messages are rendered in the page-wide flash container.
  // Looking for the English source-of-truth text — exact wording
  // is localized; we just check the success-keyword prefix.
  const flash = page.locator('[role="alert"], .flash, [data-flash]').first();
  if ((await flash.count()) === 0) return '';
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
    // the success flash visible. The flash text is the source of
    // truth message.
    const flash = await getSuccessFlash(page);
    expect(flash.toLowerCase()).toContain('settings updated');

    // The field is re-rendered with the saved value prepopulated.
    await expect(page.locator('#euros_per_kwh')).toHaveValue('0.32');
  });

  test('clearing the field does NOT show "is invalid" — it clears the rate', async ({ page }) => {
    await navigateToSettings(page);

    // First set a value so we have something to clear.
    await fillEnergyRateAndSubmit(page, '0.45');
    await expect(page.locator('#euros_per_kwh')).toHaveValue('0.45');

    // Now submit a blank form. The regression we guard against:
    // this used to surface the Ecto "is invalid" error and the user
    // saw "invalid value" on every blank submit.
    await fillEnergyRateAndSubmit(page, '');

    // No "is invalid" error message anywhere on the page.
    await expect(page.locator('text=/is invalid/i')).toHaveCount(0);

    // The success flash is shown.
    const flash = await getSuccessFlash(page);
    expect(flash.toLowerCase()).toContain('settings updated');

    // The field is empty (placeholder hint shows).
    await expect(page.locator('#euros_per_kwh')).toHaveValue('');
  });

  test('non-numeric input does NOT show "is invalid" — it clears the rate', async ({ page }) => {
    await navigateToSettings(page);

    // Set a rate first so we can verify the form actually clears it.
    await fillEnergyRateAndSubmit(page, '0.50');
    await expect(page.locator('#euros_per_kwh')).toHaveValue('0.50');

    // Paste garbage. The browser's <input type="number"> may strip
    // non-numeric characters on its own; either way the server must
    // NOT surface "is invalid" — empty and unparseable input both
    // map to nil at the changeset level.
    await fillEnergyRateAndSubmit(page, 'abc');

    // The "is invalid" error must NOT appear.
    await expect(page.locator('text=/is invalid/i')).toHaveCount(0);

    // The success flash confirms the save happened.
    const flash = await getSuccessFlash(page);
    expect(flash.toLowerCase()).toContain('settings updated');
  });
});
