defmodule DtuApp.Accounts.Passkey do
  use Ecto.Schema
  import Ecto.Changeset

  alias DtuApp.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "passkeys" do
    belongs_to :user, User

    field :credential_id, :binary
    field :public_key, :binary
    field :sign_count, :integer, default: 0
    field :alg, :integer
    field :transports, {:array, :string}, default: []
    field :friendly_name, :string
    field :last_used_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @max_name_length 60

  def registration_changeset(passkey, attrs) do
    passkey
    |> cast(attrs, [
      :user_id,
      :credential_id,
      :public_key,
      :sign_count,
      :alg,
      :transports,
      :friendly_name
    ])
    |> validate_required([:user_id, :credential_id, :public_key, :alg, :friendly_name])
    |> validate_length(:friendly_name, min: 1, max: @max_name_length)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:credential_id)
  end

  def usage_changeset(passkey, attrs) do
    passkey
    # `force_changes: true` so that a usage update with the same
    # `sign_count` as the persisted record still produces a change
    # for `validate_change/3` to inspect. Without it, Ecto's `cast/4`
    # drops the field when the new value equals the existing value,
    # silently letting `sign_count` stall (the WebAuthn clone-detector
    # trap we explicitly want to catch).
    |> cast(attrs, [:sign_count, :last_used_at], force_changes: true)
    |> validate_required([:sign_count, :last_used_at])
    |> validate_change(:sign_count, fn :sign_count, new_count ->
      # The strict-monotonic check is the WebAuthn clone detector
      # (spec §7.2 step 19). The spec carves out the no-sign-count-
      # authenticator case: when BOTH stored and new counts are zero,
      # the authenticator simply doesn't track usage and equality is
      # the legitimate state. Otherwise the new count must be
      # strictly greater than the stored one — anything else is a
      # clone signal.
      cond do
        new_count > passkey.sign_count ->
          []

        new_count == 0 and passkey.sign_count == 0 ->
          []

        true ->
          [sign_count: "must be strictly greater than the stored value (replay signal)"]
      end
    end)
  end
end
