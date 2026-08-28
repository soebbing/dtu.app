defmodule DtuAppWeb.Passkeys.OriginTest do
  @moduledoc """
  Pins the origin string the WebAuthn library compares against
  `clientDataJSON.origin`.

  Regression guard for the bug where the controller built
  `"https://dtu.app:443"` (or `":4000"` behind a TLS-terminating
  proxy without `X-Forwarded-Port`) — strings the browser never
  writes, because WHATWG's `URL.origin` strips the default port for
  the scheme. The `webauthn` library does an exact-string compare,
  so the mismatch surfaces as `400 origin_mismatch` from the
  `registration/finish` and `authentication/finish` endpoints.

  See `DtuAppWeb.Passkeys.Origin` for the rationale and
  `deps/webauthn/lib/webauthn/registration/response.ex` for the
  underlying comparison.
  """

  use ExUnit.Case, async: true

  import Plug.Conn

  alias DtuAppWeb.Passkeys.Origin

  # `Phoenix.ConnTest.build_conn/0` defaults to `https://www.example.com`
  # — fine for a smoke test, but every assertion here overrides every
  # field that `Origin.from_conn/1` reads, so we set them explicitly.

  describe "from_conn/1 — default-port stripping (the bug)" do
    test "https on port 443 omits the port" do
      conn = conn_with(scheme: :https, host: "dtu.app", port: 443)
      assert Origin.from_conn(conn) == "https://dtu.app"
    end

    test "https on the BEAM bind port with X-Forwarded-Port: 443 omits the port" do
      conn =
        conn_with(scheme: :https, host: "dtu.app", port: 4000)
        |> put_req_header("x-forwarded-port", "443")

      assert Origin.from_conn(conn) == "https://dtu.app"
    end

    test "http on port 80 omits the port" do
      conn = conn_with(scheme: :http, host: "example.com", port: 80)
      assert Origin.from_conn(conn) == "http://example.com"
    end
  end

  describe "from_conn/1 — non-default ports pass through" do
    test "https on a custom port keeps the port" do
      conn = conn_with(scheme: :https, host: "dtu.app", port: 8443)
      assert Origin.from_conn(conn) == "https://dtu.app:8443"
    end

    test "http on the dev port keeps the port" do
      conn = conn_with(scheme: :http, host: "localhost", port: 4000)
      assert Origin.from_conn(conn) == "http://localhost:4000"
    end
  end

  describe "from_conn/1 — X-Forwarded-Port precedence" do
    test "X-Forwarded-Port wins over conn.port" do
      conn =
        conn_with(scheme: :https, host: "dtu.app", port: 4000)
        |> put_req_header("x-forwarded-port", "8443")

      assert Origin.from_conn(conn) == "https://dtu.app:8443"
    end

    test "non-numeric X-Forwarded-Port falls back to conn.port" do
      conn =
        conn_with(scheme: :https, host: "dtu.app", port: 4000)
        |> put_req_header("x-forwarded-port", "garbage")

      assert Origin.from_conn(conn) == "https://dtu.app:4000"
    end

    test "missing X-Forwarded-Port falls back to conn.port" do
      conn = conn_with(scheme: :https, host: "dtu.app", port: 4000)
      assert Origin.from_conn(conn) == "https://dtu.app:4000"
    end
  end

  describe "strip_default_port/2 — direct matrix" do
    test "https/443 → nil" do
      assert Origin.strip_default_port(:https, 443) == nil
    end

    test "http/80 → nil" do
      assert Origin.strip_default_port(:http, 80) == nil
    end

    test "non-default ports pass through unchanged" do
      assert Origin.strip_default_port(:https, 8443) == 8443
      assert Origin.strip_default_port(:http, 4000) == 4000
      assert Origin.strip_default_port(:https, 1) == 1
    end
  end

  # Build a conn with explicit scheme/host/port — the three fields
  # `from_conn/1` reads. `Phoenix.ConnTest.build_conn/0` defaults to
  # `https://www.example.com`, which we override wholesale because
  # nothing else in the helper cares about the default.
  defp conn_with(opts) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:scheme, opts[:scheme])
    |> Map.put(:host, opts[:host])
    |> Map.put(:port, opts[:port])
  end
end
