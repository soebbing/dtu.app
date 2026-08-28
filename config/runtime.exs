import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/dtu_app start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :dtu_app, DtuAppWeb.Endpoint, server: true
end

config :dtu_app, DtuAppWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :dtu_app, DtuApp.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # For production, allow PHX_HOST env var or default to localhost for local testing
  host = System.get_env("PHX_HOST", "localhost")

  config :dtu_app, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # The public scheme/port the app is served at. Drives URL generation for
  # things like magic-link emails: PHX_SCHEME/PHX_PORT must match how users
  # actually reach the site. A non-default port (anything but 80 for http or
  # 443 for https) is included in generated URLs; default ports are omitted.
  # Use http/4000 for local dev, https/443 behind TLS in production.
  url_scheme = System.get_env("PHX_SCHEME", "http")
  url_port = String.to_integer(System.get_env("PHX_PORT", "4000"))

  config :dtu_app, DtuAppWeb.Endpoint,
    url: [host: host, port: url_port, scheme: url_scheme],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # Embedded MQTT broker: let compose / production override the listening port
  # (e.g. to remap 1883) and disable it entirely when MQTT_BROKER_ENABLED=false.
  # The transport_opts defaults from config/config.exs still apply.
  config :dtu_app, :mqtt_broker,
    enabled: System.get_env("MQTT_BROKER_ENABLED", "true") in ~w(true 1),
    port: String.to_integer(System.get_env("MQTT_BROKER_PORT", "1883"))

  # DNS alias for the MQTT endpoint, shown to users as the broker host in the
  # device setup modal. Useful when MQTT runs on a different domain than the web
  # app (e.g. mqtt.example.com). When unset (or empty), the web app's host
  # (PHX_HOST) is used as the broker host.
  if System.get_env("MQTT_HOST", "") != "" do
    config :dtu_app, :mqtt_host, System.fetch_env!("MQTT_HOST")
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :dtu_app, DtuAppWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :dtu_app, DtuAppWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Mailer
  #
  # Three delivery modes, picked in order of precedence:
  #
  #   1. RESEND_API_KEY set  -> Swoosh.Adapters.Resend (production email via
  #                              the Resend transactional API)
  #   2. MAIL_DELIVERY=mailpit -> Swoosh.Adapters.SMTP pointed at a local
  #                              Mailpit server (see docker-compose.yml) so
  #                              magic-link emails can be inspected in a web
  #                              UI at http://localhost:8025 without an
  #                              external account
  #   3. fallback            -> Swoosh.Adapters.Local (in-memory; emails are
  #                              swallowed, the magic-link URL appears in the
  #                              server logs / IEx session)
  #
  # MAIL_FROM must be an address on a domain verified in your Resend account
  # for Resend, and a domain Mailpit will accept for the SMTP fallback
  # (anything works locally).
  cond do
    System.get_env("RESEND_API_KEY", "") != "" ->
      config :dtu_app, DtuApp.Mailer,
        adapter: Swoosh.Adapters.Resend,
        api_key: System.fetch_env!("RESEND_API_KEY")

    System.get_env("MAIL_DELIVERY", "") == "mailpit" ->
      config :dtu_app, DtuApp.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        relay: System.get_env("SMTP_RELAY", "mailpit"),
        port: String.to_integer(System.get_env("SMTP_PORT", "1025")),
        domain: System.get_env("SMTP_DOMAIN", "localhost"),
        authentication: :none,
        tls: :never

    true ->
      :ok
  end

  config :dtu_app, :mail_from, System.get_env("MAIL_FROM", "dtu.app <noreply@localhost>")
end

# ── Passkeys / WebAuthn ────────────────────────────────────────────────────
# RP ID (origin's effective domain) and RP name (human-readable party name
# shown by the browser during the ceremony). Defaults are dev-friendly —
# override in prod via WEBAUTHN_RP_ID / WEBAUTHN_RP_NAME env vars.
config :dtu_app,
       :webauthn_rp_id,
       (case System.get_env("WEBAUTHN_RP_ID") do
          nil -> "localhost"
          "" -> "localhost"
          val -> val
        end)

config :dtu_app, :webauthn_rp_name, System.get_env("WEBAUTHN_RP_NAME") || "dtu.app"

# Kill switch — defaults OFF in :prod for the 24h monitoring window
# after first launch, defaults ON in :dev/:test. Operators flip with
# `PASSKEYS_ENABLED=true` (enable) or `PASSKEYS_ENABLED=false` (disable).
# See `DtuAppWeb.Passkeys.KillSwitch` for the decision matrix.
config :dtu_app,
       :passkeys_enabled,
       DtuAppWeb.Passkeys.KillSwitch.enabled?(System.get_env("PASSKEYS_ENABLED"), config_env())

# ── Web Push (VAPID) ───────────────────────────────────────────────────────
# Required for native browser notifications delivered by the service
# worker when no tab is open. All three VAPID_* vars come from the
# environment; in :dev a fresh keypair is generated on every boot
# (logged for convenience) so the developer doesn't have to provision
# keys just to test the OS-notification path. In :test we skip
# entirely — push tests can inject a stubbed module.
vapid_pub = System.get_env("VAPID_PUBLIC_KEY", "") |> String.trim()
vapid_priv = System.get_env("VAPID_PRIVATE_KEY", "") |> String.trim()
vapid_sub = System.get_env("VAPID_SUBJECT", "mailto:admin@localhost") |> String.trim()

case config_env() do
  :test ->
    # The test environment configures a stub Finch pool and never
    # sends real push notifications; see `config/test.exs`. Keep the
    # keys present so the public_key/0 call doesn't blow up if a test
    # exercises the controller path.
    :ok

  _ ->
    {vapid_pub, vapid_priv} =
      cond do
        vapid_pub != "" and vapid_priv != "" ->
          {vapid_pub, vapid_priv}

        config_env() == :prod ->
          raise """
          environment variables VAPID_PUBLIC_KEY and VAPID_PRIVATE_KEY
          are missing. Generate a keypair with `mix web_push.gen.vapid`
          and set both, plus VAPID_SUBJECT, before starting in :prod.
          """

        true ->
          # Dev convenience: fresh keypair each boot. The JS-side
          # `PushManager.subscribe()` call captures the public key at
          # enable-time, so changing the key on restart invalidates any
          # in-flight subscription — which is fine for dev. Operators
          # upgrading from a no-VAPID setup will need to re-enable
          # notifications on each device once after deploy.
          %{public_key: pk, private_key: sk} = WebPush.Vapid.generate_keypair()

          require Logger

          Logger.warning(fn ->
            "[vapid] generated ephemeral dev keypair — set VAPID_PUBLIC_KEY/VAPID_PRIVATE_KEY in prod"
          end)

          {pk, sk}
      end

    config :web_push,
      finch: DtuAppWeb.WebPushFinch,
      vapid: %{
        public_key: vapid_pub,
        private_key: vapid_priv,
        subject: vapid_sub
      }
end

# ── Release / git version ──────────────────────────────────────────────────
# The unobtrusive site footer shows the currently-running release. The
# release workflow passes RELEASE_VERSION (the git tag, e.g. v2026-07-26-1)
# at build time, so production images render a stable identifier.
#
# In development (`mix phx.server`) no env var is set, so we fall back to
# the current git branch via the local repo, then finally to the
# Mix.Project version from mix.exs.
version =
  cond do
    v = System.get_env("RELEASE_VERSION", "") ->
      if v != "", do: v, else: nil

    true ->
      nil
  end

version =
  case version do
    nil ->
      app_root = Application.app_dir(:dtu_app, "..")

      # `System.cmd/3` raises `ErlangError{:enoent, …}` when the binary
      # is missing (the release image doesn't ship git — `.git` is in
      # .dockerignore) and propagates the rejection of detached HEADs via
      # the `with`. Rescue both so a missing git / no current branch just
      # means we fall back to Mix.Project's :version.
      try do
        with {out, 0} <- System.cmd("git", ["-C", app_root, "rev-parse", "--abbrev-ref", "HEAD"]),
             branch <- String.trim(out),
             false <- branch == "HEAD" do
          branch
        end
      rescue
        ErlangError -> nil
      catch
        _, _ -> nil
      end

    v ->
      v
  end

version = version || to_string(Mix.Project.config()[:version])

config :dtu_app, :version, version
