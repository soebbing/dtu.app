// Global Playwright fixture that blocks the passkey
// `fireConditionalMediation` probe from reaching the server.
//
// Why this is necessary
// ---------------------
//
// `assets/js/hooks/passkey_flow.js` fires a non-awaited
// `POST /auth/passkey/authentication/begin` on every mount of
// `data-kind="authentication"` (i.e. on every visit to
// `/users/log-in`) so the browser can offer an autofill chip. The
// server-side `DtuAppWeb.Plugs.PasskeyRateLimit` caps each
// `(127.0.0.1, "authentication_options")` pair at 10 hits per 60 s.
//
// Only `passkey_login.spec.js` used to install a route abort; the
// other ~15 specs that visit `/users/log-in` to log in with email +
// password leaked one probe per visit. Across a `--workers=1` CI run
// that easily exceeds the 10/60s ceiling, and `passkey_login.spec.js`
// — which runs LAST alphabetically — trips the limiter before its
// own conditional probe even gets a chance to succeed.
//
// This fixture replaces the per-spec `blockConditionalMediation()`
// helper and applies to EVERY spec via a `require()` from each
// `test/e2e/*.spec.js` file (Playwright rejects `test.beforeEach()`
// called from a config file or from a file the config requires — see
// https://playwright.dev/docs/api/class-test#test-before-each — so a
// pure-config approach is not an option).
//
// Per-test semantics
// ------------------
//
// By default, every request to `/auth/passkey/authentication/begin`
// is aborted (the same effect as the old per-spec helper before
// `allowBegin()` was called).
//
// `passkey_login.spec.js` calls `allowBegin(page)` right before
// clicking the "Use a passkey" button, which sets a one-shot flag
// scoped to that page: the NEXT request to that URL is allowed
// through, the one after that is aborted again. This mirrors the
// old per-spec helper exactly so the passkey tests keep working
// unchanged in behaviour — only the wiring moves.
//
// Every other spec just gets the unconditional block for free.

const { test } = require('@playwright/test');

// Per-page one-shot flag: when `true`, the next request to
// `/auth/passkey/authentication/begin` is allowed through, then the
// flag is reset to `false`. Captured in closure by `page.route()`
// so each test page has its own copy.
const pageStates = new WeakMap();

test.beforeEach(async ({ page }) => {
  const state = { allowBegin: false };
  pageStates.set(page, state);

  await page.route('**/auth/passkey/authentication/begin', (route) => {
    if (state.allowBegin) {
      state.allowBegin = false;
      return route.continue();
    }
    return route.abort();
  });
});

/**
 * Allow the next `POST /auth/passkey/authentication/begin` request
 * issued by `page` to reach the server. One-shot per page: the
 * flag is consumed by the next matching request so the
 * conditional-mediation probe on the FOLLOWING navigation is
 * aborted again (which is what we want — only the request the
 * test explicitly triggers should leak).
 *
 * Required by `passkey_login.spec.js` between
 * `page.goto('/users/log-in')` + `waitForPasskeyHook(page)` and
 * `clickPasskeyButton(page, ...)`.
 */
async function allowBegin(page) {
  const state = pageStates.get(page);
  if (state) state.allowBegin = true;
}

module.exports = { allowBegin };
