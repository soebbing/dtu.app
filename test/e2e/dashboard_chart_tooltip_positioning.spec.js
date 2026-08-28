const { test, expect } = require('@playwright/test');
const { waitForLiveSocketConnected } = require('./_helpers');
require('./_setup/global-fixture');

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
    //
    // NB: we deliberately do NOT check `toBeVisible()` on the guide
    // line. It's a vertical SVG `<line>` (`x1 == x2`), so its
    // geometric bounding box has width 0 — Playwright's visibility
    // check considers zero-bounding-box elements hidden regardless
    // of stroke width, and reports the line as hidden even when the
    // hook correctly un-hides it. We assert the hook fired on the
    // guide line via the `x1` attribute being updated (the default
    // static value is "0", so a non-zero x1 means the hook wrote it)
    // and the inline `style` no longer containing `display:none`.
    const tooltip = page.locator('#chart-tooltip');
    const guide = page.locator('#chart-guide-line');
    await expect(tooltip).toBeVisible({ timeout: 3000 });
    await expect
      .poll(
        async () => {
          const style = await guide.getAttribute('style');
          return style === null || !style.includes('display:none');
        },
        { timeout: 3000, message: 'guide line still has inline display:none' }
      )
      .toBe(true);

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
    // Same SVG-line bounding-box caveat as in the middle-hover test
    // — see the long-form comment there. Poll the inline style
    // instead of `toBeVisible()`.
    await expect
      .poll(
        async () => {
          const style = await guide.getAttribute('style');
          return style === null || !style.includes('display:none');
        },
        { timeout: 3000, message: 'guide line still has inline display:none' }
      )
      .toBe(true);

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

test.describe('Acceptance: Chart tooltip overlay follows the touch on mobile', () => {
  // Mobile-specific regression: the same chart-container-vs-viewBox
  // mismatch applies *inversely* on narrow viewports — the SVG
  // renders at LESS than 800 CSS px wide, so the hook's scaleX is
  // < 1 instead of > 1. If the conversion from CSS-px cursor
  // position to user-unit foreignObject x is wrong (or absent) the
  // overlay drifts to the LEFT of the cursor on mobile, because the
  // raw pixel value reads as a position closer to the left edge of
  // the (smaller) viewBox.
  //
  // Pinning an iPhone X-ish viewport (375×812, the default for
  // `devices['iPhone X']`) is the right mobile representative:
  // it's narrow enough that the SVG scales down (scaleX ≈ 0.43),
  // and the dashboard's single-column mobile layout means the
  // chart container is essentially full-viewport-width minus the
  // px-4 side padding.
  //
  // We use `mouse.move` rather than `page.touchscreen.tap` because
  // the hook binds both `touchstart` and `mousemove` to the same
  // `move()` handler, and the positioning math reads only
  // `e.clientX` / `e.touches[0].clientX` — both in CSS px. The
  // touch-event plumbing would force us to enable `hasTouch` on the
  // context, which adds CI runtime for no behavioural coverage
  // gain (the bug we're guarding is a coordinate-system bug, not a
  // touch-event-handling bug).

  test.beforeEach(async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 812 });
    await logIn(page);
    await expect(page.locator('h1')).toContainText('PV Power Dashboard', { timeout: 10000 });
    await waitForLiveSocketConnected(page);
    await expect(page.locator('#solar-chart-svg')).toBeVisible({ timeout: 10000 });
    await page.waitForFunction(
      () => document.querySelectorAll('#solar-chart-svg path[data-series]').length > 0,
      null,
      { timeout: 10000 }
    );
    await page.locator('#solar-chart-svg').scrollIntoViewIfNeeded();
  });

  test('overlay stays at the cursor when the SVG is narrower than the viewBox', async ({ page }) => {
    const svg = page.locator('#solar-chart-svg');
    const box = await svg.boundingBox();
    // Defensive: skip if the chart somehow didn't shrink on this
    // viewport (the bug requires rect.width < 800 to reproduce).
    test.skip(
      box.width >= 800,
      `chart rendered at ${box.width} CSS px wide — bug requires < 800 (mobile-scaled)`
    );

    // Tap (via mouse.move) at the horizontal middle of the chart.
    const tapX = box.x + box.width * 0.5;
    const tapY = box.y + box.height * 0.5;
    await page.mouse.move(tapX, tapY);

    const tooltip = page.locator('#chart-tooltip');
    const guide = page.locator('#chart-guide-line');
    await expect(tooltip).toBeVisible({ timeout: 3000 });
    await expect
      .poll(
        async () => {
          const style = await guide.getAttribute('style');
          return style === null || !style.includes('display:none');
        },
        { timeout: 3000, message: 'guide line still has inline display:none' }
      )
      .toBe(true);

    const tooltipX = parseFloat(await tooltip.getAttribute('x'));
    const guideX1 = parseFloat(await guide.getAttribute('x1'));

    // The cursor at 50 % of the rendered chart width lands at user
    // unit 400 (the middle of the 0..800 viewBox). Before the fix
    // the hook set `x` to the raw CSS-pixel value (≈ 170 on a
    // 343-CSS-px mobile chart), which placed the tooltip at user
    // unit 170 — about a quarter of the chart to the LEFT of the
    // cursor. Tight tolerance here is the regression assertion:
    // anything outside [380, 420] means the conversion went wrong.
    expect(tooltipX).toBeGreaterThan(380);
    expect(tooltipX).toBeLessThan(420);
    expect(guideX1).toBeGreaterThan(380);
    expect(guideX1).toBeLessThan(420);

    // The tooltip should sit 4 CSS px to the right of the guide
    // line — in user units that's 4 / scaleX, which is ≈ 9 on a
    // 0.43× mobile chart. The drift-before-fix scenario would have
    // the tooltip FAR to the left of the cursor (its CSS-pixel x
    // would have been ~170, much smaller than the cursor's
    // ~170-px position scaled to user units 400).
    expect(tooltipX).toBeGreaterThan(guideX1);
    expect(tooltipX - guideX1).toBeLessThan(15);
  });

  test('overlay flips to the left of the cursor when near the right edge (mobile)', async ({ page }) => {
    const svg = page.locator('#solar-chart-svg');
    const box = await svg.boundingBox();
    test.skip(
      box.width >= 800,
      `chart rendered at ${box.width} CSS px wide — bug requires < 800 (mobile-scaled)`
    );

    // Tap (via mouse.move) near the right edge of the chart so the
    // flip threshold (tooltipWidthCss + 20 CSS px from the right
    // edge — about 100 CSS px on a 343-CSS-px mobile chart, i.e. the
    // rightmost ~30 %) trips.
    const tapX = box.x + box.width * 0.92;
    const tapY = box.y + box.height * 0.5;
    await page.mouse.move(tapX, tapY);

    const tooltip = page.locator('#chart-tooltip');
    const guide = page.locator('#chart-guide-line');
    await expect(tooltip).toBeVisible({ timeout: 3000 });
    await expect
      .poll(
        async () => {
          const style = await guide.getAttribute('style');
          return style === null || !style.includes('display:none');
        },
        { timeout: 3000, message: 'guide line still has inline display:none' }
      )
      .toBe(true);

    const tooltipX = parseFloat(await tooltip.getAttribute('x'));
    const guideX1 = parseFloat(await guide.getAttribute('x1'));

    // Flipped: tooltip's LEFT edge is LEFT of the guide line. Before
    // the fix the tooltip stayed on the right even at the right edge
    // (clamped to the chart's right edge) — the cursor floated
    // outside the tooltip's left edge with no visible flip.
    expect(tooltipX).toBeLessThan(guideX1);

    // The tooltip's right edge (xUnits + 200 user units) should land
    // close to but left of the cursor — a ~10 CSS px gap, scaled to
    // user units (10 / scaleX ≈ 23 on a 0.43× mobile chart).
    const tooltipRightX = tooltipX + 200;
    const gapUnits = guideX1 - tooltipRightX;
    expect(gapUnits).toBeGreaterThan(-5);
    expect(gapUnits).toBeLessThan(30);
  });
});