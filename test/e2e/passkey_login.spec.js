// E2E coverage for the passkey login flow.
//
// We use Chromium's CDP `WebAuthn.enable` +
// `WebAuthn.addVirtualAuthenticator` (via `installVirtualAuthenticator`
// in `_helpers.js`) to register a software authenticator at the start of
// each test. This lets us drive the real
// `navigator.credentials.create/get` API without a hardware device.
//
// Headless Chromium does NOT support conditional mediation reliably, so
// all three tests use the explicit "Use a passkey" button rather than the
// autofill chip. The conditional-mediation path is covered by a manual
// smoke test in Task 9's checklist.
//
// Notes on the pages under test:
//
//   * `/users/log-in` and `/users/settings` are DEAD (controller-rendered)
//     pages, not LiveViews. `waitForLiveSocketConnected` is therefore not
//     applicable here — the PasskeyFlow hook is bound by the
//     `bootstrapDeadHooks()` shim in `assets/js/app.js`, which runs right
//     after `liveSocket.connect()`. `waitForPasskeyHook()` below waits for
//     that shim to have run.
//
//   * The PasskeyFlow hook SWALLOWS `NotAllowedError` by design (a
//     user-cancelled / refused authenticator prompt is not an error worth
//     showing). Test 2 asserts the resulting user-facing behaviour —
//     "nothing happens, the login form is still there" — rather than an
//     inline error banner, which would never appear for that failure mode.
//     Test 3's failure comes from the SERVER (the credential was deleted,
//     so `/auth/passkey/authentication/finish` rejects it), which DOES go
//     through `showError()`, so the banner assertion is valid there.

const { test, expect } = require('@playwright/test');
const {
  installVirtualAuthenticator,
  removeVirtualAuthenticator,
} = require('./_helpers');

// Seeded by `priv/repo/seeds.exs` (re-run by the Playwright globalSetup).
const E2E_EMAIL = 'test@example.com';
const E2E_PASSWORD = 'password123456';

/**
 * Wait until `assets/js/app.js` has run its `bootstrapDeadHooks()` shim,
 * which is what binds `phx-hook="PasskeyFlow"` on dead (non-LiveView)
 * pages. `window.liveSocket` is assigned immediately before the shim, so
 * "liveSocket present AND document fully loaded" is a reliable proxy.
 */
async function waitForPasskeyHook(page) {
  await page.waitForLoadState('load');
  await page.waitForFunction(() => !!window.liveSocket, null, {
    timeout: process.env.CI ? 30000 : 15000,
    polling: 50,
  });
}

/**
 * Click a "start the ceremony" passkey button.
 *
 * `dispatchEvent('click')` rather than `.click()`: on `/users/log-in` the
 * hook has a `navigator.credentials.get({mediation: "conditional"})`
 * outstanding from mount, and Chromium's conditional-UI machinery makes
 * Playwright's actionability/post-click settling hang until the action
 * timeout. The hook binds a plain `click` listener, so a dispatched event
 * drives exactly the same code path.
 */
async function clickPasskeyButton(page, cardSelector) {
  await page
    .locator(`${cardSelector} button[data-passkey-action='start']`)
    .dispatchEvent('click');
}

async function logInWithPassword(page) {
  await page.goto('/users/log-in');
  const form = page.locator('#login_form_password');
  await form.locator('input[type="email"]').fill(E2E_EMAIL);
  await form.locator('input[type="password"]').fill(E2E_PASSWORD);
  await form.locator('button').first().click();
  await page.waitForURL(/\/dashboard/, { timeout: 15000 });
}

/**
 * Log out. The nav renders `<.link href="/users/log-out" method="delete">`,
 * which `phoenix_html.js` turns into a generated hidden form on click. The
 * link exists twice (desktop nav + mobile menu) and visibility depends on
 * the viewport, so we submit the equivalent form ourselves instead of
 * hunting for the visible copy.
 */
async function logOut(page) {
  await page.goto('/dashboard');
  await page.evaluate(() => {
    const csrf = document
      .querySelector("meta[name='csrf-token']")
      .getAttribute('content');
    const form = document.createElement('form');
    form.method = 'post';
    form.action = '/users/log-out';
    form.innerHTML =
      '<input type="hidden" name="_method" value="delete">' +
      '<input type="hidden" name="_csrf_token">';
    form.querySelector("input[name='_csrf_token']").value = csrf;
    document.body.appendChild(form);
    form.submit();
  });
  await page.waitForURL(/\/(users\/log-in)?$/, { timeout: 15000 });
}

/** Enroll a passkey from `/users/settings` and wait for the reload. */
async function enrollPasskey(page, friendlyName) {
  await page.goto('/users/settings');
  await waitForPasskeyHook(page);

  await page.locator("#passkeys-card input[name='friendly_name']").fill(friendlyName);
  await clickPasskeyButton(page, '#passkeys-card');

  // The hook calls `location.reload()` on success; the enrolled key then
  // appears in the list.
  await expect(
    page.locator('#passkeys-card').getByText(friendlyName, { exact: false })
  ).toBeVisible({ timeout: 15000 });
}

/**
 * Stop the hook's conditional-mediation probe from reaching the server.
 *
 * On mount, `PasskeyFlow` fires a non-awaited
 * `POST /auth/passkey/authentication/begin` so the browser can offer an
 * autofill chip. That costs one `authentication_options` hit against
 * `DtuAppWeb.Plugs.PasskeyRateLimit`'s 10-per-60s-per-IP window on EVERY
 * visit to `/users/log-in` — including the plain password logins these
 * tests do — which trips the limiter partway through the file and turns
 * later tests into spurious 429 failures. It also leaves a
 * `navigator.credentials.get()` outstanding, which makes Chromium's
 * conditional-UI machinery stall Playwright's click actionability.
 *
 * We are not testing the conditional path (headless Chromium doesn't
 * support it reliably), so abort those requests and only let the ones the
 * tests explicitly trigger through.
 */
async function blockConditionalMediation(page) {
  let allow = false;

  await page.route('**/auth/passkey/authentication/begin', (route) =>
    allow ? route.continue() : route.abort()
  );

  return {
    // One-way switch, flipped immediately before the test clicks "Use a
    // passkey". It is not reset afterwards: the hook issues its fetch
    // asynchronously, so re-arming the block on the next tick would race
    // the very request we just enabled. Each test navigates to
    // `/users/log-in` at most once after flipping, so at most one extra
    // conditional probe gets through.
    allowBegin() {
      allow = true;
    },
  };
}

test.describe('Acceptance: Passkey login', () => {
  // Serial, not parallel: `PasskeyRateLimit` keys its sliding window on
  // (IP, ceremony action), and every worker here shares the loopback IP.
  test.describe.configure({ mode: 'serial' });

  let authenticatorId;
  let mediation;

  test.beforeEach(async ({ page, context }) => {
    authenticatorId = await installVirtualAuthenticator(page, context);
    mediation = await blockConditionalMediation(page);
  });

  test.afterEach(async ({ page, context }) => {
    await removeVirtualAuthenticator(page, context, authenticatorId).catch(() => {});
    authenticatorId = null;
  });

  test('enroll → log out → log back in with passkey', async ({ page }) => {
    await logInWithPassword(page);

    await enrollPasskey(page, 'MacBook Touch ID');

    await logOut(page);

    // ---- Authenticate with the passkey ----
    await page.goto('/users/log-in');
    await waitForPasskeyHook(page);
    mediation.allowBegin();
    await clickPasskeyButton(page, '#passkey-login-card');

    // The hook follows `body.redirect` from the finish endpoint.
    await page.waitForURL(/\/(dashboard|)$/, { timeout: 15000 });
    await expect(page).not.toHaveURL(/\/users\/log-in/);
  });

  test('failed passkey authentication falls back to email + password', async ({ page, context }) => {
    await logInWithPassword(page);
    await enrollPasskey(page, 'Doomed Key');
    await logOut(page);

    // ---- Make the ceremony fail ----
    // CDP has no "refuse this assertion" flag, so we remove the virtual
    // authenticator entirely. `navigator.credentials.get()` then rejects
    // with NotAllowedError — which the hook deliberately swallows (it is
    // indistinguishable from the user cancelling the OS prompt). So the
    // user-visible outcome is "the button does nothing": no redirect, the
    // login form is still there, and email + password still works.
    await removeVirtualAuthenticator(page, context, authenticatorId);
    authenticatorId = null;

    await page.goto('/users/log-in');
    await waitForPasskeyHook(page);
    mediation.allowBegin();
    await clickPasskeyButton(page, '#passkey-login-card');

    // No redirect: still on the login page, form still rendered.
    await expect(page).toHaveURL(/\/users\/log-in/);
    await expect(page.locator('#login_form_password')).toBeVisible();
    // And no spurious error banner (NotAllowedError is silent by design).
    await expect(page.locator('#passkey-login-card [data-passkey-error]')).toBeHidden();

    // ---- Email + password fallback still works ----
    const form = page.locator('#login_form_password');
    await form.locator('input[type="email"]').fill(E2E_EMAIL);
    await form.locator('input[type="password"]').fill(E2E_PASSWORD);
    await form.locator('button').first().click();
    await page.waitForURL(/\/dashboard/, { timeout: 15000 });
  });

  test('removing a passkey makes it unusable for the next login', async ({ page }) => {
    await logInWithPassword(page);
    await enrollPasskey(page, 'To Remove');

    // The remove link is `<.link method="post" data-confirm=...>`, which
    // `phoenix_html.js` turns into a generated form gated behind
    // `window.confirm`.
    const deleteResponse = page.waitForResponse(
      (r) => /\/users\/settings\/passkeys\/.*\/delete$/.test(r.url())
    );
    // Target the Remove link in THIS passkey's row. `.first()` would hit
    // whichever key sorts first — earlier tests in this file enroll their
    // own keys against the same seeded user and nothing cleans them up
    // between tests, so the list is not guaranteed to hold just one.
    page.once('dialog', (dialog) => dialog.accept());
    await page
      .locator('#passkeys-card li')
      .filter({ hasText: 'To Remove' })
      .getByRole('link', { name: /Remove/i })
      .click();
    await deleteResponse;

    // The app registers a Service Worker, and the GET that follows the
    // delete's 302 can be answered from its cache — showing the passkey
    // that was just removed. Re-navigate explicitly so the assertion sees
    // server-rendered state.
    await page.goto('/users/settings');
    await expect(
      page.locator('#passkeys-card').getByText('To Remove', { exact: false })
    ).toHaveCount(0, { timeout: 15000 });

    await logOut(page);

    // The credential still lives in the virtual authenticator, so
    // `navigator.credentials.get()` succeeds — but the server no longer
    // knows it, so `/finish` rejects and the hook surfaces the banner.
    await page.goto('/users/log-in');
    await waitForPasskeyHook(page);
    mediation.allowBegin();
    await clickPasskeyButton(page, '#passkey-login-card');

    await expect(
      page.locator('#passkey-login-card [data-passkey-error]')
    ).toBeVisible({ timeout: 15000 });
    await expect(page).toHaveURL(/\/users\/log-in/);
  });
});
