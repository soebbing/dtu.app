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
