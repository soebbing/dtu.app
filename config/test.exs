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

# In test we don't send emails
config :dtu_app, DtuApp.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

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
config :web_push,
  finch: DtuAppWeb.WebPushFinch,
  vapid: %{
    public_key:
      "BPEkkVKqVKK7gR7g5dZQXz3Lp1zQ0nYfR2zL3lUjk1z7p5VnY2Q0wT8aM5cN9bO0sZc2vF3dXzQ0vW8aM5cN9bO0sZc2vF3dXw",
    private_key: "DtKMYV5z0qL3lUjk1z7p5VnY2Q0wT8aM5cN9bO0sZc2vF3dXzQ0vW8aM5cN9bO0s",
    subject: "mailto:test@localhost"
  }
