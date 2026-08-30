defmodule DtuAppWeb.Plugs.PasskeyRateLimit do
  @moduledoc """
  Sliding-window rate limit for the passkey ceremony endpoints.

  Caps each `(remote_ip, action)` pair at `@limit` requests per
  `@window_ms` (default: 10 requests / 60 s). The `action` is read
  from `conn.private[:passkey_action]` so the controller can declare
  what it's about to do before invoking the plug.

  Returns 429 with `%{error: "too_many_attempts"}` JSON when the
  limit is exceeded.

  Bypassed entirely when the application env key
  `:dtu_app, :passkey_rate_limit_enabled` is `false` — set by
  `config/runtime.exs` per the `DtuAppWeb.Passkeys.RateLimit` decision
  matrix (defaults OFF in `:dev`/`:test`, defaults ON in `:prod`,
  overridable with `PASSKEYS_RATE_LIMIT_ENABLED`). The CI Playwright
  run uses the env override to disable it; the dedicated unit test
  `test/dtu_app_web/plugs/passkey_rate_limit_test.exs` exercises the
  plug directly so bypassing in CI doesn't lose coverage.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @limit 10
  @window_ms 60 * 1000

  def init(opts), do: opts

  def call(conn, _opts) do
    if Application.get_env(:dtu_app, :passkey_rate_limit_enabled, true) do
      enforce(conn)
    else
      conn
    end
  end

  defp enforce(conn) do
    action = Map.get(conn.private, :passkey_action, "default")
    ip = remote_ip(conn) || "unknown"
    key = {ip, action}

    if within_limit?(key) do
      register_hit(key)
      conn
    else
      conn
      |> put_status(:too_many_requests)
      |> json(%{error: "too_many_attempts"})
      |> halt()
    end
  end

  defp within_limit?(key) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - @window_ms

    hits =
      case :ets.lookup(:passkey_rate_limit, key) do
        [{^key, timestamps}] -> Enum.filter(timestamps, &(&1 >= cutoff))
        [] -> []
      end

    length(hits) < @limit
  end

  defp register_hit(key) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - @window_ms

    :ets.insert(
      :passkey_rate_limit,
      {key,
       [
         now
         | Enum.filter(
             List.wrap(
               :ets.lookup(:passkey_rate_limit, key)
               |> Enum.map(fn {_, ts} -> ts end)
               |> List.flatten()
             ),
             &(&1 >= cutoff)
           )
       ]}
    )
  end

  defp remote_ip(conn) do
    case conn.remote_ip do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      _ -> nil
    end
  end
end
