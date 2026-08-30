defmodule DtuAppWeb.Passkeys.RateLimitTest do
  @moduledoc """
  Pins the `DtuAppWeb.Passkeys.RateLimit.enabled?/2` decision matrix.

  The default-in-prod / override-via-env / unknown-falls-back-to-
  per-env-default contract is enforced here so CI's
  `PASSKEYS_RATE_LIMIT_ENABLED=false` (set in
  `.github/workflows/ci.yml`) is the only thing standing between a
  `--workers=1` Playwright run with `retries: 2` and a `429 too_many_attempts`.
  Changing the matrix is a breaking change for the e2e suite — bump
  the relevant test below.
  """

  use ExUnit.Case, async: true

  alias DtuAppWeb.Passkeys.RateLimit

  describe "per-env defaults (env_value nil)" do
    test "prod defaults to enabled" do
      assert RateLimit.enabled?(nil, :prod) == true
    end

    test "dev defaults to enabled" do
      assert RateLimit.enabled?(nil, :dev) == true
    end

    test "test defaults to enabled" do
      assert RateLimit.enabled?(nil, :test) == true
    end

    test "any unknown config_env also defaults to enabled" do
      assert RateLimit.enabled?(nil, :staging) == true
    end
  end

  describe "explicit env overrides win" do
    test "\"true\" forces enabled in any env" do
      assert RateLimit.enabled?("true", :prod) == true
      assert RateLimit.enabled?("true", :dev) == true
      assert RateLimit.enabled?("true", :test) == true
      assert RateLimit.enabled?("true", :staging) == true
    end

    test "\"false\" forces disabled in any env (including prod)" do
      assert RateLimit.enabled?("false", :prod) == false
      assert RateLimit.enabled?("false", :dev) == false
      assert RateLimit.enabled?("false", :test) == false
      assert RateLimit.enabled?("false", :staging) == false
    end
  end

  describe "unknown env values fall back to per-env default" do
    test "empty string is unknown → falls back" do
      assert RateLimit.enabled?("", :prod) == true
      assert RateLimit.enabled?("", :dev) == true
    end

    test "non-boolean string is unknown → falls back" do
      assert RateLimit.enabled?("1", :prod) == true
      assert RateLimit.enabled?("yes", :dev) == true
      # The match is case-sensitive on purpose — `"TRUE"` is unknown,
      # not enabled. Falls back to per-env default (true everywhere).
      assert RateLimit.enabled?("TRUE", :prod) == true
    end
  end
end
