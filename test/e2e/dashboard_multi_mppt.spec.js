const { test, expect } = require('@playwright/test');

// E2E coverage for the multi-inverter / per-MPPT chart breakdown.
//
// Regression: a customer with a DTU that polled multiple inverters, each
// exposing one or two MPPT strings, reported two symptoms on the live
// system:
//   1. "Current Generation" displayed 0 W even though the production
//      curve clearly showed the system producing.
//   2. The chart legend listed every (inverter, MPPT) pair, but the
//      per-MPPT lines were drawn flat at the X-axis.
//
// Root cause (fixed in lib/dtu_app/devices.ex):
//   * `current_power` summed `ac_power` over the latest reading per
//     (dtu_id, inverter_serial), but per-MPPT rows only store `dc_power`
//     (the firmware publishes per-channel DC scalars on
//     `[serial]/[1-4]/...`). Whichever (inverter, MPPT) row was most
//     recent picked a nil `ac_power`, zeroing the sum.
//   * `list_day_chart_data/3` bucketed `ac_power || 0.0`, so per-MPPT
//     series always plotted at 0 W.
//
// The fix:
//   * `current_power` now restricts the "latest reading per inverter"
//     query to `mppt_index = 0` (the AC aggregate row).
//   * The chart picks `ac_power` for `mppt_index = 0` rows and
//     `dc_power` for `mppt_index >= 1` rows via `chart_power_for_mppt/1`.
//
// The seeded "Garage Array" DTU (see priv/repo/seeds.exs) has two
// inverters ("West Roof" with two MPPTs, "East Garage" with one) and
// exposes the full multi-series chart surface.

const E2E_EMAIL = 'test@example.com';
const E2E_PASSWORD = 'password123456';

async function logIn(page) {
  await page.goto('/');
  await page.getByRole('link', { name: 'Sign In' }).click();
  await expect(page).toHaveURL(/\/users\/log-in/, { timeout: 10000 });

  const form = page.locator('#login_form_password');
  await form.locator('input[type="email"]').fill(E2E_EMAIL);
  await form.locator('input[type="password"]').fill(E2E_PASSWORD);
  await form.getByRole('button', { name: /Log in/i }).click();
  await page.waitForURL(/\/dashboard/, { timeout: 15000 });

  // LiveView takes a moment to swap from the static page to the live view.
  await page.waitForLoadState('domcontentloaded');
  await page.waitForTimeout(500);
}

// Click a switcher button and wait for the chart's data-series count to
// change. The legend's children are a reliable proxy for "the chart has
// finished re-rendering with the new DTU selection" — once they update,
// the corresponding paths on the SVG have been reissued too.
async function selectDtuAndWait(page, buttonSelector, expectedSeriesCount) {
  await page.locator(buttonSelector).click();

  // Wait up to ~5 s for the chart to expose the expected number of
  // distinct <path data-series="..."> elements.
  for (let i = 0; i < 50; i++) {
    const count = await page.locator('#solar-chart-svg path[data-series]').count();
    if (count >= expectedSeriesCount) return;
    await page.waitForTimeout(100);
  }
}

test.describe('Acceptance Tests: Multi-Inverter / Per-MPPT Breakdown', () => {
  test.beforeEach(async ({ page }) => {
    await logIn(page);
    await expect(page.locator('h1')).toContainText('PV Power Dashboard', { timeout: 10000 });
  });

  test('Garage Array DTU shows non-zero Current Generation when multiple inverters are producing', async ({ page }) => {
    // The seeded Garage Array has two inverters and three MPPTs in total.
    // Select it via the DTU switcher so the dashboard filters down to
    // only its readings.
    await selectDtuAndWait(page, '#dtu-switcher button:has-text("Garage Array")', 3);

    // Stat: Current Generation must be non-zero. Pre-fix, this stat
    // summed `ac_power` over the latest reading per inverter, but the
    // latest row per inverter happened to be a per-MPPT row with nil
    // `ac_power`, so the displayed value was 0 W.
    const currentPowerText = await page.locator('#stat-current-power').textContent();
    const currentPower = parseFloat(currentPowerText.replace(/[^0-9.]/g, ''));
    expect(currentPower).toBeGreaterThan(0);

    // Today's yield must also be > 0 since the sine-arc seed runs
    // 06:00–19:00.
    const todayYieldText = await page.locator('#stat-today-yield').textContent();
    const todayYield = parseFloat(todayYieldText.replace(/[^0-9.]/g, ''));
    expect(todayYield).toBeGreaterThan(0);
  });

  test('Garage Array chart renders one path per (inverter, MPPT) — not all flat at zero', async ({ page }) => {
    // Three series expected: West Roof AC, West Roof MPPT 1, West Roof
    // MPPT 2 (plus East Garage AC, but East Garage is part of "Total").
    // We're filtering to Garage Array only, so 3 distinct series for
    // the West Roof inverter + 1 for East Garage = 4. Wait for that.
    await selectDtuAndWait(page, '#dtu-switcher button:has-text("Garage Array")', 4);

    // Each path must have a non-empty `d` attribute AND that path must
    // describe a non-flat curve. We assert the path's `d` attribute
    // has at least 3 segments (`M ... L ... L ...`) — a flat-at-zero
    // line would have all points at y=250, but a curve that actually
    // moves will have varying y coordinates.
    const pathDataList = await page
      .locator('#solar-chart-svg path[data-series]')
      .evaluateAll(els => els.map(el => el.getAttribute('d')));

    expect(pathDataList.length).toBeGreaterThanOrEqual(3);

    // Each path must have at least one move-to and several line-to
    // commands (otherwise it's not a real curve). A flat-at-zero line
    // is geometrically valid but only has one L per bucket — make sure
    // each path has a healthy number of points.
    for (const d of pathDataList) {
      const lineTos = (d.match(/L /g) || []).length;
      expect(lineTos).toBeGreaterThan(5);
    }
  });

  test('Garage Array legend lists each (inverter, MPPT) entry with the right label', async ({ page }) => {
    await selectDtuAndWait(page, '#dtu-switcher button:has-text("Garage Array")', 4);

    // Legend must contain the friendly name for the AC aggregate and
    // each per-MPPT string. The labels follow
    // `Name (AC)` / `Name — MPPT N` per `series_legend` in
    // `assign_line_chart_data/4`.
    const legendText = await page.locator('#chart-legend').textContent();
    expect(legendText).toContain('West Roof (AC)');
    expect(legendText).toContain('West Roof — MPPT 1');
    expect(legendText).toContain('West Roof — MPPT 2');
    expect(legendText).toContain('East Garage (AC)');
  });

  test('Garage Array chart exposes a fleet-wide "Total" line and clicking its legend entry hides the curve', async ({ page }) => {
    await selectDtuAndWait(page, '#dtu-switcher button:has-text("Garage Array")', 4);

    // The Total line is the headline curve; it must appear in the
    // legend strip alongside the per-inverter / per-MPPT entries.
    const totalLegend = page.locator('#chart-legend button[data-legend-key="total"]');
    await expect(totalLegend).toBeVisible();

    // The Total path itself must start out visible (display !== "none").
    const totalPath = page.locator('#solar-chart-svg path[data-legend-key="total"]');
    await expect(totalPath).toBeVisible();

    // Clicking the Total legend button toggles the path's display:none
    // and dims the button so the user can see which series are off.
    await totalLegend.click();
    await expect(totalPath).toBeHidden();
    await expect(totalLegend).toHaveAttribute('aria-pressed', 'false');
    await expect(totalLegend).toHaveClass(/opacity-40/);

    // Clicking again restores the path and the legend button state.
    await totalLegend.click();
    await expect(totalPath).toBeVisible();
    await expect(totalLegend).toHaveAttribute('aria-pressed', 'true');
    await expect(totalLegend).not.toHaveClass(/opacity-40/);
  });

  test('Garage Array chart lines actually move vertically — no per-MPPT line is flat at the X-axis', async ({ page }) => {
    // Pre-fix regression: every per-MPPT line was drawn flat at y=250
    // because the bucketing read `ac_power || 0.0` even though those
    // rows only carry `dc_power`. After the fix each per-MPPT path's
    // y-coordinates span a range that includes both the bottom of the
    // SVG (y=250) and points meaningfully above it (the sine arc peak
    // reaches ~30 W on a 200 W y_max, so y-coords drop to ~215 — well
    // above the X-axis).
    await selectDtuAndWait(page, '#dtu-switcher button:has-text("Garage Array")', 4);

    // For each path with a `data-series` attribute, parse its `d`
    // attribute and collect the y-coordinates. Pre-fix the per-MPPT
    // paths would have every y at exactly 250; post-fix they span at
    // least 10 px of vertical range.
    const seriesYRanges = await page
      .locator('#solar-chart-svg path[data-series]')
      .evaluateAll(els =>
        els.map(el => {
          const d = el.getAttribute('d');
          const series = el.getAttribute('data-series');
          // Match `L <x> <y>` and `M <x> <y>` coordinates.
          const ys = (d.match(/(?:^|[ML])\s*[\d.-]+\s+([\d.-]+)/g) || [])
            .map(s => parseFloat(s.trim().split(/\s+/).pop()));
          return { series, ys };
        })
      );

    expect(seriesYRanges.length).toBeGreaterThanOrEqual(3);

    for (const { series, ys } of seriesYRanges) {
      expect(ys.length).toBeGreaterThan(0);
      const minY = Math.min(...ys);
      const maxY = Math.max(...ys);
      const range = maxY - minY;
      // A "flat at zero" pre-fix line has range 0; the post-fix curves
      // span at least a few px of vertical movement across the sine arc.
      expect(range, `series ${series} should not be flat at zero`).toBeGreaterThan(2);
    }
  });
});
