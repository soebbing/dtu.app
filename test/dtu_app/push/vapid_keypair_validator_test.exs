defmodule DtuApp.Push.VapidKeypairValidatorTest do
  @moduledoc """
  Tests for `DtuApp.Push.VapidKeypairValidator`.

  Catches the most common operational failure mode for native push:
  the configured `VAPID_PUBLIC_KEY` and `VAPID_PRIVATE_KEY` env vars
  don't form a valid ECDSA P-256 keypair — e.g. one was regenerated
  without the other, or a private key from a different keypair was
  pasted in by mistake. APNs rejects every push with `403 BadJwtToken`
  until the env vars are aligned.

  The validator runs at boot (called from `DtuApp.Application.start/2`)
  and raises with a clear, actionable error instead of leaving the
  failure mode to surface as opaque 403s in production logs.
  """

  use ExUnit.Case, async: false

  alias DtuApp.Push.VapidKeypairValidator

  # Generate a valid ECDSA P-256 keypair and base64url-encode both halves.
  # The same shape `mix web_push.gen.vapid` produces.
  defp fresh_keypair do
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      public_key: Base.url_encode64(public, padding: false),
      private_key: Base.url_encode64(private, padding: false),
      subject: "mailto:test@localhost"
    }
  end

  defp put_vapid(cfg) do
    Application.put_env(:web_push, :vapid,
      public_key: cfg[:public_key],
      private_key: cfg[:private_key],
      subject: cfg[:subject] || "mailto:test@localhost"
    )
  end

  defp clear_vapid, do: Application.delete_env(:web_push, :vapid)

  describe "validate!/1 — happy path" do
    test "matching keypair from a fresh generation passes" do
      kp = fresh_keypair()
      put_vapid(kp)

      assert :ok = VapidKeypairValidator.validate!()
    end

    test "the placeholder keypair from config/test.exs passes" do
      # `config/test.exs` ships a hard-coded placeholder keypair
      # generated once with `WebPush.Vapid.generate_keypair/0`. If this
      # test fails, someone regenerated it incorrectly — the app
      # wouldn't start in :test at all.
      clear_vapid()

      # config/test.exs applies at boot; manually re-apply to be safe.
      put_vapid(%{
        public_key:
          "BJTUEpHLN69OMVAoFchd_RCm7kzXYyiGLhj-yHFwp0dCHciZUh6XRChhfY6R0cEm4CZ5whrZPaNszMPlWkBMuy0",
        private_key: "xE0IOv4yhbso6voJbQkZj2X9kEr8zsh9yTZouFU9cYc"
      })

      assert :ok = VapidKeypairValidator.validate!()
    end
  end

  describe "validate!/1 — missing or empty keys" do
    test "skips validation when public_key is nil (e.g. :test env without VAPID config)" do
      Application.put_env(:web_push, :vapid, public_key: nil, private_key: "x")

      assert :ok = VapidKeypairValidator.validate!()
    end

    test "skips validation when private_key is nil" do
      Application.put_env(:web_push, :vapid, public_key: "x", private_key: nil)

      assert :ok = VapidKeypairValidator.validate!()
    end

    test "skips validation when public_key is empty string" do
      Application.put_env(:web_push, :vapid, public_key: "", private_key: "x")

      assert :ok = VapidKeypairValidator.validate!()
    end

    test "skips validation when private_key is empty string" do
      Application.put_env(:web_push, :vapid, public_key: "x", private_key: "")

      assert :ok = VapidKeypairValidator.validate!()
    end

    test "skips validation when the vapid config itself is missing" do
      clear_vapid()

      assert :ok = VapidKeypairValidator.validate!()
    end
  end

  describe "validate!/1 — malformed keys" do
    test "raises when public_key is not valid base64url" do
      Application.put_env(
        :web_push,
        :vapid,
        public_key: "!!!not-base64!!!",
        private_key: "xE0IOv4yhbso6voJbQkZj2X9kEr8zsh9yTZouFU9cYc"
      )

      assert_raise ArgumentError, ~r/VAPID keypair integrity check failed/, fn ->
        VapidKeypairValidator.validate!()
      end
    end

    test "raises when private_key is not valid base64url" do
      {public, _private} = :crypto.generate_key(:ecdh, :prime256v1)
      pub_b64 = Base.url_encode64(public, padding: false)

      Application.put_env(
        :web_push,
        :vapid,
        public_key: pub_b64,
        private_key: "!!!not-base64!!!"
      )

      assert_raise ArgumentError, ~r/VAPID keypair integrity check failed/, fn ->
        VapidKeypairValidator.validate!()
      end
    end

    test "raises when public_key decodes to the wrong size (not 65 bytes)" do
      kp = fresh_keypair()

      Application.put_env(
        :web_push,
        :vapid,
        # 10 random bytes — not a valid P-256 point
        public_key: Base.url_encode64(:crypto.strong_rand_bytes(10), padding: false),
        private_key: kp.private_key
      )

      assert_raise ArgumentError, ~r/public_key must be 65 bytes/, fn ->
        VapidKeypairValidator.validate!()
      end
    end

    test "raises when private_key decodes to the wrong size (not 32 bytes)" do
      kp = fresh_keypair()

      Application.put_env(
        :web_push,
        :vapid,
        public_key: kp.public_key,
        # 10 random bytes — not a valid P-256 scalar
        private_key: Base.url_encode64(:crypto.strong_rand_bytes(10), padding: false)
      )

      assert_raise ArgumentError, ~r/private_key must be 32 bytes/, fn ->
        VapidKeypairValidator.validate!()
      end
    end
  end

  describe "validate!/1 — mismatched keypair (the prod bug)" do
    test "raises when public_key and private_key are from DIFFERENT keypairs" do
      # Two unrelated keypairs. The signature won't verify because the
      # private key doesn't correspond to the public key.
      kp_a = fresh_keypair()
      kp_b = fresh_keypair()

      Application.put_env(
        :web_push,
        :vapid,
        public_key: kp_a.public_key,
        private_key: kp_b.private_key,
        subject: "mailto:admin@localhost"
      )

      assert_raise ArgumentError,
                   ~r/public_key does not correspond to private_key|mismatch|signed JWT does not verify/,
                   fn ->
                     VapidKeypairValidator.validate!()
                   end
    end

    test "the error message names the operational fix" do
      kp_a = fresh_keypair()
      kp_b = fresh_keypair()

      Application.put_env(
        :web_push,
        :vapid,
        public_key: kp_a.public_key,
        private_key: kp_b.private_key
      )

      error =
        try do
          VapidKeypairValidator.validate!()
          nil
        rescue
          e in ArgumentError -> Exception.message(e)
        end

      assert error =~ "mix web_push.gen.vapid",
             "error message must point the operator at `mix web_push.gen.vapid`"

      assert error =~ "VAPID_PUBLIC_KEY" and error =~ "VAPID_PRIVATE_KEY",
             "error message must name both env vars so the operator updates both"

      assert error =~ "BadJwtToken" or error =~ "APNs",
             "error message must explain WHY this matters (APNs will reject pushes)"
    end
  end
end
