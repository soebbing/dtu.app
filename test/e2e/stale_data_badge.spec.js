const { test, expect } = require('@playwright/test');
require('./_setup/global-fixture');

// E2E coverage for the stale-data freshness badge.
//
// The badge sits at the top of the layout, above `<OfflineBanner>`,
// and tells the user how fresh the dashboard's data is — when the
// fleet stops publishing readings, when the LiveView socket drops,
// or when the browser itself is offline, the badge flips from
// "Updated 12s ago" to "Stale" / "Offline — last seen Xm ago".
//
// We don't have a real DTU broadcasting over MQTT in the test
// environment, so the badge's "fresh" state is driven by LiveView's
// own events (`phx:connected`, `phx:notify`) — any of those counts
// as a tick. The spec drives that by re-mounting the page after a
// synthetic `phx:notify` dispatch (so the hook sees a tick) and
// before/after firing `phx:disconnected` and the offline event.
//
// What we exercise:
//   1. The badge is hidden while a reading tick is recent (default
//      online + LiveView connected state).
//   2. Firing a synthetic reading tick flips the badge text to a
//      relative "Updated …" string.
//   3. Going offline (dispatching the window `offline` event) flips
//      the badge to an offline-style message.
//   4. The badge recovers to a fresh state once `online` fires
//      again and a tick comes in.
//
// Assumes the app is running on :4000 against a database seeded with
// `mix run priv/repo/seeds.exs` (test@example.com / password123456).

const E2E_EMAIL = 'test@example.com';
const E2E_PASSWORD = 'password123456';
const BADGE_SELECTOR = '#stale-data-badge';

async function logIn(page) {
  await page.goto('/');
  await page.getByRole('link', { name: 'Sign In' }).click();
  await expect(page).toHaveURL(/\/users\/log-in/, { timeout: 10000 });

  const form = page.locator('#login_form_password');
  await form.locator('input[type="email"]').fill(E2E_EMAIL);
  await form.locator('input[type="password"]').fill(E2E_PASSWORD);

  await form.getByRole('button', { name: /Log in/i }).click();
  await page.waitForURL(/\/dashboard/, { timeout: 15000 });
}

test.describe('PWA: stale-data freshness badge', () => {
  test.beforeEach(async ({ page }) => {
    await logIn(page);

    // LiveView hydrates `phx-hook` elements asynchronously after the
    // initial render. Wait for `phx-r=""` to appear so we know the
    // hook's `mounted()` has run before we start dispatching events.
    await page.waitForFunction(
      (sel) => {
        const el = document.querySelector(sel);
        return el && el.hasAttribute('phx-r');
      },
      BADGE_SELECTOR,
      { timeout: 5000, polling: 50 }
    );
  });

  test('badge is present and reports fresh on a normal page load', async ({ page }) => {
    // The hook stamps `data-freshness` on the root element so
    // observers can assert without coupling to the exact text
    // (which is localized).
    await expect(page.locator(BADGE_SELECTOR)).toHaveAttribute(
      'data-freshness',
      'fresh',
      { timeout: 5000 }
    );
  });

  test('badge updates its relative timestamp when a reading tick arrives', async ({ page }) => {
    // Capture the timestamp before the tick, fire a synthetic
    // `phx:notify` (the hook treats any such event as a "tick"),
    // then capture again and assert it moved forward.
    const before = await page.locator(BADGE_SELECTOR).getAttribute('data-last-tick');

    await page.evaluate(() => {
      // Phoenix uses `CustomEvent` with `detail` for `phx:notify`.
      // A real notification has shape `{title, body, tag, ...}`;
      // the hook doesn't read any of those fields — it just treats
      // any `phx:notify` as evidence the server is alive.
      window.dispatchEvent(
        new CustomEvent('phx:notify', { detail: {title: 'tick', body: ''} })
      )
    });

    await expect(page.locator(BADGE_SELECTOR)).toHaveAttribute(
      'data-last-tick',
      // Use a regex: the timestamp should be a positive integer
      // and strictly greater than the pre-tick value. Without
      // `>`, Playwright's string-equality would race the hook.
      // We instead assert it changed at all — the relative-time
      // text re-renders once the timestamp updates.
      new RegExp(`^(?!${before}$).+`),
      { timeout: 3000 }
    );
  });

  test('badge flips to offline when the browser fires the offline event', async ({ page }) => {
    await page.evaluate(() => {
      // The hook listens to both `online` and `offline` window
      // events. Note that dispatching `offline` doesn't actually
      // toggle `navigator.onLine` — but the hook doesn't read
      // that property at all, it just listens to the events.
      window.dispatchEvent(new Event('offline'))
    })

    await expect(page.locator(BADGE_SELECTOR)).toHaveAttribute(
      'data-freshness',
      'offline',
      { timeout: 3000 }
    );
  });

  test('badge flips to disconnected when LiveView drops the socket', async ({ page }) => {
    await page.evaluate(() => {
      // Phoenix fires `phx:disconnected` whenever the live socket
      // connection drops. We dispatch it synthetically here.
      window.dispatchEvent(new Event('phx:disconnected'))
    })

    await expect(page.locator(BADGE_SELECTOR)).toHaveAttribute(
      'data-freshness',
      'disconnected',
      { timeout: 3000 }
    );
  });

  test('badge recovers to fresh after a reconnect', async ({ page }) => {
    // Trip into disconnected…
    await page.evaluate(() => {
      window.dispatchEvent(new Event('phx:disconnected'))
    })
    await expect(page.locator(BADGE_SELECTOR)).toHaveAttribute(
      'data-freshness',
      'disconnected',
      { timeout: 3000 }
    )

    // …then fire `phx:connected` + a synthetic reading tick. The
    // hook should flip back to fresh and stamp a new tick.
    await page.evaluate(() => {
      window.dispatchEvent(new Event('phx:connected'))
      window.dispatchEvent(
        new CustomEvent('phx:notify', { detail: {title: 'tick'} })
      )
    })

    await expect(page.locator(BADGE_SELECTOR)).toHaveAttribute(
      'data-freshness',
      'fresh',
      { timeout: 3000 }
    )
  });
});
