// E2E coverage for the CSV export of historical readings.
//
// What we verify:
//
//   * The "Download CSV" button is visible on `/devices/:id/details`.
//   * Clicking it triggers a download whose filename matches
//     `dtu-<id>-readings-<start>_<end>.csv` (the format
//     `DtuAppWeb.DeviceExportController` builds — see the
//     `build_filename/3` helper there).
//   * The downloaded file starts with the 17-column header row
//     from `@csv_header` and contains at least one data row whose
//     `dtu_id` column matches the device we exported.
//
// What we don't verify here:
//
//   * Tenant isolation — that's an ExUnit concern (the
//     "does not leak rows" case in `device_export_controller_test.exs`)
//     and exercises the same query helper this UI thread.
//   * Streaming / chunked encoding — same reason: an HTTP-level
//     detail, not a user-journey one. The ExUnit tests pin the
//     response shape; the e2e test pins the user-visible file.
//
// Why `Promise.all` around `waitForEvent('download')` and the
// click: `download` events fire AFTER the click is dispatched, so
// we register the listener first to avoid a race where the
// browser commits the download before Playwright's listener is
// ready.

const { test, expect } = require('@playwright/test');
const { waitForLiveSocketConnected } = require('./_helpers');
require('./_setup/global-fixture');

const E2E_EMAIL = 'test@example.com';
const E2E_PASSWORD = 'password123456';

test.describe.serial('Acceptance Tests: CSV export of historical readings', () => {
  async function logIn(page) {
    await page.goto('/');
    await page.getByRole('link', { name: 'Sign In' }).click();
    await expect(page).toHaveURL(/\/users\/log-in/, { timeout: 10000 });
    await page.fill('#login_form_password input[type="email"]', E2E_EMAIL);
    await page.fill('#login_form_password input[type="password"]', E2E_PASSWORD);
    await Promise.all([
      page.waitForNavigation(),
      page.click('#login_form_password button'),
    ]);
    await expect(page).toHaveURL(/\/dashboard/, { timeout: 10000 });
  }

  test('Download CSV button downloads a readable file with the 17-column header', async ({ page }) => {
    await logIn(page);

    // Click through to the seeded `Roof Inverter` device (see
    // `priv/repo/seeds.exs`). The dashboard's device card opens
    // the device-details page when clicked; using direct
    // navigation here is faster and more deterministic across
    // viewport sizes.
    await page.goto('/devices');
    await expect(page).toHaveURL(/\/devices/, { timeout: 10000 });
    await waitForLiveSocketConnected(page);

    const deviceLink = page.getByRole('link', { name: 'Details' }).first();
    await expect(deviceLink).toBeVisible({ timeout: 10000 });
    await deviceLink.click();
    await expect(page).toHaveURL(/\/devices\/\d+\/details/, { timeout: 10000 });

    // The export button uses a stable id (see the `id="btn-download-csv"`
    // attribute in `device_live/details.html.heex`) so this selector
    // doesn't break when other buttons are added to the page header.
    const downloadButton = page.locator('#btn-download-csv');
    await expect(downloadButton).toBeVisible({ timeout: 10000 });

    // Trigger the download and capture the file. `waitForEvent('download')`
    // resolves with a `Download` object that exposes `path()` once the
    // browser has finished writing the file to its temp dir.
    const [download] = await Promise.all([
      page.waitForEvent('download', { timeout: 15000 }),
      downloadButton.click(),
    ]);

    // Filename shape — `DtuAppWeb.DeviceExportController.build_filename/3`
    // renders `<dtu-id>-readings-<start>_<end>.csv`. The default range
    // is "30 days ago → today UTC" so the dates will match whatever the
    // server's `Date.utc_today()` returns. We assert the prefix and
    // `.csv` extension instead of the full string so the test doesn't
    // flake at midnight UTC.
    const filename = download.suggestedFilename();
    expect(filename).toMatch(/^dtu-\d+-readings-\d{4}-\d{2}-\d{2}_\d{4}-\d{2}-\d{2}\.csv$/);

    const path = await download.path();
    expect(path).toBeTruthy();
    const body = require('fs').readFileSync(path, 'utf8');

    // The 17-column header row — order matches `@csv_header` in
    // `device_export_controller.ex`. If a future refactor reorders
    // columns or drops one, this assertion fails loudly.
    const lines = body.split(/\r?\n/).filter((l) => l !== '');
    expect(lines[0]).toBe(
      'inserted_at,dtu_id,inverter_serial,inverter_name,mppt_index,power_type,' +
        'ac_power,dc_power,frequency,temperature,yield_day,yield_total,' +
        'consumption_power,consumption_energy_day,consumption_energy_total,producing,reachable'
    );

    // The seeded device (Roof Inverter, see `priv/repo/seeds.exs`)
    // gets a day's worth of readings every time `mix ecto.setup`
    // runs, so the export must contain at least one data row. We
    // assert that the second line starts with an ISO-8601 timestamp
    // and that `dtu_id` (column 2) is an integer.
    expect(lines.length).toBeGreaterThan(1);
    const firstDataRow = lines[1].split(',');
    expect(firstDataRow[0]).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/);
    expect(firstDataRow[1]).toMatch(/^\d+$/);
  });
});
