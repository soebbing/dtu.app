defmodule DtuApp.Push.VapidKeypairValidator do
  @moduledoc """
  Boot-time sanity check that the configured VAPID keypair forms a
  valid pair.

  ## Why this exists

  APNs (and every VAPID-spec push service) verifies the JWT
  `Authorization` header against the **public key registered with the
  push service for the subscription**. That public key is the one
  baked into the user's iOS-device subscription at enable-time — it
  matches the server-side public key that the `PushManager.subscribe()`
  call advertised via the `/push/vapid/public_key` endpoint.

  If the env vars `VAPID_PUBLIC_KEY` and `VAPID_PRIVATE_KEY` don't
  form a valid ECDSA P-256 keypair — typical failure modes:

    1. Operator regenerated one but not the other (e.g. ran
       `mix web_push.gen.vapid`, updated only `VAPID_PRIVATE_KEY`).
    2. Operator copy-pasted a private key from a different keypair
       (e.g. from a previous project's `priv.pem`).
    3. The env var values contain line breaks, padding, or non-
       base64url characters from a wrapped PEM-style paste.

  ...then every push fails with `403 BadJwtToken` from APNs. The
  failure is opaque from the prod logs alone — the JWT structure
  looks correct, the audience/alg/sub are fine, only the signature
  won't verify. Operators have to manually decode the JWT to figure
  out it's a keypair problem.

  ## What this does

  Runs at boot (called from `DtuApp.Application.start/2` after the
  Finch pool is up but before any notifier children start). Builds a
  throwaway JWT the same way `WebPush.Vapid` does, signs it with the
  configured private key, and verifies the signature against the
  configured public key using Erlang's `:crypto.verify/5`. If the
  signature doesn't verify, raises `ArgumentError` with a message
  that names both env vars, points at `mix web_push.gen.vapid`, and
  explains the user-visible symptom (APNs 403 BadJwtToken).

  Skips validation in environments where the keys aren't set (`:test`,
  dev without VAPID) so the app boots regardless. The trade-off: a
  silent :test-mode miss. The validator is intentionally not invoked
  by `:test` config — `runtime.exs` keeps the production raise in
  place for `:prod` and only generates ephemeral dev keypairs in
  `:dev`. The validator only runs when keys are explicitly set.
  """

  @public_key_byte_size 65
  @private_key_byte_size 32

  @doc """
  Returns `:ok` if the configured keypair is valid, raises
  `ArgumentError` otherwise.

  Skips silently (returns `:ok`) when no keypair is configured —
  `:test` env and `dev` mode with no VAPID env vars both fall through.
  The intentional trade-off is documented in the moduledoc.
  """
  @spec validate!() :: :ok
  def validate! do
    cfg = Application.get_env(:web_push, :vapid, [])

    with {:present, public_b64, private_b64} <- fetch_keys(cfg),
         :ok <- validate_subject(cfg),
         {:ok, public_bytes} <- decode_key(public_b64, "public_key", @public_key_byte_size),
         {:ok, private_bytes} <- decode_key(private_b64, "private_key", @private_key_byte_size),
         :ok <- verify_pair(public_bytes, private_bytes) do
      :ok
    else
      :missing ->
        :ok

      {:error, reason} ->
        raise ArgumentError, error_message(reason)
    end
  end

  # ── internals ───────────────────────────────────────────────────────

  # Returns {:present, pub, priv} or :missing. The two-arg `is_binary/1`
  # guard from production code's reader (Elixir's `Application.get_env/3`
  # falls back to the default `[]` when the key isn't set, and the
  # default for `:public_key`/`:private_key` in config is `nil`) means
  # a missing key arrives here as `nil`, not `:undefined`.
  defp fetch_keys(cfg) do
    public = Keyword.get(cfg, :public_key)
    private = Keyword.get(cfg, :private_key)

    cond do
      is_nil(public) or is_nil(private) -> :missing
      String.trim(to_string(public)) == "" -> :missing
      String.trim(to_string(private)) == "" -> :missing
      true -> {:present, public, private}
    end
  end

  # RFC 8292 §2 requires the JWT `sub` claim to be a `mailto:` or
  # `https://` URL — the push service uses it to contact the operator
  # about abuse. Apple (APNs) is the strictest of the bunch and returns
  # `403 BadJwtToken` for ANY other value, including bare email
  # addresses (the most common typo — operators set
  # `VAPID_SUBJECT=mailto:admin@yourdomain.com` and end up with
  # `mailto:admin@yourdomain.com` in the JWT, but if the `mailto:` /
  # `https://` prefix is missing Apple rejects the whole push).
  #
  # We caught this in prod on 2026-09-19: the env var was set to a
  # bare email address (`mailto:admin@localhost` got truncated to
  # `madmin@localhost` somewhere), and every push to
  # web.push.apple.com came back 403 BadJwtToken until the env was
  # fixed. Failing the boot at this point means a misconfigured
  # deploy rolls back instead of silently shipping 403s.
  #
  # Runs only after `fetch_keys/1` returns `:present` — when no
  # VAPID is configured at all (`:test` env, dev mode without env
  # vars), we skip the check entirely because there's nothing to
  # validate against and the deploy has opted out of native push.
  defp validate_subject(cfg) do
    # Use `Keyword.fetch/2` rather than `Keyword.get/2` so an absent
    # `:subject` key is treated as `:missing` (skip), distinct from
    # an explicit `subject: ""` or `subject: nil` (raise). The
    # absent case is the `:test` env / dev-without-VAPID path —
    # runtime.exs has a default in production but the validator
    # doesn't depend on that default. The explicit-empty case is
    # a real misconfiguration (operator set VAPID_SUBJECT="" in
    # the host env) and must fail loudly.
    case Keyword.fetch(cfg, :subject) do
      :error ->
        :ok

      {:ok, raw} ->
        subject = if is_binary(raw), do: String.trim(raw), else: ""

        cond do
          subject == "" ->
            {:error, :invalid_subject}

          String.starts_with?(subject, "mailto:") ->
            :ok

          String.starts_with?(subject, "https://") ->
            :ok

          true ->
            {:error, :invalid_subject}
        end
    end
  end

  defp decode_key(b64, label, expected_size) do
    case Base.url_decode64(b64, padding: false) do
      {:ok, bytes} when byte_size(bytes) == expected_size ->
        {:ok, bytes}

      {:ok, bytes} ->
        {:error, "#{label} must be #{expected_size} bytes, got #{byte_size(bytes)}"}

      :error ->
        {:error, "#{label} is not valid base64url"}
    end
  end

  # Build a minimal JWT the same way `WebPush.Vapid` does (header +
  # claims + raw r||s ES256 signature) and verify it with
  # `:crypto.verify/5`. Both the library and this module go through
  # `:crypto.sign(:ecdsa, :sha256, …)` for the DER step, so the
  # round-trip is apples-to-apples.
  defp verify_pair(public_bytes, private_bytes) do
    signing_input = build_signing_input()

    der_sig =
      :crypto.sign(:ecdsa, :sha256, signing_input, [private_bytes, :secp256r1])

    raw_sig = der_to_raw_r_s(der_sig)
    der_sig_for_verify = raw_r_s_to_der(raw_sig)

    if :crypto.verify(:ecdsa, :sha256, signing_input, der_sig_for_verify, [
         public_bytes,
         :secp256r1
       ]) do
      :ok
    else
      {:error, :public_key_does_not_correspond_to_private_key}
    end
  end

  defp build_signing_input do
    header = %{"alg" => "ES256", "typ" => "JWT"}

    claims = %{
      "aud" => "https://test",
      "exp" => System.system_time(:second) + 3600,
      "sub" => "mailto:test@localhost"
    }

    header_b64 = b64url(Jason.encode!(header))
    claims_b64 = b64url(Jason.encode!(claims))
    header_b64 <> "." <> claims_b64
  end

  defp b64url(bin), do: Base.url_encode64(bin, padding: false)

  # DER ECDSA signature → fixed 64-byte raw `r || s`. Mirrors
  # `WebPush.Vapid.der_ecdsa_to_raw/1` so the conversion is byte-
  # identical to what the library emits on the wire.
  defp der_to_raw_r_s(<<0x30, _seq_len, 0x02, r_len, rest::binary>>),
    do: extract_rs(rest, r_len)

  defp der_to_raw_r_s(<<0x30, 0x81, _seq_len, 0x02, r_len, rest::binary>>),
    do: extract_rs(rest, r_len)

  defp extract_rs(rest, r_len) do
    <<r::binary-size(r_len), 0x02, s_len, s::binary-size(s_len)>> = rest
    pad32(trim_leading_zero(r)) <> pad32(trim_leading_zero(s))
  end

  defp trim_leading_zero(<<0x00, rest::binary>>) when byte_size(rest) > 0,
    do: trim_leading_zero(rest)

  defp trim_leading_zero(bin), do: bin

  defp pad32(bin) when byte_size(bin) == 32, do: bin

  defp pad32(bin) when byte_size(bin) < 32 do
    pad_bits = (32 - byte_size(bin)) * 8
    <<0::size(pad_bits), bin::binary>>
  end

  # Raw r||s → DER ECDSA signature for `:crypto.verify/5`. Erlang's
  # ECDSA verifier expects DER (per `man 3 verify`), unlike `:sign/4`
  # which always emits DER.
  defp raw_r_s_to_der(<<r::binary-size(32), s::binary-size(32)>>) do
    r_der = encode_der_int(r)
    s_der = encode_der_int(s)
    <<0x30, byte_size(r_der) + byte_size(s_der)>> <> r_der <> s_der
  end

  defp encode_der_int(bin) when byte_size(bin) <= 127 do
    if :binary.first(bin) >= 0x80 do
      <<0x02, byte_size(bin) + 1, 0x00>> <> bin
    else
      <<0x02, byte_size(bin)>> <> bin
    end
  end

  defp encode_der_int(<<0x00, rest::binary>>), do: encode_der_int(rest)

  defp error_message(:public_key_does_not_correspond_to_private_key) do
    """
    VAPID keypair integrity check failed: public_key does not correspond to private_key.

    APNs (and every VAPID-spec push service) verifies each push's
    JWT signature against the public key Apple has registered for
    the user's subscription. When the configured VAPID_PUBLIC_KEY
    and VAPID_PRIVATE_KEY don't form a valid pair — for example,
    one was regenerated without the other, or a private key from
    a different keypair was pasted in by mistake — every push
    fails with `403 BadJwtToken` until both env vars are aligned.

    Operational fix:

      1. Generate a fresh keypair:        mix web_push.gen.vapid
      2. Update BOTH env vars on the prod host:
           VAPID_PUBLIC_KEY  = <new public key>
           VAPID_PRIVATE_KEY = <new private key>
      3. Restart the app so the new keypair loads.
      4. Have iOS users re-enable push notifications — the new
         public key invalidates their existing subscription,
         which was bound to the old key.

    For background on why this happens silently, see the moduledoc.
    """
  end

  defp error_message(reason) when is_binary(reason) do
    """
    VAPID keypair integrity check failed: #{reason}.

    APNs will reject every push with `403 BadJwtToken` until the
    env vars are fixed. To regenerate a matching pair:

      1. mix web_push.gen.vapid
      2. Update BOTH VAPID_PUBLIC_KEY and VAPID_PRIVATE_KEY on the prod host
      3. Restart the app
      4. Have iOS users re-enable push notifications (new public
         key invalidates the old subscription)
    """
  end

  # RFC 8292 §2 requires the JWT `sub` claim to be a `mailto:` or
  # `https://` URL. Apple's APNs rejects everything else with
  # `403 BadJwtToken` — see `validate_subject/1` for the prod
  # incident this guards against.
  defp error_message(:invalid_subject) do
    """
    VAPID_SUBJECT env var must be a `mailto:` or `https://` URL.

    RFC 8292 §2 requires the JWT `sub` claim to be a URL the push
    service can use to contact the operator about abuse. Apple
    APNs returns `403 BadJwtToken` for ANY other value — bare
    email addresses (the most common typo, missing the
    `mailto:` prefix) and the literal string `mailto` (missing
    the colon) are the two failure modes seen so far. Every push
    to web.push.apple.com comes back 403 until this is fixed.

    Operational fix:

      1. Set VAPID_SUBJECT to a mailto: URL on the prod host:

           VAPID_SUBJECT=mailto:admin@yourdomain.com

         (`https://yourdomain.com/contact` is also accepted by
         every RFC 8292-compliant push service — both shapes
         keep existing iOS subscriptions valid)

      2. Restart the app container.

      3. Have iOS users re-enable push notifications once, so
         the new subject propagates into existing subscriptions.
    """
  end
end
