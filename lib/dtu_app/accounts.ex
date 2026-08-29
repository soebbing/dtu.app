defmodule DtuApp.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias DtuApp.Repo

  alias DtuApp.Accounts.{Passkey, SharedLink, User, UserToken, UserNotifier}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    # `authenticated_at` is populated from the session token's
    # `inserted_at`, which is written via `DtuApp.Time.utc_now()`; the
    # comparison side must use the same DB clock so it doesn't drift.
    DateTime.after?(ts, DtuApp.Time.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `DtuApp.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `DtuApp.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  @doc """
  Updates the user's notification preferences (`notify_dtu_connection`,
  `notify_sun_down`, `notify_sun_up`). The dashboard reads these via
  the LiveView's socket assigns to decide whether to push a browser
  notification.
  """
  def update_notification_settings(user, attrs) do
    user
    |> User.notification_settings_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Persists the user's local UTC offset (in seconds, positive east of
  UTC). Called by the dashboard on every `:set_timezone` push from
  the JS, so the server-side `SunUp` producer can compute "today" in
  the user's local TZ even when no LiveView is attached. Best-effort
  — returns `:ok` on success and logs + swallows failures so a
  transient DB hiccup doesn't break the dashboard render.
  """
  @spec update_user_tz_offset(User.t(), integer()) :: :ok | {:error, term()}
  def update_user_tz_offset(user, offset_seconds) when is_integer(offset_seconds) do
    user
    |> Ecto.Changeset.change(%{tz_offset_seconds: offset_seconds})
    |> Repo.update()
    |> case do
      {:ok, _user} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Persists the user's geographic position (decimal degrees, WGS84).
  Called by the dashboard once per session when the colocated JS
  hook resolves `navigator.geolocation.getCurrentPosition(...)`.

  Mirrors `update_user_tz_offset/2`'s best-effort contract: a failed
  write returns `{:error, reason}` rather than crashing the
  LiveView render, and a successful write returns `:ok` (not
  `{:ok, %User{}}`) so callers can use a one-line
  `_ = Accounts.update_user_location(user, ...)` check without
  pattern matching.

  `latitude` / `longitude` may be `nil` (the hook passes nil when
  the user denied geolocation or the browser doesn't support it) —
  `User.location_changeset/2` handles the nil-through case and
  zeros out any stored partial position from a prior write.
  """
  @spec update_user_location(User.t(), %{latitude: float() | nil, longitude: float() | nil}) ::
          :ok | {:error, term()}
  def update_user_location(user, %{latitude: _, longitude: _} = attrs) do
    user
    |> User.location_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, _user} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Builds a settings-changeset for the user. The form on
  `/users/settings` posts `euros_per_kwh` (a decimal string); the
  underlying `User.settings_changeset/2` converts that to whole
  cents and validates the range. This wrapper exists so the
  controller can pass the user through unchanged, matching the
  pattern used by `change_user_email/3` and `change_user_password/3`.
  """
  def change_user_settings(user, attrs \\ %{}) do
    User.settings_changeset(user, attrs)
  end

  @doc """
  Persists the user's account-wide settings. Currently only
  `cents_per_kwh` (the energy rate for the dashboard savings card);
  the changeset rejects negative or out-of-range rates. A successful
  call returns `{:ok, %User{}}`; a validation failure returns
  `{:error, %Ecto.Changeset{}}` for the controller to redisplay.
  """
  def update_user_settings(user, attrs) do
    user
    |> User.settings_changeset(attrs)
    |> Repo.update()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    case UserToken.verify_magic_link_token_query(token) do
      {:ok, query} ->
        case Repo.one(query) do
          # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
          {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
            raise """
            magic link log in is not allowed for unconfirmed users with a password set!

            This cannot happen with the default implementation, which indicates that you
            might have adapted the code to a different use case. Please make sure to read the
            "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
            """

          {%User{confirmed_at: nil} = user, _token} ->
            user
            |> User.confirm_changeset()
            |> update_user_and_delete_all_tokens()

          {user, token} ->
            Repo.delete!(token)
            {:ok, {user, []}}

          nil ->
            {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Shared links (anonymous current-day dashboard share)

  @doc """
  Returns the user's existing shared link, or `nil` if sharing is off.
  """
  @spec get_shared_link(User.t()) :: SharedLink.t() | nil
  def get_shared_link(%User{id: user_id}) do
    Repo.one(from(s in SharedLink, where: s.user_id == ^user_id))
  end

  @doc """
  Resolves a plaintext URL token (as received by the public `/s/:token`
  route) to its owning user, or `nil` if the token doesn't match any
  row. Looks up by SHA-256 hash so the raw token is never stored.
  """
  @spec get_user_by_share_token(String.t()) :: User.t() | nil
  def get_user_by_share_token(plaintext) when is_binary(plaintext) do
    hashed = SharedLink.hash(plaintext)

    query =
      from(s in SharedLink,
        where: s.token_hash == ^hashed,
        join: u in User,
        on: u.id == s.user_id,
        select: u
      )

    Repo.one(query)
  end

  @doc """
  Create (or replace) the user's active shared link. Returns
  `{plaintext_token, shared_link}` — the plaintext is what the caller
  puts into the UI for the user to copy. The plaintext is **not**
  stored; only its SHA-256 hash lands in the DB.

  If the user already has an active share, it is deleted first inside
  a transaction so the new token's `unique_index(:shared_links,
  [:token_hash])` won't collide on a re-toggled row.
  """
  @spec create_shared_link(User.t()) ::
          {:ok, {String.t(), SharedLink.t()}} | {:error, Ecto.Changeset.t()}
  def create_shared_link(%User{} = user) do
    {plaintext, hashed} = SharedLink.generate()

    Repo.transact(fn ->
      Repo.delete_all(from(s in SharedLink, where: s.user_id == ^user.id))

      %SharedLink{user_id: user.id, token_hash: hashed}
      |> SharedLink.changeset(%{user_id: user.id, token_hash: hashed})
      |> Repo.insert()
      |> case do
        {:ok, link} -> {:ok, {plaintext, link}}
        other -> other
      end
    end)
  end

  @doc """
  Revoke the user's shared link (toggle off). No-op if none exists.
  """
  @spec revoke_shared_link(User.t()) :: :ok
  def revoke_shared_link(%User{id: user_id}) do
    Repo.delete_all(from(s in SharedLink, where: s.user_id == ^user_id))
    :ok
  end

  ## Passkeys

  @doc """
  Creates a passkey for a user.

  Wraps `Passkey.registration_changeset/2` and inserts the row.
  Returns `{:ok, %Passkey{}}` on success, `{:error, %Ecto.Changeset{}}`
  on validation failure.

  ## Examples

      iex> create_passkey(%{user_id: id, credential_id: bytes, public_key: bytes, alg: -7, friendly_name: "MacBook"})
      {:ok, %Passkey{}}
  """
  def create_passkey(attrs) do
    %Passkey{}
    |> Passkey.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists every passkey enrolled for a user, oldest first.

  ## Examples

      iex> list_passkeys(user)
      [%Passkey{}, ...]
  """
  def list_passkeys(%User{id: user_id}) do
    from(p in Passkey, where: p.user_id == ^user_id, order_by: [asc: p.inserted_at])
    |> Repo.all()
  end

  @doc """
  Looks up a passkey by id, scoped to the given user.

  Returns `nil` if the passkey doesn't exist OR is owned by a
  different user. The user-scoping is intentional — callers must never
  see another user's passkey row, even briefly.

  A non-UUID `id` returns `nil` rather than raising, so a hand-crafted
  URL can't 500 the settings page.

  ## Examples

      iex> get_user_passkey(user, "b3d1...")
      %Passkey{}

      iex> get_user_passkey(user, "missing")
      nil
  """
  def get_user_passkey(%User{id: user_id}, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.one(from(p in Passkey, where: p.id == ^id and p.user_id == ^user_id))
      :error -> nil
    end
  end

  @doc """
  Looks up a passkey by its raw `credential_id` bytes (NOT base64url).

  Returns `nil` when no row matches.

  ## Examples

      iex> find_passkey_by_credential_id(<<0x01, 0x02, ...>>)
      %Passkey{}

      iex> find_passkey_by_credential_id(<<0xff, 0xfe, ...>>)
      nil
  """
  def find_passkey_by_credential_id(credential_id) when is_binary(credential_id) do
    Repo.get_by(Passkey, credential_id: credential_id)
  end

  @doc """
  Deletes a passkey owned by `user`. Refuses to delete a passkey that
  belongs to someone else.

  Returns `:ok` on successful delete, `{:error, :not_found}` if the
  passkey doesn't exist or isn't owned by the user.

  ## Examples

      iex> delete_passkey(user, passkey)
      :ok

      iex> delete_passkey(other_user, passkey)
      {:error, :not_found}
  """
  def delete_passkey(%User{id: user_id}, %Passkey{id: id, user_id: user_id}) do
    # `delete_all` rather than `Repo.delete/1` so a stale struct (row
    # already removed in another tab/request) reports `:not_found`
    # instead of raising a MatchError or Ecto.StaleEntryError.
    case Repo.delete_all(from(p in Passkey, where: p.id == ^id)) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  def delete_passkey(_user, _passkey), do: {:error, :not_found}

  @doc """
  Updates the sign_count and last_used_at on a passkey after a
  successful authentication. The strict-greater-than sign_count check
  is enforced by `Passkey.usage_changeset/2`.

  Returns `{:ok, %Passkey{}}` on success, `{:error, %Ecto.Changeset{}}`
  when the new sign_count doesn't exceed the previous one (replay signal).

  ## Examples

      iex> touch_passkey(passkey, %{sign_count: 6, last_used_at: ~U[2026-08-27 12:00:00Z]})
      {:ok, %Passkey{sign_count: 6}}
  """
  def touch_passkey(%Passkey{} = passkey, attrs) do
    passkey
    |> Passkey.usage_changeset(attrs)
    |> Repo.update()
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
