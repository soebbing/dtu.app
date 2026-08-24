defmodule DtuAppWeb.Plugs.Locale do
  import Plug.Conn

  # The set of locales we ship .po catalogs for. Anything outside
  # this set falls back to "en" — see `resolve_locale/2`. Mirrors
  # `@supported_locales` on `DtuApp.Accounts.User`; a value written
  # by the settings form that isn't in this list would also be
  # rejected by the User changeset, so they should stay in sync.
  @supported_locales ~w(en de fr)

  def init(opts), do: opts

  def call(conn, _opts) do
    # Locale resolution priority:
    #   1. Logged-in user's persisted `User.locale` (the user
    #      explicitly chose this in /users/settings — it wins).
    #   2. `Accept-Language` request header (best-effort browser
    #      signal for signed-out visitors).
    #   3. The default "en".
    #
    # `fetch_current_scope_for_user` (in the :browser pipeline
    # upstream of this plug — see lib/dtu_app_web/router.ex)
    # assigns `current_scope` before we run, so the signed-in
    # user is already available here. The scope's user is nil for
    # signed-out visitors, in which case we fall through to
    # Accept-Language.
    locale = resolve_locale(conn)

    Gettext.put_locale(DtuAppWeb.Gettext, locale)

    conn
    |> put_session("locale", locale)
    |> assign(:locale, locale)
    # Expose the configured release/branch identifier (see config/runtime.exs)
    # to every rendered template — the unobtrusive site footer reads this.
    |> assign(:version, Application.get_env(:dtu_app, :version, "dev"))
  end

  def on_mount(:default, _params, session, socket) do
    # The session-stored locale is what the plug saved on the request
    # that opened the LiveView. For first connect (no session yet)
    # we'd default to "en". The plug is also mounted in the live
    # socket's on_mount chain (see router.ex line ~89) so the assign
    # is already populated when we get here.
    locale = Map.get(session, "locale", "en")
    Gettext.put_locale(DtuAppWeb.Gettext, locale)
    {:cont, Phoenix.Component.assign(socket, :locale, locale)}
  end

  defp resolve_locale(conn) do
    case user_locale(conn) do
      loc when loc in @supported_locales -> loc
      _ -> parse_accept_language(conn)
    end
  end

  defp user_locale(conn) do
    case conn.assigns[:current_scope] do
      %{user: %{locale: loc}} when is_binary(loc) -> loc
      _ -> nil
    end
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
        |> Enum.find(&(&1 in @supported_locales)) || "en"

      _ ->
        "en"
    end
  end
end
