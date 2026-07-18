const { defineConfig, devices } = require('@playwright/test');

module.exports = defineConfig({
  testDir: './test/e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: 'html',
  use: {
    baseURL: 'http://localhost:4000',
    trace: 'on-first-retry',
    // Increase timeout for CI environments where things can be slower
    actionTimeout: process.env.CI ? 15000 : 10000,
    navigationTimeout: process.env.CI ? 30000 : 20000,
    // When PLAYWRIGHT_CHROME is set (e.g. on NixOS, where the Playwright-
    // bundled chromium can't run), drive that system Chrome for every project.
    launchOptions: {
      executablePath: process.env.PLAYWRIGHT_CHROME || undefined,
    },
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});
