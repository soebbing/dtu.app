defmodule DtuApp.MqttBroker.Credentials do
  @moduledoc """
  In-memory cache of DTU MQTT credentials for the broker's connect hot path.

  The broker resolves an incoming connection to a device by `mqtt_username`
  alone, then verifies the password with a constant-time Argon2 check. To keep
  that path off the database, credentials live in two ETS tables owned by this
  GenServer:

    * `:mqtt_credentials` — `username => password_hash`
    * `:mqtt_devices`     — `username => %{id, user_id, kind, base_topic, name}`

  The `Devices` context calls `refresh/1` after a create/update and `drop/1`
  after a delete so the cache tracks the database without a broker restart.
  """

  use GenServer

  require Logger

  alias DtuApp.Repo
  alias DtuApp.Devices.Dtu

  # --- Public API -------------------------------------------------------------

  @doc """
  Start the credentials cache GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Verify a username and password in constant time.
  Returns `{:ok, device_map}` if credentials are valid, `{:error, :unauthorized}` otherwise.
  """
  @spec verify(String.t() | nil, String.t() | nil) :: {:ok, map()} | {:error, :unauthorized}
  def verify(username, password) when is_binary(username) and is_binary(password) do
    case :ets.lookup(:mqtt_credentials, username) do
      [{^username, hash}] ->
        if Argon2.verify_pass(password, hash) do
          case :ets.lookup(:mqtt_devices, username) do
            [{^username, device}] -> {:ok, device}
            [] -> {:error, :unauthorized}
          end
        else
          {:error, :unauthorized}
        end

      [] ->
        Argon2.no_user_verify()
        {:error, :unauthorized}
    end
  end

  def verify(_, _) do
    Argon2.no_user_verify()
    {:error, :unauthorized}
  end

  @doc """
  Re-seed the cached credential for `username` from the database.
  """
  @spec refresh(String.t()) :: :ok
  def refresh(username) when is_binary(username) do
    GenServer.call(__MODULE__, {:refresh, username})
  end

  @doc """
  Evict the cached credential for `username` (after a device is deleted).
  """
  @spec drop(String.t()) :: :ok
  def drop(username) when is_binary(username) do
    GenServer.call(__MODULE__, {:drop, username})
  end

  # --- GenServer Callbacks ----------------------------------------------------

  @impl true
  def init(_opts) do
    # Create the named ETS tables. The owner is this GenServer process.
    :ets.new(:mqtt_credentials, [:set, :protected, :named_table])
    :ets.new(:mqtt_devices, [:set, :protected, :named_table])

    # Populate tables from the database on startup
    populate_cache()

    {:ok, %{}}
  end

  @impl true
  def handle_call({:refresh, username}, _from, state) do
    case Repo.get_by(Dtu, mqtt_username: username) do
      nil ->
        :ets.delete(:mqtt_credentials, username)
        :ets.delete(:mqtt_devices, username)

      device ->
        insert_device(device)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:drop, username}, _from, state) do
    :ets.delete(:mqtt_credentials, username)
    :ets.delete(:mqtt_devices, username)
    {:reply, :ok, state}
  end

  # --- Helper Functions -------------------------------------------------------

  defp populate_cache do
    # Only load if the DB table exists (prevents crashes during first migrations)
    try do
      Repo.all(Dtu)
      |> Enum.each(&insert_device/1)
      Logger.info("[CredentialsCache] loaded devices into ETS")
    rescue
      _ ->
        Logger.warning("[CredentialsCache] Could not seed cache, table 'dtus' might not exist yet")
    end
  end

  defp insert_device(%Dtu{} = device) do
    :ets.insert(:mqtt_credentials, {device.mqtt_username, device.mqtt_password_hash})

    device_info = %{
      id: device.id,
      user_id: device.user_id,
      kind: device.kind,
      base_topic: device.base_topic,
      name: device.name
    }

    :ets.insert(:mqtt_devices, {device.mqtt_username, device_info})
  end
end
