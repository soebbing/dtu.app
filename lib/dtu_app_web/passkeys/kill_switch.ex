defmodule DtuAppWeb.Passkeys.KillSwitch do
  @moduledoc """
  Decides whether the passkeys feature is enabled, based on the
  `PASSKEYS_ENABLED` env var and the active `config_env()`.

  Per Global Constraint #4 of the passkeys plan, `:prod` defaults to
  **disabled** for the 24-hour monitoring window after first launch;
  `:dev` and `:test` default to **enabled**. The operator can override
  either direction with `PASSKEYS_ENABLED=true` (enable) or
  `PASSKEYS_ENABLED=false` (disable). Unknown env values fall back
  to the per-env default rather than enabling — see
  `config/runtime.exs` for the single declaration site.
  """

  @doc """
  Returns the kill-switch decision.

  - `env_value` is the raw `System.get_env("PASSKEYS_ENABLED")` result
    (`nil` when unset) or any caller-supplied equivalent.
  - `config_env` is `:dev | :test | :prod | ...` (the result of
    `Mix.env()` or `config_env()`).
  """
  @spec enabled?(env_value :: String.t() | nil, config_env :: atom()) :: boolean()
  def enabled?(env_value, config_env) do
    default = if config_env == :prod, do: false, else: true

    case env_value do
      "true" -> true
      "false" -> false
      _ -> default
    end
  end
end
