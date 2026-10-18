defmodule DtuApp.MqttBroker.Transport do
  @moduledoc """
  Thin ThousandIsland transport adapter for the embedded MQTT broker.

  This is a drop-in replacement for `MqttX.Transport.ThousandIsland`
  that additionally forwards `:read_timeout` to ThousandIsland.

  ## Why this module exists

  `MqttX.Server`'s bundled ThousandIsland adapter builds the
  ThousandIsland options from `:port`, `:ip`, `:num_acceptors`,
  `:transport_module`, `:transport_options`, and `:rate_limit` only.
  It never forwards `:read_timeout`, so ThousandIsland's default
  **60-second** read timeout always applies
  (`ThousandIsland.ServerConfig`). ThousandIsland closes a connection
  after 60 s without client data and calls
  `MqttX.Transport.Handler.handle_timeout/1`, which the broker turns
  into a `:dtu_disconnected` broadcast.

  MQTT itself already has a keepalive mechanism: the server enforces
  `1.5 × keep_alive` (from the client's CONNECT, or the
  `server_keep_alive` override for MQTT 5). A DTU whose keepalive is
  at or above 60 s therefore lost its socket on roughly a one-minute
  cadence even though it was perfectly healthy. Each reconnect then
  produced a `dtu_connection` notification.

  We disable the transport-level read timeout (`:infinity`) so only
  the MQTT keepalive governs liveness. The value can still be
  overridden via `:read_timeout` in the broker's start options if a
  deployment ever wants a hard idle cap.

  ## Relationship to MqttX

  The connection handler is still `MqttX.Transport.ThousandIsland.Handler`
  — we only reproduce the adapter's `start_link/3` wiring (including
  the retained-messages ETS table) so the MQTT protocol state machine
  stays upstream-owned.
  """

  @behaviour MqttX.Transport

  alias MqttX.Transport.ThousandIsland.Handler, as: MqttHandler

  @default_port 1883
  @default_num_acceptors 100
  @default_read_timeout :infinity

  @impl true
  def start_link(handler, handler_opts, opts) do
    port = Keyword.get(opts, :port, @default_port)
    ip = Keyword.get(opts, :ip, {0, 0, 0, 0})
    num_acceptors = Keyword.get(opts, :num_acceptors, @default_num_acceptors)
    read_timeout = Keyword.get(opts, :read_timeout, @default_read_timeout)

    transport_module =
      Keyword.get(opts, :transport_module, ThousandIsland.Transports.TCP)

    transport_options = Keyword.get(opts, :transport_options, [])

    retained_table = create_retained_table(port)

    rate_limiter =
      case Keyword.get(opts, :rate_limit) do
        nil -> nil
        rate_limit_opts -> MqttX.Server.RateLimiter.new(rate_limit_opts)
      end

    handler_options = %{
      handler: handler,
      handler_opts: handler_opts,
      transport_opts: opts,
      retained_table: retained_table,
      rate_limiter: rate_limiter
    }

    ThousandIsland.start_link(
      port: port,
      handler_module: MqttHandler,
      handler_options: handler_options,
      transport_module: transport_module,
      transport_options: [{:ip, ip} | transport_options],
      num_acceptors: num_acceptors,
      read_timeout: read_timeout
    )
  end

  @impl true
  def send(socket, data), do: ThousandIsland.Socket.send(socket, data)

  @impl true
  def close(socket) do
    ThousandIsland.Socket.close(socket)
    :ok
  end

  @impl true
  def peername(socket), do: ThousandIsland.Socket.peername(socket)

  @impl true
  def getopts(socket, opts), do: ThousandIsland.Socket.getopts(socket, opts)

  @impl true
  def setopts(socket, opts), do: ThousandIsland.Socket.setopts(socket, opts)

  # Same table name + options as `MqttX.Transport.ThousandIsland`, so
  # the retained-message store is compatible either way.
  defp create_retained_table(port) do
    table_name = :"mqttx_retained_#{port}"

    case :ets.whereis(table_name) do
      :undefined -> :ets.new(table_name, [:named_table, :public, :set])
      _ref -> table_name
    end
  end
end
