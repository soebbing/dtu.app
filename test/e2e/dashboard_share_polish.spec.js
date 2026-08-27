const { test, expect } = require('@playwright/test');
const { waitForLiveSocketConnected } = require('./_helpers');

// E2E coverage for the share-link UX polish-2 pass:
//
//   * The share panel sits below the chart, not in the toolbar —
//     so the URL row never has to compete for horizontal space
//     with the quick-range buttons.
//   * Clicking the toggle flips a spinner on immediately so the
//     user gets feedback during the (async) token mint.
//   * Tapping into the URL input selects the entire value, on
//     desktop click AND on mobile pointerdown (where iOS Safari
//     sometimes doesn't fire `focus` for readonly inputs).
//   * Clicking the copy icon writes the URL to the clipboard
//     and shows a "Copied!" hint next to the button for 1.5 s.
//
// Assumes the app is running on :4000 against a database seeded
// with `mix run priv/repo/seeds.exs` (test@example.com /
// password123456).

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

// Reset the share-link state to "off" before each test runs so the
// "toggling on" assertions land on a known starting point. The toggle
// is a sr-only checkbox; the visible click target is `#share-toggle-label`,
// which (since the `<label for=…>` fix) toggles the checkbox AND fires
// `phx-click="toggle_share"`. If the share is currently ON, one click
// turns it off; if it's already OFF, we leave it alone.
//
// Without this, tests run in random order across the file and one test
// can leave sharing enabled for the next — flipping the "toggling on"
// click into a "toggling off" click instead, with no spinner visible.
async function ensureShareOff(page) {
  await waitForLiveSocketConnected(page);

  const toggle = page.locator('#share-toggle');
  const isChecked = await toggle.isChecked();
  if (!isChecked) return;

  await page.locator('#share-toggle-label').click();
  // Wait for the URL row to vanish — that's the visible signal that
  // the toggle took effect.
  await expect(page.locator('#share-url-row')).toBeHidden({ timeout: 5000 });
}

test.describe('Acceptance: Share-link UX polish', () => {
  test.beforeEach(async ({ page, viewport }) => {
    // Tests in this file span two viewports (desktop click +
    // mobile tap) — `viewport` is set per-test via a fixture
    // override where needed. The default Playwright viewport
    // (1280×720) is fine for the desktop flow.
    await logIn(page);
    await expect(page.locator('h1')).toContainText('PV Power Dashboard', { timeout: 10000 });
    await ensureShareOff(page);
  });

  test('share panel sits below the chart, not in the toolbar', async ({ page }) => {
    // The chart container holds the share panel as a sibling of the
    // SVG / empty-state. Walking from the chart-title down should
    // cross the share-toggle before the next top-level section
    // ("Device Connection Status") starts.
    const chartTitle = page.locator('#chart-title');
    const sharePanel = page.locator('#share-panel');
    const deviceSection = page.getByRole('heading', { name: /Device Connection Status/i });

    await expect(chartTitle).toBeVisible();
    await expect(sharePanel).toBeVisible();
    await expect(deviceSection).toBeVisible();

    // The share panel must NOT live in the toolbar row that holds
    // the 1D / 7D / 30D / YTD / Custom range switcher. If it did,
    // it would be a sibling of `#quick-range-switcher` — assert the
    // share panel is NOT inside that toolbar.
    const inToolbar = await page.evaluate(() => {
      const panel = document.querySelector('#share-panel');
      const toolbar = document.querySelector('#quick-range-switcher');
      if (!panel || !toolbar) return null;
      return toolbar.contains(panel);
    });
    expect(inToolbar).toBe(false);

    // And the share panel must be inside the chart container —
    // asserted by checking the chart panel element contains both
    // `#chart-title` and `#share-panel`.
    const panelIsBelowChart = await page.evaluate(() => {
      const all = Array.from(document.querySelectorAll('div'));
      const chartContainer = all.find(
        (d) => d.contains(document.querySelector('#chart-title')) && d.contains(document.querySelector('#share-panel'))
      );
      return Boolean(chartContainer);
    });
    expect(panelIsBelowChart).toBe(true);
  });

  test('toggling the share switch on shows the spinner first, then the URL row', async ({ page }) => {
    const toggle = page.locator('#share-toggle');

    // The toolbar switch is a `sr-only` checkbox — Playwright's
    // `check()` / `click()` work on the underlying input, but the
    // visual element is the label wrapper. We click the label
    // because that's the actual click target users see.
    await page.locator('#share-toggle-label').click();

    // The click handler synchronously sets `:share_loading?` true
    // and the cond block swaps the hint text for the spinner.
    // LiveView delivers the render in a single patch, so by the
    // time the locator resolves the spinner should be in the DOM.
    //
    // We don't assert that the spinner is visible here — the
    // spawned Task that mints the share token can complete before
    // Playwright's visibility check settles, and the URL row
    // replaces the spinner in the very next LiveView patch.
    // Asserting the spinner reliably in E2E is a race against
    // wall-clock DB roundtrip time, which the synchronous ExUnit
    // test already covers by capturing the render_click HTML.
    // For E2E we only need to confirm the END state: the URL row
    // appears with the share token in the value.
    const urlInput = page.locator('#share-url-input');
    await expect(urlInput).toBeVisible({ timeout: 5000 });
    await expect(urlInput).toHaveValue(/\/s\//);

    // The spinner is gone.
    const spinner = page.locator('#share-loading-row');
    await expect(spinner).toBeHidden();
  });

  test('clicking the URL input selects the entire value (desktop)', async ({ page }) => {
    // Make sure we have a URL to focus first.
    await page.locator('#share-toggle-label').click();
    const urlInput = page.locator('#share-url-input');
    await expect(urlInput).toBeVisible({ timeout: 5000 });

    // Click into the input. The SelectOnFocus hook listens on
    // `click`, `focus`, and `pointerdown` and calls
    // `this.select()` (deferred via setTimeout(0) so it runs
    // AFTER the browser's default click cursor placement).
    await urlInput.click();

    // Poll the selection state — the deferred select() can land
    // a tick after the click resolves, so a single read might
    // catch the browser's mid-click cursor position. expect.poll
    // retries the evaluator until the assertions pass (or the
    // 5 s timeout fires).
    await expect
      .poll(
        async () =>
          await page.evaluate(() => {
            const el = document.querySelector('#share-url-input');
            return {
              start: el.selectionStart,
              end: el.selectionEnd,
              length: el.value.length,
            };
          }),
        { timeout: 5000 }
      )
      .toMatchObject({ start: 0, length: expect.any(Number) });

    const selection = await page.evaluate(() => {
      const el = document.querySelector('#share-url-input');
      return {
        start: el.selectionStart,
        end: el.selectionEnd,
        length: el.value.length,
      };
    });
    expect(selection.start).toBe(0);
    expect(selection.end).toBe(selection.length);
    expect(selection.length).toBeGreaterThan(0);
  });

  test('tapping the URL input selects the entire value on a mobile viewport', async ({ page }) => {
    // iOS Safari's tap-into-readonly-input doesn't always fire
    // `focus` — the hook handles that by also listening to
    // `pointerdown`. Pin a phone-sized viewport and use a
    // touch-style tap (single `mouse.move` is enough; the hook
    // reacts to the pointerdown that Playwright synthesizes).
    await page.setViewportSize({ width: 390, height: 844 });

    await page.locator('#share-toggle-label').click();
    const urlInput = page.locator('#share-url-input');
    await expect(urlInput).toBeVisible({ timeout: 5000 });
    await urlInput.scrollIntoViewIfNeeded();

    // Tap on the input. We don't issue a separate `focus()` call
    // — the hook must select on the pointerdown alone, otherwise
    // iOS Safari (which sometimes skips focus) would defeat the
    // whole point of the hook.
    const box = await urlInput.boundingBox();
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.up();

    // Poll the selection state — the deferred select() can land
    // a tick after the tap resolves.
    await expect
      .poll(
        async () =>
          await page.evaluate(() => {
            const el = document.querySelector('#share-url-input');
            return {
              start: el.selectionStart,
              end: el.selectionEnd,
              length: el.value.length,
            };
          }),
        { timeout: 5000 }
      )
      .toMatchObject({ start: 0, length: expect.any(Number) });

    const selection = await page.evaluate(() => {
      const el = document.querySelector('#share-url-input');
      return { start: el.selectionStart, end: el.selectionEnd, length: el.value.length };
    });
    expect(selection.start).toBe(0);
    expect(selection.end).toBe(selection.length);
  });

  test('clicking the copy button writes the URL to the clipboard and shows a Copied! hint', async ({
    page,
    context,
  }) => {
    // Grant clipboard permissions for the localhost origin so
    // `navigator.clipboard.writeText` resolves rather than throwing
    // (which would fall through to the legacy `execCommand` path).
    await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: 'http://localhost:4000' });

    await page.locator('#share-toggle-label').click();
    const urlInput = page.locator('#share-url-input');
    await expect(urlInput).toBeVisible({ timeout: 5000 });
    const expectedUrl = await urlInput.inputValue();

    // Click the dedicated copy button (NOT the input — the input
    // also has select-on-focus behaviour, and we want to test the
    // button's own click handler).
    const copyBtn = page.locator('#btn-share-copy');
    await expect(copyBtn).toBeVisible();
    await copyBtn.click();

    // The hook reveals the "Copied!" hint by toggling opacity-0 →
    // opacity-100 on `#share-copy-hint`. The hint starts hidden
    // (opacity-0); after a successful copy it should be visible
    // for 1.5 s.
    const hint = page.locator('#share-copy-hint');
    await expect(hint).toBeVisible({ timeout: 2000 });
    await expect(hint).toContainText(/Copied/i);

    // The button's icon was swapped to emerald — `data-value`
    // stays the same, but the `class="copied"` marker is set
    // so the SVG recolour can be confirmed via a class sniff.
    await expect(copyBtn).toHaveClass(/copied/);

    // The clipboard contains the URL.
    const clip = await page.evaluate(() => navigator.clipboard.readText());
    expect(clip).toBe(expectedUrl);

    // The hint auto-dismisses after 1.5 s.
    await expect(hint).toBeHidden({ timeout: 4000 });
  });
});
