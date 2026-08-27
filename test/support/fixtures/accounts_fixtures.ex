defmodule DtuApp.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `DtuApp.Accounts` context.
  """

  import Ecto.Query

  alias DtuApp.Accounts
  alias DtuApp.Accounts.Passkey
  alias DtuApp.Accounts.Scope
  alias DtuApp.Repo

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email()
    })
  end

  def unconfirmed_user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Accounts.register_user()

    user
  end

  def user_fixture(attrs \\ %{}) do
    user = unconfirmed_user_fixture(attrs)

    token =
      extract_user_token(fn url ->
        Accounts.deliver_login_instructions(user, url)
      end)

    {:ok, {user, _expired_tokens}} =
      Accounts.login_user_by_magic_link(token)

    # `register_user/1` only persists `:email` (see
    # `User.email_changeset/2`), so notification flags handed in via
    # `attrs` are silently dropped. Apply them through
    # `update_notification_settings/2` so tests that want a user
    # with `notify_sun_up: true` actually get one.
    notification_attrs =
      Map.take(attrs, [:notify_dtu_connection, :notify_sun_down, :notify_sun_up])

    case notification_attrs do
      %{} = n when map_size(n) == 0 ->
        user

      _ ->
        {:ok, user} = Accounts.update_notification_settings(user, notification_attrs)
        user
    end
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  def set_password(user) do
    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: valid_user_password()})

    user
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    DtuApp.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_user_magic_link_token(user) do
    {encoded_token, user_token} = Accounts.UserToken.build_email_token(user, "login")
    DtuApp.Repo.insert!(user_token)
    {encoded_token, user_token.token}
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    DtuApp.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end

  def passkey_fixture(user_or_attrs, attrs \\ %{})

  def passkey_fixture(%DtuApp.Accounts.User{} = user, attrs) do
    passkey_fixture(%{user_id: user.id}, attrs)
  end

  def passkey_fixture(attrs, attrs_override) do
    merged = Map.merge(attrs, attrs_override)
    {user_attrs, pk_attrs} = Map.split(merged, [:user_id])

    pk_attrs =
      Enum.into(pk_attrs, %{
        user_id:
          Map.get(user_attrs, :user_id) ||
            user_fixture().id,
        credential_id: :crypto.strong_rand_bytes(32),
        # Passkey.public_key is stored as a CBOR-encoded binary (Task 5).
        # Controllers round-trip through CBOR.decode/1 before handing the
        # key to Webauthn.Cose.to_public_key/1, so the fixture must be
        # valid CBOR or the auth happy path hard-pattern-matches and 500s.
        # This is a minimal P-256 EC2 COSE map per RFC 8152 §7.
        public_key: CBOR.encode(%{1 => 2, 3 => -7, -1 => 1, -2 => <<4::256>>, -3 => <<4::256>>}),
        sign_count: 0,
        alg: -7,
        transports: [],
        friendly_name: "Test Passkey"
      })

    {:ok, passkey} =
      %Passkey{}
      |> Passkey.registration_changeset(pk_attrs)
      |> Repo.insert()

    passkey
  end
end
