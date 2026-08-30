import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :argon2_elixir, t_cost: 1, m_cost: 8

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :dtu_app, DtuApp.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "dtu_app_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :dtu_app, DtuAppWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "V6Zd3tavE/k/axa98zlBDBsqNUgPmlCQfkEAt7lGKXfOW6Qj4Mzjh+IyEusVYVH/",
  server: false

# Disable the embedded MQTT broker during tests — nothing under test binds a
# real port. The handler is exercised in isolation where needed.
config :dtu_app, :mqtt_broker, enabled: false

# The singleton notification producers (`DtuConnection`, `SunDown`,
# `SunUp`) call `Repo` from inside their `handle_info/2` callbacks.
# The Ecto SQL Sandbox (`:manual` mode, see `test_helper.exs`) only
# allows the checked-out test process to use the connection, so the
# long-lived supervisors would race the test owner. Per-test
# instances are brought up via `start_supervised!/1` from
# `test/dtu_app/notifications/*.exs`.
config :dtu_app, :notifier_children, enabled: false

# The `DtuApp.MqttBroker.Telemetry` and `DtuApp.MqttBroker.TopicRegistry`
# GenServers are started in the application supervisor (not gated by
# `:notifier_children`) because `DtuApp.MqttBroker.TopicRegistryTest`
# reads the live ETS-backed topic map from the running GenServer. Their
# `init/1` callbacks subscribe to PubSub topics (`dtu:uplink`,
# `dtu:presence`, `dtu:ro_fanout`) — that subscription path is what
# races the SQL sandbox in CI:
#
#   * a `MqttBrokerTest` calls `Broker.handle_publish/4`, which
#     broadcasts `{:uplink, _}` on `dtu:uplink`;
#   * the long-lived GenServers receive that broadcast async and call
#     `Repo` from their `handle_info/2`;
#   * if the next test's setup (`user_fixture → Time.utc_now →
#     Repo.query_now`) starts before that Repo call returns, the
#     sandbox is already checked out by the GenServer — the next
#     checkout blocks for `queue_target` ms then raises
#     `DBConnection.ConnectionError: connection not available`.
#
# Same fix as the notifier producers: don't subscribe in :test. The
# GenServers still run (so `TopicRegistryTest` can read ETS), and the
# few tests that drive `handle_info/2` directly do so synchronously on
# the test process, which owns the connection.
config :dtu_app, :mqtt_broker_subscribers, enabled: false

# In test we don't send emails
config :dtu_app, DtuApp.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Effectively disable the share-loading-spinner minimum-visible-time in
# tests. The handler schedules a `Process.send_after/3` for the DB work;
# setting this very high means the timer never fires during a test, and
# the test must drive the second phase explicitly via
# `send(view.pid, {:mint_shared_link | :revoke_shared_link, _})`. Without
# this, even a 0-ms timer races with the click response and the
# loading state is gone before the test can assert on it.
config :dtu_app, :share_load_delay_ms, 60_000

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# VAPID keys for test. Real cryptographic operations are not exercised
# in test — `DtuApp.Push.deliver/2` short-circuits when the `:web_push`
# config is empty (see `runtime.exs`) and is instead stubbed via
# `Mox`/explicit mocks. These keys exist so `WebPush.Vapid.public_key/0`
# doesn't crash if a test reads the controller's JSON body shape.
#
# Both keys are valid URL-safe base64 P-256 points generated once with
# `WebPush.Vapid.generate_keypair/0` and hard-coded here for stability.
# The public key is exactly 87 base64url chars (= ceil(65 * 4 / 3)) —
# the 0x04 uncompressed-point header plus 32 bytes of X and 32 bytes of
# Y. Anything else will trip the `atob("String contains an invalid
# character")` check in `assets/js/push_subscribe.js` when the browser
# tries to subscribe.
config :web_push,
  finch: DtuAppWeb.WebPushFinch,
  vapid: %{
    public_key:
      "BJTUEpHLN69OMVAoFchd_RCm7kzXYyiGLhj-yHFwp0dCHciZUh6XRChhfY6R0cEm4CZ5whrZPaNszMPlWkBMuy0",
    private_key: "xE0IOv4yhbso6voJbQkZj2X9kEr8zsh9yTZouFU9cYc",
    subject: "mailto:test@localhost"
  }

# Explicit test value for the WebAuthn relying-party ID. Mirrors the
# dev/prod default ("localhost") and forces a known value regardless of
# any WEBAUTHN_RP_ID env var that may be set on a developer's machine —
# the ceremony's origin check is unforgiving about host mismatches.
config :dtu_app, :webauthn_rp_id, "localhost"
config :dtu_app, :webauthn_rp_name, "dtu.app"

# Inject WebAuthn library mocks for tests. The library dispatches via
# `Application.compile_env(:webauthn, :auth_response/:registration_response, ...)`
# at boot — pointing these at the *Mock variants lets tests skip signature
# verification (which would otherwise require real crypto). The auth mock
# branches on the challenge STRING: `"warn"` forces sign_count=0 (clone
# detector path), `"originMismatch"` returns the origin error, anything
# else returns the happy-path `{:ok, cred, sign_count+1}`.
config :webauthn, :auth_response, Webauthn.AuthenticationMock.Response
config :webauthn, :registration_response, Webauthn.RegistrationMock.Response

# Route the Open-Meteo HTTP client through Req.Test in :test so calls
# never hit the network. Tests install stubs via `Req.Test.stub/2`,
# mirroring how `Webauthn.*Mock.Response` short-circuits the WebAuthn
# ceremony — see `test/dtu_app/weather/open_meteo_test.exs`.
config :dtu_app, DtuApp.Weather.OpenMeteo, plug: {Req.Test, DtuApp.Weather.OpenMeteo}
