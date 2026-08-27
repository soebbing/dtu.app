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
  """

  # Auth mock challenge strings → behavior (see
  # `deps/webauthn/lib/webauthn/authentication_mock/response.ex`).
  # Inline literals below — no module attribute to keep the warnings
  # log clean.

  # `0b01010001` — UP=1, UV=1, AT=1, ED=0. WebAuthn §6.1: AT must be set
  # when the authData is followed by attested credential data (which it
  # is, since registration must carry a credential).
  @flags <<0x51>>

  @doc """
  Returns `{attestation_map, credential_id}` for a fresh enrollment.

  `attestation_map` is the JSON shape `navigator.credentials.create()`
  would POST to `/auth/passkey/registration/finish`. `credential_id` is
  the raw bytes — callers must remember it for any later authentication
  step (the registration mock doesn't persist it; we let the controller
  persist it).
  """
  @spec fake_attestation(String.t(), String.t(), String.t()) :: {map(), binary()}
  def fake_attestation(rp_id, _origin, challenge) do
    credential_id = :crypto.strong_rand_bytes(32)

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

    response = %{
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

    {response, credential_id}
  end

  @doc """
  Returns `{assertion_map, passkey}` for an existing enrollment.

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
  @spec fake_assertion(String.t(), String.t(), String.t(), map()) :: {map(), map()}
  def fake_assertion(_rp_id, _origin, challenge, passkey) do
    response = %{
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

    {response, passkey}
  end
end
