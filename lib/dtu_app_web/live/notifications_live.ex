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
end
