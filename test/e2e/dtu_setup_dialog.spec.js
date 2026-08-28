const { test, expect } = require('@playwright/test');
const { waitForLiveSocketConnected } = require('./_helpers');
require('./_setup/global-fixture');

test.describe('Acceptance Tests: DTU Setup Instructions Dialog & Localization', () => {
  
  test.describe('English Locale (Default)', () => {
    test('successfully adds DTU and displays dialog in English', async ({ page }) => {
      // 1. Log in
      await page.goto('/');
      await page.click('text=Log in');
      await page.fill('#login_form_password input[type="email"]', 'test@example.com');
      await page.fill('#login_form_password input[type="password"]', 'password123456');
      await Promise.all([
        page.waitForNavigation(),
        page.click('#login_form_password button')
      ]);

      // 2. Navigate to Device management. The dashboard's "Manage
      // Devices" CTA only renders in the onboarding state
      // (`@devices == []`), so once the seeds' DTUs exist we navigate
      // directly to `/devices` via the URL.
      await page.goto('/devices');
      await expect(page).toHaveURL(/\/devices/, { timeout: 10000 });
      await page.waitForTimeout(500);

      // 3. Add DTU
      const dtuName = `English Inverter ${Date.now()}`;
      await page.click('text=Add DTU');
      await page.waitForTimeout(500);
      await page.fill('input[name="dtu[name]"]', dtuName);
      await page.selectOption('select[name="dtu[kind]"]', 'opendtu');

      // Wait for the LiveView socket to connect before
      // clicking Save; otherwise the form may submit as
      // a native POST to its `action` URL, which on
      // `/devices/new` 404s because the route is
      // GET-only. See `_helpers.js` for the why.
      await waitForLiveSocketConnected(page);
      await page.click('button:has-text("Save")');

      // Wait for modal to appear
      await page.waitForTimeout(1000);

      // 4. Verify English modal credentials & instructions
      const modal = page.locator('#created-device-modal');
      await expect(modal).toBeVisible({ timeout: 10000 });
      await expect(page.locator('#created-device-modal-title')).toContainText('DTU Configured Successfully!', { timeout: 10000 });
      await expect(modal).toContainText('MQTT Broker / Server:', { timeout: 10000 });
      await expect(modal).toContainText('localhost', { timeout: 10000 });
      await expect(modal).toContainText('MQTT Port:', { timeout: 10000 });
      await expect(modal).toContainText('1883', { timeout: 10000 });
      await expect(modal).toContainText('Hardware setup instructions:', { timeout: 10000 });

      // 5. Dismiss the modal and verify it closes
      await page.click('#btn-close-created-modal');
      await expect(modal).toHaveCount(0);
      await expect(page.locator('#devices')).toContainText('English Inverter');
    });
  });

  test.describe('German Locale', () => {
    test.use({
      locale: 'de-DE',
      extraHTTPHeaders: { 'accept-language': 'de-DE,de;q=0.9' }
    });

    test('successfully adds DTU and displays dialog in German', async ({ page }) => {
      // 1. Log in (German: Anmelden). Use the German seed user
      // (`test-de@example.com`) so the post-login page renders in
      // German — with `current_scope.user.locale` winning over
      // `Accept-Language` (introduced in PR #151), the default
      // `test@example.com` (locale "en") would re-render the
      // post-login `/devices` page in English and break the
      // `text=DTU hinzufügen` click below.
      await page.goto('/');
      await page.click('text=Anmelden');
      await page.fill('#login_form_password input[type="email"]', 'test-de@example.com');
      await page.fill('#login_form_password input[type="password"]', 'password123456');
      await Promise.all([
        page.waitForNavigation(),
        page.click('#login_form_password button')
      ]);

      // 2. Navigate to Device management. The dashboard's "Manage
      // Devices" CTA only renders in the onboarding state
      // (`@devices == []`), so once the seeds' DTUs exist we navigate
      // directly to `/devices` via the URL.
      await page.goto('/devices');
      await page.waitForTimeout(500); // Wait for navigation

      // 3. Add DTU (German: DTU hinzufügen)
      const dtuName = `Deutscher Inverter ${Date.now()}`;
      await page.click('text=DTU hinzufügen');
      await page.fill('input[name="dtu[name]"]', dtuName);
      await page.selectOption('select[name="dtu[kind]"]', 'opendtu');

      // See the English test above for the rationale;
      // LiveView socket must be up before submitting.
      await waitForLiveSocketConnected(page);
      await page.click('button:has-text("Speichern")');

      // Wait for modal to appear
      await page.waitForTimeout(1000);

      // 4. Verify German modal credentials & instructions
      const modal = page.locator('#created-device-modal');
      await expect(modal).toBeVisible({ timeout: 10000 });
      await expect(page.locator('#created-device-modal-title')).toContainText('DTU erfolgreich konfiguriert!', { timeout: 10000 });
      await expect(modal).toContainText('MQTT Broker / Server:', { timeout: 10000 });
      await expect(modal).toContainText('localhost', { timeout: 10000 });
      await expect(modal).toContainText('MQTT-Port:', { timeout: 10000 });
      await expect(modal).toContainText('1883', { timeout: 10000 });
      await expect(modal).toContainText('Anweisungen zur Hardware-Einrichtung:', { timeout: 10000 });

      // 5. Dismiss the modal
      await page.click('#btn-close-created-modal');
      await expect(modal).toHaveCount(0);
      await expect(page.locator('#devices')).toContainText('Deutscher Inverter');
    });
  });

  test.describe('French Locale', () => {
    test.use({
      locale: 'fr-FR',
      extraHTTPHeaders: { 'accept-language': 'fr-FR,fr;q=0.9' }
    });

    test('successfully adds DTU and displays dialog in French', async ({ page }) => {
      // 1. Log in (French: Se connecter). Use the French seed user
      // (`test-fr@example.com`) for the same reason as the German
      // test above: with user.locale winning over Accept-Language,
      // the default `test@example.com` would render `/devices` in
      // English, breaking the `text=Ajouter une DTU` click below.
      await page.goto('/');
      await page.click('text=Se connecter');
      await page.fill('#login_form_password input[type="email"]', 'test-fr@example.com');
      await page.fill('#login_form_password input[type="password"]', 'password123456');
      await Promise.all([
        page.waitForNavigation(),
        page.click('#login_form_password button')
      ]);

      // 2. Navigate to Device management. The dashboard's "Manage
      // Devices" CTA only renders in the onboarding state
      // (`@devices == []`), so once the seeds' DTUs exist we navigate
      // directly to `/devices` via the URL.
      await page.goto('/devices');
      await page.waitForTimeout(500); // Wait for navigation

      // 3. Add DTU (French: Ajouter une DTU)
      const dtuName = `Onduleur Français ${Date.now()}`;
      await page.click('text=Ajouter une DTU');
      await page.fill('input[name="dtu[name]"]', dtuName);
      await page.selectOption('select[name="dtu[kind]"]', 'opendtu');

      // See the English test above for the rationale;
      // LiveView socket must be up before submitting.
      await waitForLiveSocketConnected(page);
      await page.click('button:has-text("Enregistrer")');

      // Wait for modal to appear
      await page.waitForTimeout(1000);

      // 4. Verify French modal credentials & instructions
      const modal = page.locator('#created-device-modal');
      await expect(modal).toBeVisible({ timeout: 10000 });
      await expect(page.locator('#created-device-modal-title')).toContainText('Configuration de la DTU réussie !', { timeout: 10000 });
      await expect(modal).toContainText('Courtier / Serveur MQTT :', { timeout: 10000 });
      await expect(modal).toContainText('localhost');
      await expect(modal).toContainText('Port MQTT :');
      await expect(modal).toContainText('1883');
      await expect(modal).toContainText('Instructions de configuration du matériel :');

      // 5. Dismiss the modal
      await page.click('#btn-close-created-modal');
      await expect(modal).toHaveCount(0);
      await expect(page.locator('#devices')).toContainText('Onduleur Français');
    });
  });
});
