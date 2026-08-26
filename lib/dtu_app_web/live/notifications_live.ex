defmodule DtuAppWeb.NotificationsLive do
  @moduledoc """
  The `/notifications` page. Lets the user opt in/out of:

    * `:notify_dtu_connection` — a browser notification when a
      single inverter goes offline (and again when it comes back).
    * `:notify_sun_down` — a summary notification at end-of-day
      comparing today's yield + peak with yesterday's.
    * `:notify_sun_up` — a single morning ping when the fleet first
      produces power for the day (once per user per local day).

  The browser-side permission state (allowed / blocked / not
  installed as PWA / not supported) is computed by the JS hook
  `NotificationPermission` and pushed to the server so the
  template can render the right CTA per state.
  """
  use DtuAppWeb, :live_view

  alias DtuApp.Accounts
  alias DtuApp.Notifications
  alias DtuApp.PushSubscriptions
  alias DtuApp.Time

  require Logger

  @history_page_size 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to the per-user notification topic so the LiveView
      # receives events fired by `DtuApp.Notifications.broadcast/2`.
      # The hook on the page is the actual consumer — it creates the
      # `new Notification(...)` after dedup against localStorage.
      user = socket.assigns.current_scope.user
      Notifications.subscribe(user.id)
    end

    user = socket.assigns.current_scope.user
    has_subscriptions = PushSubscriptions.list_for_user(user) != []

    {:ok,
     socket
     |> assign(:page_title, gettext("Notifications"))
     # The JS hook on `#notifications-permission` overrides this
     # `loading` placeholder on mount with one of
     # `granted` / `denied` / `default` / `unsupported` /
     # `not_installed`. The `device` field is added in the same
     # push so the template can render platform-specific copy
     # (e.g. "install as PWA" for mobile, plain Enable for
     # desktop). Defaulting to `nil` here keeps the catch-all
     # "Checking browser capabilities…" branch active until the
     # hook's first push lands.
     |> assign(:notification_state, %{"state" => "loading", "device" => nil})
     |> assign(:has_push_subscriptions, has_subscriptions)
     |> assign_history(user, 1)
     |> assign_form(Accounts.User.notification_settings_changeset(user, %{}))}
  end

  # Load the first page of the user's notification history into
  # `:history_items` / `:history_page` / `:history_total_pages`.
  # Called from mount/3 and after every mutation (delete, clear-all,
  # paginate) so the UI always reflects DB state without needing a
  # local cache that could drift.
  defp assign_history(socket, user, page) do
    total = Notifications.count_user_notifications(user)
    total_pages = max(1, div(total + @history_page_size - 1, @history_page_size))
    page = min(max(1, page), total_pages)
    items = Notifications.list_user_notifications(user, page, @history_page_size)

    socket
    |> assign(:history_items, items)
    |> assign(:history_page, page)
    |> assign(:history_total_pages, total_pages)
    |> assign(:history_total, total)
  end

  @impl true
  def handle_info({:notification, payload}, socket) do
    # Forward the server-computed payload to the JS hook. The hook
    # formats the title/body and dedups against localStorage.
    #
    # The history list refreshes on the same event so a fresh
    # broadcast shows up at the top of page 1 immediately. If the
    # user is currently on a non-first page, we keep them there and
    # just refresh that page's contents — pagination state survives
    # a new event without snapping the user back to page 1.
    socket =
      socket
      |> push_event("notify", payload)
      |> assign_history(socket.assigns.current_scope.user, socket.assigns.history_page)

    {:noreply, socket}
  end

  def handle_event("set_history_page", %{"page" => page}, socket) do
    user = socket.assigns.current_scope.user
    page = page |> to_string() |> String.to_integer()

    {:noreply, assign_history(socket, user, page)}
  end

  def handle_event("delete_notification", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    id = id |> to_string() |> String.to_integer()

    _ = Notifications.delete(user, id)

    # After deleting, the current page may now be empty. Stay on
    # the same page index; `assign_history/3` clamps it back into
    # range so we never render a phantom page.
    {:noreply, assign_history(socket, user, socket.assigns.history_page)}
  end

  def handle_event("clear_all_notifications", _payload, socket) do
    user = socket.assigns.current_scope.user
    _ = Notifications.clear_all(user)

    socket =
      socket
      |> assign_history(user, 1)
      |> put_flash(:info, gettext("Notification history cleared."))

    {:noreply, socket}
  end

  def handle_event("notification_state", params, socket) do
    # The hook on the page sends {"state": "...", "installed": true|false}
    # once on mount and whenever the display-mode or permission state
    # changes. We store it as the assign the template renders.
    #
    # The debug-level log is the breadcrumb for the
    # "stuck on 'Checking browser capabilities…'" bug: if the page is
    # stuck, the absence of this line in the prod logs means the push
    # never reached the server (hook didn't run, `view.isConnected()`
    # rejected the push, or the SW served a stale bundle without the
    # hook). Its presence tells us the round-trip landed and the
    # problem is on the client.
    Logger.debug("notifications: state pushed #{inspect(params)}")

    {:noreply, assign(socket, :notification_state, params)}
  end

  # The `PushSubscribe` JS hook sends this once `/push/subscribe`
  # has returned 200. We only render the "Native push is enabled"
  # badge after this fires — *before* it, the browser may have
  # permission but no service-worker subscription (e.g. iOS Safari
  # ≥ 16.4 granted permission but `PushManager` is undefined), and
  # we don't want to claim native push is on when it isn't.
  @impl true
  def handle_event("push_subscribed", %{"endpoint" => _endpoint}, socket) do
    {:noreply, assign(socket, :has_push_subscriptions, true)}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.update_notification_settings(user, user_params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Notification settings saved."))
         |> assign_form(Accounts.User.notification_settings_changeset(user, %{}))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  @impl true
  def handle_event("test_notification", _payload, socket) do
    # Fire a synthetic notification to the user's own notifications topic
    # so the JS hook (already subscribed in mount/3) can render it via
    # `new Notification(...)`. Bypasses the DTU-state and opt-in checks
    # so a user who just enabled notifications can verify their setup
    # works without waiting for an inverter to actually go offline.
    user = socket.assigns.current_scope.user

    Notifications.broadcast(user.id, %{
      event: "test",
      title: gettext("Test notification"),
      body: gettext("If you can read this, browser notifications are working."),
      tag: "test"
    })

    {:noreply, put_flash(socket, :info, gettext("Test notification sent."))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: :user))
  end

  # The notifications page template is inlined here (rather than in a
  # colocated `index.html.heex`) because Phoenix LiveView 1.2.5's
  # `template_filename/1` looks for `<module_name>.html.heex` based
  # on the underscored module name — for `DtuAppWeb.NotificationsLive`
  # that's `notifications_live.html.heex`, not `index.html.heex`. A
  # directory-style LiveView (e.g. `live/notifications_live/...`) with
  # no `render/1` would crash on the static render path with
  # `Path.dirname(nil)`. Inlining the template here is the same
  # pattern the dashboard uses (see `def render/1` in
  # `dashboard_live.ex`).
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <%!--
        Notifications-firing hook. Mounted here (and on the dashboard)
        so the user can configure their preferences and the JS hook is in
        scope to fire `new Notification(...)` on `notify` events. The hook
        is invisible (`hidden`) and only acts as a `phx:notify` event
        sink. The server pushes events via `DtuApp.Notifications.broadcast/2`.
      --%>
      <div
        id="notifications-firing"
        phx-hook="Notifications"
        data-user-id={@current_scope.user.id}
        hidden
      >
      </div>
      <%!--
        Push subscription hook. Owns the PushManager lifecycle
        (subscribe on grant, persist endpoint to the server). The
        `NotificationPermission` hook on the panel above dispatches a
        `push:enable` event on grant, which triggers this hook's
        auto-subscribe. `data-push="auto"` makes the hook also
        auto-subscribe on next visit for users who have already
        granted permission in a prior session — see
        `assets/js/push_subscribe.js`.
      --%>
      <div
        id="push-subscribe"
        phx-hook="PushSubscribe"
        data-user-id={@current_scope.user.id}
        data-push="auto"
        hidden
      >
      </div>
      <div class="mx-auto max-w-2xl space-y-6 py-8" id="notifications-page">
        <div>
          <h1 class="text-3xl font-extrabold tracking-tight text-zinc-900 dark:text-white">
            {gettext("Notifications")}
          </h1>
          <p class="mt-2 text-sm text-zinc-500 dark:text-zinc-400">
            {gettext(
              "Receive alerts in your browser when your inverters change state or the day's production wraps up. Notifications only fire when this site is installed as a PWA."
            )}
          </p>
        </div>

        <%!-- The JS hook on this container reports the browser's
             notification capability and permission state to the server
             (the `notification_state` assigns) so we can render the
             right CTA. --%>
        <div
          id="notifications-permission"
          phx-hook="NotificationPermission"
          data-user-id={@current_scope.user.id}
        >
          <%= case Map.get(@notification_state, "state") do %>
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
                  <%= if Map.get(@notification_state, "device") == "desktop" do %>
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
                {gettext(
                  "Notifications are enabled. Pick what you'd like to be notified about below."
                )}
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
                  <%= if Map.get(@notification_state, "device") == "mobile" and
                          Map.get(@notification_state, "installed") == false do %>
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
                  <%= if Map.get(@notification_state, "device") == "desktop" do %>
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

        <%!-- The form is always rendered. The fields are persisted to
             the user record regardless of permission state, so the
             user's preferences are saved even before they enable
             notifications. --%>
        <.form
          for={@form}
          phx-submit="save"
          id="notifications-form"
          class="space-y-4 rounded-xl border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-800 p-6"
        >
          <h2 class="text-lg font-semibold text-zinc-900 dark:text-white">
            {gettext("What to notify about")}
          </h2>

          <label class="flex items-start gap-3 cursor-pointer">
            <.input
              type="checkbox"
              field={@form[:notify_dtu_connection]}
              class="mt-1"
            />
            <span>
              <span class="block text-sm font-medium text-zinc-900 dark:text-white">
                {gettext("Inverter connection state")}
              </span>
              <span class="block text-sm text-zinc-500 dark:text-zinc-400">
                {gettext(
                  "A notification whenever an inverter goes offline or comes back online. The notification names the inverter."
                )}
              </span>
            </span>
          </label>

          <label class="flex items-start gap-3 cursor-pointer">
            <.input
              type="checkbox"
              field={@form[:notify_sun_down]}
              class="mt-1"
            />
            <span>
              <span class="block text-sm font-medium text-zinc-900 dark:text-white">
                {gettext("End-of-day summary")}
              </span>
              <span class="block text-sm text-zinc-500 dark:text-zinc-400">
                {gettext(
                  "When the sun goes down, get today's total yield compared to yesterday and the peak power from today compared to yesterday, if yesterday's data is available."
                )}
              </span>
            </span>
          </label>

          <label class="flex items-start gap-3 cursor-pointer">
            <.input
              type="checkbox"
              field={@form[:notify_sun_up]}
              class="mt-1"
            />
            <span>
              <span class="block text-sm font-medium text-zinc-900 dark:text-white">
                {gettext("Morning sun-up ping")}
              </span>
              <span class="block text-sm text-zinc-500 dark:text-zinc-400">
                {gettext(
                  "A cheerful one-off when your panels start producing for the day. Fires once per day, in your local timezone, the moment your fleet wakes up."
                )}
              </span>
            </span>
          </label>

          <div class="flex justify-end">
            <.button
              class="inline-flex items-center gap-2 rounded-lg bg-emerald-500 hover:bg-emerald-400 px-4 py-2 text-sm font-semibold text-zinc-950 transition"
              phx-disable-with={gettext("Saving…")}
            >
              {gettext("Save preferences")}
            </.button>
          </div>
        </.form>

        <!-- Test notification: only show when the browser has actually
             granted permission, so the click is guaranteed to fire a real
             system notification (rather than silently failing). -->
        <%= if Map.get(@notification_state, "state") == "granted" do %>
          <div class="rounded-xl border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-800 p-6 space-y-2">
            <h2 class="text-lg font-semibold text-zinc-900 dark:text-white">
              {gettext("Test notification")}
            </h2>
            <p class="text-sm text-zinc-500 dark:text-zinc-400">
              {gettext(
                "Send a one-off test notification to verify the browser is set up correctly. It should appear within a second or two."
              )}
            </p>
            <button
              id="btn-test-notification"
              type="button"
              phx-click="test_notification"
              class="inline-flex items-center gap-2 rounded-lg bg-zinc-900 hover:bg-zinc-700 dark:bg-zinc-100 dark:hover:bg-zinc-300 px-4 py-2 text-sm font-semibold text-white dark:text-zinc-950 transition"
            >
              <.icon name="hero-bell-alert" class="h-4 w-4" />
              {gettext("Send test notification")}
            </button>
          </div>
        <% end %>

        <%!--
          Notification history. Persisted by `DtuApp.Notifications.broadcast/2`
          so the user can review every notification the server sent — sun-up,
          sun-down, dtu_connection, and the synthetic test events fired from
          the button above. Renders newest-first with 50 items per page; live
          updates refresh in place when the page is open and a new broadcast
          arrives (handled in `handle_info({:notification, ...})`).
        --%>
        <div
          id="notification-history"
          class="rounded-xl border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-800 p-6 space-y-4"
        >
          <div class="flex items-center justify-between gap-3">
            <h2 class="text-lg font-semibold text-zinc-900 dark:text-white">
              {gettext("Recent notifications")}
            </h2>
            <%= if @history_total > 0 do %>
              <button
                type="button"
                phx-click="clear_all_notifications"
                data-confirm={gettext("Clear all notifications? This cannot be undone.")}
                class="text-xs font-medium text-rose-600 hover:text-rose-500 dark:text-rose-400 dark:hover:text-rose-300 transition"
              >
                {gettext("Clear all")}
              </button>
            <% end %>
          </div>

          <%= if @history_total == 0 do %>
            <p class="text-sm text-zinc-500 dark:text-zinc-400">
              {gettext(
                "No notifications yet. The list updates automatically the next time your devices trigger an event or you send a test notification above."
              )}
            </p>
          <% else %>
            <ul role="list" class="divide-y divide-zinc-100 dark:divide-zinc-700">
              <%= for n <- @history_items do %>
                <li
                  id={"notification-row-#{n.id}"}
                  class="flex items-start gap-3 py-3"
                >
                  <div class="min-w-0 flex-1">
                    <div class="flex items-center gap-2">
                      <span class="truncate text-sm font-semibold text-zinc-900 dark:text-white">
                        {n.title}
                      </span>
                      <span class="shrink-0 rounded-full bg-zinc-100 dark:bg-zinc-700 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-zinc-600 dark:text-zinc-300">
                        {n.event}
                      </span>
                      <span class="shrink-0 text-xs text-zinc-500 dark:text-zinc-400">
                        {format_relative_time(n.delivered_at)}
                      </span>
                    </div>
                    <p class="mt-1 text-sm text-zinc-600 dark:text-zinc-300 break-words">
                      {n.body}
                    </p>
                  </div>
                  <button
                    type="button"
                    phx-click="delete_notification"
                    phx-value-id={n.id}
                    aria-label={gettext("Delete notification")}
                    title={gettext("Delete notification")}
                    class="shrink-0 rounded-md p-1.5 text-zinc-400 hover:bg-zinc-100 hover:text-rose-500 dark:hover:bg-zinc-700 dark:hover:text-rose-400 transition"
                  >
                    <.icon name="hero-x-mark" class="h-4 w-4" />
                  </button>
                </li>
              <% end %>
            </ul>

            <%= if @history_total_pages > 1 do %>
              <div class="flex items-center justify-between border-t border-zinc-100 dark:border-zinc-700 pt-3 text-sm">
                <button
                  type="button"
                  phx-click="set_history_page"
                  phx-value-page={@history_page - 1}
                  disabled={@history_page <= 1}
                  class="inline-flex items-center gap-1 rounded-md px-2 py-1 text-zinc-600 hover:bg-zinc-100 disabled:opacity-40 disabled:cursor-not-allowed dark:text-zinc-300 dark:hover:bg-zinc-700 transition"
                >
                  <.icon name="hero-chevron-left" class="h-4 w-4" />
                  {gettext("Previous")}
                </button>
                <span class="text-xs text-zinc-500 dark:text-zinc-400">
                  {gettext("Page %{page} of %{total}",
                    page: @history_page,
                    total: @history_total_pages
                  )}
                </span>
                <button
                  type="button"
                  phx-click="set_history_page"
                  phx-value-page={@history_page + 1}
                  disabled={@history_page >= @history_total_pages}
                  class="inline-flex items-center gap-1 rounded-md px-2 py-1 text-zinc-600 hover:bg-zinc-100 disabled:opacity-40 disabled:cursor-not-allowed dark:text-zinc-300 dark:hover:bg-zinc-700 transition"
                >
                  {gettext("Next")}
                  <.icon name="hero-chevron-right" class="h-4 w-4" />
                </button>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Human-readable "X ago" label for a notification's `delivered_at`.
  # Mirrors `DtuAppWeb.DeviceLive.Details.format_relative_time/1` so the
  # history page reads consistently with the device-details "last
  # seen" column. Future-dated rows (clock skew between DB and a
  # user's browser) are clamped to "just now" rather than rendering
  # negative values.
  @spec format_relative_time(DateTime.t()) :: String.t()
  defp format_relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(Time.utc_now(), dt, :second) |> max(0)

    cond do
      diff < 60 -> gettext("just now")
      diff < 3600 -> gettext("%{n} minutes ago", n: div(diff, 60))
      diff < 86_400 -> gettext("%{n} hours ago", n: div(diff, 3600))
      true -> gettext("%{n} days ago", n: div(diff, 86_400))
    end
  end
end
