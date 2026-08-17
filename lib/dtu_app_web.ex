defmodule DtuAppWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use DtuAppWeb, :controller
      use DtuAppWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  # Static paths served by `Plug.Static` at the endpoint root.
  #
  # These are the *unfingerprinted* logical paths that `~p"/foo"` resolves
  # to in templates. `mix phx.digest` writes both the unhashed file and a
  # fingerprinted sibling (`foo-<digest>.ext`) for each entry on this list,
  # and the browser always requests the fingerprinted URL because
  # `Phoenix.Endpoint.static_lookup/1` rewrites the unhashed path via
  # `cache_static_manifest`.
  #
  # Two entries need extra thought:
  #
  #   * `cache_manifest.json` is produced by `mix phx.digest` and is
  #     fetched at runtime by the service worker (`assets/js/app.js`)
  #     and the SW itself (`priv/static/service-worker.js`) to discover
  #     the fingerprinted asset URLs. It lives in `priv/static/` but is
  #     not covered by any `only` prefix, so it must be listed explicitly.
  #   * `manifest.webmanifest` and `service-worker.js` are *also* served
  #     under their fingerprinted names (`manifest-<digest>.webmanifest`,
  #     `service-worker-<digest>.js`). Those fingerprinted URLs are 404'd
  #     by `Plug.Static`'s `only:` filter because the filter matches the
  #     first URL segment, and the fingerprinted URL has a different
  #     first segment. They're handled by `only_matching` in
  #     `lib/dtu_app_web/endpoint.ex` so the fingerprinted filenames
  #     don't need to be listed here (they change every build).
  def static_paths,
    do:
      ~w(assets fonts images favicon.ico robots.txt manifest.webmanifest service-worker.js offline.html cache_manifest.json)

  # Prefix-allowlist for `Plug.Static`'s `:only_matching` option.
  #
  # `Plug.Static.path_status/2` checks the *first* URL segment against the
  # `:only` list (`deps/plug/lib/plug/static.ex:242`). That's a problem for
  # fingerprinted filenames whose unhashed twin (e.g. `manifest.webmanifest`)
  # is in `static_paths/0` but whose fingerprinted URL
  # (`manifest-<digest>.webmanifest`) has a different first segment — so the
  # `only:` filter would 404 them.
  #
  # `:only_matching` is a relaxed check: any URL whose first segment
  # *starts with* one of these prefixes is allowed. Listing `manifest` and
  # `service-worker` covers every digest of those two files without having
  # to enumerate the fingerprints (which change every release).
  def static_match_paths,
    do: ~w(manifest service-worker)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: DtuAppWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: DtuAppWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import DtuAppWeb.CoreComponents

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias DtuAppWeb.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: DtuAppWeb.Endpoint,
        router: DtuAppWeb.Router,
        statics: DtuAppWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
