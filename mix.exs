defmodule DtuApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :dtu_app,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {DtuApp.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:argon2_elixir, "~> 4.0"},
      {:phoenix, "~> 1.8.8"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      # Required by Swoosh.Adapters.SMTP (the local Mailpit dev path in
      # config/runtime.exs). Swoosh lists gen_smtp as optional so it has to
      # be declared explicitly here.
      {:gen_smtp, "~> 1.0"},
      {:req, "~> 0.5"},
      # Web Push (RFC 8030) with VAPID authentication (RFC 8292)
      # and aes128gcm payload encryption (RFC 8291). Used by
      # `DtuApp.Push` to send signed/encrypted notifications to
      # the user's service worker. Requires VAPID env vars at
      # runtime; see `config/runtime.exs` and `.env.example`.
      {:web_push, "~> 0.1.0"},
      # Finch HTTP client — used by `web_push` to POST encrypted
      # payloads to push services (Mozilla, Google, Apple). Listed
      # explicitly so we supervise the pool in `DtuApp.Application`.
      {:finch, "~> 0.19"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      # WebAuthn / FIDO2 server-side ceremony (challenge generation,
      # attestation parsing, signature verification). Used by
      # `DtuAppWeb.PasskeyController` to enroll and authenticate
      # passkeys. See `docs/superpowers/specs/2026-08-27-passkeys-design.md`.
      {:webauthn, "~> 0.0.9"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      # Embedded MQTT broker (we own our device connections). See AGENTS.md in deps/mqttx.
      {:mqttx, "~> 0.10.0"},
      {:thousand_island, "~> 1.4"},
      # RFC 4180 CSV encoder. Used by `DtuAppWeb.DeviceExportController`
      # to stream historical readings as a downloaded CSV file —
      # see `test/dtu_app_web/controllers/device_export_controller_test.exs`.
      {:nimble_csv, "~> 1.2"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind dtu_app", "esbuild dtu_app"],
      "assets.deploy": [
        "compile",
        "tailwind dtu_app --minify",
        "esbuild dtu_app --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
