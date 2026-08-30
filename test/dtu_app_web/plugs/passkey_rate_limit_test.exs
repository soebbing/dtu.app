defmodule DtuAppWeb.Plugs.PasskeyRateLimitTest do
  use DtuAppWeb.ConnCase, async: false

  import Plug.Test

  alias DtuAppWeb.Plugs.PasskeyRateLimit

  setup do
    # Clear the shared ETS table before each test so a prior test's
    # hits don't poison the next test's assertions. The brief's
    # verbatim test file omits this and is non-deterministic as a
    # result — test ordering can run "rejects the 11th" before
    # "allows requests under the limit" and observe a pre-poisoned
    # counter.
    :ets.delete_all_objects(:passkey_rate_limit)
    # Force the kill switch on for every test below — the test file
    # is the authoritative source of "what does the plug DO when
    # enforced"; the bypass path is pinned in
    # `test/dtu_app_web/passkeys/rate_limit_test.exs` and exercised
    # by the dedicated bypass test below. Without this on_init the
    # file would silently inherit whatever the runtime env config
    # set (dev = disabled by default), making "rejects the 11th"
    # pass-or-fail depending on the runner's MIX_ENV.
    Application.put_env(:dtu_app, :passkey_rate_limit_enabled, true)
    on_exit(fn -> Application.delete_env(:dtu_app, :passkey_rate_limit_enabled) end)
    :ok
  end

  defp conn_for(action, ip \\ {127, 0, 0, 1}) do
    conn = conn(:post, "/", "")
    conn = %{conn | remote_ip: ip}
    Plug.Conn.put_private(conn, :passkey_action, action)
  end

  test "allows requests under the limit" do
    Enum.each(1..10, fn _ ->
      conn = PasskeyRateLimit.call(conn_for("registration_options"), [])
      refute conn.halted
    end)
  end

  test "rejects the 11th request with 429" do
    Enum.each(1..10, fn _ ->
      PasskeyRateLimit.call(conn_for("registration_options"), [])
    end)

    conn = PasskeyRateLimit.call(conn_for("registration_options"), [])
    assert conn.halted
    assert conn.status == 429
    assert conn.resp_body =~ "too_many_attempts"
  end

  test "different actions do not share a limit" do
    Enum.each(1..10, fn _ ->
      PasskeyRateLimit.call(conn_for("registration_options"), [])
    end)

    # Authentication endpoint has its own counter.
    conn = PasskeyRateLimit.call(conn_for("authentication_options"), [])
    refute conn.halted
  end

  test "bypasses entirely when :passkey_rate_limit_enabled is false" do
    # CI flips this off via PASSKEYS_RATE_LIMIT_ENABLED=false so the
    # Playwright e2e suite (--workers=1, retries: 2) doesn't trip the
    # 10/60s budget on its own retries. The bypass MUST short-circuit
    # before any ETS lookup so a flooded test run can't accidentally
    # exercise the limiter through a misconfig.
    Application.put_env(:dtu_app, :passkey_rate_limit_enabled, false)

    Enum.each(1..50, fn _ ->
      conn = PasskeyRateLimit.call(conn_for("registration_options"), [])
      refute conn.halted
    end)
  end
end
