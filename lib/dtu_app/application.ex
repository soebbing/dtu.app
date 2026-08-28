defmodule DtuApp.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Public named ETS table for the passkey rate-limit plug. Created
    # here, BEFORE the supervision tree starts, so it lives for the
    # lifetime of the application master process — `:public` and
    # `:named_table` make it accessible from any process via
    # `:ets.lookup/2` / `:ets.insert/2` without a GenServer wrapper.
    # `read_concurrency: true` lets many requests read in parallel;
    # `write_concurrency` stays off (single writer at a time, which
    # is fine for our traffic). The brief's intended tuple form
    # `{:ets, :passkey_rate_limit, opts}` is the deprecated
    # `Supervisor.Spec` shorthand and is rejected by current
    # supervisors — creating the table pre-supervision is the
    # canonical Elixir pattern for a top-level named table.
    :ets.new(:passkey_rate_limit, [:set, :public, :named_table, read_concurrency: true])

    # Finch HTTP pool dedicated to the `web_push` library. We
    # supervise our own pool (named `DtuAppWeb.WebPushFinch`) so
    # push traffic never shares a connection pool with anything
    # else in the app — a slow push service (FCM, Apple) can
    # never back up unrelated HTTP work. `config :web_push, finch:
    # DtuAppWeb.WebPushFinch` (in `runtime.exs`) tells the library
    # which pool to use.
    children =
      ([
         DtuAppWeb.Telemetry,
         DtuApp.Repo,
         {DNSCluster, query: Application.get_env(:dtu_app, :dns_cluster_query) || :ignore},
         {Phoenix.PubSub, name: DtuApp.PubSub},
         {Finch, name: DtuAppWeb.WebPushFinch},
         {DtuApp.Accounts.PasskeyChallengeCache, []}
       ] ++
         mqtt_broker_children() ++
         [
           # Consumes DTU uplinks and parses OpenDTU telemetry. Must start after
           # PubSub (subscribes on init).
           {DtuApp.MqttBroker.Telemetry, :ok},
           # Live buffer of every MQTT topic a DTU has published recently.
           # Powers the device-details LiveView's "all topics, not just
           # the ones the parser interprets" tree. Independent of the
           # parser's normal reading-rows path — its uplink subscription
           # is parallel to `Telemetry`'s, so a slow parser never
           # back-pressures the live-topic capture. Started after
           # PubSub for the same reason as `Telemetry`.
           {DtuApp.MqttBroker.TopicRegistry, :ok},
           # Server-side producers for `event: "dtu_connection"` and
           # `event: "sun_down"` notifications. These used to live in
           # the dashboard LiveView's `handle_info/2` clauses, which
           # meant notifications only fired while a LV process was
           # alive (i.e. while the user had a tab open). Moving the
           # producers into supervised GenServers lets the in-page and
           # native-push fan-out fire even when the user has no tab
           # open — the dashboard's LV was the only consumer, and a
           # closed tab silently disabled both. Started after the
           # broker / Telemetry GenServers so the broker's
           # `:dtu_connected` / `:dtu_disconnected` broadcasts on
           # `dtu:presence` are already flowing on the PubSub layer.
           #
           # Skipped in `:test` because the singleton producers use
           # `Repo` from inside their `handle_info/2` callbacks, and
           # the Ecto SQL Sandbox (`:manual` mode, see
           # `test_helper.exs`) only allows the checked-out test
           # process to use the connection. Running the producers in
           # tests races the per-test sandbox owner: a producer
           # callback lands after the test process exits → its
           # connection is reclaimed → the next test's `checkout`
           # sees the Repo as unregistered. The producer behaviour is
           # exercised by the dedicated notifier tests under
           # `test/dtu_app/notifications/`, which spawn their own
           # dedicated GenServers via `start_supervised!/1` and so
           # never touch the application tree's instance.
           # Start to serve requests, typically the last entry
           notifier_children() ++
             [DtuAppWeb.Endpoint]
         ])
      |> List.flatten()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DtuApp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DtuAppWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Children for the embedded MQTT broker (MqtX). Disabled in environments that
  # set `enabled: false` (e.g. test), so nothing binds the broker port there.
  # Started after PubSub so the broker callbacks can broadcast on connect.
  defp mqtt_broker_children do
    cfg = Application.get_env(:dtu_app, :mqtt_broker, [])

    if Keyword.get(cfg, :enabled, true) do
      port = Keyword.get(cfg, :port, 1883)
      transport_opts = Keyword.get(cfg, :transport_opts, %{})

      [
        # Credentials cache must start before the broker so handle_connect can
        # verify against it. Gated with the broker (both off in test).
        DtuApp.MqttBroker.Credentials,
        %{
          id: DtuApp.MqttBroker.Broker,
          start:
            {MqttX.Server, :start_link,
             [DtuApp.MqttBroker.Broker, [], [port: port, transport_opts: transport_opts]]}
        }
      ]
    else
      []
    end
  end

  # Notification producer GenServers. Off in `:test` (see the long
  # comment in `start/2` above for the sandbox-ownership reason).
  #
  # The gate reads `Application.get_env/3` against a config-driven flag,
  # **not** `Mix.env/0` — `Mix` is a compile-time tooling module that
  # isn't loaded in OTP releases, so calling `Mix.env/0` here would
  # crash production boot before the supervision tree is up. See the
  # regression test in `test/dtu_app/application_test.exs`.
  defp notifier_children do
    if Application.get_env(:dtu_app, :notifier_children, [])[:enabled] == false do
      []
    else
      [
        DtuApp.Notifications.DtuConnection,
        DtuApp.Notifications.SunDown,
        DtuApp.Notifications.SunUp
      ]
    end
  end
end
