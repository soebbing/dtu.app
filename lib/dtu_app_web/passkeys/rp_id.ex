defmodule DtuAppWeb.Passkeys.RpId do
  @moduledoc """
  Resolves the WebAuthn **Relying-Party ID** (`rp.id`) the browser must
  match against the page origin during a ceremony.

  Per the WebAuthn spec, `rp.id` MUST be a registrable-domain suffix of
  the origin's effective domain — i.e. a production deploy at
  `https://dtu.app` cannot use `"localhost"` as the RP ID, because
  `localhost` is not a suffix of `dtu.app` and the browser raises
  `SecurityError: The operation is insecure` from
  `navigator.credentials.create/get`.

  Defaults are env-aware:

  | `config_env()` | default `:webauthn_rp_id` |
  |----------------|---------------------------|
  | `:dev`         | `"localhost"`             |
  | `:test`        | `"localhost"`             |
  | anything else  | `"dtu.app"`               |

  Operators can override via the `WEBAUTHN_RP_ID` env var in any env.
  `config/runtime.exs` calls this helper so the matrix is testable
  without booting the app.

  See `test/dtu_app_web/passkeys/rp_id_test.exs` for the pinned matrix.
  """

  @doc """
  Returns the default RP ID for the given `config_env()`.

  - `config_env` is `Mix.env()` / `config_env()` output
    (`:dev | :test | :prod | ...`).
  """
  @spec default(config_env :: atom()) :: String.t()
  def default(:dev), do: "localhost"
  def default(:test), do: "localhost"
  def default(_), do: "dtu.app"
end
