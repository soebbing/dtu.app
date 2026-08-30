defmodule DtuAppWeb.Passkeys.RateLimit do
  @moduledoc """
  Decides whether `DtuAppWeb.Plugs.PasskeyRateLimit` is active, based
  on the `PASSKEYS_RATE_LIMIT_ENABLED` env var and the active
  `config_env()`.

  Defaults to **enabled** in every environment — the plug is cheap
  (in-memory ETS sliding window keyed on `(remote_ip, action)`) and
  the existing `test/dtu_app_web/controllers/passkey_controller_test.exs`
  test "429 rate_limited after 10 attempts" assumes enforcement is on
  in `:test`. The only flipper is the CI Playwright e2e suite, which
  sets `PASSKEYS_RATE_LIMIT_ENABLED=false` via `.github/workflows/ci.yml`
  to keep its `retries: 2` (= 3 attempts per serial block) from
  tripping the 10/60s/IP budget on the same `authentication_options`
  action. Operators can override the other direction with
  `PASSKEYS_RATE_LIMIT_ENABLED=true` (default behavior) — useful only
  if someone wants to defensively re-enable after the e2e override.
  Unknown env values fall back to the per-env default.

  The plug keys its counter on `(remote_ip, action)` and rejects with
  `too_many_attempts` once 10 hits land within 60 s. Disabling it for
  CI doesn't lose coverage because
  `test/dtu_app_web/plugs/passkey_rate_limit_test.exs` exercises the
  plug's enforcement path directly and pins the bypass in the
  dedicated "bypasses entirely when :passkey_rate_limit_enabled is
  false" test.

  See `test/dtu_app_web/passkeys/rate_limit_test.exs` for the pinned
  decision matrix.
  """

  @doc """
  Returns whether the passkey rate limit should be enforced.

  - `env_value` is the raw `System.get_env("PASSKEYS_RATE_LIMIT_ENABLED")`
    result (`nil` when unset) or any caller-supplied equivalent.
  - `config_env` is `:dev | :test | :prod | ...` (the result of
    `Mix.env()` or `config_env()`).
  """
  @spec enabled?(env_value :: String.t() | nil, config_env :: atom()) :: boolean()
  def enabled?(env_value, _config_env) do
    # Default: enabled everywhere. The only flipper is CI's Playwright
    # e2e suite, which uses the env override below.
    default = true

    case env_value do
      "true" -> true
      "false" -> false
      _ -> default
    end
  end
end
