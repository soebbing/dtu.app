defmodule DtuAppWeb.Plugs.Locale do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    locale = parse_accept_language(conn)
    Gettext.put_locale(DtuAppWeb.Gettext, locale)

    conn
    |> put_session("locale", locale)
    |> assign(:locale, locale)
  end

  def on_mount(:default, _params, session, socket) do
    locale = Map.get(session, "locale", "en")
    Gettext.put_locale(DtuAppWeb.Gettext, locale)
    {:cont, Phoenix.Component.assign(socket, :locale, locale)}
  end

  defp parse_accept_language(conn) do
    case Plug.Conn.get_req_header(conn, "accept-language") do
      [value | _] when is_binary(value) and value != "" ->
        value
        |> String.split(",")
        |> Enum.map(fn lang ->
          lang
          |> String.split(";")
          |> List.first()
          |> String.trim()
          |> String.downcase()
        end)
        |> Enum.map(fn
          "de" <> _ -> "de"
          "fr" <> _ -> "fr"
          "en" <> _ -> "en"
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)
        |> List.first() || "en"

      _ ->
        "en"
    end
  end
end
