defmodule DtuApp.MqttBroker.Broker do
  @moduledoc """
  Embedded MQTT broker that DTUs connect to and publish telemetry on.

  DTUs publish OpenDTU-format JSON payloads (see the project plan). This broker
  is a thin bridge between the raw MQTT connections and the rest of the
  application: every uplink PUBLISH is broadcast on `Phoenix.PubSub` so that
  telemetry ingestion, LiveViews, etc. can consume it without coupling to the
  connection process.

  Servers are per-connection state machines, so `state` here is one device's
  state. App-wide coordination happens through PubSub, not through this process.
  """

  use MqttX.Server

  require Logger

  # PubSub topic prefixes. A connected device subscribes to its own downlink
  # topic on connect so the app can push commands to it via
  # `DtuApp.MqttBroker.publish_downlink/2`.
  @uplink_topic "dtu:uplink"
  @presence_topic "dtu:presence"

  @impl true
  def init(_opts) do
    # Per-connection state.
    %{client_id: nil, device: nil}
  end

  @impl true
  def handle_connect(client_id, credentials, state) do
    # Fallback for the 3-arity behaviour callback. The 4-arity variant below
    # takes precedence when defined (it carries the connect metadata), so this
    # clause only runs if the transport ever calls the 3-arity form.
    handle_connect(client_id, credentials, %{protocol_version: nil, keep_alive: nil}, state)
  end

  @impl true
  def handle_connect(client_id, credentials, connect_info, state) do
    Logger.info(
      "[MQTT] CONNECT client_id=#{client_id} v#{connect_info.protocol_version} " <>
        "keepalive=#{connect_info.keep_alive}"
    )

    username = Map.get(credentials || %{}, :username)
    password = Map.get(credentials || %{}, :password)

    case DtuApp.MqttBroker.Credentials.verify(username, password) do
      {:ok, device} ->
        # Subscribe this connection process to its own downlink channel so the app
        # can fan commands out to the device.
        Phoenix.PubSub.subscribe(DtuApp.PubSub, downlink_topic(client_id))

        Phoenix.PubSub.broadcast(DtuApp.PubSub, @presence_topic, {:dtu_connected, client_id, device.id})

        {:ok, Map.merge(state, %{client_id: client_id, device: device})}

      {:error, _reason} ->
        Logger.warning("[MQTT] CONNECT AUTH FAILED client_id=#{client_id} username=#{inspect(username)}")
        {:error, 0x86, state}
    end
  end

  @impl true
  def handle_publish(topic, payload, _opts, state) do
    topic_str = Enum.join(topic, "/")

    Logger.debug("[MQTT] PUBLISH client_id=#{state.client_id} topic=#{topic_str}")

    # Broadcast the uplink for the rest of the app to consume. Include authenticated device info.
    Phoenix.PubSub.broadcast(
      DtuApp.PubSub,
      @uplink_topic,
      {:uplink, state.client_id, state.device, topic_str, payload}
    )

    {:ok, state}
  end

  @impl true
  def handle_subscribe(topics, state) do
    # Grant each requested topic its own requested QoS. OpenDTU telemetry is
    # fire-and-forget, so devices usually subscribe at QoS 0.
    {:ok, Enum.map(topics, & &1.qos), state}
  end

  @impl true
  def handle_unsubscribe(_topics, state) do
    {:ok, state}
  end

  @impl true
  def handle_disconnect(reason, state) do
    Logger.info("[MQTT] DISCONNECT client_id=#{state.client_id} reason=#{inspect(reason)}")

    if state.client_id do
      device_id = if state.device, do: state.device.id, else: nil

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        @presence_topic,
        {:dtu_disconnected, state.client_id, device_id}
      )
    end

    :ok
  end

  @impl true
  def handle_info({:downlink, topic, payload, opts}, state) do
    # Fan-out from the app to the device. The transport turns this tuple into a
    # PUBLISH packet sent over the connection.
    {:publish, topic, payload, Map.take(opts, [:qos, :retain]), state}
  end

  def handle_info(_message, state) do
    {:ok, state}
  end

  # --- Public helpers for the rest of the app ---------------------------------

  @doc """
  Publish a downlink message to a connected device by its `client_id`.

  Returns `:ok` regardless of whether the device is currently connected — the
  message is simply dropped if nothing is subscribed to the downlink topic.
  """
  @spec publish_downlink(String.t(), String.t(), binary(), keyword()) :: :ok
  def publish_downlink(client_id, topic, payload, opts \\ []) do
    Phoenix.PubSub.broadcast(
      DtuApp.PubSub,
      downlink_topic(client_id),
      {:downlink, topic, payload, Map.new(opts)}
    )
  end

  @doc "Subscribe the calling process to all telemetry uplinks."
  @spec subscribe_uplink() :: :ok | {:error, term()}
  def subscribe_uplink, do: Phoenix.PubSub.subscribe(DtuApp.PubSub, @uplink_topic)

  @doc "Subscribe the calling process to device connect/disconnect presence."
  @spec subscribe_presence() :: :ok | {:error, term()}
  def subscribe_presence, do: Phoenix.PubSub.subscribe(DtuApp.PubSub, @presence_topic)

  defp downlink_topic(client_id), do: "dtu:downlink:#{client_id}"
end
