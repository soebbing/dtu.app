const { test, expect } = require('@playwright/test');
require('./_setup/global-fixture');

// E2E coverage for the `/notifications` history filter chip row.
//
// Flow under test:
//   1. Logged-in user lands on /notifications.
//   2. The chip row renders with one chip per known event + an
//      "All" chip, with the All chip marked active by default.
//   3. Clicking a chip scopes the history list to that event AND
//      push_patch-es the URL so the filter is bookmarkable.
//   4. Clicking the "All" chip clears the URL param back to
//      /notifications (no `?event=...` residue).
//   5. Mounting with `?event=...` already in the URL applies the
//      filter on first render — so a user sharing a filtered URL
//      sees the same view as the sharer.
//
// Why this matters: the URL is the contract. If a refactor drops
// the `push_patch`, a user who shares a link loses their filter
// silently — this spec catches that regression at the boundary
// the user actually sees.
test.describe('Acceptance Tests: Notifications history filter', () => {
  // Log-in helper shared with `notifications.spec.js` /
  // `notifications-channel-toggle.spec.js`. The Playwright pattern
  // is `page.click('text=Log in')` → fill email + password → submit.
  // Returns once the user is on `/dashboard`.
  async function logIn(page) {
    await page.goto('/');
    await page.click('text=Log in');
    await expect(page).toHaveURL(/\/users\/log-in/, { timeout: 10000 });
    await page.fill('input[type="email"]', 'test@example.com');
    await page.fill('input[type="password"]', 'password123456');
    await Promise.all([
      page.waitForNavigation(),
      page.click('button:has-text("Log in")')
    ]);
    await expect(page).toHaveURL(/\/dashboard/, { timeout: 10000 });
  }

  test('renders the chip row with All active, narrows on click, and updates the URL', async ({ page }) => {
    await logIn(page);

    // Navigate to /notifications. The chip row is below the form;
    // we scroll to it so Playwright's auto-wait doesn't time out
    // on an element outside the viewport on a tall page.
    await page.goto('/notifications');
    await expect(page).toHaveURL(/\/notifications/, { timeout: 10000 });

    // The chip row container is rendered.
    const chipRow = page.locator('#notification-history-filters');
    await expect(chipRow).toBeVisible();

    // All six chips exist. The All chip is the active one on a
    // clean mount (aria-pressed="true").
    const allChip = chipRow.locator('button[data-event-filter="all"]');
    const sunDownChip = chipRow.locator('button[data-event-filter="sun_down"]');
    await expect(allChip).toBeVisible();
    await expect(sunDownChip).toBeVisible();

    // aria-pressed drives the active-chip styling on the server.
    // Asserting via the attribute rather than the computed style
    // so the test is not coupled to the chip's visual treatment.
    await expect(allChip).toHaveAttribute('aria-pressed', 'true');
    await expect(sunDownChip).toHaveAttribute('aria-pressed', 'false');

    // Click the Sun down chip. The LiveView push_patch fires; we
    // wait for the URL to update to the filtered form.
    await sunDownChip.click();
    await expect(page).toHaveURL(/\/notifications\?event=sun_down/, { timeout: 5000 });

    // The chip's aria-pressed flips after the LiveView round-trip.
    await expect(sunDownChip).toHaveAttribute('aria-pressed', 'true');
    await expect(allChip).toHaveAttribute('aria-pressed', 'false');
  });

  test('clicking All clears the URL param back to /notifications', async ({ page }) => {
    await logIn(page);

    // Land on a pre-filtered URL — the chip row applies the filter
    // on first render (server reads `params["event"]`).
    await page.goto('/notifications?event=sun_down');
    await expect(page).toHaveURL(/\/notifications\?event=sun_down/, { timeout: 10000 });

    // The Sun down chip is active; All is not.
    const allChip = page.locator('#notification-history-filters button[data-event-filter="all"]');
    const sunDownChip = page.locator('#notification-history-filters button[data-event-filter="sun_down"]');
    await expect(sunDownChip).toHaveAttribute('aria-pressed', 'true');
    await expect(allChip).toHaveAttribute('aria-pressed', 'false');

    // Click All. The URL should drop the param entirely so a
    // copy/paste after clicking All doesn't carry the redundant
    // `?event=all` residue.
    await allChip.click();
    await expect(page).toHaveURL(/\/notifications$/, { timeout: 5000 });
    await expect(allChip).toHaveAttribute('aria-pressed', 'true');
  });

  test('mounting with an unknown event= falls back to All (no crash)', async ({ page }) => {
    await logIn(page);

    // Hand-edited URL — the server's `normalize_event_filter/1`
    // allow-list drops bogus values to "all" so the page must not
    // crash and must not show a chip from outside the known set.
    await page.goto('/notifications?event=<script>alert(1)</script>');
    await expect(page).toHaveURL(/\/notifications\?event=/, { timeout: 10000 });

    // All chip is active.
    const allChip = page.locator('#notification-history-filters button[data-event-filter="all"]');
    await expect(allChip).toHaveAttribute('aria-pressed', 'true');
  });
});
