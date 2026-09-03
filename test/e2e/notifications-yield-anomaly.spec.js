const { test, expect } = require('@playwright/test');
const { waitForLiveSocketConnected } = require('./_helpers');
require('./_setup/global-fixture');

// E2E coverage for the new "Mid-day yield collapse" toggle on
// /notifications (added by the yield-anomaly-notifications feature).
//
// The new toggle mirrors the existing per-topic checkboxes
// (`:notify_dtu_connection`, `:notify_sun_down`, `:notify_sun_up`):
// it is a plain `<input type="checkbox">` inside a wrapping
// `<label class="flex items-start gap-3 cursor-pointer">`. The
// label's first child is the visible title — "Mid-day yield
// collapse" — which we use as the accessible name for `getByLabel`.
//
// What we're proving:
//   1. The new toggle is in the DOM (i.e. the
//      `notify_yield_anomaly` field is wired through
//      `User.notification_settings_changeset/2` and rendered by
//      the LiveView template).
//   2. Toggling it on, saving, and reloading persists the value
//      on the user record.
//
// Defaults:
//   * `User.notify_yield_anomaly` ships as `false` — the migration
//     adds the column with `default: false` so existing users
//     don't start receiving the new alert on deploy.
//   * The seeded test user starts with all toggles off; if a
//     prior spec run left this one on, we explicitly uncheck
//     before toggling on again.
//
// Run alongside `notifications-channel-toggle.spec.js` (which
// flips the channel chip for the same user) by relying on the
// seeded email/password — no fixture changes needed.

test.describe.serial('Acceptance Tests: Yield-anomaly notification toggle', () => {
  async function logIn(page) {
    await page.goto('/');
    await page.click('text=Log in');
    await expect(page).toHaveURL(/\/users\/log-in/, { timeout: 10000 });
    await page.fill('input[type="email"]', 'test@example.com');
    await page.fill('input[type="password"]', 'password123456');
    await Promise.all([
      page.waitForNavigation(),
      page.click('button:has-text("Log in")'),
    ]);
    await expect(page).toHaveURL(/\/dashboard/, { timeout: 10000 });
  }

  test('the new Mid-day yield collapse toggle appears, can be turned on, and persists across reload', async ({ page }) => {
    await logIn(page);

    await page.goto('/notifications');
    await expect(page).toHaveURL(/\/notifications/, { timeout: 10000 });

    // See `notifications-channel-toggle.spec.js` for why this is
    // required (LiveView socket needs to join before `phx-submit`
    // hits the server-side `save` handler).
    await waitForLiveSocketConnected(page);

    await expect(page.locator('#notifications-form')).toBeVisible();

    // The wrapping <label> makes the title the accessible name for
    // the inner checkbox. `exact: true` so "Mid-day yield collapse"
    // can't accidentally match a future "Mid-day yield" sublabel.
    const yaToggle = page.getByLabel('Mid-day yield collapse', { exact: true });
    await expect(yaToggle).toBeAttached();

    // Reset to the documented default before turning it on —
    // protects against a stale-on-disk state from a previous run.
    if (await yaToggle.isChecked()) {
      await yaToggle.uncheck();
      await page.click('button:has-text("Save preferences")');
      await page.waitForTimeout(500);
      await page.reload();
      await expect(page).toHaveURL(/\/notifications/, { timeout: 10000 });
      await waitForLiveSocketConnected(page);
    }

    await expect(
      page.getByLabel('Mid-day yield collapse', { exact: true })
    ).not.toBeChecked();

    // Turn it on and save.
    await yaToggle.check();
    await expect(yaToggle).toBeChecked();
    await page.click('button:has-text("Save preferences")');

    // Brief wait for the LiveView round-trip + flash re-render
    // before reloading — mirrors the pattern in
    // `notifications.spec.js`.
    await page.waitForTimeout(500);

    // Hard reload — the seeded user would re-render with the
    // toggle OFF if the save hadn't persisted.
    await page.reload();
    await expect(page).toHaveURL(/\/notifications/, { timeout: 10000 });
    await waitForLiveSocketConnected(page);
    await expect(
      page.getByLabel('Mid-day yield collapse', { exact: true })
    ).toBeChecked();
  });
});
