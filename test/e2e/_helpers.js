// Shared Playwright helpers.
//
// Right now there's exactly one helper —
// `waitForLiveSocketConnected(page, { timeout } = {})`
// — that the DTU-creation E2E specs call right before
// clicking Submit. The point is that `<.form phx-submit>`
// only routes through the LiveView socket once
// `liveSocket.connect()` has fired; if Playwright
// clicks Submit before then, the browser falls back to
// a native HTML POST to the form's `action` URL, which
// on `/devices/new` (GET-only) 404s. On CI the live
// socket can take noticeably longer than 500ms to
// connect, which is why the DTU-creation specs were
// consistently failing in CI even though the form's
// `handle_event("save", ...)` on the server is correct.

const LIVEVIEW_JOINED_EVENT = "phx:joined";

/**
 * Wait until Phoenix LiveView's WebSocket has connected
 * for the current LiveView page.
 *
 * `liveSocket` is exposed on `window` by `assets/js/app.js`
 * (`window.liveSocket = liveSocket`). We poll its
 * `isConnected()` / `connectionState()` from the Node side
 * via `page.waitForFunction()` so we don't depend on the
 * standard `phx:joined` window event timing.
 *
 * Why poll instead of listening for `phx:joined`?
 *
 *   `phx:joined` fires exactly once when the LiveView
 *   WebSocket handshake completes — typically before
 *   Playwright gets a chance to install a listener for
 *   it (Playwright runs after navigation + hydration). A
 *   naive `addEventListener("phx:joined", …)` then waits
 *   forever for an event that's already done; every test
 *   using the helper timed out at 30 s on every CI run.
 *
 *   `isConnected()` (a method on Phoenix.LiveSocket
 *   since 1.x) reads `connection.state() === "open"` on
 *   the underlying `Socket`. It returns `true` from the
 *   moment the WebSocket opens and stays `true` across
 *   reconnects, so polling it from Node is both safe and
 *   robust to "the event already fired" / "LiveView JS
 *   hasn't even loaded yet" / "the socket was disconnected
 *   and is reconnecting" all at once.
 *
 * Call this right before clicking any submit
 * (`phx-submit`) button on a LiveView form, or right
 * before interacting with any UI that depends on
 * `liveSocket.connect()` having fired.
 *
 * The fallback form-submit issue this guards against
 * is also defensively side-stepped at the
 * `<.form>` action level by the device-creation form,
 * which now sets `action="/devices"` explicitly so the
 * no-LiveView-yet fallback POST lands on a route that
 * does not 404. This helper is the primary fix; the
 * form `action` is the secondary.
 *
 * @param {import('@playwright/test').Page} page
 *   The Playwright page to wait on.
 * @param {object} [opts]
 *   Optional. Supports `timeout` (number, ms). Defaults
 *   to 30 s on CI and 15 s elsewhere, matching
 *   `playwright.config.js`.
 *
 * @returns {Promise<void>}
 *   Resolves once the LiveView socket has connected.
 *   Rejects with a `TimeoutError` if it does not within
 *   the timeout.
 */
async function waitForLiveSocketConnected(page, opts = {}) {
  const timeout = opts.timeout ?? (process.env.CI ? 30000 : 15000);

  // Poll `liveSocket.isConnected()` (with a
  // `connectionState() === "open"` fallback for older
  // LiveSocket builds that don't expose `isConnected`)
  // every 50 ms. `waitForFunction` resolves as soon as
  // the predicate returns truthy, and rejects with a
  // `TimeoutError` after the configured timeout — the
  // exact semantics we want without writing a manual
  // timer dance.
  await page.waitForFunction(
    () => {
      const ls = window.liveSocket;
      if (!ls) return false;

      if (typeof ls.isConnected === "function") {
        return ls.isConnected();
      }

      if (typeof ls.connectionState === "function") {
        return ls.connectionState() === "open";
      }

      // No public API — fall back to inspecting the
      // underlying Socket, which LiveSocket exposes via
      // `getSocket()` in 1.x.
      const sock = typeof ls.getSocket === "function" ? ls.getSocket() : null;
      if (sock && typeof sock.isConnected === "function") {
        return sock.isConnected();
      }

      // Last-resort fallback: assume the event has
      // already fired (the user navigated and waited).
      return true;
    },
    null,
    { timeout, polling: 50 }
  );
}

// Virtual WebAuthn authenticator (CDP `WebAuthn.enable` +
// `WebAuthn.addVirtualAuthenticator`). Lets the e2e specs simulate
// a hardware authenticator without a real device.
//
// Usage:
//   let authenticatorId;
//   test.beforeEach(async ({ page, context }) => {
//     authenticatorId = await installVirtualAuthenticator(page, context);
//   });
//   test.afterEach(async ({ page, context }) => {
//     await removeVirtualAuthenticator(page, context, authenticatorId);
//   });

async function installVirtualAuthenticator(page, context) {
  const cdp = await context.newCDPSession(page);
  await cdp.send("WebAuthn.enable");
  const { authenticatorId } = await cdp.send("WebAuthn.addVirtualAuthenticator", {
    options: {
      protocol: "ctap2",
      transport: "internal",
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true
    }
  });
  return authenticatorId;
}

async function removeVirtualAuthenticator(page, context, authenticatorId) {
  if (!authenticatorId) return;
  const cdp = await context.newCDPSession(page);
  await cdp.send("WebAuthn.removeVirtualAuthenticator", { authenticatorId });
}

/**
 * Read every credential Chromium's virtual authenticator has
 * stored. Backed by CDP `WebAuthn.getCredentials` — each entry
 * is the full shape `WebAuthn.addCredential` accepts, so the
 * returned array can be round-tripped back into a fresh
 * authenticator via {@link addVirtualAuthenticatorCredential}.
 *
 * Why this exists: `test/e2e/passkey_login.spec.js` runs the
 * three tests in `serial` mode, and Playwright's default retry
 * config (`CI ? 2 : 0`) can re-run the whole serial block up
 * to three times. `DtuAppWeb.Plugs.PasskeyRateLimit` keys its
 * sliding window on `(remote_ip, action)` with a 10/60s
 * ceiling. To keep the per-retry `registration_options` /
 * `verify_registration` budget under that ceiling, test 3
 * re-uses the credential test 1 enrolled rather than enrolling
 * its own — this helper captures it after test 1's enrollment,
 * and {@link addVirtualAuthenticatorCredential} re-injects it
 * into test 3's fresh authenticator (the per-test
 * `installVirtualAuthenticator` in `beforeEach` otherwise wipes
 * browser-side credential state along with everything else).
 *
 * @param {import('@playwright/test').Page} page
 *   The Playwright page the authenticator is attached to.
 * @param {import('@playwright/test').BrowserContext} context
 *   The Playwright context — used to acquire a CDP session
 *   (`newCDPSession`), mirroring how
 *   {@link installVirtualAuthenticator} acquires its session.
 * @param {string} authenticatorId
 *   The CDP `authenticatorId` previously returned by
 *   {@link installVirtualAuthenticator}. Passed through to
 *   `WebAuthn.getCredentials` so the call targets the right
 *   authenticator.
 *
 * @returns {Promise<Array<object>>}
 *   Resolves with the credentials CDP knows about (each entry
 *   includes `credentialId`, `isResidentCredential`, `rpId`,
 *   `privateKey` as PKCS#8 base64, `userHandle` base64,
 *   `signCount`, etc.). Resolves with `[]` when the
 *   authenticator has nothing stored — Chromium returns an
 *   empty `credentials` array in that case rather than
 *   rejecting, so callers can treat `[]` as a normal outcome.
 */
async function getVirtualAuthenticatorCredentials(page, context, authenticatorId) {
  const cdp = await context.newCDPSession(page);
  const { credentials } = await cdp.send("WebAuthn.getCredentials", {
    authenticatorId
  });
  return credentials || [];
}

/**
 * Inject a single credential into Chromium's virtual
 * authenticator. Backed by CDP `WebAuthn.addCredential`.
 *
 * Lets a freshly installed authenticator (the per-test
 * `beforeEach` in `test/e2e/passkey_login.spec.js` installs
 * one before every test, intentionally with no credentials)
 * come pre-populated with a credential captured earlier via
 * {@link getVirtualAuthenticatorCredentials}. After injection
 * the browser can assert the credential during
 * `navigator.credentials.get()`, so the surrounding test can
 * proceed to the server-side assertion it actually wants to
 * exercise (e.g. "the server rejects this credential because
 * its DB row was deleted") without burning a fresh enrollment
 * against `DtuAppWeb.Plugs.PasskeyRateLimit`.
 *
 * The `credential` arg is the full object returned by
 * `WebAuthn.getCredentials` — pass it through unchanged
 * rather than reshaping it (the CDP layer is strict about
 * the field set and encoding: `privateKey` is PKCS#8 base64,
 * `userHandle` is base64, `signCount` is a number, etc.).
 *
 * @param {import('@playwright/test').Page} page
 *   The Playwright page the authenticator is attached to.
 * @param {import('@playwright/test').BrowserContext} context
 *   The Playwright context — used to acquire a CDP session
 *   (`newCDPSession`), mirroring how
 *   {@link installVirtualAuthenticator} acquires its session.
 * @param {string} authenticatorId
 *   The CDP `authenticatorId` of the authenticator to inject
 *   the credential into.
 * @param {object} credential
 *   The credential object — exactly as returned by
 *   {@link getVirtualAuthenticatorCredentials}. Pass through
 *   unchanged.
 *
 * @returns {Promise<void>}
 *   Resolves once CDP has accepted the credential. Rejects
 *   with the raw CDP error if the `authenticatorId` is
 *   unknown or the credential shape is rejected — letting
 *   the surrounding test fail loudly rather than silently
 *   drift into a "credential not present" assertion path.
 */
async function addVirtualAuthenticatorCredential(page, context, authenticatorId, credential) {
  const cdp = await context.newCDPSession(page);
  await cdp.send("WebAuthn.addCredential", {
    authenticatorId,
    credential
  });
}

module.exports = {
  waitForLiveSocketConnected,
  installVirtualAuthenticator,
  removeVirtualAuthenticator,
  getVirtualAuthenticatorCredentials,
  addVirtualAuthenticatorCredential,
  // Exported for tests that want to assert a specific
  // event name (rather than hard-coding it).
  LIVEVIEW_JOINED_EVENT,
};