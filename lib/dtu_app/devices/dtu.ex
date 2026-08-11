defmodule DtuApp.Devices.Dtu do
  @moduledoc """
  A physical DTU (Data Transfer Unit) running OpenDTU or AhoyDTU firmware.

  Each DTU authenticates to the MQTT broker with its own `mqtt_username` /
  `mqtt_password`. The username is globally unique: the broker resolves an
  incoming connection to exactly one device by username alone.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds [:opendtu, :ahoydtu, :shelly3em]

  schema "dtus" do
    field :name, :string
    field :kind, Ecto.Enum, values: @kinds
    field :mqtt_username, :string
    field :mqtt_password, :string, redact: true
    field :mqtt_password_hash, :string, redact: true
    field :base_topic, :string, default: "solar"
    # Online/offline status is **derived** from `last_seen_at`, not
    # stored. See `online?/2` below. `last_seen_at` is touched on every
    # MQTT uplink (`DtuApp.MqttBroker.Telemetry`) and on CONNECT /
    # DISCONNECT, so the derived value tracks the DTU's actual liveness
    # in real time.
    field :last_seen_at, :utc_datetime_usec

    # Most recent error surfaced by the MQTT telemetry pipeline. Written
    # by `DtuApp.MqttBroker.Telemetry.record_dtu_error/2` whenever the
    # parser rejects an uplink or a `readings` insert fails. Read by the
    # dashboard and device-list LiveViews to render a bubble / fill so
    # users can see when a DTU is misconfigured or upstream is sending
    # malformed data. Both columns are nullable — a happy device has
    # NULLs and renders nothing.
    field :last_error, :string
    field :last_error_at, :utc_datetime_usec

    belongs_to :user, DtuApp.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a device owned by `user`.
  `mqtt_username`, `mqtt_password`, and `base_topic` are system-generated unless explicitly provided.
  """
  def create_changeset(user, attrs) when not is_nil(user) do
    %__MODULE__{}
    |> cast(attrs, [:name, :kind])
    |> validate_required([:name, :kind])
    |> put_change(:user_id, user.id)
    |> put_new_credentials(attrs)
    |> validate_length(:name, min: 1, max: 64)
    |> default_base_topic_for_kind(attrs)
    |> unique_constraint(:mqtt_username, name: :dtus_mqtt_username_index)
    |> unique_constraint(:name, name: :dtus_user_id_name_index)
    |> maybe_hash_password()
  end

  @doc """
  Changeset for updating a device. The username, password, and base topic cannot be changed by the user.
  """
  def update_changeset(%__MODULE__{} = dtu, attrs) do
    dtu
    |> cast(attrs, [:name, :kind])
    |> validate_required([:name, :kind])
    |> validate_length(:name, min: 1, max: 64)
    |> default_base_topic_for_kind(attrs)
    |> unique_constraint(:name, name: :dtus_user_id_name_index)
  end

  defp put_new_credentials(changeset, attrs) do
    username = Map.get(attrs, :mqtt_username) || Map.get(attrs, "mqtt_username")
    password = Map.get(attrs, :mqtt_password) || Map.get(attrs, "mqtt_password")

    username =
      username ||
        "dtu_" <> Base.hex_encode32(:crypto.strong_rand_bytes(8), case: :lower, padding: false)

    password =
      password || Base.hex_encode32(:crypto.strong_rand_bytes(12), case: :lower, padding: false)

    changeset
    |> put_change(:mqtt_username, username)
    |> put_change(:mqtt_password, password)
  end

  # Hash the password and store it in mqtt_password_hash.
  defp maybe_hash_password(changeset) do
    password = get_change(changeset, :mqtt_password)

    if password && password != "" && changeset.valid? do
      changeset
      |> put_change(:mqtt_password_hash, Argon2.hash_pwd_salt(password))
    else
      changeset
    end
  end

  # Update base_topic based on selected kind.
  defp default_base_topic_for_kind(changeset, attrs) do
    provided_topic = Map.get(attrs, :base_topic) || Map.get(attrs, "base_topic")

    cond do
      provided_topic && provided_topic != "" ->
        put_change(changeset, :base_topic, provided_topic)

      get_change(changeset, :kind) == :ahoydtu ->
        put_change(changeset, :base_topic, "inverter")

      get_change(changeset, :kind) == :opendtu ->
        put_change(changeset, :base_topic, "solar")

      get_change(changeset, :kind) == :shelly3em ->
        put_change(changeset, :base_topic, "shellies/shellyplus3em")

      true ->
        if is_nil(get_field(changeset, :base_topic)) do
          case get_field(changeset, :kind) do
            :ahoydtu -> put_change(changeset, :base_topic, "inverter")
            :opendtu -> put_change(changeset, :base_topic, "solar")
            :shelly3em -> put_change(changeset, :base_topic, "shellies/shellyplus3em")
            _ -> changeset
          end
        else
          changeset
        end
    end
  end

  @doc "Verify a plaintext password against the stored hash (constant-time)."
  def valid_password?(%__MODULE__{mqtt_password_hash: hash}, password)
      when is_binary(hash) and byte_size(password) > 0 do
    Argon2.verify_pass(password, hash)
  end

  def valid_password?(_, _) do
    Argon2.no_user_verify()
    false
  end

  # Threshold (in seconds) below which a DTU is considered online.
  # Five minutes gives enough headroom for OpenDTU's and AhoyDTU's
  # normal publish cadence (telemetry usually lands every 5–30 s) while
  # still flipping to offline within a few minutes of a silent drop —
  # WiFi blip, NAT timeout, power-cycle without a clean MQTT
  # DISCONNECT, etc. See `online?/2` for the comparison.
  @online_threshold_seconds 300

  @doc """
  Is this DTU currently online?

  Online is derived from `last_seen_at`: a DTU is online iff
  `now - last_seen_at < #{@online_threshold_seconds} s`. `last_seen_at`
  is touched on every MQTT uplink (and on CONNECT / DISCONNECT) by
  `DtuApp.MqttBroker.Telemetry`, so the answer reflects the DTU's
  real-time liveness rather than the last time the broker saw a TCP
  CONNECT.

  A `nil` `last_seen_at` (the device has never been seen) is offline.

  Pass `now` explicitly in tests to make the comparison deterministic
  relative to a fixed clock. Defaults to `DtuApp.Time.utc_now/0` so
  both sides of the comparison (the stored timestamp and the
  comparison time) come from the database clock — see the
  `DtuApp.Time` @moduledoc for why this matters.
  """
  @spec online?(%__MODULE__{}, DateTime.t()) :: boolean()
  def online?(dtu, now \\ nil)

  def online?(%__MODULE__{last_seen_at: nil}, _now), do: false

  def online?(%__MODULE__{last_seen_at: last_seen_at}, nil)
      when is_struct(last_seen_at, DateTime) do
    online?(%__MODULE__{last_seen_at: last_seen_at}, DtuApp.Time.utc_now())
  end

  def online?(%__MODULE__{last_seen_at: last_seen_at}, now)
      when is_struct(last_seen_at, DateTime) and is_struct(now, DateTime) do
    DateTime.diff(now, last_seen_at, :second) < @online_threshold_seconds
  end

  def online?(%__MODULE__{}, _now), do: false
end
