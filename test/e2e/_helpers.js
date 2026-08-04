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
 * for the current LiveView page. LiveView dispatches the
 * standard `phx:joined` event on `window` once the
 * `liveSocket.connect()` handshake completes; this
 * helper installs a one-shot listener for that event
 * (with the requested timeout) and resolves.
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

  // Playwright's documented pattern for waiting on a
  // window event from a test is to install the listener
  // on `window`, store the resolver on `window` so the
  // `page.evaluate(...)` callback can resolve it, and
  // race against `setTimeout(...)`. See the
  // `@playwright/test` docs and the LiveView source for
  // the `phx:joined` event.
  await page.evaluate(
    ([eventName, timeoutMs]) => {
      return new Promise((resolve, reject) => {
        const handle = () => {
          clearTimeout(timeoutHandle);
          window.removeEventListener(eventName, handle);
          resolve();
        };

        const timeoutHandle = setTimeout(() => {
          window.removeEventListener(eventName, handle);
          reject(
            new Error(
              `Timed out after ${timeoutMs} ms waiting for ` +
              `the LiveView socket to connect (no '${eventName}' ` +
              `window event). The page may not have a LiveView ` +
              `mount, or LiveView JavaScript failed to load.`
            )
          );
        }, timeoutMs);

        window.addEventListener(eventName, handle, { once: true });
      });
    },
    [LIVEVIEW_JOINED_EVENT, timeout],
    { timeout }
  );
}

module.exports = {
  waitForLiveSocketConnected,
  // Exported for tests that want to assert a specific
  // event name (rather than hard-coding it).
  LIVEVIEW_JOINED_EVENT,
};
