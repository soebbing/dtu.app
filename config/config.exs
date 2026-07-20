# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :dtu_app, :scopes,
  user: [
    default: true,
    module: DtuApp.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: DtuApp.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :dtu_app,
  ecto_repos: [DtuApp.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :dtu_app, DtuAppWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DtuAppWeb.ErrorHTML, json: DtuAppWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: DtuApp.PubSub,
  live_view: [signing_salt: "sO3caV+W"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Embedded MQTT broker (MqttX). DTUs connect here and publish OpenDTU-format
# telemetry. See the project plan and deps/mqttx/AGENTS.md.
# In production this port is exposed (plain TCP) and Traefik wraps TLS on 8883.
config :dtu_app, :mqtt_broker,
  enabled: true,
  port: 1883,
  transport_opts: %{
    # Override client keepalive server-side so DTUs behind NAT/proxies stay alive.
    server_keep_alive: 30,
    receive_maximum: 100,
    max_packet_size: 256_000
  }

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :dtu_app, DtuApp.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  dtu_app: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --external:phoenix-colocated/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  dtu_app: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
