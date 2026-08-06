defmodule DtuAppWeb.OfflineBanner do
  @moduledoc """
  A sticky top-of-page banner that appears when the browser is offline.

  The banner is hidden by default. The `OfflineBanner` LiveView hook reads
  `navigator.onLine` and the `online`/`offline` window events, and toggles
  a `data-offline="true"` attribute on the banner's root. The banner is
  positioned at the very top of `<body>`, above the navbar and any flash
  messages, and slides in/out via CSS transitions on that attribute.

  This complements, but does not replace, the existing LiveView "Attempting
  to reconnect" flashes in `DtuAppWeb.Layouts.flash_group/1` — those
  cover transient WebSocket drops; this banner covers the case where the
  browser itself has lost network connectivity.
  """

  use DtuAppWeb, :html

  attr :id, :string, default: "offline-banner"
  attr :class, :string, default: ""

  def offline_banner(assigns) do
    ~H"""
    <div
      id={@id}
      role="status"
      aria-live="polite"
      phx-hook="OfflineBanner"
      data-offline="false"
      class={[
        "offline-banner",
        "fixed inset-x-0 top-0 z-50",
        "transform -translate-y-full opacity-0",
        "transition-all duration-300 ease-out motion-reduce:transition-none",
        "bg-amber-500 text-amber-950",
        "shadow-md",
        @class
      ]}
    >
      <div class="mx-auto flex max-w-7xl items-center gap-3 px-4 py-2 text-sm font-medium sm:px-6 lg:px-8">
        <.icon name="hero-wifi" class="size-5 shrink-0" />
        <span class="flex-1">
          {gettext("You're offline. Showing the latest data we have.")}
        </span>
      </div>
    </div>
    """
  end
end
