defmodule DtuAppWeb.Plugs.LocaleTest do
  use DtuAppWeb.ConnCase, async: true

  alias DtuAppWeb.Plugs.Locale

  test "call/2 parses accept-language and sets session + assigns", %{conn: conn} do
    # The plug writes to the session; initialize a test session first.
    conn = Plug.Test.init_test_session(conn, %{})

    # 1. No accept-language header: fallback to "en"
    conn1 = Locale.call(conn, [])
    assert Plug.Conn.get_session(conn1, "locale") == "en"
    assert conn1.assigns.locale == "en"
    assert Gettext.get_locale(DtuAppWeb.Gettext) == "en"

    # 2. German locale
    conn2 =
      conn
      |> Plug.Conn.put_req_header("accept-language", "de-DE,de;q=0.9,en-US;q=0.8,en;q=0.7")
      |> Locale.call([])

    assert Plug.Conn.get_session(conn2, "locale") == "de"
    assert conn2.assigns.locale == "de"
    assert Gettext.get_locale(DtuAppWeb.Gettext) == "de"

    # 3. French locale
    conn3 =
      conn
      |> Plug.Conn.put_req_header("accept-language", "fr-FR,fr;q=0.9")
      |> Locale.call([])

    assert Plug.Conn.get_session(conn3, "locale") == "fr"
    assert conn3.assigns.locale == "fr"
    assert Gettext.get_locale(DtuAppWeb.Gettext) == "fr"

    # 4. Unknown locale: fallback to "en"
    conn4 =
      conn
      |> Plug.Conn.put_req_header("accept-language", "es-ES,es;q=0.9")
      |> Locale.call([])

    assert Plug.Conn.get_session(conn4, "locale") == "en"
    assert conn4.assigns.locale == "en"
    assert Gettext.get_locale(DtuAppWeb.Gettext) == "en"
  end

  test "on_mount/4 sets Gettext locale from session and assigns socket" do
    socket = Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, :dummy, nil)

    # 1. Session with German
    {:cont, socket1} = Locale.on_mount(:default, %{}, %{"locale" => "de"}, socket)
    assert socket1.assigns.locale == "de"
    assert Gettext.get_locale(DtuAppWeb.Gettext) == "de"

    # 2. Session with French
    {:cont, socket2} = Locale.on_mount(:default, %{}, %{"locale" => "fr"}, socket)
    assert socket2.assigns.locale == "fr"
    assert Gettext.get_locale(DtuAppWeb.Gettext) == "fr"

    # 3. Session missing locale: default to "en"
    {:cont, socket3} = Locale.on_mount(:default, %{}, %{}, socket)
    assert socket3.assigns.locale == "en"
    assert Gettext.get_locale(DtuAppWeb.Gettext) == "en"
  end
end
