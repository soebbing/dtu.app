// End-to-end test for the passwordless / magic-link login flow.
//
// Requires Mailpit to be reachable at MAILPIT_URL (default
// http://localhost:8025 in CI and on the host during local dev). The Phoenix
// app is configured with MAIL_DELIVERY=mailpit in CI so transactional email
// lands in the Mailpit inbox instead of being swallowed by the in-memory
// adapter.
const { test, expect, request } = require('@playwright/test');
require('./_setup/global-fixture');

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
      // Use the parsed JSON API rather than the raw RFC822 source: Mailpit
      // returns the body already decoded from quoted-printable, so we don't
      // have to undo the long-URL soft-line-wrapping that QP encoding
      // applies around column 76 (a magic-link URL hits that limit and
      // gets split as `…=\n<continuation>`).
      const detail = await api.get(`${MAILPIT_URL}/api/v1/message/${match.ID}`);
      const body = await detail.json();
      // Mailpit names the two parts Body.HTML and Body.Plain (newer builds)
      // or just HTML / Text on older ones — try both.
      const html = body?.Body?.HTML ?? body?.HTML ?? '';
      const plain = body?.Body?.Plain ?? body?.Body?.Text ?? body?.Text ?? '';
      const haystack = html || plain;
      const link = haystack.match(/https?:\/\/[^\s"'<>]*\/users\/log-in\/[A-Za-z0-9_=-]+/);
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
      // session template (see user_session_html/new.html.heex). Fill the email
      // and submit, then wait for the redirect back to /users/log-in (the
      // controller returns a flash + redirect regardless of whether the email
      // is registered, to avoid user enumeration).
      await page.fill('#login_form_magic input[type="email"]', USER_EMAIL);
      await Promise.all([
        page.waitForURL(/\/users\/log-in/, { timeout: 10000 }),
        page.click('#login_form_magic button')
      ]);

      // 2. Pull the magic link out of Mailpit.
      const { link } = await fetchMagicLink(api, { toEmail: USER_EMAIL });

      // 3. Follow the magic link in a fresh request context and verify the
      //    session cookie logs us in: the controller confirms the token
      //    and redirects to `signed_in_path` (~p"/"), which the home
      //    controller in turn redirects to /dashboard for authenticated
      //    users. The request context follows redirects automatically.
      const visitor = await playwright.request.newContext({
        baseURL: 'http://localhost:4000'
      });
      const res = await visitor.get(link);
      const finalUrl = res.url();
      await expect(res).toBeOK();
      expect(finalUrl).toMatch(/\/dashboard/);

      await visitor.dispose();
    } finally {
      await api.dispose();
    }
  });
});
