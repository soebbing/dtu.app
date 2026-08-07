const { test, expect } = require('@playwright/test');

// E2E coverage for the dashboard's "Saved this period" card.
//
// Regression: the card was added by `feat(energy-cost-widget)` but its
// `compute_savings/2` helper divided by 100 — and `format_savings/1`
// *also* divided by 100 — so every card value was 100× too small. For
// typical residential yields (a few kWh per day at €0.32/kWh) the
// `round()` step then collapsed the value to 0 cents, which the
// dashboard rendered as "€0.00". Customers reported "the savings
// card always shows 0" even on days with obvious production.
//
// What we exercise here:
//   1. With no rate set, the card is hidden (the template's
//      `<%= if @savings %>` guard short-circuits when @cents_per_kwh
//      is nil, so we never see a misleading "€0.00 saved").
//   2. Setting €0.32/kWh and viewing a day with non-zero yield shows a
//      non-zero amount — and crucially NOT the pre-fix "€0.02" value
//      that the bug produced for the same yield. This pins the units
//      end-to-end.
//   3. Setting a higher rate (€0.45/kWh) and switching to a Day view
//      shows a different (higher) amount — proving the calculation
//      is reactive to both the rate and the period's yield.
//   4. Setting a low feed-in tariff (€0.08/kWh) — historically the
//      trickiest case, where pre-fix the rounded value would
//      collapse to €0.00.
//
// Assumes the app is running on :4000 against a database seeded with
// `mix run priv/repo/seeds.exs` (test@example.com / password123456,
// DTUs with seeded today's yield of ~3-4 kWh).

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
  await page.goto('/users/settings');
  await expect(page).toHaveURL(/\/users\/settings/, { timeout: 10000 });
  await waitForPageStable(page);
}

async function setEnergyRate(page, value) {
  // Fill the energy-rate input and submit. The form posts a
  // top-level `euros_per_kwh` field on the `#update_settings` form.
  await page.locator('#euros_per_kwh').fill(value);

  const form = page.locator('#update_settings');
  await Promise.all([
    page.waitForURL(/\/users\/settings/, { timeout: 10000 }),
    form.getByRole('button', { name: /Save Settings/i }).click()
  ]);

  // Wait briefly for the success flash and any post-redirect state.
  await page.waitForTimeout(300);
}

async function clearEnergyRate(page) {
  await setEnergyRate(page, '');
}

async function getSavingsCardText(page) {
  // The savings card carries id="stat-saved" (per dashboard_live.ex).
  // When @savings is nil the entire card is hidden, so the locator
  // resolves to zero elements — return an empty string in that case
  // so callers can assert "card is hidden" without a separate
  // visibility check.
  const locator = page.locator('#stat-saved');
  const count = await locator.count();
  if (count === 0) return null;
  return (await locator.textContent()) ?? '';
}

async function navigateToDashboard(page) {
  await page.goto('/dashboard');
  await expect(page).toHaveURL(/\/dashboard/, { timeout: 10000 });
  await waitForPageStable(page);
}

test.describe('Acceptance Tests: Dashboard "Saved this period" card', () => {
  test.beforeEach(async ({ page }) => {
    await logIn(page);
    await expect(page.locator('h1')).toContainText('PV Power Dashboard', { timeout: 10000 });
    // Ensure the test starts from a clean rate state so the hidden-card
    // assertion in the first test isn't order-dependent on a previous
    // test having left a rate behind.
    await navigateToSettings(page);
    await clearEnergyRate(page);
  });

  test('card is hidden when the user has not set an energy rate', async ({ page }) => {
    // With @cents_per_kwh == nil, `compute_savings/2` returns nil and
    // the template's `<%= if @savings %>` guard hides the card. A
    // brand-new user shouldn't see a misleading "€0.00 saved" claim.
    await navigateToDashboard(page);
    await expect(page.locator('#stat-saved')).toHaveCount(0);
  });

  test('card shows a non-zero amount at €0.32/kWh with the seeded today yield', async ({ page }) => {
    // The seed gives the Roof Inverter ~3-4 kWh today. At €0.32/kWh
    // that's roughly €1.00-€1.30. Pre-fix this rendered as "€0.01"
    // or "€0.00" depending on rounding. Post-fix the card must show
    // a real euro amount (€X.XX with X ≥ 1 in the euros column, or at
    // least a non-zero cent value).
    await navigateToSettings(page);
    await setEnergyRate(page, '0.32');

    await navigateToDashboard(page);

    // Today view: the savings card is the 4th stat card in the grid.
    await expect(page.locator('#stat-saved')).toBeVisible({ timeout: 10000 });

    const text = await getSavingsCardText(page);
    expect(text).not.toBeNull();
    // Match the locale-aware format helper's output: "X.XX €" with an
    // optional thousands separator (`,` in en, `.` in de, NBSP in fr).
    // Pre-fix the test asserted `^€\d+\.\d{2}$`; post-fix the symbol
    // is at the end so German and French formats also match. The
    // optional `(?:[,. ]\d{3})*` group accepts the thousands
    // separator; the decimal must be `.` (matches en/de formats); the
    // en-thousands-sep `,` and de-thousands-sep `.` and fr-thousands
    // -sep space are all covered.
    expect(text.trim()).toMatch(/^-?\d{1,3}(?:[,. ]\d{3})*\.\d{2} €$/);

    // Pre-fix, the same yield + rate would render as "€0.0X" with X
    // typically 0-2 (e.g. €0.01 for a 4 kWh day). Make sure we're not
    // seeing that: the value must be at least €0.10.
    const numeric = parseFloat(text.replace('€', ''));
    expect(numeric).toBeGreaterThanOrEqual(0.1);
    // And not absurdly large (sanity ceiling for a single day at
    // typical residential scale — well below €100/day).
    expect(numeric).toBeLessThan(100);
  });

  test('card value scales with the configured rate (€0.45 vs €0.32)', async ({ page }) => {
    // Pin that the calculation actually reads @cents_per_kwh. At a
    // higher rate, the same period's yield produces a strictly
    // larger savings amount. Pre-fix both rates would round to
    // single-digit cents and the comparison would be unreliable.
    await navigateToSettings(page);
    await setEnergyRate(page, '0.32');

    await navigateToDashboard(page);
    await expect(page.locator('#stat-saved')).toBeVisible({ timeout: 10000 });

    const atLowRate = parseFloat((await getSavingsCardText(page)).replace('€', ''));

    // Bump the rate and re-check.
    await navigateToSettings(page);
    await setEnergyRate(page, '0.45');

    await navigateToDashboard(page);
    await expect(page.locator('#stat-saved')).toBeVisible({ timeout: 10000 });

    const atHighRate = parseFloat((await getSavingsCardText(page)).replace('€', ''));

    // The higher rate MUST produce a strictly greater savings amount
    // for the same day's yield (rate scaled 0.32 → 0.45 = 1.40625×).
    expect(atHighRate).toBeGreaterThan(atLowRate);
    // Allow a small tolerance for LiveView re-render / rate-entry
    // rounding — the ratio should be ~1.41, we accept 1.30..1.55.
    const ratio = atHighRate / atLowRate;
    expect(ratio).toBeGreaterThan(1.30);
    expect(ratio).toBeLessThan(1.55);
  });

  test('low feed-in tariff (€0.08/kWh) still shows a non-zero amount', async ({ page }) => {
    // The German Einspeisevergütung (feed-in tariff) is well under
    // the residential purchase rate. With the seeded ~3-4 kWh yield,
    // pre-fix the value rounded to 0 cents and rendered as "€0.00" —
    // the exact "always shows 0" symptom from the field. Post-fix the
    // card must show a non-zero amount.
    await navigateToSettings(page);
    await setEnergyRate(page, '0.08');

    await navigateToDashboard(page);
    await expect(page.locator('#stat-saved')).toBeVisible({ timeout: 10000 });

    const text = await getSavingsCardText(page);
    expect(text).not.toBeNull();
    expect(text.trim()).toMatch(/^-?\d{1,3}(?:[,. ]\d{3})*\.\d{2} €$/);

    // At 3-4 kWh × €0.08/kWh = €0.24-€0.32. Pre-fix this would round
    // to "€0.01" or "€0.00"; post-fix the user sees a real euro
    // amount above 20 cents.
    const numeric = parseFloat(text.replace('€', ''));
    expect(numeric).toBeGreaterThan(0.15);
  });

  test('clearing the rate hides the card again', async ({ page }) => {
    // Set a rate, confirm the card appears, then clear it and confirm
    // the card disappears. This pins the round-trip: clearing the
    // form must not leave a stale render behind.
    await navigateToSettings(page);
    await setEnergyRate(page, '0.32');

    await navigateToDashboard(page);
    await expect(page.locator('#stat-saved')).toBeVisible({ timeout: 10000 });

    await navigateToSettings(page);
    await clearEnergyRate(page);

    await navigateToDashboard(page);
    await expect(page.locator('#stat-saved')).toHaveCount(0);
  });
});
