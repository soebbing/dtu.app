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
// All three tests share a SINGLE enrolled passkey (named
// `SHARED_KEY_NAME` below). Tests 2 and 3 reuse the credential enrolled
// by test 1 instead of enrolling their own. Why:
//
//   `DtuAppWeb.Plugs.PasskeyRateLimit` caps each `(127.0.0.1, <action>)`
//   pair at 10 hits per 60 s. In CI the Playwright config retries each
//   serial block up to 2 more times (3 attempts total), and `serial`
//   mode means a failure retries the WHOLE block — so enrollment would
//   otherwise burn `registration_options` + `verify_registration` hits
//   three times in one window. Sharing a single enrollment keeps every
//   per-action counter under the budget even at full retry pressure
//   (max 6 hits per action across all attempts; the 10/60s ceiling has
//   headroom to spare — see also the per-attempt-to-retry math
//   immediately below).
//
//   Test 3 doesn't re-enroll either — it captures the credential test 1
//   enrolled (via `getVirtualAuthenticatorCredentials`) and re-injects
//   it into the fresh authenticator test 3's `beforeEach` installs
//   (via `addVirtualAuthenticatorCredential`). Without that injection,
//   test 3's authenticator would be empty and the browser-side
//   `navigator.credentials.get()` would have nothing to assert, so
//   test 3 would have to enroll — bringing the per-retry
//   `registration_options` / `verify_registration` budget to 12 hits
//   per action (3 attempts × 2 enrollments × 2 calls), tripping the
//   rate limiter and surfacing `Passkey error: too_many_attempts` on
//   the settings page during test 1's enrollment. The injection
//   halves that, to a comfortable 6 hits per action across all three
//   attempts.
//
//   Test 1 still covers "enroll, log out, log in with passkey" exactly
//   as before — it owns the enrollment. Test 2 covers the
//   failed-ceremony fallback by removing the virtual authenticator
//   (no fresh enrollment needed; the server-side
//   `authentication_options` + the browser's `NotAllowedError` are
//   independent of how many keys exist on the server). Test 3 covers
//   "removing a passkey makes it unusable" by deleting the shared key
//   and then attempting to authenticate with it — the server-side
//   `verify_authentication` rejection is what makes the login fail,
//   which is the whole point of the assertion.
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
  getVirtualAuthenticatorCredentials,
  addVirtualAuthenticatorCredential,
} = require('./_helpers');
// Side-effect import: registers a `test.beforeEach` that aborts the
// passkey `fireConditionalMediation` probe (`POST
// /auth/passkey/authentication/begin` fired by the `PasskeyFlow` hook
// on every `/users/log-in` mount). Without this every visit to the
// login page would burn one `authentication_options` hit against
// `DtuAppWeb.Plugs.PasskeyRateLimit`'s 10/60s/IP budget and trip the
// limiter partway through the suite. `allowBegin` is the per-page
// one-shot escape hatch used right before the "Use a passkey" button
// click — see `test/e2e/_setup/global-fixture.js`.
const { allowBegin } = require('./_setup/global-fixture');

// Seeded by `priv/repo/seeds.exs` (re-run by the Playwright globalSetup).
const E2E_EMAIL = 'test@example.com';
const E2E_PASSWORD = 'password123456';

// One enrolled passkey, shared by all three tests in this file. See
// the top-of-file comment for the rate-limit-budget rationale.
const SHARED_KEY_NAME = 'MacBook Touch ID';

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
  // appears in the list. Wait for the visible list AND for the reload
  // itself to fully settle (`networkidle`), so subsequent navigations
  // in the same test don't race the still-in-flight reload and surface
  // as `ERR_ABORTED`.
  await expect(
    page.locator('#passkeys-card').getByText(friendlyName, { exact: false })
  ).toBeVisible({ timeout: 15000 });
  await page.waitForLoadState('networkidle');
}

/**
 * Remove every passkey on the settings page whose friendly name matches
 * the given string. The Remove link is
 * `<.link method="post" data-confirm=...>`, which `phoenix_html.js`
 * turns into a generated form gated behind `window.confirm`.
 *
 * Used at the start of test 1 to wipe any leftover passkeys from a
 * previous retry of this serial block (the seeds wipe the DB only once
 * per `npx playwright test` invocation, not per retry), so each retry
 * begins from a clean "0 keys with this name" state. Also used inside
 * test 3 to wipe everything before deleting + attempting to log in.
 *
 * Always uses `page.goto('/users/settings')` (not `page.reload()`):
 * after `PasskeyFlow`'s post-enrollment `location.reload()`, a second
 * `page.reload()` races the in-flight navigation and surfaces as
 * `ERR_ABORTED`. `goto` to the same URL still triggers a fresh request
 * and is more deterministic — `waitForPasskeyHook` then guarantees the
 * hook has re-bound before the loop runs.
 */
async function removeAllPasskeysNamed(page, friendlyName) {
  await page.goto('/users/settings');
  await waitForPasskeyHook(page);

  while (
    (await page
      .locator('#passkeys-card li')
      .filter({ hasText: friendlyName })
      .count()) > 0
  ) {
    const deleteResponse = page.waitForResponse(
      (r) => /\/users\/settings\/passkeys\/.*\/delete$/.test(r.url())
    );
    page.once('dialog', (dialog) => dialog.accept());
    await page
      .locator('#passkeys-card li')
      .filter({ hasText: friendlyName })
      .getByRole('link', { name: /Remove/i })
      .first()
      .click();
    await deleteResponse;

    // The app registers a Service Worker, and the GET that follows the
    // delete's 302 can be answered from its cache — showing the passkey
    // that was just removed. Re-navigate explicitly so the assertion sees
    // server-rendered state.
    await page.goto('/users/settings');
    await waitForPasskeyHook(page);
  }
}

test.describe('Acceptance: Passkey login', () => {
  // Serial, not parallel: `PasskeyRateLimit` keys its sliding window on
  // (IP, ceremony action), and every worker here shares the loopback IP.
  test.describe.configure({ mode: 'serial' });

  let authenticatorId;
  // Captured by test 1 after its `enrollPasskey` succeeds, then
  // re-injected into the fresh authenticator test 3's `beforeEach`
  // installs — see the top-of-file comment for the rate-limit-budget
  // rationale. `null` until test 1 runs at least once.
  let cachedCredential = null;

  test.beforeEach(async ({ page, context }, testInfo) => {
    authenticatorId = await installVirtualAuthenticator(page, context);
    // Test 3 needs an already-enrolled credential to attempt
    // authentication after deleting its DB row. Without injection,
    // test 3's fresh authenticator has nothing to assert and test 3
    // would have to enroll — see top-of-file comment for the budget
    // math. The `testInfo.title` guard matters because injecting on
    // test 1's `beforeEach` would put a stale (post-retry) credential
    // into an empty fresh authenticator; test 1 always enrolls fresh,
    // so injecting at that point is harmless but pointless.
    if (
      cachedCredential &&
      testInfo.title === 'removing a passkey makes it unusable for the next login'
    ) {
      await addVirtualAuthenticatorCredential(
        page,
        context,
        authenticatorId,
        cachedCredential
      );
    }
  });

  test.afterEach(async ({ page, context }) => {
    await removeVirtualAuthenticator(page, context, authenticatorId).catch(() => {});
    authenticatorId = null;
  });

  test('enroll → log out → log back in with passkey', async ({ page, context }) => {
    await logInWithPassword(page);

    // Wipe any leftover passkeys from a previous retry of this serial
    // block before enrolling — see top-of-file comment. The seeds run
    // only once per `npx playwright test` invocation, so a failed-then-
    // retried block can otherwise land here with the previous attempt's
    // row still present.
    await removeAllPasskeysNamed(page, SHARED_KEY_NAME);

    await enrollPasskey(page, SHARED_KEY_NAME);

    // Stash the fresh credential so test 3 (which runs later in this
    // `serial` block) can inject it into its own authenticator instead
    // of enrolling again — see top-of-file comment for the
    // rate-limit-budget rationale. Exactly one credential exists at
    // this point: test 1 just enrolled, `removeAllPasskeysNamed` wiped
    // any leftovers above, and no other test has touched the
    // authenticator yet.
    const credentials = await getVirtualAuthenticatorCredentials(
      page,
      context,
      authenticatorId
    );
    cachedCredential = credentials[0];

    await logOut(page);

    // ---- Authenticate with the passkey ----
    await page.goto('/users/log-in');
    await waitForPasskeyHook(page);
    await allowBegin(page);
    await clickPasskeyButton(page, '#passkey-login-card');

    // The hook follows `body.redirect` from the finish endpoint.
    //
    // `page.waitForURL` with default `waitUntil: "load"` would race
    // the navigation here: the hook drives `window.location.href =
    // body.redirect`, and the `load` event isn't always observed by
    // Playwright within the timeout — the dev server's slow `/dashboard`
    // render plus any pre-fetched service-worker content leaves the
    // `load` lifecycle event un-fired. `waitForFunction` polling
    // `window.location.pathname` directly is independent of the page's
    // lifecycle and stops the moment the browser actually committed
    // the new URL.
    await page.waitForFunction(
      () => window.location.pathname === '/' || window.location.pathname === '/dashboard',
      null,
      { timeout: 15000, polling: 50 }
    );
    await expect(page).not.toHaveURL(/\/users\/log-in/);
  });

  test('failed passkey authentication falls back to email + password', async ({ page, context }) => {
    await logInWithPassword(page);
    await logOut(page);

    // Re-uses the key enrolled by the FIRST test in this serial block —
    // see top-of-file comment. The failure mode we exercise here is
    // "the browser refused to assert" (NotAllowedError), which has
    // nothing to do with how many keys the server knows about.

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
    await allowBegin(page);
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

    // `beforeEach` installed a fresh virtual authenticator AND injected
    // the credential test 1 enrolled (see top-of-file comment for why).
    // No re-enrollment is needed — the injected credential matches the
    // DB row test 1 left behind, so `removeAllPasskeysNamed` below
    // wipes exactly that row, and the subsequent authentication
    // attempt fails server-side (server no longer knows the
    // credential) rather than browser-side.
    //
    // The remove link is `<.link method="post" data-confirm=...>`,
    // which `phoenix_html.js` turns into a generated form gated
    // behind `window.confirm`. `removeAllPasskeysNamed` wipes every
    // row matching the friendly name so the `.getByRole` below sees
    // exactly one match (Playwright strict mode would otherwise error
    // on a retry that left a duplicate row from the previous attempt).
    await removeAllPasskeysNamed(page, SHARED_KEY_NAME);

    // The app registers a Service Worker, and the GET that follows the
    // delete's 302 can be answered from its cache — showing the passkey
    // that was just removed. Re-navigate explicitly so the assertion sees
    // server-rendered state.
    await page.goto('/users/settings');
    await expect(
      page.locator('#passkeys-card').getByText(SHARED_KEY_NAME, { exact: false })
    ).toHaveCount(0, { timeout: 15000 });

    await logOut(page);

    // The credential still lives in the virtual authenticator, so
    // `navigator.credentials.get()` succeeds — but the server no longer
    // knows it, so `/finish` rejects and the hook surfaces the banner.
    await page.goto('/users/log-in');
    await waitForPasskeyHook(page);
    await allowBegin(page);
    await clickPasskeyButton(page, '#passkey-login-card');

    await expect(
      page.locator('#passkey-login-card [data-passkey-error]')
    ).toBeVisible({ timeout: 15000 });
    await expect(page).toHaveURL(/\/users\/log-in/);
  });
});
