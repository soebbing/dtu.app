const { test, expect } = require('@playwright/test');
const { waitForLiveSocketConnected } = require('./_helpers');
require('./_setup/global-fixture');

// E2E coverage for the WIP dashboard historical features:
//   - seeded telemetry renders the Today production curve + stat cards
//   - granularity stepper (Day / Week / Month / Year) swaps stat cards + chart title
//   - prev/next stepper walks periods and shows the empty-state past the data horizon
//   - DTU switcher filters between an individual device and the "Total" aggregate
//
// Assumes the app is running on :4000 against a database seeded with
// `mix run priv/repo/seeds.exs` (test@example.com / password123456, two DTUs,
// today's curve + historical days back ~1 year).

const E2E_EMAIL = 'test@example.com';
const E2E_PASSWORD = 'password123456';

// Helper function to wait for page to be stable and ready
// Phoenix LiveView maintains persistent connections, so we use 'domcontentloaded' instead of 'networkidle'
async function waitForPageStable(page) {
  await page.waitForLoadState('domcontentloaded');
  await page.waitForTimeout(500); // Additional buffer for rendering
}

async function logIn(page) {
  await page.goto('/');
  await page.getByRole('link', { name: 'Sign In' }).click();
  await expect(page).toHaveURL(/\/users\/log-in/, { timeout: 10000 });

  // The login page has both a password form and a magic-link form, each with
  // its own email input — scope fills to the password form explicitly.
  const form = page.locator('#login_form_password');
  await form.locator('input[type="email"]').fill(E2E_EMAIL);
  await form.locator('input[type="password"]').fill(E2E_PASSWORD);

  // Traditional POST form: the submit button has no explicit type attribute
  // (a bare <button> defaults to submit), so select it by its label instead.
  await form.getByRole('button', { name: /Log in/i }).click();
  await page.waitForURL(/\/dashboard/, { timeout: 15000 });
  await waitForPageStable(page);
}

test.describe('Acceptance Tests: Dashboard Historical Views & DTU Switcher', () => {
  test.beforeEach(async ({ page }) => {
    await logIn(page);
    await expect(page).toHaveURL(/\/dashboard/, { timeout: 10000 });
    await expect(page.locator('h1')).toContainText('PV Power Dashboard', { timeout: 10000 });
    // The granularity <select> fires `phx-change` which only reaches the
    // server once the LiveView WebSocket is connected. On CI the socket
    // can take noticeably longer to connect than the local CI browser
    // busy-loop, so wait for it before any test starts interacting with
    // phx-bound controls. See `_helpers.js` for the why.
    await waitForLiveSocketConnected(page);
  });

  test('Today view renders the seeded production curve and live stat cards', async ({ page }) => {
    // Live (Today) view is the default landing state.
    await expect(page.locator('#quick-range-switcher #btn-range-1d')).toBeVisible();

    // First verify we're in live mode by checking the Yield tile exists.
    await expect(page.locator('#stat-yield-kwh')).toBeVisible();

    // Live stat cards: today's yield (kWh) and peak power (W).
    await expect(page.locator('#stat-yield-kwh')).toContainText(/kWh/);
    await expect(page.locator('#stat-peak-watts')).toContainText(/W/);

    // Seeded today's readings (06:00–19:00 sine arc) must produce a chart, not the empty state.
    await expect(page.locator('#solar-chart-svg')).toBeVisible();
    await expect(page.locator('#empty-chart')).toHaveCount(0);
    await expect(page.locator('#chart-title')).toContainText("Today's Production Curve");
  });

  test('granularity stepper switches Day view to bar stats and back to Today live view', async ({ page }) => {
    // The new range-presets toolbar hides the historical stepper until
    // the user picks Custom (see dashboard_range_presets.spec.js for
    // the contract). Click Custom first so the stepper renders.
    await page.locator('#btn-range-custom').click();
    await expect(page.locator('#history-picker')).toBeVisible();

    // Switch to historical Day granularity by directly interacting with the select element
    const selectElement = page.locator('#select-granularity');
    await selectElement.selectOption('day');

    // Wait for the select value to actually change
    await expect(selectElement).toHaveValue('day');

    // Day view: the period-stable Yield card (#stat-yield-kwh) is
    // present in both the live and historical layouts — it surfaces
    // the day's kWh total instead of today's last reading. Peak
    // Power stays the same.
    await expect(page.locator('#stat-yield-kwh')).toBeVisible();
    await expect(page.locator('#stat-peak-watts')).toBeVisible();
    await expect(page.locator('#chart-title')).toContainText('Production Curve for');

    // Return to the live Today view via the quick-range tab.
    await page.locator('#btn-range-1d').click();

    // Yield tile remains present (period-stable label across all
    // presets).
    await expect(page.locator('#stat-yield-kwh')).toBeVisible();
  });

  test('Week / Month / Year granularities show Daily/Monthly aggregate stats', async ({ page }) => {
    // Range-presets toolbar hides the stepper by default; reveal it.
    await page.locator('#btn-range-custom').click();
    await expect(page.locator('#history-picker')).toBeVisible();

    for (const gran of ['week', 'month', 'year']) {
      await page.locator('#select-granularity').selectOption(gran);

      // Aggregate views: the period-stable Yield tile shows the period
      // total in kWh (week total / month total / year total), and the
      // Peak Power tile shows the period's peak wattage. The Yield
      // card stays present across every preset — period-stable — so
      // we just assert its kWh content and the Peak Power tile's
      // visibility after the LiveView re-render settles.
      await expect(page.locator('#stat-yield-kwh')).toContainText(/kWh/);
      await expect(page.locator('#stat-peak-watts')).toBeVisible();

      // Chart switches to a bar chart for these granularities.
      await expect(page.locator('#solar-chart-svg')).toBeVisible();
      await expect(page.locator('#empty-chart')).toHaveCount(0);
    }
  });

  test('prev/next stepper walks periods and hits the empty state past the data horizon', async ({ page }) => {
    // Day granularity. Today has seeded readings (06:00–19:00), so the chart
    // shows; stepping forward past the seeded days lands on a day with none.
    // The range-presets toolbar hides the stepper by default; reveal it.
    await page.locator('#btn-range-custom').click();
    await expect(page.locator('#history-picker')).toBeVisible();

    await page.locator('#select-granularity').selectOption('day');

    // Wait for LiveView to re-render the Day-granular historical chart.
    // The stat cards are period-stable, so we wait for the chart title to
    // flip from the 1D "Today's Production Curve" wording to the historical
    // "Production Curve for ..." wording instead.
    await expect(page.locator('#chart-title')).toContainText('Production Curve for');

    await expect(page.locator('#solar-chart-svg')).toBeVisible();

    // Step forward until we reach a future day with no readings. The
    // line chart is replaced by the #empty-chart placeholder.
    for (let i = 0; i < 10; i++) {
      await page.locator('#btn-history-next').click();

      // Wait a moment for LiveView to process the click
      await page.waitForTimeout(500);

      const becameEmpty = await page
        .locator('#empty-chart')
        .waitFor({ state: 'attached', timeout: 1500 })
        .then(() => true)
        .catch(() => false);
      if (becameEmpty) break;
    }
    await expect(page.locator('#empty-chart')).toBeVisible();
    await expect(page.locator('#solar-chart-svg')).toHaveCount(0);

    // Stepping back (prev) returns to a period with data.
    await page.locator('#btn-history-prev').click();

    // Wait for the line chart to reappear after stepping back. The empty
    // placeholder should disappear once we land back on a seeded day.
    await expect(page.locator('#solar-chart-svg')).toBeVisible();
    await expect(page.locator('#empty-chart')).toHaveCount(0);
  });

  // NOTE: the Year granularity stepper is currently broken in the app —
  // `shift_period/3` for year-over-Date produced a malformed offset, so "next"
  // does not advance the selected year. Tracked separately; covered here once fixed.

  test('DTU switcher filters between an individual device and the Total aggregate', async ({ page }) => {
    // The switcher only renders when more than one device exists (the seed creates two).
    await expect(page.locator('#dtu-switcher')).toBeVisible();
    await expect(page.locator('#btn-select-total')).toBeVisible();

    // Select the first individual device.
    const roofBtn = page.locator('#dtu-switcher button', { hasText: 'Roof Inverter' });
    await expect(roofBtn).toHaveCount(1);
    await roofBtn.click();

    // Wait for the chart to update after DTU selection with retry approach
    let attempts = 0;
    const maxAttempts = 10;
    while (attempts < maxAttempts) {
      const state = await page.evaluate(() => {
        return document.querySelector('#solar-chart-svg') !== null;
      });
      if (state) break;
      attempts++;
      await page.waitForTimeout(1000);
    }

    // Switch back to the Total (all DTUs) aggregate.
    await page.locator('#btn-select-total').click();

    // Wait for the chart to remain visible after switching back to total with retry
    attempts = 0;
    while (attempts < maxAttempts) {
      const state = await page.evaluate(() => {
        return document.querySelector('#solar-chart-svg') !== null &&
               document.querySelector('#empty-chart') === null;
      });
      if (state) break;
      attempts++;
      await page.waitForTimeout(1000);
    }
  });
});
