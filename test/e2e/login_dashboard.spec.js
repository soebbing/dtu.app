const { test, expect } = require('@playwright/test');

test.describe('Acceptance Tests: Authentication, Dashboard & DTU Creation', () => {
  test('successfully logs in, displays dashboard, and manages system-defined DTUs', async ({ page }) => {
    // 1. Go to the home page
    await page.goto('/');

    // 2. Navigate to log in
    await page.click('text=Log in');
    await expect(page).toHaveURL(/\/users\/log-in/, { timeout: 10000 });

    // 3. Fill credentials
    await page.fill('input[type="email"]', 'test@example.com');
    await page.fill('input[type="password"]', 'password123456');

    // 4. Click submit and wait for navigation.
    //    The login submit <button> has no explicit type attribute (a bare
    //    <button> defaults to submit), so match it by its label instead.
    await Promise.all([
      page.waitForNavigation(),
      page.click('button:has-text("Log in")')
    ]);

    // 5. Should be redirected to the dashboard
    await expect(page).toHaveURL(/\/dashboard/, { timeout: 10000 });

    // 6. Verify key elements on the dashboard page
    await expect(page.locator('h1')).toContainText('PV Power Dashboard', { timeout: 10000 });
    await expect(page.locator('#stat-current-power')).toContainText('0.0 W', { timeout: 10000 });
    await expect(page.locator('#device-status-grid')).toBeVisible({ timeout: 10000 });

    // 7. Click Manage Devices
    await page.click('#btn-manage-devices');
    await page.waitForTimeout(1000); // Wait for navigation and LiveView update
    await expect(page).toHaveURL(/\/devices/, { timeout: 10000 });

    // 8. Add a new DTU
    await page.click('text=Add DTU');
    await page.waitForTimeout(500); // Wait for navigation
    await expect(page).toHaveURL(/\/devices\/new/, { timeout: 10000 });

    // Verify inputs for credentials do NOT exist
    await expect(page.locator('input[name="dtu[mqtt_username]"]')).toHaveCount(0);
    await expect(page.locator('input[name="dtu[mqtt_password]"]')).toHaveCount(0);
    await expect(page.locator('input[name="dtu[base_topic]"]')).toHaveCount(0);

    // Fill the allowed fields
    await page.fill('input[name="dtu[name]"]', 'Garden Inverter');
    await page.selectOption('select[name="dtu[kind]"]', 'opendtu');

    // Save and wait for redirect
    await Promise.all([
      page.waitForNavigation(),
      page.click('button:has-text("Save")')
    ]);

    // Wait for modal to appear
    await page.waitForTimeout(1000);

    // Confirm the success dialog and MQTT configuration instructions are shown
    await expect(page.locator('#created-device-modal')).toBeVisible({ timeout: 10000 });
    await expect(page.locator('#created-device-modal-title')).toContainText('DTU Configured Successfully!', { timeout: 10000 });
    await expect(page.locator('#created-device-modal')).toContainText('localhost', { timeout: 10000 });
    await expect(page.locator('#created-device-modal')).toContainText('1883', { timeout: 10000 });

    // Dismiss the modal
    await page.click('#btn-close-created-modal');
    await expect(page.locator('#created-device-modal')).toHaveCount(0);

    // Confirm it is listed
    await expect(page.locator('#devices')).toContainText('Garden Inverter');

    // 9. Edit the DTU and verify system-generated details are displayed
    await page.click('text=Edit');
    
    // Verify system-defined info is visible and non-editable
    await expect(page.locator('text=MQTT Connection Details')).toBeVisible();
    
    const username = await page.locator('#copy-mqtt-username').textContent();
    expect(username).toMatch(/^dtu_[a-z0-9]+$/);
    
    const baseTopic = await page.locator('#copy-base-topic').textContent();
    expect(baseTopic).toBe('solar');

    const password = await page.locator('#copy-mqtt-password').textContent();
    expect(password.length).toBeGreaterThan(5);

    // Cancel edit to return to index
    await page.click('text=Cancel');
    await expect(page).toHaveURL(/\/devices/);

    // 10. Verify deletion confirmation modal flow
    // Click Remove to open confirmation dialog
    await page.click('button:has-text("Remove")');
    await expect(page.locator('#confirm-delete-modal')).toBeVisible();

    // Click Cancel in modal
    await page.click('#btn-cancel-delete');
    await expect(page.locator('#confirm-delete-modal')).toHaveCount(0);
    await expect(page.locator('#devices')).toContainText('Garden Inverter');

    // Click Remove again
    await page.click('button:has-text("Remove")');
    await expect(page.locator('#confirm-delete-modal')).toBeVisible();

    // Click Confirm Delete in modal
    await page.click('#btn-confirm-delete');
    await expect(page.locator('#confirm-delete-modal')).toHaveCount(0);
    await expect(page.locator('#devices')).not.toContainText('Garden Inverter');
  });
});
