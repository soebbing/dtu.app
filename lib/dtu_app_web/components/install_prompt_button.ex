defmodule DtuAppWeb.InstallPromptButton do
  @moduledoc """
  Inline button that surfaces the browser's PWA install prompt.

  The button is hidden by default. The `InstallPromptButton` JS hook
  (in `assets/js/install_prompt_button.js`) captures the browser's
  `beforeinstallprompt` event, reveals the button when the browser
  signals the app is installable, and calls `event.prompt()` on click.
  After install or dismissal the button stays hidden for a 30-day
  cooldown (recorded in `localStorage`) so we don't keep nagging
  visitors who already said no.

  Renders as a plain `<button>` with `hidden` so the chrome is
  invisible before JS hydrates — the hook then flips it visible only
  when the browser actually has an install prompt to offer. iOS
  Safari never fires `beforeinstallprompt`, so on iOS the button
  stays hidden and users install via the share sheet ("Add to Home
  Screen"); the button is still rendered for HTML consistency.
  """

  use DtuAppWeb, :html

  attr :id, :string, default: "install-prompt-button"
  attr :class, :string, default: ""

  attr :variant, :string,
    default: "navbar",
    values: ["navbar", "burger"],
    doc: "Visual style: `navbar` for the right-side cluster, `burger` for the mobile menu row."

  def install_prompt_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-hook="InstallPromptButton"
      hidden
      aria-label={gettext("Install dtu.app")}
      class={[
        (@variant == "navbar" &&
           "inline-flex items-center gap-1.5 rounded-lg bg-emerald-500/90 hover:bg-emerald-400 text-zinc-950 px-3 py-1.5 text-sm font-semibold shadow-sm shadow-emerald-500/10 transition") ||
          (@variant == "burger" &&
             "flex items-center gap-2 px-2 py-2 rounded-lg text-sm font-semibold bg-emerald-500/90 hover:bg-emerald-400 text-zinc-950 transition") ||
          "",
        @class
      ]}
    >
      <.icon name="hero-arrow-down-tray" class="h-4 w-4" />
      <span>
        {gettext("Install")}
      </span>
    </button>
    """
  end
end
