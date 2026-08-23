const { test, expect } = require('@playwright/test');
const { waitForLiveSocketConnected } = require('./_helpers');

// E2E regression for the chart tooltip overlay's cursor-tracking
// math.
//
// The chart SVG declares `viewBox="0 0 800 280"` and renders at the
// container's full width via `class="w-full"`. On any viewport where
// the rendered chart is wider than 800 CSS px (every desktop), each
// SVG user unit maps to `(rect.width / 800)` CSS px. The cursor's
// local `x` in the ChartTooltip hook is in CSS px, but every
// position attribute the hook writes (`<line x1 x2>`, `<foreignObject
// x>`) is in user units — so writing the CSS-pixel value verbatim
// drifts the overlay to the right by exactly that scale factor, and
// the further right you hover the more pronounced it gets.
//
// Earlier versions of the hook did not convert. On a 1280-wide
// desktop the rendered chart is ~1000 CSS px wide (scale ≈ 1.25),
// so a hover at the middle set the tooltip's `x` attribute to ~500
// instead of the expected user-unit 400 — the cursor appeared
// roughly a quarter of the chart's width to the LEFT of the
// tooltip. These tests pin a desktop viewport, hover at known
// positions, and assert the overlay lands at the cursor in user
// units (not in raw CSS pixels).
//
// Assumes the app is running on :4000 against a database seeded
// with `mix run priv/repo/seeds.exs` (test@example.com /
// password123456, three DTUs, today's sine-arc curve).

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

test.describe('Acceptance: Chart tooltip overlay follows the cursor', () => {
  test.beforeEach(async ({ page }) => {
    // Pin a wide viewport so the SVG actually stretches past 800 CSS
    // px wide — that is the precondition for the user-unit ↔
    // CSS-pixel mismatch the bug was about. On the default 1280×720
    // viewport the dashboard's sidebar takes ~256 px, leaving the
    // chart container ~1000 CSS px wide (scaleX ≈ 1.25), which is
    // already enough to drift the overlay 20 %+ away from the
    // cursor before the fix.
    //
    // The height is set tall enough that the chart sits in the
    // viewport on first paint (the dashboard renders stat cards
    // and a granularity switcher above the chart that push it below
    // the fold on 1280×720 — Playwright's `mouse.move` doesn't
    // auto-scroll, so an off-screen cursor generates no mousemove
    // and the hook never updates the overlay attributes).
    await page.setViewportSize({ width: 1280, height: 1024 });

    await logIn(page);
    await expect(page.locator('h1')).toContainText('PV Power Dashboard', { timeout: 10000 });
    await waitForLiveSocketConnected(page);
    await expect(page.locator('#solar-chart-svg')).toBeVisible({ timeout: 10000 });
    await page.waitForFunction(
      () => document.querySelectorAll('#solar-chart-svg path[data-series]').length > 0,
      null,
      { timeout: 10000 }
    );
    // Defensive: even on the taller viewport the chart can land
    // below the fold on smaller laptop screens. Bring it into view
    // before any mouse.move so the hook's mousemove listener
    // actually fires (otherwise `display:none` stays on the
    // foreignObject and `toBeVisible()` times out).
    await page.locator('#solar-chart-svg').scrollIntoViewIfNeeded();
  });

  test('guide line and tooltip land at the cursor on a stretched viewport', async ({ page }) => {
    const svg = page.locator('#solar-chart-svg');
    const box = await svg.boundingBox();
    // Defensive: if the chart somehow didn't stretch (e.g. CI ran
    // the test on a tiny viewport), skip — the bug cannot reproduce
    // when rect.width ≤ 800.
    test.skip(
      box.width <= 800,
      `chart rendered at ${box.width} CSS px wide — bug requires > 800`
    );

    // Hover at the horizontal middle of the chart.
    const cursorX = box.x + box.width * 0.5;
    const cursorY = box.y + box.height * 0.5;
    await page.mouse.move(cursorX, cursorY);

    // The hook un-hides both elements on first move and writes
    // their `x` attributes. Wait for the tooltip to be visible so we
    // know the handler ran (visibility also implies the attribute
    // was set — `display:none` would keep the element hidden).
    const tooltip = page.locator('#chart-tooltip');
    const guide = page.locator('#chart-guide-line');
    await expect(tooltip).toBeVisible({ timeout: 3000 });
    await expect(guide).toBeVisible();

    const tooltipX = parseFloat(await tooltip.getAttribute('x'));
    const guideX1 = parseFloat(await guide.getAttribute('x1'));

    // The cursor at 50 % of the rendered chart width lands at user
    // unit 400 (the middle of the 0..800 viewBox). Before the fix
    // the hook set `x` to the raw CSS-pixel value (≈ 500+ on a
    // 1000-CSS-px chart), drifting the overlay ~25 % of the chart
    // width to the right of the cursor. Tight tolerance here is the
    // regression assertion: anything outside [380, 420] means the
    // conversion went wrong.
    expect(tooltipX).toBeGreaterThan(380);
    expect(tooltipX).toBeLessThan(420);
    expect(guideX1).toBeGreaterThan(380);
    expect(guideX1).toBeLessThan(420);

    // The tooltip sits 4 CSS px to the right of the guide line in
    // the non-flipped case. In user units that's 4 / scaleX, which
    // is ≈ 3 on a 1.25× chart and ≈ 2 on a 1.8× chart — so the
    // tooltip should always be a small positive number of units
    // past the guide line, never a large one. Before the fix the
    // tooltip was 25 % of the chart further right than the guide
    // line on a stretched viewport.
    expect(tooltipX).toBeGreaterThan(guideX1);
    expect(tooltipX - guideX1).toBeLessThan(10);
  });

  test('tooltip flips to the left of the cursor when near the right edge', async ({ page }) => {
    const svg = page.locator('#solar-chart-svg');
    const box = await svg.boundingBox();
    test.skip(
      box.width <= 800,
      `chart rendered at ${box.width} CSS px wide — bug requires > 800`
    );

    // Hover at 95 % of the chart width — well past the flip
    // threshold (tooltipWidthCss + 20 CSS px from the right edge,
    // which is ≈ 270 CSS px on a 1.25× chart).
    const cursorX = box.x + box.width * 0.95;
    const cursorY = box.y + box.height * 0.5;
    await page.mouse.move(cursorX, cursorY);

    const tooltip = page.locator('#chart-tooltip');
    const guide = page.locator('#chart-guide-line');
    await expect(tooltip).toBeVisible({ timeout: 3000 });
    await expect(guide).toBeVisible();

    const tooltipX = parseFloat(await tooltip.getAttribute('x'));
    const guideX1 = parseFloat(await guide.getAttribute('x1'));

    // When flipped, the tooltip's LEFT edge is to the LEFT of the
    // guide line (the cursor sits in the gap between the guide
    // line and the tooltip's right edge). Before the fix the
    // tooltip always stayed on the right — even at the right edge,
    // where the clamp `Math.min(rect.width - tooltipWidth, ...)`
    // just pinned it to the chart's right edge and left the cursor
    // floating well outside the tooltip's left edge.
    expect(tooltipX).toBeLessThan(guideX1);

    // The tooltip's right edge (xUnits + 200 user units, the
    // foreignObject's static width attribute) should land within
    // ~15 user units to the LEFT of the cursor — i.e. a ~10 CSS px
    // gap, scaled to user units. The flip should keep the tooltip
    // hugging the cursor, not pinned to the chart edge.
    const tooltipRightX = tooltipX + 200;
    const gapUnits = guideX1 - tooltipRightX;
    expect(gapUnits).toBeGreaterThan(-5); // not overflowing past cursor
    expect(gapUnits).toBeLessThan(15);    // within ~10 CSS px gap
  });
});