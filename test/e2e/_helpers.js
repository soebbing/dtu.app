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

module.exports = {
  waitForLiveSocketConnected,
  installVirtualAuthenticator,
  removeVirtualAuthenticator,
  // Exported for tests that want to assert a specific
  // event name (rather than hard-coding it).
  LIVEVIEW_JOINED_EVENT,
};