const { test, expect } = require('@playwright/test');

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
// The seeded fixture (`priv/repo/seeds.exs`) creates three devices:
//   * "Roof Inverter"  (OpenDTU, today sine-arc 06:00–19:00, 580 W peak)
//   * "Balcony Inverter" (AhoyDTU, no today readings — historical only)
//   * "Garage Array"  (OpenDTU, today sine-arc with 2 inverters,
//                       580 W + 380 W peak)
//
// The dashboard's chart collapses per-MPPT DC rows into the
// inverter's AC aggregate on the server
// (`assign_line_chart_data/5`), so each inverter exposes one chart
// line. The Total fleet-wide line is rendered when more than one
// inverter is in scope, hidden when only one.
//
// Scenarios covered:
//   1. The switcher lists every device plus the Total button.
//   2. Switching to a single-device view reduces the chart series
//      count to that device's inverters only.
//   3. Switching back to Total aggregates every device's inverters
//      and re-adds the Total line.
//   4. "Current Generation" and "Today's Total Yield" stat cards
//      update with the selected device.
//   5. Historical (Day) granularity respects the device filter too —
//      the chart and stats both narrow to the selected DTU.
//   6. A device with no today data (Balcony Inverter) renders an
//      empty chart and zero stats, but the switcher still renders.
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
// "Total Yield").
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

  test("Today's Total Yield stat card updates when switching devices", async ({ page }) => {
    // Pin the live stat card across DTU selections. The card's
    // value must change when the scope changes — if it stayed
    // constant, the dashboard would be ignoring the device filter
    // for stats (the exact bug this test guards against).

    // Total view: should reflect the sum of every device's
    // `today_yield`. We only assert it's positive — the exact
    // value depends on seed magnitudes (sine arc integration)
    // and isn't worth pinning to a decimal.
    const totalYield = await readStatNumber(page, '#stat-today-yield');
    expect(totalYield).not.toBeNull();
    expect(totalYield).toBeGreaterThan(0);

    // Roof Inverter only — its seeded yield is a subset of the
    // fleet total (it produces one inverter vs the fleet's three).
    // A buggy dashboard would still show the fleet total here.
    await page.locator('#dtu-switcher button', { hasText: 'Roof Inverter' }).click();

    // Wait for the LiveView round-trip to update the stat card.
    await page.waitForFunction(
      prevTotal => {
        const el = document.querySelector('#stat-today-yield');
        if (!el) return false;
        const text = el.textContent || '';
        const match = text.replace(/\s/g, '').match(/-?\d+(?:[.,]\d+)?/);
        if (!match) return false;
        return parseFloat(match[0].replace(',', '.')) !== prevTotal;
      },
      totalYield,
      { timeout: 10000 }
    );

    const roofYield = await readStatNumber(page, '#stat-today-yield');
    expect(roofYield).not.toBeNull();
    expect(roofYield).toBeGreaterThan(0);
    // Roof Inverter produces one inverter; Total aggregates three.
    // The device-scoped value must therefore be smaller than the
    // Total. Use a tolerance of 0.5 kWh to absorb rounding noise
    // (the yield is rounded to one decimal upstream).
    expect(roofYield).toBeLessThan(totalYield);

    // Garage Array: two inverters, so its today_yield should sit
    // between the Roof-only and Total values (Garage's two
    // inverters produce more than Roof alone, but the Total adds
    // Roof's contribution on top so Total is still the largest).
    await page.locator('#dtu-switcher button', { hasText: 'Garage Array' }).click();
    await page.waitForFunction(
      prevRoof => {
        const el = document.querySelector('#stat-today-yield');
        if (!el) return false;
        const text = el.textContent || '';
        const match = text.replace(/\s/g, '').match(/-?\d+(?:[.,]\d+)?/);
        if (!match) return false;
        return parseFloat(match[0].replace(',', '.')) !== prevRoof;
      },
      roofYield,
      { timeout: 10000 }
    );

    const garageYield = await readStatNumber(page, '#stat-today-yield');
    expect(garageYield).not.toBeNull();
    expect(garageYield).toBeGreaterThan(0);
    // Garage Array's two inverters produce ≥ Roof's single inverter.
    expect(garageYield).toBeGreaterThanOrEqual(roofYield - 0.1);
    // And < Total because Total adds Roof's contribution on top.
    expect(garageYield).toBeLessThan(totalYield);
  });

  test('chart legend only lists inverters in the current scope', async ({ page }) => {
    // Roof Inverter: legend should contain exactly one inverter
    // name (the serial "116180123456" or "Roof Inverter") and not
    // the West Roof / East Garage strings from the Garage Array.
    await page.locator('#dtu-switcher button', { hasText: 'Roof Inverter' }).click();
    await page.waitForFunction(
      () => document.querySelectorAll('#chart-legend button').length > 0,
      null,
      { timeout: 10000 }
    );

    let legendText = await page.locator('#chart-legend').textContent();
    expect(legendText).not.toContain('West Roof');
    expect(legendText).not.toContain('East Garage');
    // The fleet-Total legend entry must NOT appear with only one
    // inverter in scope.
    expect(await page.locator('#chart-legend button[data-legend-key="total"]').count()).toBe(0);

    // Switch to Garage Array: West Roof + East Garage should now
    // both appear, plus the Total entry (two inverters in scope).
    await page.locator('#dtu-switcher button', { hasText: 'Garage Array' }).click();
    await page.waitForFunction(
      () => {
        const keys = Array.from(
          document.querySelectorAll('#chart-legend button[data-legend-key]')
        ).map(b => b.getAttribute('data-legend-key'));
        // Wait until the legend reflects the Garage Array view
        // (Total + 2 inverter rows).
        return keys.includes('total') && keys.filter(k => k.startsWith('series:')).length === 2;
      },
      null,
      { timeout: 10000 }
    );

    legendText = await page.locator('#chart-legend').textContent();
    expect(legendText).toContain('West Roof');
    expect(legendText).toContain('East Garage');
    expect(await page.locator('#chart-legend button[data-legend-key="total"]').count()).toBe(1);
  });

  test('Balcony Inverter (no today data) renders an empty chart and zero stats', async ({ page }) => {
    // The Balcony Inverter (AhoyDTU, id 2) has historical readings
    // but none for today. Selecting it must:
    //   * show the empty-chart placeholder (`#empty-chart`) instead
    //     of a rendered curve, since `path_data == ""`
    //   * zero the live "Current Generation" stat (no recent reading)
    //   * zero the "Today's Total Yield" stat (no today readings)
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
    const currentPower = await readStatNumber(page, '#stat-current-power');
    expect(currentPower).not.toBeNull();
    expect(currentPower).toBe(0);

    // Today's Total Yield should also be 0 kWh (no today rows).
    const todayYield = await readStatNumber(page, '#stat-today-yield');
    expect(todayYield).not.toBeNull();
    expect(todayYield).toBe(0);
  });

  test('switching between devices in historical Day view filters the chart and stats correctly', async ({ page }) => {
    // The DTU switcher must apply to the historical Day view too —
    // it's the same `selected_dtu_id` assign that drives
    // `assign_dashboard_data/5` regardless of `time_range`. Pick
    // Day granularity, walk to a day with seeded Roof Inverter
    // historicals (yesterday), and verify that selecting the Roof
    // Inverter narrows the chart to that device's line while Total
    // widens it.
    await page.locator('#select-granularity').selectOption('day');

    // LiveView swaps from live stat cards (`#stat-current-power`)
    // to historical ones (`#stat-total-yield`). Poll for the swap
    // rather than relying on a fixed sleep.
    await page.waitForFunction(
      () => document.querySelector('#stat-total-yield') !== null,
      null,
      { timeout: 10000 }
    );

    // The seed creates historical readings for the Roof Inverter
    // on multiple days (1, 2, 3, 4, 5, 6, 7, 10, 15, 30, 45, 90,
    // 365, 380 days back). The stepper's first selectable day is
    // the most recent, which is yesterday. Step back once from
    // the empty-state guard so we land on a day with seeded data.

    // Click prev until the chart becomes non-empty. The historical
    // day view renders `#solar-chart-svg` only when there's at
    // least one bucket. Day 1 back (yesterday) has Roof Inverter
    // data, so a single click should suffice.
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

    // Switch to Total — adds Garage Array's inverters and the
    // fleet Total line. Garage Array only has today readings
    // (see seeds.exs), so historical days see only the Roof
    // Inverter + Total: 1 inverter + 1 Total = 2 paths.
    await page.locator('#btn-select-total').click();
    await page.waitForFunction(
      () => document.querySelectorAll('#solar-chart-svg path[data-series]').length >= 2,
      null,
      { timeout: 10000 }
    );

    const totalBreakdown = await chartSeriesBreakdown(page);
    // The seeded Garage Array has no historical-day readings, so
    // the historical Total view exposes only the Roof Inverter
    // and the fleet Total line. Pin that exactly.
    expect(totalBreakdown.inverters).toBe(1);
    expect(totalBreakdown.total).toBe(1);

    // The historical day view's "Total Yield" stat should be
    // non-zero on a day with seeded data.
    const dayYield = await readStatNumber(page, '#stat-total-yield');
    expect(dayYield).not.toBeNull();
    expect(dayYield).toBeGreaterThan(0);

    // Switching to Balcony Inverter on the historical day view
    // narrows to its data — the seed gives Balcony a different
    // sine-arc (lower power), so its yield for the same historical
    // day should differ from Roof Inverter's. Both should be
    // positive; we don't pin the exact magnitudes.
    await page.locator('#dtu-switcher button', { hasText: 'Balcony Inverter' }).click();
    await page.waitForFunction(
      prev => {
        const el = document.querySelector('#stat-total-yield');
        if (!el) return false;
        const text = el.textContent || '';
        const match = text.replace(/\s/g, '').match(/-?\d+(?:[.,]\d+)?/);
        if (!match) return false;
        return parseFloat(match[0].replace(',', '.')) !== prev;
      },
      dayYield,
      { timeout: 10000 }
    );

    const balconyYield = await readStatNumber(page, '#stat-total-yield');
    expect(balconyYield).not.toBeNull();
    expect(balconyYield).toBeGreaterThan(0);
    // Different sine-arc magnitudes, so the values must differ.
    expect(Math.abs(balconyYield - dayYield)).toBeGreaterThan(0.1);
  });
});
