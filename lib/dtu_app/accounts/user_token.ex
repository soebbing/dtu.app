defmodule DtuApp.Accounts.UserToken do
  use Ecto.Schema
  import Ecto.Query
  alias DtuApp.Accounts.UserToken

  @hash_algorithm :sha256
  @rand_size 32

  # It is very important to keep the magic link token expiry short,
  # since someone with access to the email may take over the account.
  @magic_link_validity_in_minutes 15
  @change_email_validity_in_days 7
  @session_validity_in_days 14

  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :authenticated_at, :utc_datetime
    belongs_to :user, DtuApp.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Generates a token that will be stored in a signed place,
  such as session or cookie. As they are signed, those
  tokens do not need to be hashed.

  The reason why we store session tokens in the database, even
  though Phoenix already provides a session cookie, is because
  Phoenix's default session cookies are not persisted, they are
  simply signed and potentially encrypted. This means they are
  valid indefinitely, unless you change the signing/encryption
  salt.

  Therefore, storing them allows individual user
  sessions to be expired. The token system can also be extended
  to store additional data, such as the device used for logging in.
  You could then use this information to display all valid sessions
  and devices in the UI and allow users to explicitly expire any
  session they deem invalid.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    # Use the database clock for `authenticated_at` AND `inserted_at` so the
    # comparison in `verify_session_token_query/1` (`token.inserted_at >
    # ^cutoff`) round-trips through one and only one time source — the DB.
    # The schema's `timestamps(type: :utc_datetime, updated_at: false)` macro
    # would otherwise auto-fill `inserted_at` from `DateTime.utc_now()` on the
    # app container, reintroducing app↔DB clock drift on the verify query.
    # See `DtuApp.Time` for the rationale and the
    # `set_db_clock_defaults_for_time_columns` migration for the column-level
    # safety net.
    dt = user.authenticated_at || DtuApp.Time.utc_now()

    {token,
     %UserToken{
       token: token,
       context: "session",
       user_id: user.id,
       authenticated_at: dt,
       inserted_at: DtuApp.Time.utc_now()
     }}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user found by the token, if any, along with the token's creation time.

  The token is valid if it matches the value in the database and it has
  not expired (after @session_validity_in_days).
  """
  def verify_session_token_query(token) do
    # Pin the cutoff to the database clock so the comparison matches the
    # clock that wrote `inserted_at`. Previously this used `ago(N, "day")`
    # which is also DB-side, but the write site used `DateTime.utc_now()`
    # on the app — two clocks, possible drift. See `DtuApp.Time`.
    cutoff = DtuApp.Time.utc_now() |> DateTime.add(-@session_validity_in_days, :day)

    query =
      from token in by_token_and_context_query(token, "session"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ^cutoff,
        select: {%{user | authenticated_at: token.authenticated_at}, token.inserted_at}

    {:ok, query}
  end

  @doc """
  Builds a token and its hash to be delivered to the user's email.

  The non-hashed token is sent to the user email while the
  hashed part is stored in the database. The original token cannot be reconstructed,
  which means anyone with read-only access to the database cannot directly use
  the token in the application to gain access. Furthermore, if the user changes
  their email in the system, the tokens sent to the previous email are no longer
  valid.

  Users can easily adapt the existing code to provide other types of delivery methods,
  for example, by phone numbers.
  """
  def build_email_token(user, context) do
    build_hashed_token(user, context, user.email)
  end

  defp build_hashed_token(user, context, sent_to) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    # Route `inserted_at` through the DB clock — see the matching comment in
    # `build_session_token/1`. Without this explicit assignment, Ecto's
    # `timestamps(type: :utc_datetime, updated_at: false)` macro would
    # auto-fill `inserted_at` from `DateTime.utc_now()` on the app container,
    # defeating the migration's `DEFAULT now()` safety net and reintroducing
    # app↔DB clock drift in `verify_magic_link_token_query/1` and
    # `verify_change_email_token_query/2`.
    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: hashed_token,
       context: context,
       sent_to: sent_to,
       user_id: user.id,
       inserted_at: DtuApp.Time.utc_now()
     }}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  If found, the query returns a tuple of the form `{user, token}`.

  The given token is valid if it matches its hashed counterpart in the
  database. This function also checks whether the token has expired. The context
  of a magic link token is always "login".

  Tokens come from `Base.url_encode64/2` (no padding, URL-safe alphabet)
  but they reach us through a real email round-trip — an email client
  may append `=` padding (URL-safe base64 → standard base64 padding
  conversion), trailing whitespace from a soft line break in the
  body, or quote-printable line-fold sequences (`=\r\n` → empty) when
  the URL crosses the 76-column QP wrap boundary. `Base.url_decode64/2`
  with `padding: false` rejects all of these as invalid base64url.

  `sanitize_magic_link_token/1` strips QP artifacts and re-pads before
  `Base.url_decode64/2` runs, so a clean copy-paste from any email
  client resolves to the same decoded token.
  """
  def verify_magic_link_token_query(token) do
    case sanitize_magic_link_token(token) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        # Pin the cutoff to the database clock. The magic-link window is
        # only 15 minutes wide, so even a few minutes of app↔DB clock drift
        # would mis-classify a freshly-issued link as "expired" on click —
        # the production bug this whole refactor exists to prevent.
        cutoff =
          DtuApp.Time.utc_now() |> DateTime.add(-@magic_link_validity_in_minutes, :minute)

        query =
          from token in by_token_and_context_query(hashed_token, "login"),
            join: user in assoc(token, :user),
            where: token.inserted_at > ^cutoff,
            where: token.sent_to == user.email,
            select: {user, token}

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Strip the artifacts that real email round-trips append to a magic-link
  token before calling `Base.url_decode64/2`.

  Handles the three real-world noise sources:
    * **Whitespace at the start / end** of the token — copy-paste
      artifacts, address-bar formatting, an accidental trailing space.
      `String.trim/1` strips only leading and trailing whitespace, so
      the original token bytes in the middle are preserved.
    * **Quoted-printable soft-line-break markers `=\r\n` / `=\n`** —
      inserted when an email body wraps a long URL at column 76. They
      appear anywhere in the string (most often mid-token).
    * **Trailing `=` padding** that some email clients append when they
      confuse base64url with standard base64.

  Intentionally does NOT strip middle whitespace — a paste with
  arbitrary characters between letters is a typo, not an email-client
  artifact. Rejecting those cases is the correct UX (the user gets the
  "Magic link is invalid" flash and retries).
  """
  @spec sanitize_magic_link_token(String.t()) :: {:ok, binary()} | :error
  def sanitize_magic_link_token(token) when is_binary(token) do
    sanitized =
      token
      # QP soft-line-break: `=\r\n` (Windows / RFC standard) or `=\n`
      # (some clients strip the `\r` themselves first). These are
      # zero-width line-break markers — collapse them to nothing so the
      # base64url chars on either side reconnect.
      |> String.replace("=\r\n", "")
      |> String.replace("=\n", "")
      # Trim twice: once before stripping the trailing `=` (to remove
      # surrounding whitespace from a copy-paste), and once after (to
      # remove any whitespace that was sitting just past the trailing
      # `=`, e.g. `" =  "` at the end). base64url has no whitespace
      # anywhere in its alphabet, so any in the token is noise. Trim
      # both ends without touching the middle.
      |> String.trim()
      # Trailing `=` padding that some clients add when they confuse
      # base64url with standard base64. Trim only the end (`=$`); an
      # embedded `=` mid-token would have been a QP marker, which the
      # earlier `String.replace` already collapsed.
      |> String.replace(~r/=+$/, "")
      |> String.trim()

    case sanitized do
      "" ->
        :error

      s when byte_size(s) >= 43 ->
        # 32 raw bytes encode to 43 base64url chars without padding.
        # Anything shorter is malformed.
        case Base.url_decode64(s, padding: false) do
          {:ok, decoded} when byte_size(decoded) == 32 -> {:ok, decoded}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def sanitize_magic_link_token(_), do: :error

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user_token found by the token, if any.

  This is used to validate requests to change the user
  email.
  The given token is valid if it matches its hashed counterpart in the
  database and if it has not expired (after @change_email_validity_in_days).
  The context must always start with "change:".
  """
  def verify_change_email_token_query(token, "change:" <> _ = context) do
    case sanitize_magic_link_token(token) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        cutoff =
          DtuApp.Time.utc_now() |> DateTime.add(-@change_email_validity_in_days, :day)

        query =
          from token in by_token_and_context_query(hashed_token, context),
            where: token.inserted_at > ^cutoff

        {:ok, query}

      :error ->
        :error
    end
  end

  defp by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end
end
