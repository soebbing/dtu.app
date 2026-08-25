const { test, expect } = require('@playwright/test');
const { waitForLiveSocketConnected } = require('./_helpers');

// Acceptance tests for the new 5-up stats card row above the chart.
// Replaces the legacy 4-up row (Current Generation / Today's Total
// Yield / Total Yield lifetime / Peak Power / Peak Yield Day / Saved
// this period) with a period-stable layout:
//
//   1. Yield (kWh)            — id stat-yield-kwh
//   2. Peak Power (W)         — id stat-peak-watts
//   3. Peak Time              — id stat-peak-time
//   4. Self-consumption (%)   — id stat-self-consumption (hidden w/o Shelly)
//   5. Saved this period (€)  — id stat-saved (hidden w/o rate)
//
// Plus Current Consumption (id stat-current-consumption) when a Shelly
// is paired. The cards are period-aware: clicking a preset updates
// the Yield card's sub-label and the headline kWh/W figures.
test.describe('Acceptance Tests: Dashboard stats card row (5-up)', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await page.getByRole('link', { name: 'Sign In' }).click();
    await expect(page).toHaveURL(/\/users\/log-in/, { timeout: 10000 });

    const form = page.locator('#login_form_password');
    await form.locator('input[type="email"]').fill('test@example.com');
    await form.locator('input[type="password"]').fill('password123456');
    await form.getByRole('button', { name: /Log in/i }).click();

    await page.waitForURL(/\/dashboard/, { timeout: 15000 });
    await waitForLiveSocketConnected(page);
  });

  test('renders the three period-stable tiles for an inverter-only seeded user', async ({ page }) => {
    // The seeded fixture (`test/e2e/_setup`) has three OpenDTU
    // inverters and no Shelly, so the Self-consumption and Saved
    // tiles may be hidden (Saved requires a configured rate,
    // Self-consumption requires a Shelly). The three period-stable
    // tiles must always be present.
    await expect(page.locator('#stat-yield-kwh')).toBeVisible();
    await expect(page.locator('#stat-peak-watts')).toBeVisible();
    await expect(page.locator('#stat-peak-time')).toBeVisible();
  });

  test('Yield card sub-label changes as the user clicks presets', async ({ page }) => {
    // The sub-label is rendered as a sibling div under the
    // headline `#stat-yield-kwh` element, so it lives inside the
    // same card `<dl>` block. Query the parent card (the Yield
    // tile's wrapping div) and assert the sub-label inside it.

    // 1D (default) → sub-label "Today".
    const yieldCard = page.locator('#stat-yield-kwh').locator('..');
    await expect(yieldCard).toContainText(/Today/i);

    // 7D → "Last 7 days".
    await page.locator('#btn-range-7d').click();
    await expect(page.locator('#chart-title')).toContainText('Last 7 days');
    await expect(yieldCard).toContainText(/Last 7 days/i);

    // 30D → "Last 30 days".
    await page.locator('#btn-range-30d').click();
    await expect(page.locator('#chart-title')).toContainText('Last 30 days');
    await expect(yieldCard).toContainText(/Last 30 days/i);

    // YTD → "Year to date".
    await page.locator('#btn-range-ytd').click();
    await expect(page.locator('#chart-title')).toContainText('Year to date');
    await expect(yieldCard).toContainText(/Year to date/i);
  });

  test('Peak Power tile shows an integer wattage', async ({ page }) => {
    // The Peak Power card formats its value via
    // `Devices.format_number(n, 0, locale)` — so it must end with
    // " W" with no decimal. The em-dash placeholder would also be
    // visible when there are no readings.
    const peakText = await page.locator('#stat-peak-watts').innerText();
    // Either a real wattage (e.g. "1_500 W") or the em-dash ("—").
    expect(peakText).toMatch(/\d[\d,. \s]*\s*W|^—$/);
  });

  test('Peak Time tile shows an HH:MM string or the em-dash placeholder', async ({ page }) => {
    const peakTimeText = await page.locator('#stat-peak-time').innerText();
    expect(peakTimeText.trim()).toMatch(/^\d{1,2}:\d{2}$|^—$/);
  });
});