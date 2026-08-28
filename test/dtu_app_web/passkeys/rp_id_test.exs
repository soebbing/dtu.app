defmodule DtuAppWeb.Passkeys.RpIdTest do
  @moduledoc """
  Pins the per-env default for `:webauthn_rp_id`.

  Regression guard for the drift where `config/runtime.exs` defaulted
  to `"localhost"` for every env — fine in dev/test, but the prod
  deploy at `https://dtu.app` would then surface
  `SecurityError: The operation is insecure` from
  `navigator.credentials.create/get` because `"localhost"` is not a
  registrable-domain suffix of `dtu.app`.
  """

  use ExUnit.Case, async: true

  alias DtuAppWeb.Passkeys.RpId

  doctest RpId

  test "dev defaults to localhost" do
    assert RpId.default(:dev) == "localhost"
  end

  test "test defaults to localhost" do
    assert RpId.default(:test) == "localhost"
  end

  test "prod defaults to dtu.app" do
    assert RpId.default(:prod) == "dtu.app"
  end

  test "any other env defaults to dtu.app" do
    # Belt-and-braces: a future env name (`:staging`, `:bench`,
    # anything we haven't enumerated) should default to the
    # production target rather than silently falling back to
    # `localhost` and breaking the ceremony on the live origin.
    assert RpId.default(:staging) == "dtu.app"
    assert RpId.default(:bench) == "dtu.app"
    assert RpId.default(nil) == "dtu.app"
  end
end
