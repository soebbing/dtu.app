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
end
