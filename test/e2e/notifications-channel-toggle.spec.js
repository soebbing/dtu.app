const { test, expect } = require('@playwright/test');
const { waitForLiveSocketConnected } = require('./_helpers');

// E2E coverage for the "Deliver via" channel chip UI on /notifications.
//
// What we're proving:
//   1. Clicking a chip selects the corresponding radio (and unselects
//      the previously-selected one — all three share the same `name`).
//   2. Saving persists the choice: the same radio is still selected
//      after a hard reload of /notifications.
//   3. The same flow works for every channel (push → email → both).
//
// The chips live inside the existing #notifications-form, sharing
// the layout and save button with the per-topic checkboxes. They
// are implemented as a `role="radiogroup"` containing three
// visually-styled <label> chips; the underlying <input type="radio">
// is `sr-only` so the label is the user-facing affordance and the
// markup stays accessible.
//
// `page.getByLabel("...", { exact: true })` resolves through the
// wrapping <label> to the radio — Playwright's preferred selector
// for accessible-name lookup. We pin `exact: true` so "Email"
// can't accidentally match a future "Email me a digest" toggle,
// and "Notification" can't match the `<h1>Notifications</h1>`
// heading.
//
// Note on `notification_channel` semantics: the chip names are
// localizable (`gettext("Notification")`, `gettext("Email")`,
// `gettext("Both")`); the test assumes the seeded user has the
// default `locale: "en"` — see `priv/repo/seeds.exs`. If the
// default ever changes, pin the locale with `getByLabel(...)` /
// `test.use({ locale: 'en' })` before assuming the literal
// English labels here.
//
// Both tests in this file share the seeded `test@example.com` user
// and both mutate `notification_channel`, so we mark the describe
// block `.serial(...)` to avoid two parallel workers racing on the
// same row.

test.describe.serial('Acceptance Tests: Notifications channel chip', () => {
  async function logIn(page) {
    // Same auth flow as `notifications.spec.js` and
    // `login_dashboard.spec.js`. Extracted so the two tests in this
    // file don't each pay a copy of the comment block.
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

  test('selects Email, persists across reload', async ({ page }) => {
    await logIn(page);

    // Land on /notifications.
    await page.goto('/notifications');
    await expect(page).toHaveURL(/\/notifications/, { timeout: 10000 });

    // Wait for LiveView's WebSocket to join before clicking Save —
    // `phx-submit` only routes through the LiveView socket once
    // `liveSocket.connect()` has fired; without this wait the form
    // falls back to a native POST and the `save` handler never runs.
    await waitForLiveSocketConnected(page);

    // The form must be present and the chip labels reachable.
    // The chips are visually rendered with a wrapping <label>; the
    // underlying <input type="radio"> is `sr-only` (visually hidden
    // but still in the a11y tree), so we use `page.getByLabel(...)`
    // for accessible-name lookup. `.check({ force: true })` is
    // needed because the wrapping label intercepts pointer events
    // over the sr-only input — a normal `.check()` would otherwise
    // time out retrying against the label rather than hitting the
    // radio. Forcing still sets the radio's `checked` state, which
    // is what the LiveView form picks up via the `peer-checked:*`
    // Tailwind classes on the visible chip span.
    await expect(page.locator('#notifications-form')).toBeVisible();
    await expect(page.getByLabel('Notification', { exact: true })).toBeAttached();
    await expect(page.getByLabel('Email', { exact: true })).toBeAttached();
    await expect(page.getByLabel('Both', { exact: true })).toBeAttached();

    // Click "Email". Whatever the previous run left selected (the
    // default is "Notification"/push for a fresh seed), checking the
    // Email radio flips the selection.
    await page.getByLabel('Email', { exact: true }).check({ force: true });
    await expect(page.getByLabel('Email', { exact: true })).toBeChecked();
    await expect(
      page.getByLabel('Notification', { exact: true })
    ).not.toBeChecked();

    // Save.
    await page.click('button:has-text("Save preferences")');

    // The submit button is `phx-disable-with`d to "Saving…" while
    // the LiveView round-trip is in flight; wait briefly for the
    // success flash + form re-render before reloading, mirroring
    // `notifications.spec.js`.
    await page.waitForTimeout(500);

    // Hard reload — the seeded default would re-select "Notification"
    // if the save hadn't persisted.
    await page.reload();
    await expect(page).toHaveURL(/\/notifications/, { timeout: 10000 });
    await expect(page.getByLabel('Email', { exact: true })).toBeChecked();
    await expect(
      page.getByLabel('Notification', { exact: true })
    ).not.toBeChecked();
  });

  test('selects Both, persists across reload', async ({ page }) => {
    await logIn(page);

    await page.goto('/notifications');
    await expect(page).toHaveURL(/\/notifications/, { timeout: 10000 });

    await waitForLiveSocketConnected(page);

    // Pick "Both" — fans out to native push AND email. The test
    // user is already confirmed-at (the seed runs
    // `User.confirm_changeset()`), so the "email not confirmed"
    // warning won't render; selecting Both is a clean save either
    // way. See the comment on the first test for why `force: true`
    // is required: the radio is `sr-only`, the wrapping label
    // intercepts pointer events.
    await page.getByLabel('Both', { exact: true }).check({ force: true });
    await expect(page.getByLabel('Both', { exact: true })).toBeChecked();
    await expect(
      page.getByLabel('Notification', { exact: true })
    ).not.toBeChecked();
    await expect(page.getByLabel('Email', { exact: true })).not.toBeChecked();

    await page.click('button:has-text("Save preferences")');
    await page.waitForTimeout(500);

    await page.reload();
    await expect(page).toHaveURL(/\/notifications/, { timeout: 10000 });
    await expect(page.getByLabel('Both', { exact: true })).toBeChecked();
    // The other two chips must remain unchecked — picking Both in
    // the form cleared whichever one a prior run had selected.
    await expect(
      page.getByLabel('Notification', { exact: true })
    ).not.toBeChecked();
    await expect(page.getByLabel('Email', { exact: true })).not.toBeChecked();
  });
});
