defmodule DtuAppWeb.NotificationsLive do
  @moduledoc """
  The `/notifications` page. Lets the user opt in/out of:

    * `:notify_dtu_connection` — a browser notification when a
      single inverter goes offline (and again when it comes back).
    * `:notify_sun_down` — a summary notification at end-of-day
      comparing today's yield + peak with yesterday's.

  The browser-side permission state (allowed / blocked / not
  installed as PWA / not supported) is computed by the JS hook
  `NotificationPermission` and pushed to the server so the
  template can render the right CTA per state.
  """
  use DtuAppWeb, :live_view

  alias DtuApp.Accounts
  alias DtuApp.Notifications

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

    {:ok,
     socket
     |> assign(:page_title, gettext("Notifications"))
     |> assign(:notification_state, %{"state" => "loading"})
     |> assign_form(Accounts.User.notification_settings_changeset(user, %{}))}
  end

  @impl true
  def handle_info({:notification, payload}, socket) do
    # Forward the server-computed payload to the JS hook. The hook
    # formats the title/body and dedups against localStorage.
    {:noreply, push_event(socket, "notify", payload)}
  end

  @impl true
  def handle_event("notification_state", params, socket) do
    # The hook on the page sends {"state": "...", "installed": true|false}
    # once on mount and whenever the display-mode or permission state
    # changes. We store it as the assign the template renders.
    {:noreply, assign(socket, :notification_state, params)}
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
          <% case Map.get(@notification_state, "state") do %>
            <% "unsupported" -> %>
              <div class="rounded-lg border border-amber-300 bg-amber-50 dark:border-amber-700 dark:bg-amber-950/40 p-4 text-sm text-amber-800 dark:text-amber-200">
                {gettext(
                  "Browsers must be installed as a PWA to deliver notifications. Add this site to your home screen / applications folder and reopen it from there."
                )}
              </div>
            <% "not_installed" -> %>
              <div class="rounded-lg border border-amber-300 bg-amber-50 dark:border-amber-700 dark:bg-amber-950/40 p-4 text-sm text-amber-800 dark:text-amber-200">
                {gettext(
                  "Install this site as a PWA first (browser menu → Add to Home Screen / Install App). Once installed, the Enable button below will request notification permission."
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
                  {gettext(
                    "Click the button below; your browser will ask whether to allow notifications for this PWA."
                  )}
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

          <div class="flex justify-end">
            <.button
              class="inline-flex items-center gap-2 rounded-lg bg-emerald-500 hover:bg-emerald-400 px-4 py-2 text-sm font-semibold text-zinc-950 transition"
              phx-disable-with={gettext("Saving…")}
            >
              {gettext("Save preferences")}
            </.button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
