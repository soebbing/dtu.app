defmodule DtuAppWeb.PasskeyController do
  @moduledoc """
  HTTP endpoints for the browser-side WebAuthn ceremony.

  Two registration actions (`registration_options`, `verify_registration`)
  require an authenticated session; two authentication actions
  (`authentication_options`, `verify_authentication`) require an
  anonymous session. All four are JSON in/out and gated by the
  `PASSKEYS_ENABLED` kill switch.

  Rate limiting is enforced per `(remote_ip, action)` pair by
  `DtuAppWeb.Plugs.PasskeyRateLimit` (Task 4).

  Challenge state is held in `DtuApp.Accounts.PasskeyChallengeCache`
  (Task 3) for the duration of a single ceremony; the cookie holds
  only the `request_id` (32 hex chars).
  """

  use DtuAppWeb, :controller

  alias DtuApp.Accounts
  alias DtuApp.Accounts.PasskeyChallengeCache

  require Logger

  # ── Relying-party identity ────────────────────────────────────────
  # Compiled at boot from `config :dtu_app, :webauthn_rp_id / :webauthn_rp_name`
  # (see `config/runtime.exs` / `config/test.exs`). The defaults are
  # "localhost" / "dtu.app" — safe for dev, prod needs WEBAUTHN_RP_ID
  # + WEBAUTHN_RP_NAME env vars.
  @rp_id Application.compile_env(:dtu_app, [:webauthn_rp_id], "localhost")
  @rp_name Application.compile_env(:dtu_app, [:webauthn_rp_name], "dtu.app")
  # ES256 + RS256. Matches the algorithm set in the demo browsers and
  # is the minimum a real authenticator will offer — adding more algs
  # just expands the attack surface for attestation trust.
  @algorithms [-7, -257]
  @timeout_ms 5 * 60 * 1000

  # ---------- Registration ----------

  def registration_options(conn, %{"friendly_name" => friendly_name}) do
    conn = put_private(conn, :passkey_action, "registration_options")

    guard(conn, fn ->
      with_user(conn, fn user ->
        existing_ids =
          user.id
          |> Accounts.list_passkeys()
          |> Enum.map(& &1.credential_id)
          |> Enum.map(&Base.url_encode64(&1, padding: false))

        challenge = Webauthn.challenge()

        public_key =
          Webauthn.registration_challenge(challenge, %{
            "rp" => %{"id" => rp_id(), "name" => rp_name()},
            "user" => %{
              "id" => Base.url_encode64(to_string(user.id), padding: false),
              "name" => user.email,
              "displayName" => user.email
            },
            "pubKeyCredParams" =>
              Enum.map(@algorithms, fn alg ->
                %{"type" => "public-key", "alg" => alg}
              end),
            "excludeCredentials" =>
              Enum.map(existing_ids, fn id ->
                %{"id" => id, "type" => "public-key"}
              end),
            "timeout" => @timeout_ms
          })

        request_id = generate_request_id()

        PasskeyChallengeCache.put(request_id, %{
          challenge: challenge,
          user_id: user.id,
          kind: :registration,
          friendly_name: friendly_name
        })

        conn = put_passkey_cookie(conn, request_id)

        Logger.info("passkey registration begin user_id=#{user.id} ip=#{inspect(conn.remote_ip)}")

        json(conn, %{request_id: request_id, publicKey: public_key})
      end)
    end)
  end

  def registration_options(conn, _params) do
    conn = put_private(conn, :passkey_action, "registration_options")

    guard(conn, fn ->
      json(conn |> put_status(:bad_request), %{error: "missing_friendly_name"})
    end)
  end

  def verify_registration(conn, %{"request_id" => request_id, "attestation_response" => response})
      when is_map(response) do
    conn = put_private(conn, :passkey_action, "verify_registration")

    guard(conn, fn ->
      with_user(conn, fn user ->
        # CSRF replay protection (spec §6 step 1): the body's
        # request_id must match the cookie set by registration/begin.
        # A mismatch means someone hijacked the request body or the
        # browser swapped cookies between begin and finish.
        with {:ok, cookie_rid} <- assert_cookie_matches(conn, request_id),
             {:ok,
              %{
                challenge: challenge,
                user_id: _cached_user_id,
                kind: :registration,
                friendly_name: friendly_name
              }} <- PasskeyChallengeCache.fetch_and_delete(cookie_rid),
             {:ok, auth_data} <-
               Webauthn.registration_response(
                 %{
                   "challenge" => challenge,
                   "origin" => request_origin(conn),
                   "rp" => %{"id" => rp_id()}
                 },
                 Map.get(response["response"] || %{}, "attestationObject", ""),
                 get_in(response, ["response", "clientDataJSON"]) || ""
               ),
             %{} = acd <- Map.get(auth_data, :attested_credential_data),
             {:ok, passkey} <-
               Accounts.create_passkey(%{
                 user_id: user.id,
                 credential_id: Map.fetch!(acd, :credential_id),
                 # `webauthn ~> 0.0.9` returns the parsed COSE
                 # public-key as a CBOR-decoded map. The schema
                 # (`Passkey.public_key :binary`) expects a binary,
                 # so re-encode to CBOR before persisting — round-
                 # trip preserves every field the library parses.
                 public_key: CBOR.encode(Map.fetch!(acd, :credential_public_key)),
                 sign_count: Map.fetch!(auth_data, :sign_count),
                 # COSE alg identifier lives at key `3` per RFC 8152
                 # §7. The schema's `validate_required([:alg])` rejects
                 # the row if this pattern fails (malformed key).
                 alg:
                   case Map.fetch!(acd, :credential_public_key) do
                     %{3 => alg} when is_integer(alg) -> alg
                     _ -> nil
                   end,
                 transports:
                   Map.get(response["response"] || %{}, "transports", [])
                   |> Enum.map(&to_string/1),
                 friendly_name: friendly_name
               }) do
          Logger.info("passkey enrolled passkey_id=#{passkey.id} user_id=#{user.id}")

          conn
          |> put_status(:created)
          |> json(%{passkey_id: passkey.id, friendly_name: passkey.friendly_name})
        else
          {:error, :request_id_mismatch} ->
            json(conn |> put_status(:bad_request), %{error: "request_id_mismatch"})

          {:error, :not_found} ->
            json(conn |> put_status(:bad_request), %{error: "challenge_expired"})

          {:error, :credential_already_enrolled} ->
            conn
            |> put_status(:conflict)
            |> json(%{error: "credential_already_enrolled"})

          # The `webauthn ~> 0.0.9` library returns verification failures
          # as `{:error, "Origin mismatch"}` etc. (binary strings), not
          # atoms. Map the strings the library actually emits onto the
          # spec'd JSON error keys.
          {:error, reason} when is_binary(reason) ->
            cond do
              String.contains?(reason, "Origin") ->
                json(conn |> put_status(:bad_request), %{error: "origin_mismatch"})

              String.contains?(reason, "Challenge") ->
                json(conn |> put_status(:bad_request), %{error: "challenge_expired"})

              true ->
                Logger.warning("passkey registration failed reason=#{inspect(reason)}")
                json(conn |> put_status(:bad_request), %{error: "verification_failed"})
            end

          {:error, %Ecto.Changeset{} = cs} ->
            conn
            |> put_status(:conflict)
            |> json(%{
              error: "credential_already_enrolled",
              details: Ecto.Changeset.traverse_errors(cs, & &1)
            })

          {:error, reason} ->
            Logger.warning("passkey registration failed reason=#{inspect(reason)}")
            json(conn |> put_status(:bad_request), %{error: "verification_failed"})
        end
      end)
    end)
  end

  def verify_registration(conn, _params) do
    conn = put_private(conn, :passkey_action, "verify_registration")

    guard(conn, fn ->
      json(conn |> put_status(:bad_request), %{error: "missing_request_id"})
    end)
  end

  # ---------- Authentication placeholders ----------
  # Implemented in Task 6.

  def authentication_options(conn, _params) do
    conn = put_private(conn, :passkey_action, "authentication_options")
    guard(conn, fn -> not_implemented(conn) end)
  end

  def verify_authentication(conn, _params) do
    conn = put_private(conn, :passkey_action, "verify_authentication")
    guard(conn, fn -> not_implemented(conn) end)
  end

  # ---------- Helpers ----------

  defp guard(conn, ok_action) do
    if Application.get_env(:dtu_app, :passkeys_enabled, true) do
      ok_action.()
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "not_found"})
      |> halt()
    end
  end

  defp with_user(conn, fun) do
    case conn |> get_session() |> Map.get("user_token") |> Accounts.get_user_by_session_token() do
      {user, _} ->
        fun.(user)

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "unauthenticated"})
        |> halt()
    end
  end

  defp put_passkey_cookie(conn, request_id) do
    put_resp_cookie(conn, "passkey_request_id", request_id,
      http_only: true,
      same_site: "Lax",
      max_age: 5 * 60,
      sign: true
    )
  end

  # Reconstructs the origin URL from `conn.scheme` / `conn.host` /
  # `conn.port` (provided by `Plug.Conn`). The brief's design said
  # `conn.assigns[:origin]` would be set by `:protect_from_forgery`
  # — that turned out to be incorrect; Plug's CSRF plug does not
  # populate that assign. Building the origin from `Plug.Conn`'s
  # fields is equivalent and avoids a pipeline mutation.
  defp request_origin(conn) do
    scheme = conn.scheme |> to_string()
    host = conn.host
    port = conn.port

    "#{scheme}://#{host}#{if port, do: ":#{port}", else: ""}"
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  # Cookie-vs-body `request_id` validation. The cookie set by
  # `begin` is HttpOnly + signed, so the browser must be the one
  # echoing it back. A mismatch means the body was forged or the
  # browser swapped cookies between begin and finish (e.g. a
  # parallel tab finished first).
  defp assert_cookie_matches(conn, request_id) do
    case fetch_cookie(conn, "passkey_request_id") do
      %{"passkey_request_id" => ^request_id} -> {:ok, request_id}
      _ -> {:error, :request_id_mismatch}
    end
  end

  defp fetch_cookie(conn, name) do
    case conn.cookies do
      %Plug.Conn.Unfetched{} ->
        conn.fetch_cookies().cookies

      cookies ->
        cookies
    end
    |> Map.take([name])
  end

  defp rp_id, do: @rp_id
  defp rp_name, do: @rp_name

  defp not_implemented(conn) do
    conn
    |> put_status(:not_implemented)
    |> json(%{error: "not_implemented"})
  end
end
