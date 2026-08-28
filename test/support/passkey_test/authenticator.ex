defmodule PasskeyTest.Authenticator do
  @moduledoc """
  Produces valid attestation / assertion responses for controller tests.

  Built atop the `webauthn ~> 0.0.9` mock response modules (injected via
  `:webauthn` compile-env in test config — see `config/test.exs`). The
  mocks skip signature verification; the auth-response mock uses the
  request's challenge STRING to trigger specific behaviors:

    * `"warn"`           → clone-detector path (forces sign_count=0)
    * `"originMismatch"`  → origin mismatch error
    * any other string   → happy path (returns sign_count+1)

  The registration mock (`Webauthn.RegistrationMock.Response`) CBOR-decodes
  the attestation object and pipes the inner `authData` into
  `Webauthn.AuthenticatorData.parse/1`, so the `authData` we emit must be
  valid per the W3C §6.1 layout.

  Both helpers hard-code `"origin" => "http://www.example.com"` in the
  clientDataJSON. `Phoenix.ConnTest.build_conn()` defaults to
  `host: "www.example.com"`, so the controller's `request_origin/1`
  computes the same origin — no mismatch. The auth mock checks the
  challenge STRING for `"originMismatch"` (see
  `deps/webauthn/lib/webauthn/authentication_mock/response.ex`), not
  the origin field — and the reg mock doesn't check origin at all.
  """

  # Auth mock challenge strings → behavior (see
  # `deps/webauthn/lib/webauthn/authentication_mock/response.ex`).
  # Inline literals below — no module attribute to keep the warnings
  # log clean.

  # `0b0100_0001` — UP=1, AT=1, UV=0, ED=0, all RFU bits clear.
  # W3C WebAuthn §6.1 flag layout (MSB→LSB): ED=7, AT=6, RFU2=5..3,
  # UV=2, RFU1=1, UP=0. `0x51` (the previous value) had RFU2-bit-4 set
  # — a reserved-for-future-use bit that MUST be zero. UV=0 is fine
  # here because the controller doesn't pass `"authenticatorSelection"`
  # to `Webauthn.registration_challenge/2`; the library defaults to
  # `userVerification: "preferred"`, which accepts UV=0
  # (`deps/webauthn/lib/webauthn/registration/response.ex:64-75`).
  @flags <<0x41>>

  @doc """
  Returns the attestation map `navigator.credentials.create()` would
  POST to `/auth/passkey/registration/finish`.

  Pass `credential_id` to deterministically pre-enroll a passkey that
  this attestation collides with (409 test); defaults to fresh random
  bytes. The returned map's `"id"` / `"rawId"` are the base64url
  encoding of the supplied `credential_id`.
  """
  @spec fake_attestation(String.t(), String.t(), binary() | nil) :: map()
  def fake_attestation(rp_id, challenge, credential_id \\ nil) do
    credential_id = credential_id || :crypto.strong_rand_bytes(32)

    public_key_cbor =
      CBOR.encode(%{1 => 2, 3 => -7, -1 => 1, -2 => <<4::256>>, -3 => <<4::256>>})

    auth_data =
      :crypto.hash(:sha256, rp_id) <>
        @flags <>
        <<0::32>> <>
        <<0::128>> <>
        <<byte_size(credential_id)::16>> <>
        credential_id <>
        public_key_cbor

    attestation_object =
      CBOR.encode(%{
        "fmt" => "none",
        "attStmt" => %{},
        "authData" => auth_data
      })

    %{
      "id" => Base.url_encode64(credential_id, padding: false),
      "rawId" => Base.url_encode64(credential_id, padding: false),
      "type" => "public-key",
      "response" => %{
        "clientDataJSON" =>
          Base.url_encode64(
            Jason.encode!(%{
              "type" => "webauthn.create",
              "challenge" => challenge,
              "origin" => "http://www.example.com"
            }),
            padding: false
          ),
        "attestationObject" => Base.url_encode64(attestation_object, padding: false),
        "transports" => ["usb"]
      }
    }
  end

  @doc """
  Returns the assertion map `navigator.credentials.get()` would POST to
  `/auth/passkey/authentication/finish`.

  The auth mock doesn't validate signatures — it uses the challenge
  STRING to pick a behavior:

    * `"warn"` → `{:warn, hd(creds), 0, "cloned"}` — forces the
      controller's `Accounts.touch_passkey/2` to reject the
      non-increasing sign_count, exercising the clone-detector branch.
    * `"originMismatch"` → `{:error, "Origin does not match original request"}`.
    * anything else → happy path, sign_count+1.

  `_rp_id` is accepted for symmetry with `fake_attestation/3` but unused
  (the mock doesn't verify the rp_id hash against authenticatorData).
  """
  @spec fake_assertion(String.t(), String.t(), map()) :: map()
  def fake_assertion(_rp_id, challenge, passkey) do
    %{
      "id" => Base.url_encode64(passkey.credential_id, padding: false),
      "rawId" => Base.url_encode64(passkey.credential_id, padding: false),
      "type" => "public-key",
      "response" => %{
        "clientDataJSON" =>
          Base.url_encode64(
            Jason.encode!(%{
              "type" => "webauthn.get",
              "challenge" => challenge,
              "origin" => "http://www.example.com"
            }),
            padding: false
          ),
        # The mock doesn't validate these bytes — zero-bit placeholders
        # keep the assertion length consistent with what a real
        # authenticator would emit without committing to a specific sig.
        "authenticatorData" => Base.url_encode64(<<0::800>>, padding: false),
        "signature" => Base.url_encode64(<<0::256>>, padding: false)
      }
    }
  end
end
