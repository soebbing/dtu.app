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
    # Bumped from 10 to 20 to absorb MQTT-ingest write bursts without
    # starving the dashboard's read path. With 10 slots, the live
    # `INSERT INTO readings ...` cycle (one per Shelly/em:0 / per
    # inverter/5-10 s) held connections long enough that the
    # dashboard's mount process queued on `DBConnection.checkout`,
    # visible in telemetry as `idle_time: ~1.5 s` spikes on trivial
    # `SELECT FROM dtus WHERE id = $1` lookups (perf-telemetry
    # 2026-09-12). 20 slots gives 2× headroom for mixed read/write
    # workloads. Override at deploy time with `POOL_SIZE=N`.
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "20"),
    # `queue_target` caps the number of processes waiting for a
    # connection. When exceeded, new checkouts fail fast (raise)
    # instead of silently piling up behind a 15 s checkout_timeout —
    # which would otherwise let a dashboard mount thread wedge the
    # whole endpoint until it times out. 50 keeps the per-request
    # queue short enough that misconfigurations surface as fast
    # errors instead of long-tail latency.
    queue_target: 50,
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
end

# ## Mailer — SMTP transport, configured entirely via env vars
#
# Single Swoosh.Adapters.SMTP config; the local Mailpit sidecar (see
# docker-compose.yml) and a real production relay (SES, Mailgun,
# Postmark, Fastmail, ...) use the same code path — the only
# difference is the relay/port/auth/TLS values, which are all
# environment-driven. No JSON API path: Resend's JSON→MIME
# reconstruction drops inline `image/png` attachment bodies, which is
# what produced the grey rectangle in the SunDown chart email. SMTP
# forwards raw multipart bytes, so cid-attached PNGs survive.
#
# Per-env resolution:
#
#   :test  -> Swoosh.Adapters.Test is set in config/test.exs; this
#             block does not run for :test.
#   :dev   -> falls back to localhost:1025 (Mailpit) when SMTP_RELAY
#             is unset, so `mix phx.server` Just Works against the
#             compose sidecar.
#   :prod  -> refuses to start without SMTP_RELAY (env validation
#             here, in addition to whatever the Swoosh SMTP adapter
#             itself raises on a nil relay).
#
# Env vars:
#
#   SMTP_RELAY       (reqd in :prod)  Hostname / IP of the SMTP server.
#   SMTP_PORT        (default 587)    Standard submission port. Use 465
#                                     when SMTP_TLS=always.
#   SMTP_DOMAIN      (default PHX_HOST) HELO/EHLO domain.
#   SMTP_USERNAME    (optional)       Set when the relay requires
#                                     authentication. Pair with
#                                     SMTP_PASSWORD.
#   SMTP_PASSWORD    (optional)       Required iff SMTP_USERNAME is set.
#   SMTP_TLS         (default :if_available)
#                                     :always        — implicit TLS,
#                                                      usually :465.
#                                     :if_available  — opportunistic
#                                                      STARTTLS,
#                                                      usually :587.
#                                     :never         — plain SMTP, no
#                                                      TLS (Mailpit,
#                                                      internal relays).
#   SMTP_AUTH_MODE   (default :auto)  :auto  -> :username_password if
#                                            both SMTP_USERNAME and
#                                            SMTP_PASSWORD are set,
#                                            else :none.
#                                     :always -> always use the
#                                            credentials (errors if
#                                            either is empty).
#                                     :never  -> never authenticate.
#
# MAIL_FROM must be an address the relay accepts. For SES/Mailgun/
# Postmark that means a verified-sender (or verified-domain) address;
# for Mailpit anything works.
if config_env() != :test do
  if config_env() == :prod and System.get_env("SMTP_RELAY", "") == "" do
    raise """
    environment variable SMTP_RELAY is missing.
    Set SMTP_RELAY (and SMTP_PORT/SMTP_USERNAME/SMTP_PASSWORD/SMTP_TLS as
    required by your relay) before starting in :prod. See .env.example
    for the full list.
    """
  end

  smtp_relay_env = System.get_env("SMTP_RELAY", "") |> String.trim()
  is_dev = config_env() == :dev

  smtp_relay =
    cond do
      smtp_relay_env == "" and is_dev -> "localhost"
      smtp_relay_env == "" -> ""
      true -> smtp_relay_env
    end

  smtp_port =
    case System.get_env("SMTP_PORT", "") |> String.trim() do
      "" -> 587
      port -> String.to_integer(port)
    end

  smtp_domain =
    System.get_env("SMTP_DOMAIN", "")
    |> String.trim()
    |> case do
      "" -> System.get_env("PHX_HOST", "localhost")
      domain -> domain
    end

  # SMTP_TLS default is env-aware: :dev/:test defaults to :never (Mailpit,
  # internal relays don't do TLS); :prod defaults to :if_available
  # (opportunistic STARTTLS, the standard for production relays).
  smtp_tls_default = if config_env() == :prod, do: "if_available", else: "never"

  smtp_tls =
    case System.get_env("SMTP_TLS", smtp_tls_default) |> String.trim() do
      "" ->
        String.to_atom(smtp_tls_default)

      "always" ->
        :always

      "if_available" ->
        :if_available

      "never" ->
        :never

      other ->
        raise "SMTP_TLS must be one of always / if_available / never, got: #{inspect(other)}"
    end

  smtp_username = System.get_env("SMTP_USERNAME", "") |> String.trim()
  smtp_password = System.get_env("SMTP_PASSWORD", "") |> String.trim()

  smtp_auth_mode =
    case System.get_env("SMTP_AUTH_MODE", "auto") |> String.trim() do
      "" ->
        if smtp_username != "" and smtp_password != "",
          do: :username_password,
          else: :none

      "auto" ->
        if smtp_username != "" and smtp_password != "",
          do: :username_password,
          else: :none

      "always" ->
        if smtp_username == "" or smtp_password == "",
          do:
            raise("SMTP_AUTH_MODE=always requires both SMTP_USERNAME and SMTP_PASSWORD to be set")

        :username_password

      "never" ->
        :none

      other ->
        raise "SMTP_AUTH_MODE must be one of auto / always / never, got: #{inspect(other)}"
    end

  # Map the SMTP_TLS env setting to gen_smtp_client's two distinct
  # triggers:
  #
  #   * `ssl: true`  — implicit TLS (start TLS right after TCP connect,
  #                    before any SMTP command). Use with port 465.
  #   * `tls: <mode>` — STARTTLS upgrade after EHLO. Use with port 587.
  #                    `:always` = require STARTTLS; `:if_available` =
  #                    opportunistic; `:never` = no STARTTLS.
  #
  # These are independent: with `ssl: true` we set `tls: :never` because
  # we're already inside TLS — STARTTLS after EHLO would be nonsensical.
  # For STARTTLS (`ssl: false`), `tls: :always` / `:if_available` controls
  # whether the upgrade happens.
  #
  # The TLS option list goes via `tls_options:` (NOT `sockopts:` — that's
  # `gen_tcp:connect_option()` for socket-level tuning like `{:nodelay,
  # true}`, not SSL options). `tls_options` is passed to `:ssl.connect/3`
  # for both implicit and STARTTLS paths.
  #
  # Critical defaults we override:
  #
  #   * `versions:` — gen_smtp_client's default is
  #     `[{versions, ['tlsv1', 'tlsv1.1', 'tlsv1.2']}]`. Gmail (and most
  #     modern relays) prefer TLS 1.3 and reject a TLS 1.2-only handshake
  #     with a generic `:tls_failed`. Pinning both keeps us compatible
  #     with every common relay.
  #
  #   * `verify: :verify_peer` + `customize_hostname_check:` — gen_smtp
  #     defaults to `verify_none`, so a misissued / impersonated cert is
  #     silently accepted. We want verification.
  #
  #   * `cacerts: :public_key.cacerts_get()` — OTP 25+ API that reads the
  #     CA bundle Erlang was compiled with (better than `cacertfile` +
  #     path probing, because OTP finds its own bundle reliably regardless
  #     of the host filesystem layout).
  #
  #   * `server_name_indication:` — Gmail (and any shared-IP TLS
  #     terminator) requires SNI to pick the right cert; without it the
  #     server may serve a default / wrong cert and the verification
  #     step fails.
  {ssl_trigger, tls_options} =
    case smtp_tls do
      :never ->
        {[ssl: false, tls: :never], []}

      :always when smtp_port == 465 ->
        # Implicit TLS (port 465): connect with TLS immediately. We do
        # NOT also send STARTTLS after EHLO — `tls: :never` keeps the
        # post-EHLO behaviour as "stay on the existing TLS connection".
        {[ssl: true, tls: :never],
         [
           tls_options: [
             versions: [:"tlsv1.2", :"tlsv1.3"],
             verify: :verify_peer,
             cacerts: :public_key.cacerts_get(),
             depth: 99,
             server_name_indication: String.to_charlist(smtp_relay),
             customize_hostname_check: [
               match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
             ]
           ]
         ]}

      :always ->
        # STARTTLS (typically port 587): connect plaintext, send EHLO,
        # then upgrade via STARTTLS. `ssl: false` keeps the initial
        # connection plaintext; `tls: :always` forces the upgrade.
        {[ssl: false, tls: :always],
         [
           tls_options: [
             versions: [:"tlsv1.2", :"tlsv1.3"],
             verify: :verify_peer,
             cacerts: :public_key.cacerts_get(),
             depth: 99,
             server_name_indication: String.to_charlist(smtp_relay),
             customize_hostname_check: [
               match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
             ]
           ]
         ]}

      :if_available ->
        # STARTTLS, opportunistic: try the upgrade if the server
        # advertises it, otherwise fall back to plaintext.
        {[ssl: false, tls: :if_available],
         [
           tls_options: [
             versions: [:"tlsv1.2", :"tlsv1.3"],
             verify: :verify_peer,
             cacerts: :public_key.cacerts_get(),
             depth: 99,
             server_name_indication: String.to_charlist(smtp_relay),
             customize_hostname_check: [
               match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
             ]
           ]
         ]}
    end

  # Map our high-level SMTP_AUTH_MODE values to gen_smtp_client's
  # `auth:` field, which accepts `:always` / `:never` / `:if_available`.
  #
  # `auth: :always`  — always authenticate; gen_smtp errors out if
  #                     username/password are missing.
  # `auth: :never`   — never authenticate.
  # `auth: :if_available` — authenticate only if the server advertises
  #                     AUTH and we have credentials. The default.
  smtp_gen_auth =
    case smtp_auth_mode do
      :username_password -> :always
      :none -> :never
      _ -> :if_available
    end

  # Add `:username`/`:password` only when auth is actually enabled.
  # gen_smtp_client raises if `:username` is set with `auth: :never`,
  # so this guards against a common misconfiguration (paste a username,
  # leave SMTP_AUTH_MODE on :auto and password blank — :auto picks
  # `:none` and the orphan :username trips the adapter on first send).
  smtp_opts =
    [
      adapter: Swoosh.Adapters.SMTP,
      relay: smtp_relay,
      port: smtp_port,
      hostname: smtp_domain
    ]
    |> then(fn opts -> opts ++ ssl_trigger end)
    |> then(fn opts -> opts ++ tls_options end)
    |> then(fn opts -> Keyword.put(opts, :auth, smtp_gen_auth) end)
    |> then(fn opts ->
      if smtp_gen_auth == :always do
        opts
        |> Keyword.put(:username, smtp_username)
        |> Keyword.put(:password, smtp_password)
      else
        opts
      end
    end)

  config :dtu_app, DtuApp.Mailer, smtp_opts

  config :dtu_app, :mail_from, System.get_env("MAIL_FROM", "dtu.app <noreply@localhost>")
end

# ── Passkeys / WebAuthn ────────────────────────────────────────────────────
# RP ID (origin's effective domain) and RP name (human-readable party name
# shown by the browser during the ceremony). Defaults are env-aware:
# `:dev`/`:test` → `"localhost"`, everything else → `"dtu.app"`. The
# per-env default lives in `DtuAppWeb.Passkeys.RpId.default/1` so it can
# be pinned by a unit test (see `test/dtu_app_web/passkeys/rp_id_test.exs`);
# operators override in any env via the `WEBAUTHN_RP_ID` env var.
#
# Why env-aware: the WebAuthn spec requires `rp.id` to be a
# registrable-domain suffix of the page origin. A prod deploy at
# `https://dtu.app` cannot use `"localhost"` — the browser raises
# `SecurityError: The operation is insecure` from
# `navigator.credentials.create/get`. The previous "always localhost"
# default was a transcription drift from the spec; this hardens the
# default at the actual deploy target.
config :dtu_app,
       :webauthn_rp_id,
       (case System.get_env("WEBAUTHN_RP_ID") do
          nil -> DtuAppWeb.Passkeys.RpId.default(config_env())
          "" -> DtuAppWeb.Passkeys.RpId.default(config_env())
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

# Rate-limit — defaults ON in every env (the plug is cheap: in-memory
# ETS sliding window keyed on `(remote_ip, action)`, and the existing
# controller test "429 rate_limited after 10 attempts" assumes
# enforcement is on in :test). CI flips it OFF via
# `PASSKEYS_RATE_LIMIT_ENABLED=false` so the Playwright e2e suite
# (--workers=1, retries: 2) doesn't trip the 10/60s/IP budget on its
# own retries. Operators can override with
# `PASSKEYS_RATE_LIMIT_ENABLED=true` (default) / `…=false` (bypass).
# See `DtuAppWeb.Passkeys.RateLimit` for the decision matrix.
config :dtu_app,
       :passkey_rate_limit_enabled,
       DtuAppWeb.Passkeys.RateLimit.enabled?(
         System.get_env("PASSKEYS_RATE_LIMIT_ENABLED"),
         config_env()
       )

# ── Dashboard mount-stage timing probe ──────────────────────────────────────
# Defaults OFF everywhere. Flip to `true` on a single prod instance (or
# a debug-fleet one) to capture one `Logger.info` line per cold mount
# with per-stage wall-clock measurements. The volume is low (one line
# per cold mount, only on the enabled instance) and the log format is
# grep-able (`mount_timing=true`). See
# `DtuAppWeb.DashboardLive.MountTiming` for the field contract.
config :dtu_app,
       :dashboard_mount_timing_log,
       System.get_env("DASHBOARD_MOUNT_TIMING_LOG", "false") in ~w(true 1)

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
      vapid: [
        public_key: vapid_pub,
        private_key: vapid_priv,
        subject: vapid_sub
      ]
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
