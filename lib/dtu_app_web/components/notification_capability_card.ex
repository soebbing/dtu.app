defmodule DtuAppWeb.NotificationCapabilityCard do
  @moduledoc """
  The browser-capability + permission-state card that sits at the top
  of the Notifications page.

  Bundles three layers:

    1. **Hook wrapper** — the outer `<div id="notifications-permission"
       phx-hook="NotificationPermission" data-user-id={...}>`. The hook
       reports the browser's permission + display-mode state back to
       the server via the `notification_state` push event; we keep it
       as the wrapper so LiveView wires the hook on the same DOM node
       the user sees.

    2. **Six-variant case block** — one panel per browser state:
       `:unsupported` (old browser, no Notification API),
       `:not_installed` (mobile without PWA install),
       `:denied` (permission revoked),
       `:default` (capable but not yet prompted — shows the
       `#notifications-enable` button),
       `:granted` (permission OK + nested iOS edge-case branch),
       `:loading` (placeholder while the hook's first push lands).
       Each variant has a stable border/text palette (amber for
       soft warnings, rose for hard blocks, emerald for success,
       zinc for neutral) so users can read the urgency at a glance.

    3. **Nested iOS edge case** (only inside `:granted`) — when
       the user has permission AND has a push subscription on the
       server BUT is currently viewing the site from a non-installed
       mobile tab, `new Notification(...)` silently no-ops in the
       non-installed tab (only the home-screen PWA fires OS banners).
       Surface that with an amber-50 inset so the user understands
       why banners arrive on their home-screen icon but not in Safari.

  Was the inline `<div id="notifications-permission">` block in
  `notifications_live.html.heex` (formerly lines 46-146, ~100
  lines). Extracted so each of the six variants — plus the nested
  iOS edge case — gets its own render-only test surface and the
  `#notifications-enable` button id, the wrapper's `phx-hook`
  attribute, and the nested `:granted + mobile + not_installed`
  branch stop being invisible at a glance.
  """

  use DtuAppWeb, :html

  attr :state, :map,
    required: true,
    doc: """
    The current browser permission + display-mode state, pushed
    from the `NotificationPermission` JS hook. Reads three keys:

      * `"state"` — one of `"unsupported"`, `"not_installed"`,
        `"denied"`, `"default"`, `"granted"`, or `nil`/missing
        (renders the loading placeholder).
      * `"device"` — `"mobile"` or `"desktop"`. Gates the
        desktop-vs-mobile copy in the `:default` and `:granted`
        branches.
      * `"installed"` — boolean. Only consulted in the `:granted`
        branch to detect the iOS edge case (granted + mobile +
        not-installed = user is viewing in Safari tab, not the
        home-screen PWA).
    """

  attr :has_push_subscriptions, :boolean,
    default: false,
    doc: """
    Whether the user has at least one persisted `push_subscriptions`
    row. Gates the inner `if/else` inside the `:granted` branch:
    granted + no-subscriptions shows a "keep tab open" hint on
    desktop; granted + subscriptions + the iOS edge case shows the
    amber inset.
    """

  attr :user_id, :integer,
    required: true,
    doc: """
    The current user's id, rendered as `data-user-id` on the
    wrapper div. The JS hook reads it to namespace
    `localStorage` keys.
    """

  def notification_capability_card(assigns) do
    ~H"""
    <div
      id="notifications-permission"
      phx-hook="NotificationPermission"
      data-user-id={@user_id}
    >
      <%= case Map.get(@state, "state") do %>
        <% "unsupported" -> %>
          <div class="rounded-lg border border-amber-300 bg-amber-50 dark:border-amber-700 dark:bg-amber-950/40 p-4 text-sm text-amber-800 dark:text-amber-200">
            {gettext(
              "Browsers must be installed as a PWA to deliver notifications. Add this site to your home screen / applications folder and reopen it from there."
            )}
          </div>
        <% "not_installed" -> %>
          <div class="rounded-lg border border-amber-300 bg-amber-50 dark:border-amber-700 dark:bg-amber-950/40 p-4 text-sm text-amber-800 dark:text-amber-200">
            {gettext(
              "Install this site as a PWA first (browser menu → Add to Home Screen / Install App). Once installed, the Enable button below will request notification permission. PWA install is required on mobile devices; desktop browsers can enable notifications below without installing."
            )}
          </div>
        <% "denied" -> %>
          <div class="rounded-lg border border-rose-300 bg-rose-50 dark:border-rose-700 dark:bg-rose-950/40 p-4 text-sm text-rose-800 dark:text-rose-200">
            {gettext(
              "Notifications are blocked in your browser settings. Open your browser's site settings and allow notifications for this PWA, then reload this page."
            )}
          </div>
        <% "default" -> %>
          <div class="rounded-lg border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-800 p-4 text-sm text-zinc-700 dark:text-zinc-200">
            <p class="font-medium">
              {gettext("Notifications are available, but not yet enabled.")}
            </p>
            <p class="mt-1">
              <%= if Map.get(@state, "device") == "desktop" do %>
                {gettext(
                  "Click the button below; your browser will ask whether to allow notifications for this site. Desktop browsers do not require a PWA install — you can install later for background (closed-tab) delivery if you want it."
                )}
              <% else %>
                {gettext(
                  "Click the button below; your browser will ask whether to allow notifications for this PWA."
                )}
              <% end %>
            </p>
            <button
              id="notifications-enable"
              type="button"
              class="mt-3 inline-flex items-center gap-2 rounded-lg bg-emerald-500 hover:bg-emerald-400 px-4 py-2 text-sm font-semibold text-zinc-950 transition"
            >
              <.icon name="hero-bell" class="h-4 w-4" />
              {gettext("Enable notifications")}
            </button>
          </div>
        <% "granted" -> %>
          <div class="rounded-lg border border-emerald-300 bg-emerald-50 dark:border-emerald-700 dark:bg-emerald-950/40 p-4 text-sm text-emerald-800 dark:text-emerald-200">
            {gettext("Notifications are enabled. Pick what you'd like to be notified about below.")}
            <%= if @has_push_subscriptions do %>
              <%!--
                iOS edge case: when the user grants permission from the
                home-screen PWA (which works), then opens the same site
                in a regular Safari tab, the permission state is still
                `granted` AND `has_push_subscriptions` is still true
                (the subscription row lives on the server, not the
                browser). But `new Notification(...)` silently no-ops
                in a non-installed tab — only the home-screen app fires
                OS notifications. Detect this combination and surface
                it so the user understands why banners arrive on their
                home-screen icon but not in Safari.
              --%>
              <%= if Map.get(@state, "device") == "mobile" and
                      Map.get(@state, "installed") == false do %>
                <p class="mt-2 rounded-md border border-amber-300 bg-amber-50 dark:border-amber-700 dark:bg-amber-950/40 p-2 text-xs text-amber-800 dark:text-amber-200">
                  {gettext(
                    "You're viewing this in a regular mobile browser tab, not the installed PWA. iOS only fires OS notifications from the home-screen app — open dtu.app from your home screen to receive banners here."
                  )}
                </p>
              <% else %>
                <p class="mt-2 text-xs text-emerald-700 dark:text-emerald-300">
                  {gettext(
                    "Native push is on for this device — you'll get a system notification even when this site isn't open."
                  )}
                </p>
              <% end %>
            <% else %>
              <%= if Map.get(@state, "device") == "desktop" do %>
                <p class="mt-2 text-xs text-emerald-700 dark:text-emerald-300">
                  {gettext(
                    "Keep this tab open to receive notifications. For background delivery when the tab is closed, install this site as a PWA."
                  )}
                </p>
              <% end %>
            <% end %>
          </div>
        <% _ -> %>
          <div class="rounded-lg border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-800 p-4 text-sm text-zinc-500 dark:text-zinc-400">
            {gettext("Checking browser capabilities…")}
          </div>
      <% end %>
    </div>
    """
  end
end
