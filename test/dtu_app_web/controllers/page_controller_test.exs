defmodule DtuAppWeb.PageControllerTest do
  use DtuAppWeb.ConnCase, async: true

  alias DtuApp.AccountsFixtures

  describe "GET /imprint" do
    test "renders the imprint page" do
      conn = build_conn() |> get(~p"/imprint")
      html = html_response(conn, 200)
      assert html =~ "Imprint"
      assert html =~ "Service provider"
      assert html =~ "Contact"
      assert html =~ "Copyright"
    end

    test "renders the footer with imprint/privacy links (logged-out state)" do
      conn = build_conn() |> get(~p"/")
      html = html_response(conn, 200)
      assert html =~ ~p"/imprint"
      assert html =~ ~p"/privacy"
    end

    test "renders the footer with imprint/privacy links (logged-in state)" do
      user = AccountsFixtures.user_fixture()
      conn = build_conn() |> log_in_user(user) |> get(~p"/dashboard")
      html = html_response(conn, 200)
      assert html =~ ~p"/imprint"
      assert html =~ ~p"/privacy"
    end
  end

  describe "GET /privacy" do
    test "renders the privacy policy page" do
      conn = build_conn() |> get(~p"/privacy")
      html = html_response(conn, 200)
      assert html =~ "Privacy Policy"
      assert html =~ "Overview"
      assert html =~ "What data we collect"
      assert html =~ "Your rights"
      assert html =~ "GDPR"
    end
  end

  describe "footer version" do
    test "shows the configured :dtu_app, :version" do
      original = Application.get_env(:dtu_app, :version)
      Application.put_env(:dtu_app, :version, "vTEST-1234")
      on_exit(fn -> Application.put_env(:dtu_app, :version, original) end)

      conn = build_conn() |> get(~p"/")
      html = html_response(conn, 200)
      assert html =~ "vTEST-1234"
    end
  end
end
