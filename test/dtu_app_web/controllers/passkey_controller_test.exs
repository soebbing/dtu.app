defmodule DtuAppWeb.PasskeyControllerTest do
  @moduledoc """
  End-to-end tests for the four passkey ceremony endpoints.

  Built atop `PasskeyTest.Authenticator`, which produces fake-but-valid
  WebAuthn responses by routing the `webauthn` library through its
  in-tree mock modules (`Webauthn.RegistrationMock.Response` and
  `Webauthn.AuthenticationMock.Response`, wired via `config/test.exs`).
  No real authenticator or signature verification is exercised.

  Coverage (acceptance criteria from task 7 brief):

    * `registration/begin`     — 401 unauth, 200 options+cookie+cache,
                                404 kill-switch, 400 missing friendly_name
    * `registration/finish`    — 201 + Passkey row, 400 challenge_expired,
                                400 request_id_mismatch, 401 unauth
    * `authentication/begin`  — 409 when authed, 200 with empty allowCredentials
    * `authentication/finish` — 200 + session cookie (happy path),
                                401 credential_not_found,
                                401 sign_count_not_increasing,
                                400 challenge_expired, 409 when authed

  Note: the `webauthn` library's mock `Registration.Response` only
  parses the `authData` binary (no signature check). The mock
  `Authentication.Response` branches on the request's challenge STRING:

      "warn"          → {:warn, hd(creds), 0, "cloned"}  (clone-detector path)
      "originMismatch" → {:error, "Origin does not match original request"}
      any other       → {:ok, hd(creds), sign_count + 1}  (happy path)

  Tests pass challenge strings that drive each branch. Real authenticators
  never get this close — the mocks are only loaded in test config.

  Note on cookie plumbing: `Phoenix.ConnTest.dispatch/5` does NOT
  forward `resp_cookies` from one request to the next, so each `/finish`
  test must `put_req_cookie(conn, "passkey_request_id", value)` with the
  value extracted from the preceding `/begin` body (or hard-coded for
  negative-path tests).
  """

  use DtuAppWeb.ConnCase, async: false

  import DtuApp.AccountsFixtures
  import PasskeyTest.Authenticator

  alias DtuApp.Accounts.Passkey
  alias DtuApp.Accounts.PasskeyChallengeCache
  alias DtuApp.Repo

  @rp_id Application.compile_env(:dtu_app, [:webauthn_rp_id], "localhost")

  setup do
    # Drain the rate-limit ETS table so a prior test's hits can't push
    # us over the 10/min/IP bucket. The table is shared across tests
    # (named, public), and the IP defaults to {127, 0, 0, 1}.
    :ets.delete_all_objects(:passkey_rate_limit)
    sweep_cache()

    on_exit(fn -> sweep_cache() end)
    :ok
  end

  # ─────────────────────────── registration/begin ───────────────────────────

  describe "POST /auth/passkey/registration/begin" do
    test "401 when not authenticated", %{conn: conn} do
      resp = post(conn, "/auth/passkey/registration/begin", %{"friendly_name" => "X"})
      assert resp.status == 401

      assert json_response(resp, 401)["error"] == "unauthenticated"
    end

    test "200 with publicKey options + cookie + cache entry when authenticated", %{conn: conn} do
      user = user_fixture() |> set_password()
      conn = log_in_user(conn, user)

      resp =
        post(conn, "/auth/passkey/registration/begin", %{"friendly_name" => "MacBook"})

      assert resp.status == 200
      body = json_response(resp, 200)

      assert is_binary(body["request_id"])
      assert byte_size(body["request_id"]) == 32
      assert is_map(body["publicKey"])

      # Cookie is signed (`sign: true` in `put_passkey_cookie/2`), so
      # `resp_cookies` returns a plain map with the signed value, same_site,
      # max_age, http_only — assert it's set + matches the 5-minute spec
      # rather than reverse-engineering the signature.
      cookie = resp.resp_cookies["passkey_request_id"]
      assert is_map(cookie)
      assert is_binary(cookie[:value])
      assert cookie[:max_age] == 5 * 60
      assert cookie[:http_only] == true

      # The cache entry's `friendly_name` is read from the `begin` body
      # (not the `finish` body) — verified by `verify_registration` looking
      # up the cache entry and piping `friendly_name` into the new row.
      assert {:ok,
              %{
                kind: :registration,
                user_id: user_id,
                friendly_name: "MacBook",
                challenge: challenge
              }} = PasskeyChallengeCache.fetch_and_delete(body["request_id"])

      assert user_id == user.id
      assert is_binary(challenge)
    end

    test "404 when kill switch is off", %{conn: conn} do
      user = user_fixture() |> set_password()
      conn = log_in_user(conn, user)

      original = Application.get_env(:dtu_app, :passkeys_enabled)
      Application.put_env(:dtu_app, :passkeys_enabled, false)

      on_exit(fn ->
        Application.put_env(:dtu_app, :passkeys_enabled, original)
      end)

      resp = post(conn, "/auth/passkey/registration/begin", %{"friendly_name" => "X"})
      assert resp.status == 404

      assert json_response(resp, 404)["error"] == "not_found"
    end

    test "400 when friendly_name is missing", %{conn: conn} do
      # `registration_options` matches `%{"friendly_name" => _}` first, so
      # a body without it falls through to the catch-all clause. The
      # `passkey_action` private key is still set (the rate-limit plug
      # needs it) before the guard runs, then the guard returns 400.
      user = user_fixture() |> set_password()
      conn = log_in_user(conn, user)

      resp = post(conn, "/auth/passkey/registration/begin", %{})
      assert resp.status == 400

      assert json_response(resp, 400)["error"] == "missing_friendly_name"
    end
  end

  # ─────────────────────────── registration/finish ──────────────────────────

  describe "POST /auth/passkey/registration/finish" do
    setup do
      user = user_fixture() |> set_password()
      %{user: user}
    end

    test "201 + creates Passkey row on valid attestation", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      begin_resp =
        post(conn, "/auth/passkey/registration/begin", %{"friendly_name" => "MacBook"})

      assert begin_resp.status == 200
      body = json_response(begin_resp, 200)
      challenge = fetch_challenge_from_cache(body["request_id"])
      # The controller signs the cookie at response time, but `conn.cookies`
      # (post `fetch_cookies`) stores the value exactly as sent in the
      # Cookie header — Plug doesn't verify signatures on the request
      # side, only when writing. So the value the controller compares
      # against is the UNSIGNED `request_id` from the body.
      cookie_value = body["request_id"]

      {attestation, _credential_id} =
        fake_attestation(@rp_id, "http://www.example.com", challenge)

      conn = put_req_cookie(conn, "passkey_request_id", cookie_value)

      finish_resp =
        post(conn, "/auth/passkey/registration/finish", %{
          "request_id" => body["request_id"],
          "attestation_response" => attestation
        })

      assert finish_resp.status == 201

      body = json_response(finish_resp, 201)
      assert is_binary(body["passkey_id"])
      assert body["friendly_name"] == "MacBook"

      assert Repo.aggregate(Passkey, :count) == 1
      passkey = Repo.one(Passkey)
      assert passkey.user_id == user.id
      assert passkey.friendly_name == "MacBook"
    end

    test "400 challenge_expired when request_id is unknown", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      # Force the cookie to match an unknown request_id so the cookie-vs-
      # body check passes and we get to the cache lookup (which then 400s
      # with `challenge_expired` rather than `request_id_mismatch`).
      conn = put_req_cookie(conn, "passkey_request_id", "nonexistent")

      {attestation, _} = fake_attestation(@rp_id, "http://www.example.com", <<0::256>>)

      resp =
        post(conn, "/auth/passkey/registration/finish", %{
          "request_id" => "nonexistent",
          "attestation_response" => attestation
        })

      assert resp.status == 400
      assert json_response(resp, 400)["error"] == "challenge_expired"
    end

    test "400 request_id_mismatch when cookie and body disagree", %{conn: conn, user: user} do
      # Hit `/begin` so the server sets a cookie with request_id A,
      # then submit `/finish` with body request_id B. The cookie-vs-body
      # check fires before the cache lookup.
      conn = log_in_user(conn, user)
      _begin_resp = post(conn, "/auth/passkey/registration/begin", %{"friendly_name" => "X"})

      {attestation, _} = fake_attestation(@rp_id, "http://www.example.com", <<0::256>>)

      resp =
        post(conn, "/auth/passkey/registration/finish", %{
          "request_id" => "wrong-id",
          "attestation_response" => attestation
        })

      assert resp.status == 400
      assert json_response(resp, 400)["error"] == "request_id_mismatch"
    end

    test "401 when not authenticated", %{conn: _conn} do
      conn = build_conn() |> put_req_cookie("passkey_request_id", "x")

      resp =
        post(conn, "/auth/passkey/registration/finish", %{
          "request_id" => "x",
          "attestation_response" => %{}
        })

      assert resp.status == 401

      assert json_response(resp, 401)["error"] == "unauthenticated"
    end
  end

  # ────────────────────────── authentication/begin ──────────────────────────

  describe "POST /auth/passkey/authentication/begin" do
    test "409 when already authenticated", %{conn: conn} do
      user = user_fixture() |> set_password()
      conn = log_in_user(conn, user)

      resp = post(conn, "/auth/passkey/authentication/begin", %{})
      assert resp.status == 409

      assert json_response(resp, 409)["error"] == "already_authenticated"
    end

    test "200 with publicKey options when anonymous", %{conn: conn} do
      resp = post(conn, "/auth/passkey/authentication/begin", %{})
      assert resp.status == 200

      body = json_response(resp, 200)
      assert is_binary(body["request_id"])
      assert is_map(body["publicKey"])
      # Conditional mediation: allowCredentials is empty so the browser
      # picks which credential to use.
      assert body["publicKey"]["allowCredentials"] in [nil, [], %{}]

      # Cache entry uses `kind: :authentication` and `user_id: nil`
      # (anonymous probe — the row's owner isn't known yet).
      assert {:ok,
              %{
                kind: :authentication,
                user_id: nil,
                friendly_name: nil,
                challenge: challenge
              }} = PasskeyChallengeCache.fetch_and_delete(body["request_id"])

      assert is_binary(challenge)

      cookie = resp.resp_cookies["passkey_request_id"]
      assert is_map(cookie)
      assert cookie[:max_age] == 5 * 60
    end
  end

  # ───────────────────────── authentication/finish ──────────────────────────

  describe "POST /auth/passkey/authentication/finish" do
    setup do
      # Pre-enroll a passkey directly via the fixture. We deliberately
      # bypass the controller's registration flow here because this
      # describe block is about authentication, not enrollment.
      user = user_fixture() |> set_password()

      passkey =
        passkey_fixture(user, %{
          friendly_name: "Pre-enrolled"
        })

      %{user: user, passkey: passkey}
    end

    test "200 + login on valid assertion", %{conn: conn, passkey: passkey} do
      begin_resp = post(conn, "/auth/passkey/authentication/begin", %{})
      assert begin_resp.status == 200

      body = json_response(begin_resp, 200)
      challenge = fetch_challenge_from_cache(body["request_id"])
      cookie_value = body["request_id"]

      # The mock auth response uses the challenge STRING to pick a
      # behavior; any string other than "warn"/"originMismatch"/etc
      # takes the happy path (`{:ok, hd(creds), sign_count+1}`).
      {assertion, _} =
        fake_assertion(@rp_id, "http://www.example.com", challenge, passkey)

      conn = put_req_cookie(conn, "passkey_request_id", cookie_value)

      resp =
        post(conn, "/auth/passkey/authentication/finish", %{
          "request_id" => body["request_id"],
          "assertion_response" => assertion
        })

      assert resp.status == 200
      assert json_response(resp, 200)["redirect"] =~ "/"

      # Session cookie set — `log_in_user_from_passkey/3` calls
      # `create_or_extend_session/3`, which writes the user_token to
      # the session via `Plug.Session` (`@session_options.key` in
      # `lib/dtu_app_web/endpoint.ex`). Assert the session cookie exists
      # — proves the user is now logged in even though we don't bother
      # to assert the redirect target.
      assert resp.resp_cookies["_dtu_app_key"] != nil
    end

    test "401 credential_not_found when credential_id is unknown", %{conn: conn} do
      begin_resp = post(conn, "/auth/passkey/authentication/begin", %{})
      body = json_response(begin_resp, 200)
      challenge = fetch_challenge_from_cache(body["request_id"])
      cookie_value = body["request_id"]

      # Build a passkey-shaped struct with a fresh credential_id that
      # doesn't exist in the DB. `fake_assertion/4` only reads
      # `passkey.credential_id`; the rest of the struct is ignored by
      # the mock, so a bare map with `:credential_id` is enough.
      fake_credential = %{credential_id: :crypto.strong_rand_bytes(32)}

      {assertion, _} =
        fake_assertion(@rp_id, "http://www.example.com", challenge, fake_credential)

      conn = put_req_cookie(conn, "passkey_request_id", cookie_value)

      resp =
        post(conn, "/auth/passkey/authentication/finish", %{
          "request_id" => body["request_id"],
          "assertion_response" => assertion
        })

      assert resp.status == 401

      assert json_response(resp, 401)["error"] == "credential_not_found"
    end

    test "401 sign_count_not_increasing on clone-detector path", %{
      conn: conn,
      passkey: passkey
    } do
      # The auth mock branches on the challenge STRING, so the cache must
      # contain literally `"warn"` for the controller to trigger the
      # clone-detector path. Random challenges from `/begin` won't land
      # on this branch, so we bypass `/begin` and inject "warn" directly.
      request_id = "0123456789abcdef0123456789abcdef"

      PasskeyChallengeCache.put(request_id, %{
        challenge: "warn",
        user_id: nil,
        kind: :authentication,
        friendly_name: nil
      })

      conn = put_req_cookie(conn, "passkey_request_id", request_id)

      # The mock returns `{:warn, hd(creds), 0, msg}` for challenge
      # "warn". Sign_count=0 means the pre-enrolled passkey's stored
      # `sign_count: 0` fails `validate_number(:sign_count,
      # greater_than: 0)`, so `Accounts.touch_passkey/2` returns
      # `{:error, %Ecto.Changeset{}}` — the controller maps that to
      # 401 `sign_count_not_increasing`.
      {assertion, _} = fake_assertion(@rp_id, "http://www.example.com", "warn", passkey)

      resp =
        post(conn, "/auth/passkey/authentication/finish", %{
          "request_id" => request_id,
          "assertion_response" => assertion
        })

      assert resp.status == 401
      assert json_response(resp, 401)["error"] == "sign_count_not_increasing"
    end

    test "400 challenge_expired when request_id is unknown", %{conn: _conn} do
      conn = build_conn() |> put_req_cookie("passkey_request_id", "nonexistent")

      resp =
        post(conn, "/auth/passkey/authentication/finish", %{
          "request_id" => "nonexistent",
          "assertion_response" => %{"id" => "abc"}
        })

      assert resp.status == 400

      assert json_response(resp, 400)["error"] == "challenge_expired"
    end

    test "409 when already authenticated", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      resp =
        post(conn, "/auth/passkey/authentication/finish", %{
          "request_id" => "x",
          "assertion_response" => %{}
        })

      assert resp.status == 409

      assert json_response(resp, 409)["error"] == "already_authenticated"
    end
  end

  # ─────────────────────────── helpers ───────────────────────────

  # Re-read the challenge without deleting it so we can still POST to
  # `/finish` afterward (the controller's `fetch_and_delete/1` would
  # consume the entry). The cache is a `:public, :named_table` ETS
  # table, so a direct lookup from the test process works without
  # going through the GenServer.
  defp fetch_challenge_from_cache(request_id) do
    table = :ets.whereis(PasskeyChallengeCache)

    case :ets.lookup(table, request_id) do
      [{^request_id, %{challenge: challenge}}] -> challenge
      _ -> nil
    end
  end

  defp sweep_cache do
    table = :ets.whereis(PasskeyChallengeCache)
    :ets.delete_all_objects(table)
  end
end
