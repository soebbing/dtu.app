const { test, expect } = require('@playwright/test');
const { waitForLiveSocketConnected } = require('./_helpers');
require('./_setup/global-fixture');

// E2E coverage for the `<.flash>` auto-dismiss behavior.
//
// `CoreComponents.flash/1` renders toasts with a `Flash` JS hook
// that auto-dismisses after 10 s. Hovering or keyboard-focusing
// the toast pauses the timer; leaving restarts it. Dismissing
// hides the DOM AND clears the server-side flash entry so the
// toast does not re-appear on the next LiveView render.
//
// We exercise the timer twice — once for the happy path
// (10 s → toast gone) and once for the pause/resume path (hover
// keeps the toast alive past 10 s, mouseleave arms a fresh timer
// that dismisses it). Both tests wait a real 10 s; the suite is
// slow on purpose because the timer is what we're verifying.
test.describe('Acceptance Tests: Flash auto-dismiss', () => {
  test('info toast disappears after 10 s without interaction', async ({ page }) => {
    await page.goto('/');
    await page.click('text=Log in');
    await page.fill('input[type="email"]', 'test@example.com');
    await page.fill('input[type="password"]', 'password123456');
    await Promise.all([
      page.waitForNavigation(),
      page.click('button:has-text("Log in")')
    ]);

    // Use the `/notifications` save flow: clicking "Save preferences"
    // triggers a server-side `put_flash(:info, ...)`, which renders
    // `<div id="flash-info">` with the `Flash` hook mounted.
    await page.goto('/notifications');
    await waitForLiveSocketConnected(page);

    // Click the save button. The flash appears as a sibling of
    // the page's main content (see `Layouts.flash_group/1`).
    await page.click('button:has-text("Save preferences")');
    const toast = page.locator('#flash-info');
    await expect(toast).toBeVisible({ timeout: 5000 });

    // Wait the full 10 s plus a 2 s buffer for the DOM update to
    // land. The hook hides via `this.el.hidden = true`, so the
    // element stays in the DOM but becomes non-rendered. The
    // server-side flash entry is also cleared via `lv:clear-flash`,
    // so even a LiveView re-render cannot resurrect it.
    await page.waitForTimeout(12000);
    await expect(toast).toBeHidden();

    // Reload to confirm the server-side flash was actually
    // cleared (not just hidden client-side). A stale server-side
    // entry would re-pop the toast on the next render after a
    // navigation.
    await page.reload();
    await waitForLiveSocketConnected(page);
    await expect(toast).toHaveCount(0);
  });

  test('hovering the toast pauses the timer', async ({ page }) => {
    await page.goto('/');
    await page.click('text=Log in');
    await page.fill('input[type="email"]', 'test@example.com');
    await page.fill('input[type="password"]', 'password123456');
    await Promise.all([
      page.waitForNavigation(),
      page.click('button:has-text("Log in")')
    ]);

    await page.goto('/notifications');
    await waitForLiveSocketConnected(page);
    await page.click('button:has-text("Save preferences")');
    const toast = page.locator('#flash-info');
    await expect(toast).toBeVisible({ timeout: 5000 });

    // Park the mouse over the toast for 12 s — well past the
    // 10 s timer. While hovered, the timer is cleared (no
    // dismiss fires), so the toast must still be visible.
    await toast.hover();
    await page.waitForTimeout(12000);
    await expect(toast).toBeVisible();

    // Move the mouse far away from the toast (to the page edge)
    // so mouseleave fires and the timer restarts. Then wait a
    // fresh 10 s plus buffer — the toast must now be hidden.
    await page.mouse.move(0, 0);
    await page.waitForTimeout(12000);
    await expect(toast).toBeHidden();
  });
});
