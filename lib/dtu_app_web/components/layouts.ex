defmodule DtuAppWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use DtuAppWeb, :html

  alias DtuAppWeb.NetworkStatusIndicator
  alias DtuAppWeb.OfflineBanner

  @repo_url "https://github.com/soebbing/dtu.app"

  @doc """
  Maps the footer `@version` assign to a clickable GitHub URL.

  Recognized shapes:
    * Calver release tag (e.g. `2026-08-28-9`) → release page
    * Branch name (e.g. `main`, `fix/foo-bar`) → tree view
    * Anything else (`dev`, Mix.Project SemVer) → repo root

  The Calver pattern mirrors the tag format this repo's release
  workflow pushes (see `.github/workflows/`); `mix project version`
  falls back to a SemVer string at runtime when neither a tag nor a
  branch name is available, which gets bucketed into the
  "anything else" arm.
  """
  @spec release_href(any()) :: String.t()
  def release_href(version) when is_binary(version) do
    cond do
      dev?(version) -> @repo_url
      calver?(version) -> "#{@repo_url}/releases/tag/#{version}"
      branch?(version) -> "#{@repo_url}/tree/#{version}"
      true -> @repo_url
    end
  end

  # Defensive fallback: the `@version` assign is a string in every
  # supported environment (Calver tag, branch name, `dev`, or
  # `Mix.Project` SemVer), but a stale `Application.put_env` or a
  # future config-shape change could surface a non-binary value at
  # render time. Crashing the request is the wrong response — point
  # the user at the repo root instead.
  def release_href(_), do: @repo_url

  # The literal `dev` placeholder (see `config/runtime.exs` — used
  # when no env var, git, or Mix.Project version resolves).
  defp dev?("dev"), do: true
  defp dev?(_), do: false

  # Calver tag: `YYYY-MM-DD-N` — the shape `release.yml` pushes.
  defp calver?(version), do: version =~ ~r/^\d{4}-\d{2}-\d{2}-\d+$/

  # Branch name: alphanumerics, dashes, underscores, and slashes —
  # matches git's typical ref format. Dots are excluded because
  # SemVer strings (`0.1.0`) would otherwise sneak through here.
  defp branch?(version) do
    version != "" and version =~ ~r{^[A-Za-z0-9_\-/]+$}
  end

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :class, :string, default: "max-w-2xl"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <main class="flex-1 px-4 py-12 sm:px-6 lg:px-8">
      <div class={["mx-auto space-y-4", @class]}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Minimal layout for the public `/s/:token` share route.

  Same chrome behaviour as `app/1` (single `<main>` wrapper with
  configurable max-width), but rendered inside the
  `root_public.html.heex` root layout so the navbar, burger menu,
  user dropdown, and login/register buttons from the authenticated
  shell are absent. The "powered by dtu.app" footer lives in the
  root layout itself so it stays sticky even when this layout is
  replaced with a future public page (e.g. a public device page).
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :class, :string, default: "max-w-3xl"

  slot :inner_block, required: true

  def public(assigns) do
    ~H"""
    <main class="flex-1 px-4 py-8 sm:px-6 lg:px-8">
      <div class={["mx-auto space-y-5", @class]}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex flex-row items-center rounded-full border border-zinc-200 dark:border-zinc-700 bg-zinc-100 dark:bg-zinc-800">
      <div class="absolute w-1/3 h-full rounded-full bg-white dark:bg-zinc-700 shadow-sm left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="relative flex p-2 cursor-pointer w-1/3 justify-center"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="relative flex p-2 cursor-pointer w-1/3 justify-center"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="relative flex p-2 cursor-pointer w-1/3 justify-center"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
