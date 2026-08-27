// E2E coverage for the public /s/:token shared dashboard.
//
// What we verify:
//
//   * A logged-in user can enable sharing, copy the share URL, and
//     follow it to a working public dashboard — no login required.
//   * The public dashboard renders the three stat cards
//     (Yield today / Current power / Peak power), the Live badge,
//     and a power chart.
//   * The chart is a plain SVG with a single polyline and exactly
//     two `<text>` labels ("00:00", "12:00"). Crucially it does
//     NOT render any Y-axis numeric labels — that was the bug
//     surfaced in task #221, where watts_to_y/1 squished every
//     realistic solar day (>200 W) into the top sliver of the
//     chart and made the polyline collapse into what looked like
//     a band of overlay numbers.
//   * The Y-axis is data-driven: with a non-trivial peak, the
//     polyline spans the full vertical range (max y > 100,
//     min y < 50) — i.e. it actually fills the chart.
//   * The public layout doesn't render the authenticated navbar.
//
// We don't cover the "invalid token" path here — that's an
// ExUnit concern (covered by shared_dashboard_live_test.exs).
// E2E is for the happy path that a real visitor lands on.

const { test, expect } = require('@playwright/test');
const { waitForLiveSocketConnected } = require('./_helpers');

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
}

// Make sure sharing is OFF at the start of each test so the
// "toggling on" click is deterministic.
async function ensureShareOff(page) {
  await waitForLiveSocketConnected(page);
  const toggle = page.locator('#share-toggle');
  const isChecked = await toggle.isChecked();
  if (!isChecked) return;
  await page.locator('#share-toggle-label').click();
  await expect(page.locator('#share-url-row')).toBeHidden({ timeout: 5000 });
}

// Click the share toggle and wait for the URL row to populate,
// then read the absolute share URL. The input is a read-only
// text field showing the full URL.
async function enableShareAndCaptureUrl(page) {
  await page.locator('#share-toggle-label').click();
  const urlInput = page.locator('#share-url-input');
  await expect(urlInput).toBeVisible({ timeout: 5000 });
  const url = await urlInput.inputValue();
  await expect(url).toMatch(/\/s\//);
  return url;
}

test.describe('Acceptance: Public shared dashboard', () => {
  test.beforeEach(async ({ page }) => {
    await logIn(page);
    await expect(page.locator('h1')).toContainText('PV Power Dashboard', { timeout: 10000 });
    await ensureShareOff(page);
  });

  test('shared URL loads without authentication and renders the dashboard chrome', async ({ page, context }) => {
    const shareUrl = await enableShareAndCaptureUrl(page);

    // Drop all auth cookies so the shared page is hit anonymously.
    // The share route uses `:public_browser` and never reads the
    // session cookie, but stripping it guarantees we exercise the
    // anonymous path the same way a fresh visitor would.
    await context.clearCookies();

    await page.goto(shareUrl);
    await waitForLiveSocketConnected(page);

    // The public layout replaces the authenticated navbar — assert
    // the absence of nav-only selectors.
    await expect(page.locator('#share-toggle')).toHaveCount(0);
    await expect(page.locator('#quick-range-switcher')).toHaveCount(0);

    // Stat cards + live badge.
    await expect(page.getByText('Yield today')).toBeVisible();
    await expect(page.getByText('Current power')).toBeVisible();
    await expect(page.getByText("Peak power")).toBeVisible();
    await expect(page.locator('#shared-live-badge')).toBeVisible();

    // Chart container + the static SVG chart.
    const chart = page.locator('#shared-power-chart svg');
    await expect(chart).toBeVisible();
  });

  test('chart contains only the polyline + two time-axis labels (no Y-axis numbers)', async ({ page, context }) => {
    const shareUrl = await enableShareAndCaptureUrl(page);
    await context.clearCookies();
    await page.goto(shareUrl);
    await waitForLiveSocketConnected(page);

    // The chart card is always present (`#shared-power-chart`), but
    // its inner content branches: with seed data it renders the SVG
    // polyline + two `<text>` axis labels; without data it renders
    // the "No data yet" placeholder (no `<svg>`). Both are valid —
    // the bug we're guarding against is Y-axis *numbers* in the
    // populated branch, so skip cleanly when there's no data.
    const svg = page.locator('#shared-power-chart svg');
    const polylineCount = await page.locator('#shared-power-chart polyline').count();
    test.skip(polylineCount === 0, 'no chart data for the seeded user — skipping label assertions');

    await expect(svg).toBeVisible();

    // Two <text> labels, both clock-time strings. Anything else
    // (numeric axis labels, hidden tick marks) is a regression.
    // Use `textContent` (not `innerText`) because Playwright's
    // `innerText` strips SVG text in some shadow-DOM combinations,
    // and HEEx emits the labels with surrounding whitespace.
    const textLabels = await svg.evaluate((node) =>
      Array.from(node.querySelectorAll('text'))
        .map((t) => t.textContent.trim())
        .sort()
    );
    expect(textLabels).toEqual(['00:00', '12:00']);

    // No <text> element should contain a bare numeric value —
    // task #221's regression signature.
    const numericTextCount = await svg.evaluate((node) =>
      Array.from(node.querySelectorAll('text')).filter((t) => /^-?\d+(\.\d+)?$/.test(t.textContent.trim())).length
    );
    expect(numericTextCount).toBe(0);

    // Exactly one polyline (the production curve). If the overlay
    // ever creeps back in, this count grows.
    await expect(svg.locator('polyline')).toHaveCount(1);
  });

  test('polygon spans the full chart height for a non-trivial solar day', async ({ page, context }) => {
    // Seed assurance: this test assumes the dev/prod database has
    // at least one DTU for test@example.com and at least a few
    // hours of readings today. The `mix run priv/repo/seeds.exs`
    // seed creates that — without it the empty-state path renders
    // and the y-range assertions below become meaningless.
    const shareUrl = await enableShareAndCaptureUrl(page);
    await context.clearCookies();
    await page.goto(shareUrl);
    await waitForLiveSocketConnected(page);

    const svg = page.locator('#shared-power-chart svg');
    await expect(svg).toBeVisible();

    // The polyline must have at least one point — otherwise the
    // empty-state branch is in effect and we can't validate the
    // y-axis. Skip rather than fail so this test is informative
    // on a freshly-seeded environment without backfilled readings.
    const polylineExists = await svg.locator('polyline').count();
    test.skip(polylineExists === 0, 'no chart data for the seeded user — skipping y-range assertions');

    // Read every (x,y) pair out of the points attribute and
    // compute the y-extent. With the data-driven y-axis (task
    // #221), the polyline uses the full chart height for any
    // realistic solar day — the pre-fix bug crammed everything
    // into the top 10 px.
    const ys = await svg.evaluate((node) => {
      const polyline = node.querySelector('polyline');
      const raw = polyline.getAttribute('points') || '';
      return raw
        .trim()
        .split(/\s+/)
        .map((pair) => Number(pair.split(',')[1]))
        .filter((y) => Number.isFinite(y));
    });

    expect(ys.length).toBeGreaterThan(0);
    const yMin = Math.min(...ys);
    const yMax = Math.max(...ys);

    // A well-spread chart: the polyline touches both halves of
    // the viewBox (0-200). Without the fix, every point would be
    // in the y=6-10 band and these assertions would fail.
    expect(yMin).toBeLessThan(50);
    expect(yMax).toBeGreaterThan(100);
    // Sanity: still inside the viewBox.
    expect(yMin).toBeGreaterThanOrEqual(0);
    expect(yMax).toBeLessThanOrEqual(190);
  });
});