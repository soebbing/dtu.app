defmodule DtuAppWeb.Plugs.LocaleTest do
  use DtuAppWeb.ConnCase, async: true

  alias DtuAppWeb.Plugs.Locale

  describe "call/2 (priority chain: user.locale > accept-language > en)" do
    test "no user, no accept-language: fallback to \"en\"" do
      conn = conn_with([]) |> Locale.call([])

      assert Plug.Conn.get_session(conn, "locale") == "en"
      assert conn.assigns.locale == "en"
      assert Gettext.get_locale(DtuAppWeb.Gettext) == "en"
    end

    test "no user, German accept-language: resolves to \"de\"" do
      conn =
        conn_with([])
        |> Plug.Conn.put_req_header(
          "accept-language",
          "de-DE,de;q=0.9,en-US;q=0.8,en;q=0.7"
        )
        |> Locale.call([])

      assert conn.assigns.locale == "de"
      assert Gettext.get_locale(DtuAppWeb.Gettext) == "de"
    end

    test "no user, French accept-language: resolves to \"fr\"" do
      conn =
        conn_with([])
        |> Plug.Conn.put_req_header("accept-language", "fr-FR,fr;q=0.9")
        |> Locale.call([])

      assert conn.assigns.locale == "fr"
    end

    test "no user, unknown accept-language: fallback to \"en\"" do
      conn =
        conn_with([])
        |> Plug.Conn.put_req_header("accept-language", "es-ES,es;q=0.9")
        |> Locale.call([])

      assert conn.assigns.locale == "en"
    end

    test "logged-in user with locale=\"de\" wins over French accept-language", %{conn: conn} do
      # The user explicitly chose German in /users/settings. The
      # request's Accept-Language is French (e.g. a coworker on a
      # shared device, or a VPN that rewrites the header). The
      # user's persisted preference MUST win — it's the explicit
      # signal; the browser header is best-effort for signed-out
      # visitors only.
      user = %DtuApp.Accounts.User{id: 1, locale: "de"}
      scope = %DtuApp.Accounts.Scope{user: user}

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.assign(:current_scope, scope)
        |> Plug.Conn.put_req_header("accept-language", "fr-FR,fr;q=0.9")
        |> Locale.call([])

      assert conn.assigns.locale == "de"
      assert Gettext.get_locale(DtuAppWeb.Gettext) == "de"
    end

    test "user with an unsupported locale value falls back to accept-language", %{conn: conn} do
      # Defensive: if a value outside `User.@supported_locales` ever
      # lands on the user record (data migration, manual SQL), the
      # plug must NOT propagate it to Gettext. Falling through to
      # Accept-Language is the safest behaviour — we'd rather serve
      # the visitor in their browser's preferred language than in
      # an unknown code that screen readers / gettext may mishandle.
      user = %DtuApp.Accounts.User{id: 1, locale: "klingon"}
      scope = %DtuApp.Accounts.Scope{user: user}

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.assign(:current_scope, scope)
        |> Plug.Conn.put_req_header("accept-language", "de-DE,de;q=0.9")
        |> Locale.call([])

      assert conn.assigns.locale == "de"
    end

    test "signed-out scope (user = nil) falls through to accept-language" do
      # `fetch_current_scope_for_user` assigns `%Scope{user: nil}`
      # for unauthenticated requests. The plug must NOT crash — it
      # should just skip the user-locale branch and parse the
      # header.
      scope = %DtuApp.Accounts.Scope{user: nil}

      conn =
        conn_with([])
        |> Plug.Conn.assign(:current_scope, scope)
        |> Plug.Conn.put_req_header("accept-language", "fr-FR,fr;q=0.9")
        |> Locale.call([])

      assert conn.assigns.locale == "fr"
    end
  end

  describe "on_mount/4 (LiveView locale)" do
    test "session with German" do
      socket = Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, :dummy, nil)
      {:cont, socket} = Locale.on_mount(:default, %{}, %{"locale" => "de"}, socket)
      assert socket.assigns.locale == "de"
      assert Gettext.get_locale(DtuAppWeb.Gettext) == "de"
    end

    test "session with French" do
      socket = Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, :dummy, nil)
      {:cont, socket} = Locale.on_mount(:default, %{}, %{"locale" => "fr"}, socket)
      assert socket.assigns.locale == "fr"
    end

    test "session missing locale: default to \"en\"" do
      socket = Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, :dummy, nil)
      {:cont, socket} = Locale.on_mount(:default, %{}, %{}, socket)
      assert socket.assigns.locale == "en"
    end
  end

  # Helper: build a fresh conn with a test session but no current_scope
  # or accept-language header. Mirrors what `:fetch_session` would do
  # before `:fetch_current_scope_for_user` runs.
  defp conn_with(_) do
    Plug.Test.init_test_session(build_conn(), %{})
  end
end
