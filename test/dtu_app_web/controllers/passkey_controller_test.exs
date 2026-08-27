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

      attestation = fake_attestation(@rp_id, challenge)

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

      attestation = fake_attestation(@rp_id, <<0::256>>)

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

      attestation = fake_attestation(@rp_id, <<0::256>>)

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

    test "429 rate_limited after 10 attempts", %{conn: conn} do
      # The PasskeyRateLimit plug caps each (remote_ip, action) pair at
      # 10/minute. The setup block drains the ETS table at the start of
      # every test so we start the count from zero; the 11th request
      # should trip the limit and return 429 `too_many_attempts`.
      user = user_fixture() |> set_password()
      conn = log_in_user(conn, user)

      Enum.each(1..10, fn _ ->
        resp = post(conn, "/auth/passkey/registration/begin", %{"friendly_name" => "x"})
        assert resp.status == 200
      end)

      resp = post(conn, "/auth/passkey/registration/begin", %{"friendly_name" => "x"})
      assert resp.status == 429
      assert json_response(resp, 429)["error"] == "too_many_attempts"
    end

    test "409 credential_already_enrolled on duplicate credential_id", %{
      conn: conn,
      user: user
    } do
      # Pre-enroll a passkey with a known credential_id, then submit an
      # attestation that collides with it. The controller's two 409
      # branches (`:credential_already_enrolled` from the Ecto unique
      # index AND the `%Ecto.Changeset{}` branch) both fire here; this
      # test exercises the index path. The credential_id is supplied to
      # `fake_attestation/3` so the attestation's clientDataJSON carries
      # the same id the row already owns.
      conn = log_in_user(conn, user)

      existing_cred_id = :crypto.strong_rand_bytes(32)
      passkey_fixture(user, %{credential_id: existing_cred_id})

      begin_resp = post(conn, "/auth/passkey/registration/begin", %{"friendly_name" => "x"})
      body = json_response(begin_resp, 200)
      challenge = fetch_challenge_from_cache(body["request_id"])

      attestation = fake_attestation(@rp_id, challenge, existing_cred_id)
      conn = put_req_cookie(conn, "passkey_request_id", body["request_id"])

      finish_resp =
        post(conn, "/auth/passkey/registration/finish", %{
          "request_id" => body["request_id"],
          "attestation_response" => attestation
        })

      assert finish_resp.status == 409
      assert json_response(finish_resp, 409)["error"] == "credential_already_enrolled"
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
      # picks which credential to use. The controller hardcodes the
      # value (see `passkey_controller.ex` ~line 229) — assert equality
      # rather than membership.
      assert body["publicKey"]["allowCredentials"] == []

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
      assertion = fake_assertion(@rp_id, challenge, passkey)

      conn = put_req_cookie(conn, "passkey_request_id", cookie_value)

      resp =
        post(conn, "/auth/passkey/authentication/finish", %{
          "request_id" => body["request_id"],
          "assertion_response" => assertion
        })

      assert resp.status == 200
      # `signed_in_path/1` returns "/". Assert exact match rather than
      # fuzzy regex — the helper hardcodes the value and the redirect
      # is load-bearing for the post-login flow.
      assert json_response(resp, 200)["redirect"] == "/"

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
      # doesn't exist in the DB. `fake_assertion/3` only reads
      # `passkey.credential_id`; the rest of the struct is ignored by
      # the mock, so a bare map with `:credential_id` is enough.
      fake_credential = %{credential_id: :crypto.strong_rand_bytes(32)}

      assertion = fake_assertion(@rp_id, challenge, fake_credential)

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
      assertion = fake_assertion(@rp_id, "warn", passkey)

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

    # Gap noted in the task brief: the brief lists `origin_mismatch`
    # against `registration/finish`, but the `Webauthn.RegistrationMock`
    # doesn't check origin at all (see
    # `deps/webauthn/lib/webauthn/registration_mock/response.ex`) — so
    # the scenario is unreachable on registration. The auth mock DOES
    # key off the challenge STRING `"originMismatch"`, so the
    # controller's mapping is exercisable on `authentication/finish`
    # by swapping the cache entry's challenge after `/begin`.
    test "400 origin_mismatch on authentication/finish", %{
      conn: conn,
      passkey: passkey
    } do
      begin_resp = post(conn, "/auth/passkey/authentication/begin", %{})
      body = json_response(begin_resp, 200)

      # Force the controller's origin-mismatch branch by replacing the
      # cached challenge with the special `"originMismatch"` keyword
      # the Webauthn auth-mock recognises
      # (`deps/webauthn/lib/webauthn/authentication_mock/response.ex:34-36`).
      PasskeyChallengeCache.put(body["request_id"], %{
        challenge: "originMismatch",
        user_id: nil,
        kind: :authentication,
        friendly_name: nil
      })

      assertion = fake_assertion(@rp_id, "originMismatch", passkey)
      conn = put_req_cookie(conn, "passkey_request_id", body["request_id"])

      resp =
        post(conn, "/auth/passkey/authentication/finish", %{
          "request_id" => body["request_id"],
          "assertion_response" => assertion
        })

      assert resp.status == 400
      assert json_response(resp, 400)["error"] == "origin_mismatch"
    end
  end

  # ─────────────────────────── end-to-end ───────────────────────────

  describe "end-to-end ceremony" do
    test "enroll → log out → log back in", %{conn: conn} do
      user = user_fixture() |> set_password()
      conn = log_in_user(conn, user)

      # The credential_id is generated up front so the assertion we build
      # for the authentication leg carries the SAME id the registration
      # leg enrolled — the auth controller looks the Passkey row up by
      # credential_id, and `fake_attestation/3` no longer hands one back.
      cred_id = :crypto.strong_rand_bytes(32)

      # ---- Enroll ----
      begin_resp =
        post(conn, "/auth/passkey/registration/begin", %{"friendly_name" => "E2E Key"})

      assert begin_resp.status == 200
      %{"request_id" => reg_id} = json_response(begin_resp, 200)
      challenge = fetch_challenge_from_cache(reg_id)

      attestation = fake_attestation(@rp_id, challenge, cred_id)

      # `Phoenix.ConnTest.dispatch/5` doesn't forward `resp_cookies` between
      # requests, so the `passkey_request_id` cookie has to be replayed by
      # hand (see the module doc).
      conn = put_req_cookie(conn, "passkey_request_id", reg_id)

      finish_resp =
        post(conn, "/auth/passkey/registration/finish", %{
          "request_id" => reg_id,
          "attestation_response" => attestation
        })

      assert finish_resp.status == 201
      assert is_binary(json_response(finish_resp, 201)["passkey_id"])

      enrolled = Repo.one!(Passkey)
      assert enrolled.credential_id == cred_id
      assert enrolled.sign_count == 0
      assert enrolled.last_used_at == nil

      # ---- Log out ----
      logout_resp = delete(conn, "/users/log-out")
      assert logout_resp.status == 302

      # ---- Authenticate ----
      # A fresh conn carries no session cookie, so `require_anonymous/2`
      # on the authentication endpoints passes.
      fresh_conn = build_conn()

      auth_begin = post(fresh_conn, "/auth/passkey/authentication/begin", %{})
      assert auth_begin.status == 200
      %{"request_id" => auth_id} = json_response(auth_begin, 200)
      auth_challenge = fetch_challenge_from_cache(auth_id)

      assertion = fake_assertion(@rp_id, auth_challenge, %{credential_id: cred_id})

      fresh_conn = put_req_cookie(fresh_conn, "passkey_request_id", auth_id)

      auth_finish =
        post(fresh_conn, "/auth/passkey/authentication/finish", %{
          "request_id" => auth_id,
          "assertion_response" => assertion
        })

      assert auth_finish.status == 200
      assert json_response(auth_finish, 200)["redirect"] == "/"

      # Session cookie set — the user is logged back in purely via the
      # passkey they just enrolled.
      assert auth_finish.resp_cookies["_dtu_app_key"] != nil

      # sign_count advanced (mock returns stored + 1) and the row was touched.
      pk = Repo.one!(Passkey)
      assert pk.id == enrolled.id
      assert pk.sign_count > enrolled.sign_count
      assert pk.last_used_at != nil
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
