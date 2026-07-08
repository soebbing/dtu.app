defmodule DtuAppWeb.PageControllerTest do
  use DtuAppWeb.ConnCase, async: true

  import DtuApp.AccountsFixtures

  test "GET / renders the landing page for anonymous visitors", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Real-Time Solar Telemetry System"
    assert html_response(conn, 200) =~ "Solar Generation"
  end

  test "GET / redirects authenticated users to the dashboard", %{conn: conn} do
    conn = conn |> log_in_user(user_fixture()) |> get(~p"/")
    assert redirected_to(conn) == ~p"/dashboard"
  end
end
