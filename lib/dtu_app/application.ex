defmodule DtuApp.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        DtuAppWeb.Telemetry,
        DtuApp.Repo,
        {DNSCluster, query: Application.get_env(:dtu_app, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: DtuApp.PubSub},
        # Start the MQTT credentials cache
        DtuApp.MqttBroker.Credentials
      ] ++
        mqtt_broker_children() ++
        [
          # Consumes DTU uplinks and parses OpenDTU telemetry. Must start after
          # PubSub (subscribes on init).
          {DtuApp.MqttBroker.Telemetry, :ok},
          # Start to serve requests, typically the last entry
          DtuAppWeb.Endpoint
        ]

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
end
