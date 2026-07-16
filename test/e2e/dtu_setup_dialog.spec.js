const { test, expect } = require('@playwright/test');

test.describe('Acceptance Tests: DTU Setup Instructions Dialog & Localization', () => {
  
  test.describe('English Locale (Default)', () => {
    test('successfully adds DTU and displays dialog in English', async ({ page }) => {
      // 1. Log in
      await page.goto('/');
      await page.click('text=Log in');
      await page.fill('input[type="email"]', 'test@example.com');
      await page.fill('input[type="password"]', 'password123456');
      await Promise.all([
        page.waitForNavigation(),
        page.click('button:has-text("Log in")')
      ]);

      // 2. Navigate to Device management
      await page.click('#btn-manage-devices');
      await expect(page).toHaveURL(/\/devices/);

      // 3. Add DTU
      await page.click('text=Add DTU');
      await page.fill('input[name="dtu[name]"]', 'English Inverter');
      await page.selectOption('select[name="dtu[kind]"]', 'opendtu');
      
      await Promise.all([
        page.waitForNavigation(),
        page.click('button:has-text("Save")')
      ]);

      // 4. Verify English modal credentials & instructions
      const modal = page.locator('#created-device-modal');
      await expect(modal).toBeVisible();
      await expect(page.locator('#created-device-modal-title')).toContainText('DTU Configured Successfully!');
      await expect(modal).toContainText('MQTT Broker / Server:');
      await expect(modal).toContainText('localhost');
      await expect(modal).toContainText('MQTT Port:');
      await expect(modal).toContainText('1883');
      await expect(modal).toContainText('Hardware setup instructions:');

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
      // 1. Log in (German: Anmelden)
      await page.goto('/');
      await page.click('text=Anmelden');
      await page.fill('input[type="email"]', 'test@example.com');
      await page.fill('input[type="password"]', 'password123456');
      await Promise.all([
        page.waitForNavigation(),
        page.click('button:has-text("Log in")')
      ]);

      // 2. Navigate to Device management
      await page.click('#btn-manage-devices');

      // 3. Add DTU (German: DTU hinzufügen)
      await page.click('text=DTU hinzufügen');
      await page.fill('input[name="dtu[name]"]', 'Deutscher Inverter');
      await page.selectOption('select[name="dtu[kind]"]', 'opendtu');
      
      await Promise.all([
        page.waitForNavigation(),
        page.click('button:has-text("Speichern")')
      ]);

      // 4. Verify German modal credentials & instructions
      const modal = page.locator('#created-device-modal');
      await expect(modal).toBeVisible();
      await expect(page.locator('#created-device-modal-title')).toContainText('DTU erfolgreich konfiguriert!');
      await expect(modal).toContainText('MQTT Broker / Server:');
      await expect(modal).toContainText('localhost');
      await expect(modal).toContainText('MQTT-Port:');
      await expect(modal).toContainText('1883');
      await expect(modal).toContainText('Anweisungen zur Hardware-Einrichtung:');

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
      // 1. Log in (French: Se connecter)
      await page.goto('/');
      await page.click('text=Se connecter');
      await page.fill('input[type="email"]', 'test@example.com');
      await page.fill('input[type="password"]', 'password123456');
      await Promise.all([
        page.waitForNavigation(),
        page.click('button:has-text("Log in")')
      ]);

      // 2. Navigate to Device management
      await page.click('#btn-manage-devices');

      // 3. Add DTU (French: Ajouter une DTU)
      await page.click('text=Ajouter une DTU');
      await page.fill('input[name="dtu[name]"]', 'Onduleur Français');
      await page.selectOption('select[name="dtu[kind]"]', 'opendtu');
      
      await Promise.all([
        page.waitForNavigation(),
        page.click('button:has-text("Enregistrer")')
      ]);

      // 4. Verify French modal credentials & instructions
      const modal = page.locator('#created-device-modal');
      await expect(modal).toBeVisible();
      await expect(page.locator('#created-device-modal-title')).toContainText('Configuration de la DTU réussie !');
      await expect(modal).toContainText('Courtier / Serveur MQTT :');
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
