const { test, expect } = require('@playwright/test');
const { waitForLiveSocketConnected } = require('./_helpers');

test.describe('Acceptance Tests: Dashboard range preset toolbar', () => {
  // Range preset switching happens via the LiveView WebSocket, so we
  // wait for the socket to connect before clicking any preset tab —
  // otherwise the click could fire before `phx-click` is wired.
  test.beforeEach(async ({ page }) => {
    // The home page renders a "Sign In" link for unauthenticated users;
    // click it to land on /users/log-in where the password form lives.
    // (Trying to fill `#login_form_password` on `/` directly times out
    // — the form isn't there until you navigate to /users/log-in.)
    await page.goto('/');
    await page.getByRole('link', { name: 'Sign In' }).click();
    await expect(page).toHaveURL(/\/users\/log-in/, { timeout: 10000 });

    const form = page.locator('#login_form_password');
    await form.locator('input[type="email"]').fill('test@example.com');
    await form.locator('input[type="password"]').fill('password123456');
    await form.getByRole('button', { name: /Log in/i }).click();

    await page.waitForURL(/\/dashboard/, { timeout: 15000 });
    await waitForLiveSocketConnected(page);
  });

  test('renders the five preset buttons and lands on 1D by default', async ({ page }) => {
    // All five preset tabs are present.
    for (const id of [
      '#btn-range-1d',
      '#btn-range-7d',
      '#btn-range-30d',
      '#btn-range-ytd',
      '#btn-range-custom',
    ]) {
      await expect(page.locator(id)).toBeVisible();
    }

    // Default state is 1D (today) — chart title matches the live view.
    await expect(page.locator('#chart-title')).toContainText("Today's Production Curve");

    // Historical stepper is hidden until the user picks Custom.
    await expect(page.locator('#history-picker')).toHaveCount(0);
  });

  test('clicking 7D renders "Last 7 days" chart title without revealing the stepper', async ({ page }) => {
    await page.locator('#btn-range-7d').click();
    await expect(page.locator('#chart-title')).toContainText('Last 7 days');
    await expect(page.locator('#history-picker')).toHaveCount(0);
  });

  test('clicking 30D renders "Last 30 days" chart title', async ({ page }) => {
    // `beforeEach` already waited for the LiveSocket to connect once
    // after login, but the dashboard LiveView's socket can drop
    // between the beforeEach and this point under heavy CI load
    // (parallel suites create extra requests). Wait again right
    // before the click so the `phx-click` event is guaranteed to
    // be delivered — otherwise a reconnect in flight eats the click
    // and the chart-title never updates.
    await waitForLiveSocketConnected(page);
    await page.locator('#btn-range-30d').click();
    // The LiveView re-render runs `assign_dashboard_data/4`, which
    // queries a hypertable; under load that path can exceed the
    // 5 s default. 15 s is generous but still fails loudly on a
    // genuine regression.
    await expect(page.locator('#chart-title')).toContainText('Last 30 days', { timeout: 15000 });
  });

  test('clicking YTD renders "Year to date" chart title', async ({ page }) => {
    await page.locator('#btn-range-ytd').click();
    await expect(page.locator('#chart-title')).toContainText('Year to date');
  });

  test('clicking Custom reveals the historical stepper', async ({ page }) => {
    await page.locator('#btn-range-custom').click();
    await expect(page.locator('#history-picker')).toBeVisible();
  });

  test('clicking 1D after a different preset returns to the live view', async ({ page }) => {
    await page.locator('#btn-range-7d').click();
    await expect(page.locator('#chart-title')).toContainText('Last 7 days');

    await page.locator('#btn-range-1d').click();
    await expect(page.locator('#chart-title')).toContainText("Today's Production Curve");
    // Stepper is hidden again.
    await expect(page.locator('#history-picker')).toHaveCount(0);
  });
});