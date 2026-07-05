defmodule DtuApp.Devices.Dtu do
  @moduledoc """
  A physical DTU (Data Transfer Unit) running OpenDTU or AhoyDTU firmware.

  Each DTU authenticates to the MQTT broker with its own `mqtt_username` /
  `mqtt_password`. The username is globally unique: the broker resolves an
  incoming connection to exactly one device by username alone.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds [:opendtu, :ahoydtu]

  schema "dtus" do
    field :name, :string
    field :kind, Ecto.Enum, values: @kinds
    field :mqtt_username, :string
    field :mqtt_password, :string, redact: true
    field :mqtt_password_hash, :string, redact: true
    field :base_topic, :string, default: "solar"
    field :online, :boolean, default: false
    field :last_seen_at, :utc_datetime_usec

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

    username = username || ("dtu_" <> Base.hex_encode32(:crypto.strong_rand_bytes(8), case: :lower, padding: false))
    password = password || Base.hex_encode32(:crypto.strong_rand_bytes(12), case: :lower, padding: false)
    
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

      true ->
        if is_nil(get_field(changeset, :base_topic)) do
          case get_field(changeset, :kind) do
            :ahoydtu -> put_change(changeset, :base_topic, "inverter")
            :opendtu -> put_change(changeset, :base_topic, "solar")
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
end
