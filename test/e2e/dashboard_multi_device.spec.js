const { test, expect } = require('@playwright/test');
require('./_setup/global-fixture');

// E2E coverage for the dashboard's multi-device behaviour.
//
// The dashboard exposes a per-user DTU switcher (`#dtu-switcher`)
// that renders only when more than one device is registered. The
// switcher lists every device as a button plus a leading "Total"
// entry that aggregates readings across every device. Switching
// between devices must re-run the dashboard's `assign_dashboard_data`
// for the new DTU scope so the chart, the stat cards, and the legend
// all reflect the filtered telemetry.
//
// The seeded fixture (`priv/repo/seeds.exs`) creates three devices
// with a deliberate magnitude ordering so the per-device yields are
// *distinct* — the e2e suite asserts "switching changes the value"
// rather than the exact magnitude, but two devices producing
// identical kWh after rounding makes the assertion flake. The order
// is documented in `priv/repo/seeds.exs`:
//
//   * "Roof Inverter"   (OpenDTU)  500 W peak, today sine-arc.
//   * "Garage Array"    (OpenDTU)  800 W + 600 W peak, today sine-arc,
//                                  two inverters.
//   * "Balcony Inverter" (AhoyDTU)  no today readings — historical only.
//
// Combined today `today_yield` ordering (Garage Array > Roof Inverter
// > Balcony Inverter): the test asserts strict inequality both ways
// (Garage > Roof, Total > Garage > Roof, Roof > Balcony) so any
// silent drift in the magnitude ordering gets a clear failure.
//
// The dashboard's chart collapses per-MPPT DC rows into the
// inverter's AC aggregate on the server
// (`assign_line_chart_data/5`), so each inverter exposes one chart
// line. The Total fleet-wide line is rendered when more than one
// inverter is in scope, hidden when only one.
//
// TODAY view (seeded today readings):
//   * Total: 3 inverters (Roof + West Roof + East Garage) + 1 Total = 4 paths.
//   * Roof Inverter: 1 inverter, no Total (single inverter in scope).
//   * Garage Array: 2 inverters + 1 Total = 3 paths.
//   * Balcony Inverter: 0 inverters (no today rows) → empty chart.
//
// HISTORICAL Day view (day_offset = 1):
//   * Roof Inverter: 1 inverter, no Total (single inverter in scope).
//   * Garage Array: 0 inverters (no historical rows) → empty chart.
//   * Balcony Inverter: 1 inverter, no Total (single inverter in scope).
//   * Total: 2 inverters (Roof + Balcony) + 1 Total = 3 paths.
//
// Scenarios covered:
//   1. The switcher lists every device plus the Total button.
//   2. Switching to a single-device view reduces the chart series
//      count to that device's inverters only.
//   3. Switching back to Total aggregates every device's inverters
//      and re-adds the Total line.
//   4. "Yield" stat card updates with the selected
//      device (and the ordering Garage Array > Roof Inverter > 0
//      holds).
//   5. Chart paths filter by the selected DTU; the legend strip
//      lists inverters from the same scope.
//   6. A device with no today data (Balcony Inverter) renders an
//      empty chart and zero stats, but the switcher still renders.
//   7. Historical Day view applies the device filter too — the
//      Total view aggregates the two inverters that have historical
//      data (Roof + Balcony).
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

// Click a switcher button and wait for the chart's path count to
// match the expected value. The LiveView re-renders the chart SVG
// when the DTU selection changes; polling the path count is the
// most reliable signal that the new dashboard state has rendered.
//
// `expectedPaths` is the expected number of `path[data-series]`
// elements: 1 per inverter in scope, plus 1 for the fleet Total
// when more than one inverter is visible. The Total is rendered
// only when `distinct_inverters > 1` (see `assign_line_chart_data/5`).
async function selectDtuAndWaitForPathCount(page, buttonSelector, expectedPaths) {
  await page.locator(buttonSelector).click();

  for (let i = 0; i < 50; i++) {
    const count = await page.locator('#solar-chart-svg path[data-series]').count();
    if (count === expectedPaths) return;
    await page.waitForTimeout(100);
  }

  // Final read for the failure message.
  const final = await page.locator('#solar-chart-svg path[data-series]').count();
  throw new Error(
    `Expected ${expectedPaths} chart paths after clicking ${buttonSelector}, ` +
    `but found ${final} after 5 s.`
  );
}

// Read the visible number from a stat card. The dashboard renders
// values like "580 W" or "3.4 kWh" — we strip the unit suffix and
// parse the remaining digits. Returns `null` when the element
// isn't present (some cards are hidden when their scenario doesn't
// apply, e.g. live "Current Generation" is replaced by historical
// "Total Yield" — now the period-stable "Yield" card).
async function readStatNumber(page, selector) {
  const el = page.locator(selector);
  if ((await el.count()) === 0) return null;
  const text = await el.textContent();
  if (!text) return null;
  // Locale-aware: accept either `.` or `,` as the decimal mark.
  const match = text.replace(/\s/g, '').match(/-?\d+(?:[.,]\d+)?/);
  if (!match) return null;
  return parseFloat(match[0].replace(',', '.'));
}

// Count the chart paths and report how many of them are the
// fleet-Total line vs per-inverter lines. The Total line carries
// `data-legend-key="total"` (per `render/1` in dashboard_live.ex);
// per-inverter lines carry `data-legend-key="series:<dtu_id>:..."`.
async function chartSeriesBreakdown(page) {
  return page.locator('#solar-chart-svg path[data-series]').evaluateAll(els =>
    els.reduce(
      (acc, el) => {
        const key = el.getAttribute('data-legend-key') || '';
        if (key === 'total') acc.total += 1;
        else if (key.startsWith('series:')) acc.inverters += 1;
        else acc.other += 1;
        return acc;
      },
      { total: 0, inverters: 0, other: 0 }
    )
  );
}

test.describe('Acceptance Tests: Multi-Device Dashboard (DTU Switcher)', () => {
  test.beforeEach(async ({ page }) => {
    await logIn(page);
    await expect(page.locator('h1')).toContainText('PV Power Dashboard', { timeout: 10000 });
    await expect(page.locator('#dtu-switcher')).toBeVisible({ timeout: 10000 });
  });

  test('switcher lists every device plus the Total button', async ({ page }) => {
    // The seed creates three devices. The switcher renders one
    // button per device plus a leading "Total" entry — that's
    // four buttons in total. Each device button is identified by
    // `#btn-select-dtu-<id>` and the Total by `#btn-select-total`.
    const switcher = page.locator('#dtu-switcher');
    await expect(switcher).toBeVisible();

    // The "Total" entry is always first; pin its label so a future
    // template rename gets flagged here.
    await expect(switcher.locator('#btn-select-total')).toContainText(/Total/i);

    // Every seeded device should have its own button. The text is
    // the user-facing device name from `devices.name`.
    await expect(switcher.locator('button', { hasText: 'Roof Inverter' })).toHaveCount(1);
    await expect(switcher.locator('button', { hasText: 'Balcony Inverter' })).toHaveCount(1);
    await expect(switcher.locator('button', { hasText: 'Garage Array' })).toHaveCount(1);

    // Pinning the exact button count catches a regression that
    // would, say, re-render the Total button per device.
    const buttons = switcher.locator('button');
    await expect(buttons).toHaveCount(4);
  });

  test('Total (default) view aggregates every device, with the fleet-wide Total line rendered', async ({ page }) => {
    // The dashboard boots with `@selected_dtu_id = nil`, which means
    // "Total". Three devices are seeded; two of them (Roof Inverter,
    // Garage Array) have today readings. Garage Array exposes two
    // inverter AC rows (West Roof, East Garage — per-MPPT DC rows
    // are filtered out on the server). Roof Inverter exposes one
    // inverter. Total = 3 inverters visible, so the fleet-wide
    // Total line is rendered (it's suppressed only when there's
    // exactly one inverter in scope).
    await expect(page.locator('#btn-select-total')).toHaveClass(/bg-emerald-500/);

    // Wait for the chart's paths to settle — LiveView may take a
    // moment to swap from the static page to the live view.
    await page.waitForFunction(
      () => document.querySelectorAll('#solar-chart-svg path[data-series]').length > 0,
      null,
      { timeout: 10000 }
    );

    const breakdown = await chartSeriesBreakdown(page);
    // 3 inverters (Roof + West Roof + East Garage) + 1 fleet Total
    expect(breakdown.inverters).toBe(3);
    expect(breakdown.total).toBe(1);
  });

  test('switching to Roof Inverter narrows the chart to one inverter and hides the Total line', async ({ page }) => {
    // Roof Inverter exposes exactly one inverter. With only one
    // inverter in scope the Total line is suppressed (the headline
    // curve would just duplicate the single series). Result: 1 path
    // with `data-legend-key="series:..."`, 0 Total paths.
    const roofBtn = page.locator('#dtu-switcher button', { hasText: 'Roof Inverter' });
    await selectDtuAndWaitForPathCount(page, '#dtu-switcher button:has-text("Roof Inverter")', 1);

    const breakdown = await chartSeriesBreakdown(page);
    expect(breakdown.inverters).toBe(1);
    expect(breakdown.total).toBe(0);

    // The clicked button is now the active one (highlighted with
    // the emerald background), and the Total button is no longer
    // highlighted. The button styling guards against accidental
    // "the click didn't take" false positives.
    await expect(roofBtn).toHaveClass(/bg-emerald-500/);
    await expect(page.locator('#btn-select-total')).not.toHaveClass(/bg-emerald-500/);
  });

  test('switching to Garage Array shows two inverter lines and the fleet Total', async ({ page }) => {
    // Garage Array's two inverters (West Roof, East Garage) produce
    // two chart lines; the fleet Total is rendered because there
    // are >1 inverters in scope.
    await selectDtuAndWaitForPathCount(page, '#dtu-switcher button:has-text("Garage Array")', 3);

    const breakdown = await chartSeriesBreakdown(page);
    expect(breakdown.inverters).toBe(2);
    expect(breakdown.total).toBe(1);
  });

  test('switching back to Total restores the multi-device aggregate', async ({ page }) => {
    // Filter to a single device first so the chart drops down to one
    // path, then verify that switching back to Total widens the
    // chart to the multi-device aggregate. Pinning this round-trip
    // catches a regression where the Total click fails to refresh
    // the dashboard (e.g. an `@selected_dtu_id` assignment bug).
    await selectDtuAndWaitForPathCount(page, '#dtu-switcher button:has-text("Roof Inverter")', 1);

    // Now switch back to Total — wait for the chart to expose more
    // paths than the single-device view, which is the strongest
    // signal that the dashboard actually re-ran the aggregate
    // query.
    await page.locator('#btn-select-total').click();

    await page.waitForFunction(
      () => {
        const paths = document.querySelectorAll('#solar-chart-svg path[data-series]');
        // Total view: 3 inverters (Roof + West Roof + East Garage) +
        // 1 fleet Total line = 4 paths.
        return paths.length >= 4;
      },
      null,
      { timeout: 10000 }
    );

    const breakdown = await chartSeriesBreakdown(page);
    expect(breakdown.inverters).toBe(3);
    expect(breakdown.total).toBe(1);

    // The Total button is highlighted again, and the Roof Inverter
    // button is no longer the active selection.
    await expect(page.locator('#btn-select-total')).toHaveClass(/bg-emerald-500/);
    await expect(page.locator('#dtu-switcher button', { hasText: 'Roof Inverter' })).not.toHaveClass(
      /bg-emerald-500/
    );
  });

  test("Yield stat card updates when switching devices", async ({ page }) => {
    // Pin the live stat card across DTU selections. The card's
    // value must change when the scope changes — if it stayed
    // constant, the dashboard would be ignoring the device filter
    // for stats (the exact bug this test guards against).
    //
    // The seeded curve ordering (Garage Array 800+600 W > Roof
    // Inverter 500 W > Balcony Inverter 0 W) means the per-device
    // yields are guaranteed to be distinct after rounding, so the
    // strict inequality assertions below pin the magnitude order
    // end-to-end. The LiveView round-trip after a DTU switch is
    // fast (~300 ms in CI), so we wait a fixed 1.5 s after each
    // click rather than polling for value-changed (which would
    // hang if the seed drift ever produced two identical values).
    const totalYield = await readStatNumber(page, '#stat-yield-kwh');
    expect(totalYield).not.toBeNull();
    expect(totalYield).toBeGreaterThan(0);

    // Roof Inverter: one inverter, 500 W peak. The yield must be
    // strictly positive and strictly less than the Total (which
    // includes Garage Array on top).
    await page.locator('#dtu-switcher button', { hasText: 'Roof Inverter' }).click();
    await page.waitForTimeout(1500);
    const roofYield = await readStatNumber(page, '#stat-yield-kwh');
    expect(roofYield).not.toBeNull();
    expect(roofYield).toBeGreaterThan(0);
    expect(roofYield).toBeLessThan(totalYield);

    // Garage Array: two inverters (800 + 600 W). Its yield must be
    // strictly greater than the Roof Inverter's and at most the
    // Total (which is the max across all inverters since PR #119
    // switched fleet totals from sum to max-of-monotonic-counter).
    await page.locator('#dtu-switcher button', { hasText: 'Garage Array' }).click();
    await page.waitForTimeout(1500);
    const garageYield = await readStatNumber(page, '#stat-yield-kwh');
    expect(garageYield).not.toBeNull();
    expect(garageYield).toBeGreaterThan(0);
    expect(garageYield).toBeGreaterThan(roofYield);
    expect(garageYield).toBeLessThanOrEqual(totalYield);

    // Balcony Inverter: no today readings. Its yield must be
    // exactly 0 and the smallest of the three.
    await page.locator('#dtu-switcher button', { hasText: 'Balcony Inverter' }).click();
    await page.waitForTimeout(1500);
    const balconyYield = await readStatNumber(page, '#stat-yield-kwh');
    expect(balconyYield).not.toBeNull();
    expect(balconyYield).toBe(0);
  });

  test('chart paths filter by the selected DTU', async ({ page }) => {
    // The dashboard filters both the chart's `<path>` elements and
    // the legend strip by the selected DTU — clicking a device narrows
    // both. Pin that scope so a regression on either side
    // (filtered chart, full legend, or vice-versa) gets a clear
    // failure.
    await page.locator('#dtu-switcher button', { hasText: 'Roof Inverter' }).click();
    await selectDtuAndWaitForPathCount(page, '#dtu-switcher button:has-text("Roof Inverter")', 1);

    // Filtered chart paths: exactly one series path (Roof Inverter's
    // single inverter). The Total line is suppressed in single-
    // inverter scope.
    const roofSeriesKeys = await page
      .locator('#solar-chart-svg path[data-legend-key]')
      .evaluateAll(els => els.map(e => e.getAttribute('data-legend-key')));
    const roofInverterKeys = roofSeriesKeys.filter(k => k.startsWith('series:'));
    expect(roofInverterKeys).toHaveLength(1);
    expect(roofSeriesKeys).not.toContain('total');

    // Wait for the legend strip to render. It mirrors the chart paths
    // (one entry per inverter in scope, no fleet Total because
    // there's only one inverter).
    await page.waitForFunction(
      () => document.querySelectorAll('#chart-legend button[data-legend-key]').length > 0,
      null,
      { timeout: 10000 }
    );
    const roofLegendKeys = await page
      .locator('#chart-legend button[data-legend-key]')
      .evaluateAll(els => els.map(e => e.getAttribute('data-legend-key')));
    expect(roofLegendKeys.filter(k => k.startsWith('series:'))).toHaveLength(1);
    expect(roofLegendKeys).not.toContain('total');

    // Switch to Garage Array — chart paths and legend both filter to
    // its two inverters, plus the fleet Total line reappears (>1
    // inverter in scope).
    await selectDtuAndWaitForPathCount(
      page,
      '#dtu-switcher button:has-text("Garage Array")',
      3
    );
    const garageSeriesKeys = await page
      .locator('#solar-chart-svg path[data-legend-key]')
      .evaluateAll(els => els.map(e => e.getAttribute('data-legend-key')));
    expect(garageSeriesKeys.filter(k => k.startsWith('series:'))).toHaveLength(2);
    expect(garageSeriesKeys).toContain('total');

    await page.waitForFunction(
      () => document.querySelectorAll('#chart-legend button[data-legend-key]').length > 1,
      null,
      { timeout: 10000 }
    );
    const garageLegendKeys = await page
      .locator('#chart-legend button[data-legend-key]')
      .evaluateAll(els => els.map(e => e.getAttribute('data-legend-key')));
    expect(garageLegendKeys.filter(k => k.startsWith('series:'))).toHaveLength(2);
    expect(garageLegendKeys).toContain('total');
  });

  test('Balcony Inverter (no today data) renders an empty chart and zero stats', async ({ page }) => {
    // The Balcony Inverter (AhoyDTU, id 2) has historical readings
    // but none for today. Selecting it must:
    //   * show the empty-chart placeholder (`#empty-chart`) instead
    //     of a rendered curve, since `path_data == ""`
    //   * zero the live "Current Generation" stat (no recent reading)
    //   * zero the Yield stat (no today readings)
    // The switcher must stay visible (we're still >1 device total).
    await page.locator('#dtu-switcher button', { hasText: 'Balcony Inverter' }).click();

    // Empty chart should replace the SVG. LiveView re-renders the
    // chart panel on selection change; wait for the placeholder to
    // appear (it can take a moment after the click).
    await page.waitForFunction(
      () => document.querySelector('#empty-chart') !== null,
      null,
      { timeout: 10000 }
    );
    await expect(page.locator('#empty-chart')).toBeVisible();
    await expect(page.locator('#solar-chart-svg')).toHaveCount(0);

    // No inverter paths to count on the empty chart.
    const breakdown = await chartSeriesBreakdown(page);
    expect(breakdown.inverters).toBe(0);
    expect(breakdown.total).toBe(0);

    // The "Current Generation" stat should read 0 W (no fresh
    // readings for this device today). Note: the dashboard falls
    // back to 0 W via `Enum.filter` when no reading within the
    // 2-minute freshness window matches.
    const currentPower = await readStatNumber(page, '#stat-yield-kwh');
    expect(currentPower).not.toBeNull();
    expect(currentPower).toBe(0);

    // The Yield card should also be 0 kWh (no today rows).
    const todayYield = await readStatNumber(page, '#stat-yield-kwh');
    expect(todayYield).not.toBeNull();
    expect(todayYield).toBe(0);
  });

  test('switching between devices in historical Day view filters the chart and stats correctly', async ({ page }) => {
    // The DTU switcher must apply to the historical Day view too —
    // it's the same `selected_dtu_id` assign that drives
    // `assign_dashboard_data/5` regardless of `time_range`.
    //
    // Historical day at day_offset = 1 has Roof Inverter and
    // Balcony Inverter readings (Garage Array has no historical
    // rows). So the Total view at this day shows:
    //   * 2 inverter paths (Roof serial 116180123456 + Balcony 223344556677)
    //   * 1 Total line (>1 inverter in scope)
    // The range-presets toolbar hides the historical stepper until
    // the user picks Custom; reveal it first.
    await page.locator('#btn-range-custom').click();
    await expect(page.locator('#history-picker')).toBeVisible();

    await page.locator('#select-granularity').selectOption('day');

    // LiveView swaps from the 1D (Today) chart to a Day-granular
    // historical chart when granularity changes. The 5-up stats
    // row is period-stable (its labels and IDs are the same across
    // every preset), so we can't use a stat-card swap as the
    // signal. Instead, poll for the chart title to update — the
    // historical Day title says "Production Curve for …" while
    // the 1D title says "Today's Production Curve".
    await page.waitForFunction(
      () => {
        const title = document.querySelector('#chart-title');
        return title && /Production Curve for/i.test(title.textContent || '');
      },
      null,
      { timeout: 10000 }
    );

    // Step back once from the empty-state guard so we land on a
    // day with seeded data (day_offset = 1 = yesterday).
    for (let i = 0; i < 5; i++) {
      await page.locator('#btn-history-prev').click();
      await page.waitForTimeout(500);

      const becameVisible = await page
        .locator('#solar-chart-svg')
        .waitFor({ state: 'attached', timeout: 1500 })
        .then(() => true)
        .catch(() => false);
      if (becameVisible) break;
    }

    await expect(page.locator('#solar-chart-svg')).toBeVisible({ timeout: 10000 });

    // Roof Inverter view on a historical day with data: exactly
    // one inverter path. The chart must be visible.
    await selectDtuAndWaitForPathCount(page, '#dtu-switcher button:has-text("Roof Inverter")', 1);
    const roofBreakdown = await chartSeriesBreakdown(page);
    expect(roofBreakdown.inverters).toBe(1);
    expect(roofBreakdown.total).toBe(0);

    // Wait a fixed 1.5 s for the LiveView round-trip to update
    // the historical-day "Yield" stat card before sampling.
    await page.waitForTimeout(1500);

    // Historical day view's "Yield" stat should be
    // non-zero on a day with seeded data.
    const roofDayYield = await readStatNumber(page, '#stat-yield-kwh');
    expect(roofDayYield).not.toBeNull();
    expect(roofDayYield).toBeGreaterThan(0);

    // Switch to Total — adds Balcony Inverter's inverter and the
    // fleet Total line. Roof Inverter is already in the chart, so
    // the historical Total view exposes Roof + Balcony = 2
    // inverters + 1 Total = 3 paths.
    await page.locator('#btn-select-total').click();
    await page.waitForFunction(
      () => document.querySelectorAll('#solar-chart-svg path[data-series]').length >= 3,
      null,
      { timeout: 10000 }
    );

    const totalBreakdown = await chartSeriesBreakdown(page);
    expect(totalBreakdown.inverters).toBe(2);
    expect(totalBreakdown.total).toBe(1);

    // The historical Total view's yield is the max across all
    // inverters (PR #119 switched fleet totals from sum to
    // max-of-monotonic-counter), so it must be at least the Roof
    // Inverter-only yield — equal when the Roof contributes the max.
    await page.waitForTimeout(1500);
    const totalDayYield = await readStatNumber(page, '#stat-yield-kwh');
    expect(totalDayYield).not.toBeNull();
    expect(totalDayYield).toBeGreaterThanOrEqual(roofDayYield);

    // Switching to Balcony Inverter narrows the chart to its
    // single inverter. With only one inverter in scope the Total
    // line is suppressed.
    await selectDtuAndWaitForPathCount(
      page,
      '#dtu-switcher button:has-text("Balcony Inverter")',
      1
    );
    const balconyBreakdown = await chartSeriesBreakdown(page);
    expect(balconyBreakdown.inverters).toBe(1);
    expect(balconyBreakdown.total).toBe(0);

    // Garage Array has no historical rows — selecting it renders
    // the empty chart even though the dashboard still has the
    // switcher button.
    await page.locator('#dtu-switcher button', { hasText: 'Garage Array' }).click();
    await page.waitForFunction(
      () => document.querySelector('#empty-chart') !== null,
      null,
      { timeout: 10000 }
    );
    await expect(page.locator('#empty-chart')).toBeVisible();
    await expect(page.locator('#solar-chart-svg')).toHaveCount(0);
  });
});
