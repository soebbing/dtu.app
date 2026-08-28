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
  alias DtuApp.Accounts.Passkey
  alias DtuApp.Accounts.PasskeyChallengeCache
  alias DtuApp.Accounts.User
  alias DtuApp.Repo
  alias DtuAppWeb.UserAuth

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
          user
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
            "timeout" => @timeout_ms,
            # Passkeys don't need attestation, and asking for it hurts:
            # `webauthn`'s default is "direct", whose packed/basic
            # statements are rejected by `trustworthy?/2` unless the
            # authenticator's root cert is in the library's bundled
            # trust store ("Untrusted Root Certificate"). Platform
            # authenticators (Touch ID, Windows Hello) and the CDP
            # virtual authenticator all fall outside it. "none" is the
            # WebAuthn recommendation for this use case and is also
            # better for user privacy.
            "attestation" => "none",
            # The login page runs a USERNAME-LESS ceremony
            # (`allowCredentials: []`), which only works if the
            # credential is DISCOVERABLE (a resident key). Without this
            # the library defaults `authenticatorSelection` to `%{}`,
            # authenticators mint a non-discoverable credential, and
            # `navigator.credentials.get()` on `/users/log-in` finds
            # nothing and rejects with `NotAllowedError` — which the
            # hook swallows, so "Use a passkey" silently does nothing.
            "authenticatorSelection" => %{
              "residentKey" => "required",
              "requireResidentKey" => true,
              "userVerification" => "preferred"
            }
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
                 raw_client_data_json(response)
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
              # `unique_constraint/2` populates each error as the tuple
              # `{"has already been taken", [constraint: :unique, ...]}`
              # — passing the raw `{msg, opts}` leaf to `traverse_errors/2`
              # with the identity transformer produces JSON-encodable
              # values, but leaves the inner opts keyword list alone. Pull
              # just the message (elem/2) so Jason gets a plain string;
              # the constraint metadata is noise for a client anyway.
              details: Ecto.Changeset.traverse_errors(cs, &elem(&1, 0))
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

  # ---------- Authentication ----------
  # Spec §6: anonymous-only — replay an existing session by trying to
  # log in with a passkey would let an attacker bypass a forced logout.

  def authentication_options(conn, _params) do
    conn = put_private(conn, :passkey_action, "authentication_options")

    guard(conn, fn ->
      require_anonymous(conn, fn ->
        challenge = Webauthn.challenge()

        public_key =
          Webauthn.auth_challenge(challenge, %{
            "rp" => %{"id" => rp_id(), "name" => rp_name()},
            "timeout" => @timeout_ms,
            # Empty list: this is a conditional-mediation probe.
            # The browser picks which enrolled passkey to use; if the
            # user has none, it returns NotAllowedError and the UI
            # falls back to email + password (spec §3).
            "allowCredentials" => []
          })

        request_id = generate_request_id()

        PasskeyChallengeCache.put(request_id, %{
          challenge: challenge,
          user_id: nil,
          kind: :authentication,
          friendly_name: nil
        })

        conn = put_passkey_cookie(conn, request_id)

        Logger.info("passkey authentication begin ip=#{inspect(conn.remote_ip)}")

        json(conn, %{request_id: request_id, publicKey: public_key})
      end)
    end)
  end

  def verify_authentication(conn, %{"request_id" => request_id, "assertion_response" => response})
      when is_map(response) do
    conn = put_private(conn, :passkey_action, "verify_authentication")

    guard(conn, fn ->
      require_anonymous(conn, fn ->
        with {:ok, cookie_rid} <- assert_cookie_matches(conn, request_id),
             {:ok, %{challenge: challenge, kind: :authentication}} <-
               PasskeyChallengeCache.fetch_and_delete(cookie_rid),
             credential_id when is_binary(credential_id) <-
               decode_credential_id(response["id"]),
             %Passkey{} = passkey <- Accounts.find_passkey_by_credential_id(credential_id),
             %User{} = user <- Repo.get(User, passkey.user_id),
             {:ok, new_sign_count} <-
               verify_auth_response(passkey, challenge, response, conn),
             {:ok, _updated} <-
               Accounts.touch_passkey(passkey, %{
                 sign_count: new_sign_count,
                 last_used_at: DateTime.utc_now()
               }) do
          Logger.info("passkey authentication ok passkey_id=#{passkey.id} user_id=#{user.id}")

          UserAuth.log_in_user_from_passkey(conn, user, %{})
        else
          {:error, :request_id_mismatch} ->
            json(conn |> put_status(:bad_request), %{error: "request_id_mismatch"})

          {:error, :not_found} ->
            json(conn |> put_status(:bad_request), %{error: "challenge_expired"})

          # `Accounts.touch_passkey/2` rejected the new sign_count via
          # `Passkey.usage_changeset/2`'s `validate_number(:sign_count,
          # greater_than: passkey.sign_count)`. The authenticator
          # returned a count <= the one we already stored — the
          # WebAuthn "cloned authenticator" trap (spec §6 step 5).
          # `Repo.update/1` returns `{:error, %Ecto.Changeset{}}`, so
          # the bare-struct pattern must be wrapped in a tagged tuple.
          {:error, %Ecto.Changeset{} = cs} ->
            Logger.warning(
              "passkey authentication replay passkey_id=#{inspect(cs.data && cs.data.id)}"
            )

            json(conn |> put_status(:unauthorized), %{error: "sign_count_not_increasing"})

          # Both `decode_credential_id/1` returning nil (malformed id)
          # and `Accounts.find_passkey_by_credential_id/1` returning nil
          # (no row matches the id) collapse to the same public error —
          # we don't leak which case fired.
          nil ->
            json(conn |> put_status(:unauthorized), %{error: "credential_not_found"})

          # The `webauthn ~> 0.0.9` library returns verification
          # failures as `{:error, "Origin mismatch"}` etc. (binary
          # strings), not atoms. Map the strings the library actually
          # emits onto the spec'd JSON error keys.
          {:error, reason} when is_binary(reason) ->
            cond do
              String.contains?(reason, "Origin") ->
                json(conn |> put_status(:bad_request), %{error: "origin_mismatch"})

              String.contains?(reason, "Challenge") ->
                json(conn |> put_status(:bad_request), %{error: "challenge_expired"})

              true ->
                Logger.warning("passkey authentication failed reason=#{inspect(reason)}")

                json(conn |> put_status(:bad_request), %{error: "verification_failed"})
            end

          {:error, reason} ->
            Logger.warning("passkey authentication failed reason=#{inspect(reason)}")

            json(conn |> put_status(:bad_request), %{error: "verification_failed"})
        end
      end)
    end)
  end

  def verify_authentication(conn, _params) do
    conn = put_private(conn, :passkey_action, "verify_authentication")

    guard(conn, fn ->
      json(conn |> put_status(:bad_request), %{error: "missing_request_id"})
    end)
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
    case get_session(conn, "user_token") do
      nil ->
        unauthenticated(conn)

      token ->
        case Accounts.get_user_by_session_token(token) do
          {user, _} ->
            fun.(user)

          _ ->
            unauthenticated(conn)
        end
    end
  end

  defp unauthenticated(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "unauthenticated"})
    |> halt()
  end

  # Symmetric to `with_user/2`. 409 (Conflict) — distinct from
  # `with_user`'s 401 (Unauthorized) — because the request itself is
  # well-formed but the server refuses to perform a second login on
  # top of an active session (spec §3 "any 4xx shows inline error").
  defp require_anonymous(conn, ok_action) do
    case get_session(conn, "user_token") do
      nil -> ok_action.()
      _ -> already_authenticated(conn)
    end
  end

  defp already_authenticated(conn) do
    conn
    |> put_status(:conflict)
    |> json(%{error: "already_authenticated"})
    |> halt()
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

  # `put_passkey_cookie/2` writes the cookie with `sign: true`, so the
  # value on the wire is a signed token, not the raw request_id. It has
  # to be read back with `fetch_cookies(conn, signed: [name])` — a plain
  # `fetch_cookies/1` yields the still-signed string, which never equals
  # the request_id in the body and made every `finish` call fail with
  # `request_id_mismatch`.
  defp fetch_cookie(conn, name) do
    conn
    |> Plug.Conn.fetch_cookies(signed: [name])
    |> Map.fetch!(:cookies)
    |> Map.take([name])
  end

  defp rp_id, do: @rp_id
  defp rp_name, do: @rp_name

  # Browser-sent `credential_id` is base64url (no padding) — see
  # `navigator.credentials.get()`'s `PublicKeyCredential.id` contract.
  # Returns the raw bytes (what we store as `Passkey.credential_id`)
  # or `nil` on any failure (missing field, non-binary, undecodable).
  # The caller pattern-matches on `is_binary/1` so a `nil` here
  # collapses into the public `credential_not_found` error.
  defp decode_credential_id(base64url) when is_binary(base64url) do
    case Base.url_decode64(base64url, padding: false) do
      {:ok, bytes} -> bytes
      :error -> nil
    end
  end

  defp decode_credential_id(_), do: nil

  # Verifies the browser's assertion against the stored passkey.
  #
  # `webauthn ~> 0.0.9` looks up the credential inside the
  # `request["allowCredentials"]` list — by `credential_id` — and
  # pulls `credential_public_key` + `sign_count` from the matching
  # entry. The library expects `public_key` to be a CBOR-DECODED map,
  # but `Passkey.public_key` is stored as a CBOR-ENCODED binary
  # (Task 5 D6 re-encodes the parsed COSE map via `CBOR.encode/1`
  # before insert). Round-tripping through `CBOR.decode/1` here
  # matches what the library wants; skipping it yields "Bad
  # signature" or "Invalid public key format" from
  # `Webauthn.Cose.to_public_key/1`.
  #
  # The library returns `{:ok, _credential, new_sign_count}` on a
  # happy signature, or `{:warn, _credential, new_sign_count, _msg}`
  # when the authenticator's reported `sign_count` is <= the stored
  # one. We forward both to the caller with the new sign_count; the
  # subsequent `Accounts.touch_passkey/2` call rejects the non-
  # increasing case via `Passkey.usage_changeset/2`, which the
  # controller maps to 401 `sign_count_not_increasing` (spec §6
  # step 5 — clone detection).
  defp verify_auth_response(passkey, challenge, response, conn) do
    {:ok, public_key, _rest} = CBOR.decode(passkey.public_key)

    request = %{
      "allowCredentials" => [
        %{
          credential_id: passkey.credential_id,
          credential_public_key: public_key,
          sign_count: passkey.sign_count
        }
      ],
      "challenge" => challenge,
      "origin" => request_origin(conn),
      "rp" => %{"id" => rp_id()}
    }

    case Webauthn.auth_response(request, put_raw_client_data_json(response)) do
      {:ok, _credential, new_sign_count} ->
        {:ok, new_sign_count}

      {:warn, _credential, new_sign_count, _msg} ->
        {:ok, new_sign_count}

      {:error, _reason} = err ->
        err
    end
  end

  # `webauthn ~> 0.0.9` expects `clientDataJSON` as the RAW JSON bytes —
  # it calls `Jason.decode/1` on it directly and hashes it verbatim for
  # the signature check. The browser hands it to us base64url-encoded
  # (see `assets/js/utils/base64url.js`'s `serializeCredential/1`), so
  # it has to be decoded here first. `attestationObject`,
  # `authenticatorData` and `signature` stay base64url — the library
  # decodes those itself.
  defp raw_client_data_json(response) do
    case get_in(response, ["response", "clientDataJSON"]) do
      raw when is_binary(raw) ->
        case Base.url_decode64(raw, padding: false) do
          {:ok, json} -> json
          :error -> raw
        end

      _ ->
        ""
    end
  end

  defp put_raw_client_data_json(%{"response" => %{} = inner} = response) do
    %{response | "response" => Map.put(inner, "clientDataJSON", raw_client_data_json(response))}
  end

  defp put_raw_client_data_json(response), do: response
end
