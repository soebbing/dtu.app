defmodule DtuAppWeb.StaleDataBadge do
  @moduledoc """
  A small inline badge that surfaces the freshness of the dashboard's
  data — driven by `phx:notify` / `phx:connected` / `phx:disconnected`
  events and the browser's `online` / `offline` signals.

  Rendered above `<.offline_banner />` in the root layout, hidden by
  default while a tick is recent (the user is already looking at
  fresh data, so showing "Updated 0s ago" is just noise). When the
  freshness degrades (no tick for 60s+, LiveView drops the socket,
  or the browser loses connectivity), the badge slides in via CSS
  and shows a localized message.

  Visual states (driven by the `data-freshness` attribute the hook
  sets on the root):
    - `fresh`        — hidden (still showing "Updated Xs ago" in
                        the DOM for screen readers, but the CSS
                        hides the chrome)
    - `stale`        — visible, amber, shows "Updated Xs ago"
    - `very_stale`   — visible, amber, shows "Stale — last update Xm ago"
    - `disconnected` — visible, sky-blue, "Reconnecting — showing last known data"
    - `offline`      — visible, red, "Offline — showing last known data"
  """

  use DtuAppWeb, :html

  attr :id, :string, default: "stale-data-badge"
  attr :class, :string, default: ""

  def stale_data_badge(assigns) do
    ~H"""
    <div
      id={@id}
      role="status"
      aria-live="polite"
      phx-hook="StaleDataBadge"
      data-freshness="fresh"
      data-last-tick={DateTime.utc_now() |> DateTime.to_unix(:millisecond) |> Integer.to_string()}
      class={
        [
          "stale-data-badge",
          "fixed inset-x-0 z-40",
          # CSS hides when `data-freshness="fresh"`, slides in for
          # the degraded states. The hook updates `data-freshness`
          # as events fire.
          @class
        ]
      }
    >
      <div class="mx-auto flex max-w-7xl items-center gap-2 px-4 py-1.5 text-xs font-medium sm:px-6 lg:px-8">
        <span data-stale-badge-label>
          {gettext("Updated just now")}
        </span>
      </div>
    </div>
    """
  end
end
