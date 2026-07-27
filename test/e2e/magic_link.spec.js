// End-to-end test for the passwordless / magic-link login flow.
//
// Requires Mailpit to be reachable at MAILPIT_URL (default
// http://localhost:8025 in CI and on the host during local dev). The Phoenix
// app is configured with MAIL_DELIVERY=mailpit in CI so transactional email
// lands in the Mailpit inbox instead of being swallowed by the in-memory
// adapter.
const { test, expect, request } = require('@playwright/test');

const MAILPIT_URL = process.env.MAILPIT_URL || 'http://localhost:8025';
// The CI-seeded user, also used by login_dashboard.spec.js and
// dashboard_historical.spec.js.
const USER_EMAIL = 'test@example.com';

async function clearInbox(api) {
  await api.delete(`${MAILPIT_URL}/api/v1/messages`);
}

async function fetchMagicLink(api, {
  subjectContains = 'log in',
  toEmail,
  timeoutMs = 15_000,
  pollMs = 250
} = {}) {
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    const res = await api.get(`${MAILPIT_URL}/api/v1/messages?limit=50`);
    expect(res.ok(), `Mailpit API ${res.status()}`).toBeTruthy();
    const messages = (await res.json()).messages ?? [];

    const match = messages.find((m) => {
      const subjectOk = !subjectContains ||
        (m.Subject ?? '').toLowerCase().includes(subjectContains.toLowerCase());
      const recipientOk = !toEmail ||
        (m.To ?? []).some((t) => (t.Address ?? '') === toEmail);
      return subjectOk && recipientOk;
    });

    if (match) {
      // Prefer the raw RFC822 source so we don't have to parse Swoosh's HTML
      // formatting — the magic link is just an <a href="…"> in either Body.
      const raw = await api.get(`${MAILPIT_URL}/api/v1/message/${match.ID}/raw`);
      const text = await raw.text();
      const link = text.match(/https?:\/\/[^\s"<>]*\/users\/log-in\/[A-Za-z0-9_-]+/);
      if (link) return { message: match, link: link[0] };
    }

    await new Promise((r) => setTimeout(r, pollMs));
  }

  throw new Error(
    `No magic-link email for ${toEmail} arrived in Mailpit within ${timeoutMs}ms`
  );
}

test.describe('Acceptance Tests: Magic-Link Login (Mailpit SMTP capture)', () => {
  test('passwordless login sends a magic link via Mailpit that logs the user in', async ({ page, playwright }) => {
    const api = await request.newContext({ baseURL: MAILPIT_URL });

    try {
      // Start with a clean inbox so we don't pick up a stale link from a
      // previous test run or a manual smoke test.
      await clearInbox(api);

      // 1. Visit the login page and request a magic link.
      await page.goto('/users/log-in');
      await expect(page).toHaveURL(/\/users\/log-in/, { timeout: 10000 });

      // The "Log in with magic link" form is form#login_form_magic in the
      // session template (see user_session_html/new.html.heex).
      await page.fill('#login_form_magic input[type="email"]', USER_EMAIL);
      await page.click('#login_form_magic button');

      // The controller always returns the same flash + redirect regardless of
      // whether the email is registered (anti-enumeration), so a 200 +
      // flash is sufficient signal that the request was accepted.
      await expect(page.locator('[role="alert"]').first())
        .toContainText(/shortly/i, { timeout: 10000 });

      // 2. Pull the magic link out of Mailpit.
      const { link } = await fetchMagicLink(api, { toEmail: USER_EMAIL });

      // 3. Follow the magic link in a fresh context so we can verify the
      //    session cookie sticks (the request fixture doesn't share cookies
      //    with the page fixture).
      const visitor = await playwright.request.newContext({
        baseURL: 'http://localhost:4000'
      });
      const res = await visitor.get(link);
      // The confirm action sets a session cookie + redirects to /dashboard
      // (or the originally requested path); the request context follows
      // redirects, so we land on the final URL.
      await expect(res).toBeOK();
      const finalUrl = res.url();
      expect(finalUrl).toMatch(/\/dashboard/);

      // 4. The page that follows the redirect should render the dashboard
      //    header, confirming the session cookie is recognised by Phoenix.
      await page.goto(finalUrl);
      await expect(page.locator('h1'))
        .toContainText('PV Power Dashboard', { timeout: 10000 });

      await visitor.dispose();
    } finally {
      await api.dispose();
    }
  });
});
