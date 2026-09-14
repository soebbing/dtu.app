// E2E coverage for the public `GET /healthz` endpoint.
//
// What we verify:
//
//   * `/healthz` is reachable WITHOUT a session cookie — this is
//     the contract the docker-compose healthcheck (`wget --spider
//     http://localhost:4000/healthz`) and any external readiness
//     probe depend on. The route lives on the bare `:api` pipeline
//     with no auth plug; this test is the regression guard that
//     catches a future refactor that moves it behind
//     `:require_authenticated_user`.
//   * The endpoint returns a JSON document with the keys the
//     orchestrator (and a human running `curl`) wants: `status`,
//     `checks.database`, `checks.broker`, `version`. The exact
//     `version` value isn't asserted (it's `RELEASE_VERSION` from
//     the running container, which varies across CI runs).
//
// What we don't verify here:
//
//   * The 503 path — would require taking the DB or the MQTT
//     credentials GenServer offline mid-suite, which would cascade
//     into every other e2e spec that hits a LiveView page. The
//     unit-test (`health_controller_test.exs`) covers the 503
//     branch via the "broker enabled but not started" test; the
//     docker-compose integration is a deployment-time concern, not
//     a user-journey one.
//   * The DB / broker check contents — they're free-form strings
//     ("ok" / "disabled" / "error: ..."), so we just check the
//     keys are present and one of the expected values, not the
//     exact text.

const { test, expect } = require('@playwright/test');
require('./_setup/global-fixture');

test.describe('Acceptance Tests: /healthz endpoint', () => {
  test('returns the expected JSON shape without authentication', async ({ request }) => {
    // `request` (Playwright's APIRequestContext) bypasses the
    // browser — that's the point: an orchestrator's probe is a
    // raw HTTP GET, not a page navigation. We use `request.get`
    // rather than `page.goto('/healthz')` so the test mirrors
    // what `wget --spider` actually does.
    const response = await request.get('/healthz');

    // 200 OK in the e2e environment: the test DB is reachable
    // and the broker is disabled (per `DtuApp.Application`'s
    // `:test` config — see `mqtt_broker_children/0`). Both are
    // "healthy" states from the controller's perspective.
    expect(response.status()).toBe(200);

    const body = await response.json();
    expect(body.status).toBe('ok');
    expect(body.checks).toBeDefined();
    expect(body.checks.database).toBe('ok');
    // `broker` is either "ok" or "disabled" depending on the
    // config the e2e container was launched with — both are
    // healthy states per the controller's contract.
    expect(['ok', 'disabled']).toContain(body.checks.broker);
    expect(typeof body.version).toBe('string');
  });

  test('is reachable with an Accept: */* header (wget --spider shape)', async ({ request }) => {
    // `wget --spider` (the docker-compose healthcheck command)
    // sends an HTTP/1.1 GET with no Accept header — Phoenix's
    // `Plug.Accepts` defaults `[]` to the first declared format
    // and the `:api` pipeline declares `["json"]`, so the
    // request lands on the JSON controller. The `Accept: */*`
    // header here exercises the explicit version of the same
    // fallback.
    const response = await request.get('/healthz', {
      headers: { accept: '*/*' }
    });

    expect(response.status()).toBe(200);
    expect(response.headers()['content-type']).toMatch(/application\/json/);
    const body = await response.json();
    expect(body.status).toBe('ok');
  });
});
