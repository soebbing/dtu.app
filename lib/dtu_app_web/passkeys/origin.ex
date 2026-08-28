defmodule DtuAppWeb.Passkeys.Origin do
  @moduledoc """
  Reconstructs the URL origin the WebAuthn library compares against
  `clientDataJSON.origin` during a ceremony.

  Two non-obvious details drive the implementation:

    1. **Default ports are stripped.** WHATWG's `URL.origin` — and
       therefore the browser's `clientDataJSON.origin` — omits the
       port when it matches the scheme's default (`443` for `https`,
       `80` for `http`). The `webauthn` library does an exact-string
       compare (see `deps/webauthn/lib/webauthn/registration/response.ex`
       `origin?/2`), so this builder must mirror that — otherwise
       `https://dtu.app` from the browser fails against
       `https://dtu.app:443` from the controller and the controller
       returns `400 origin_mismatch`.

    2. **`X-Forwarded-Port` is honored.** Behind a TLS-terminating
       proxy the BEAM sees `conn.port` as the local bind port (e.g.
       `4000`), not the public port the browser thinks it's on. A
       request to `https://dtu.app` from the browser lands on the
       BEAM as `port=4000` unless nginx forwards
       `X-Forwarded-Port: 443`. Without that header the builder has
       no way to know the public port and any non-default bind port
       produces a non-matching origin.

  Both behaviors are pinned by `test/dtu_app_web/passkeys/origin_test.exs`.
  """

  alias Plug.Conn

  @doc """
  Returns the origin the WebAuthn library should compare
  `clientDataJSON.origin` against.

  Always strips the scheme's default port. Prefers `X-Forwarded-Port`
  when present (so a TLS-terminating proxy can publish the public
  port); falls back to `conn.port` otherwise.
  """
  @spec from_conn(Conn.t()) :: String.t()
  def from_conn(conn) do
    scheme = to_string(conn.scheme)
    host = conn.host

    case effective_port(conn) do
      nil -> "#{scheme}://#{host}"
      port -> "#{scheme}://#{host}:#{port}"
    end
  end

  @doc """
  Returns `nil` when `port` is the default for `scheme` (omitted by
  WHATWG from `URL.origin`); otherwise returns `port` unchanged.

  Exposed for direct unit testing of the scheme/port matrix without
  having to build a `Plug.Conn`.
  """
  @spec strip_default_port(Conn.scheme(), non_neg_integer() | nil) :: non_neg_integer() | nil
  def strip_default_port(:https, 443), do: nil
  def strip_default_port(:http, 80), do: nil
  def strip_default_port(_scheme, port), do: port

  defp effective_port(conn) do
    strip_default_port(conn.scheme, public_port(conn))
  end

  defp public_port(conn) do
    case Conn.get_req_header(conn, "x-forwarded-port") do
      [value | _] ->
        case Integer.parse(value) do
          {n, _} -> n
          :error -> conn.port
        end

      [] ->
        conn.port
    end
  end
end
