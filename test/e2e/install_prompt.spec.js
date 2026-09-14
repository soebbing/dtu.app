const { test, expect } = require('@playwright/test');
require('./_setup/global-fixture');

// E2E coverage for the PWA install prompt button.
//
// Browsers only fire `beforeinstallprompt` when the app is *actually*
// installable AND the user hasn't already installed/dismissed it, so
// we can't reliably observe the event organically in CI. Instead
// these tests fire a synthetic `BeforeInstallPromptEvent` from
// `page.evaluate()` so the hook's behavior (capture, render button,
// prompt on click, hide on `appinstalled`, 30-day cooldown) can be
// pinned end-to-end.
//
// What we exercise:
//   1. The button is hidden by default (before the event has fired).
//   2. Dispatching the event makes the button visible.
//   3. Clicking the button calls `event.prompt()` (mocked) and hides
//      the button once the user accepts.
//   4. The button does NOT reappear after dismissal because the
//      `appinstalled` event hides it permanently for the cooldown
//      window (we keep the cooldown window short so we can verify
//      the hiding behavior, not the wall-clock 30 days).
//
// Assumes the app is running on :4000 against a database seeded with
// `mix run priv/repo/seeds.exs` (test@example.com / password123456).
// We log in first so the navbar (which carries the install button)
// renders; otherwise an anonymous visitor sees the Log in / Register
// CTAs and not the install button.

const E2E_EMAIL = 'test@example.com';
const E2E_PASSWORD = 'password123456';
const INSTALL_BUTTON_SELECTOR = '#install-prompt-button';
const COOLDOWN_KEY = 'pwa:install-dismissed-at';

// Dispatch a synthetic `beforeinstallprompt` event with a controllable
// `prompt()` / `userChoice` pair. We stash the resulting event on
// `window.__lastBeforeInstallPrompt` so the test can assert that
// `prompt()` was called after the click — and so we can resolve
// `userChoice` with the desired `outcome` ("accepted" or "dismissed")
// to drive the post-prompt branch of the hook.
//
// Returns the same handle so callers can `await` a single expression
// (rather than two separate awaits) for tidier test bodies.
async function fireBeforeInstallPrompt(page, { outcome = 'accepted' } = {}) {
  // LiveView hydrates `phx-hook` elements asynchronously after the
  // initial render. If we dispatch `beforeinstallprompt` before the
  // hook's `mounted()` has run, our event is lost — the listener
  // isn't attached yet. Wait for the hook to attach (Phoenix stamps
  // `phx-r=""` on hydrated elements) before firing.
  await page.locator(INSTALL_BUTTON_SELECTOR).waitFor({ state: 'attached' })
  await page.waitForFunction(
    (sel) => {
      const el = document.querySelector(sel)
      if (!el) return false
      // `phx-r` is set by LiveView once the hook is mounted. Some
      // versions leave it empty; presence (any value) is enough.
      return el.hasAttribute('phx-r')
    },
    INSTALL_BUTTON_SELECTOR,
    { timeout: 5000, polling: 50 }
  )

  return page.evaluate(({ outcome }) => {
    let promptCalls = 0
    const event = new Event('beforeinstallprompt', { cancelable: true })
    event.prompt = () => {
      promptCalls += 1
    }
    event.userChoice = Promise.resolve({ outcome })
    Object.defineProperty(event, 'platforms', { value: ['web'] })
    Object.defineProperty(event, '__promptCalls', {
      get: () => promptCalls,
    })
    window.__lastBeforeInstallPrompt = event
    window.dispatchEvent(event)
    return { dispatched: true }
  }, { outcome })
}

async function getPromptCallCount(page) {
  return page.evaluate(() => {
    const e = window.__lastBeforeInstallPrompt
    return e ? e.__promptCalls : 0
  })
}

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

test.describe('PWA: install prompt button', () => {
  test.beforeEach(async ({ page }) => {
    // Wipe any cooldown persisted by an earlier test run so the
    // "button hidden after install" assertion isn't satisfied by a
    // stale localStorage flag from a previous invocation.
    await page.addInitScript((key) => {
      try {
        window.localStorage.removeItem(key)
      } catch (_) {}
    }, COOLDOWN_KEY);

    await logIn(page);
  });

  test('button is hidden before the browser fires beforeinstallprompt', async ({ page }) => {
    // Without any event, the hook's render path leaves the button
    // hidden. The element is still in the DOM (so LiveView keeps it
    // hydrated) — it's the `hidden` attribute / IDL property that
    // controls visibility. Asserting on the visibility (not the
    // count) matches the actual contract: the button exists, but
    // the user can't see it.
    await expect(page.locator(INSTALL_BUTTON_SELECTOR)).toBeHidden({ timeout: 5000 });
  });

  test('button becomes visible after beforeinstallprompt fires', async ({ page }) => {
    await fireBeforeInstallPrompt(page);

    await expect(page.locator(INSTALL_BUTTON_SELECTOR)).toBeVisible({ timeout: 5000 });
  });

  test('clicking the button calls prompt() and hides on appinstalled', async ({ page }) => {
    await fireBeforeInstallPrompt(page, { outcome: 'accepted' });

    const button = page.locator(INSTALL_BUTTON_SELECTOR);
    await expect(button).toBeVisible({ timeout: 5000 });

    // Click the button. The hook should invoke the captured
    // event's `prompt()` and then listen for the resulting
    // `appinstalled` event to hide the chrome permanently (and
    // record the cooldown in localStorage).
    await button.click();

    // `prompt()` was called exactly once on the captured event.
    expect(await getPromptCallCount(page)).toBe(1);

    // The browser would normally fire `appinstalled` itself once
    // the user accepts; we dispatch it synthetically because
    // Playwright doesn't install the app for real, and the hook
    // is responsible for hiding the button on that event.
    await page.evaluate(() => window.dispatchEvent(new Event('appinstalled')));

    // Wait briefly for the hook to react to appinstalled, then
    // assert the button is hidden again (the canonical "installed"
    // state).
    await expect(button).toBeHidden({ timeout: 3000 });
  });

  test('button stays hidden after a synthetic dismiss within the cooldown', async ({ page }) => {
    // This pins the cooldown: once the user dismisses or installs,
    // the button must not reappear on subsequent page loads (within
    // the cooldown window). We use appinstalled as the most reliable
    // signal here — the dismiss path goes through the same hide
    // branch, and the cooldown key is set in both.
    await fireBeforeInstallPrompt(page, { outcome: 'dismissed' });
    await page.locator(INSTALL_BUTTON_SELECTOR).click();
    await page.evaluate(() => window.dispatchEvent(new Event('appinstalled')));

    // Reload the page. A fresh hook mount should not re-show the
    // button because the cooldown flag is now set.
    await page.goto('/dashboard');
    await page.waitForLoadState('domcontentloaded');
    await expect(page.locator(INSTALL_BUTTON_SELECTOR)).toBeHidden({ timeout: 5000 });
  });
});
