const { test, expect } = require('@playwright/test');
const { waitForLiveSocketConnected } = require('./_helpers');
require('./_setup/global-fixture');

// E2E coverage for the new "Mid-day yield collapse" toggle on
// /notifications (added by the yield-anomaly-notifications feature).
//
// The new toggle mirrors the existing per-topic checkboxes
// (`:notify_dtu_connection`, `:notify_sun_down`, `:notify_sun_up`):
// a plain `<input type="checkbox">` inside a wrapping
// `<label class="flex items-start gap-3 cursor-pointer">` that
// also contains the title and the description spans.
//
// What we're proving:
//   1. The new toggle is present and bound to
//      `user[notify_yield_anomaly]` (i.e. the
//      `:notify_yield_anomaly` field is in
//      `User.notification_settings_changeset/2` and rendered by
//      the LiveView template).
//   2. Toggling it on, saving, and reloading persists the value
//      on the user record.
//
// Why `id="#user_notify_yield_anomaly"` and not `getByLabel`:
// the wrapping <label> has no `for=` attribute, so its
// accessible name concatenates the title AND the description
// span ("Mid-day yield collapse A heads-up if your fleet…").
// `getByLabel('Mid-day yield collapse', { exact: true })` will
// never match the whole-label text. Phoenix's `<.input field=
// {@form[:notify_yield_anomaly]}>` renders the checkbox with
// `id="user_notify_yield_anomaly"` — that's the stable handle we
// use here. `notifications.spec.js` uses the legacy positional
// selector (`page.locator('input[type="checkbox"]').first()`)
// because no per-field `id` was needed there; the new toggle
// rides on the form-field id so a future insert into the same
// form doesn't reorder this test.
//
// Defaults:
//   * `User.notify_yield_anomaly` ships as `false` — the migration
//     adds the column with `default: false` so existing users
//     don't start receiving the new alert on deploy.
//   * The seeded test user starts with all toggles off; if a
//     prior spec run left this one on, we explicitly uncheck
//     before toggling on again.

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

    // Phoenix `<.input field={@form[:notify_yield_anomaly]}>` renders
    // `<input id="user_notify_yield_anomaly" type="checkbox">`.
    const yaToggle = page.locator('#user_notify_yield_anomaly');
    await expect(yaToggle).toBeAttached();
    await expect(yaToggle).not.toBeChecked();

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

    await expect(page.locator('#user_notify_yield_anomaly')).not.toBeChecked();

    // Turn it on and save.
    await page.locator('#user_notify_yield_anomaly').check();
    await expect(page.locator('#user_notify_yield_anomaly')).toBeChecked();
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
    await expect(page.locator('#user_notify_yield_anomaly')).toBeChecked();
  });
});
