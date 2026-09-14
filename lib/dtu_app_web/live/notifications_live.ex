defmodule DtuAppWeb.NotificationsLive do
  @moduledoc """
  The `/notifications` page. Lets the user opt in/out of:

    * `:notify_dtu_connection` — a browser notification when a
      single inverter goes offline (and again when it comes back).
    * `:notify_sun_down` — a summary notification at end-of-day
      comparing today's yield + peak with yesterday's.
    * `:notify_sun_up` — a single morning ping when the fleet first
      produces power for the day (once per user per local day).
    * `:notify_yield_anomaly` — a single mid-day heads-up if the
      fleet stops producing for over 15 minutes while the sun is
      up.

  The browser-side permission state (allowed / blocked / not
  installed as PWA / not supported) is computed by the JS hook
  `NotificationPermission` and pushed to the server so the
  template can render the right CTA per state.

  ## Module layout

  This module owns the LiveView orchestration (mount, handle_*,
  render). Pure helpers and stateless data loaders live under
  `DtuAppWeb.NotificationsLive.*`:

    * `FilterHelpers` — URL param normalise, sentinel-to-nil
      translation, chip-row labels
    * `FormatHelpers` — `format_relative_time/1` for the history
      list
    * `History`       — page-clamping + list for the history
      section (the only DB call surface)
  """
  use DtuAppWeb, :live_view

  alias DtuApp.Accounts
  alias DtuApp.Notifications
  alias DtuApp.PushSubscriptions
  alias DtuAppWeb.NotificationsLive.FilterHelpers
  alias DtuAppWeb.NotificationsLive.FormatHelpers
  alias DtuAppWeb.NotificationsLive.History

  require Logger

  # The five event types that the `notifications.event` column can
  # hold. Drives both the filter-chip row and the "active filter"
  # highlight. Listed in display order: connection events are the
  # most-noisy on a multi-inverter install, so they're first.
  #
  # The list is also the canonical allow-list used by
  # `FilterHelpers.normalize_event_filter/1` — adding a new
  # event here is what unblocks the URL filter; the allow-list
  # clause lives in `FilterHelpers` next to the chip-row
  # rendering, so a new event ships in two edits.
  @event_filters [
    "all",
    "dtu_connection",
    "sun_down",
    "sun_up",
    "yield_anomaly",
    "test"
  ]

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

    # The event-filter URL param is read in `handle_params/3` (not
    # `mount/3`) so that `push_patch/2` from the chip-row handler
    # re-fires the read on every URL change — `mount/3` only runs
    # once per socket lifetime, which is too coarse for a filter
    # that's toggled repeatedly. The filter assign defaults to
    # "all" here so the first render before `handle_params/3`
    # returns a sensible value.
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
     # `:event_filters` is the chip-row's source of truth — the
     # list of values the template iterates to render one chip
     # each. Assigning it (rather than reading it from the module
     # attribute) lets the template access it via `@event_filters`
     # the same way it accesses every other assign. The
     # `:history_event_filter` assign below is the *active* filter;
     # the chip-row template compares each chip against it to set
     # `aria-pressed`.
     |> assign(:event_filters, @event_filters)
     |> assign(:history_event_filter, "all")
     |> assign_history(user, 1, "all")
     |> assign_form(Accounts.User.notification_settings_changeset(user, %{}))}
  end

  # Phoenix.LiveView dispatches `handle_params/3` on every URL
  # change (mount, `push_patch/2`, `push_navigate/2`) so the URL
  # remains the single source of truth for filter state. Without
  # this callback, `push_patch/2` from `filter_history` updates
  # the address bar but leaves the assign + history list on the
  # previous filter — `push_patch` would be a no-op for state, only
  # a URL-bar cosmetic change.
  @impl true
  def handle_params(params, _url, socket) do
    event_filter = FilterHelpers.normalize_event_filter(params["event"])
    user = socket.assigns.current_scope.user

    {:noreply,
     socket
     |> assign(:history_event_filter, event_filter)
     |> assign_history(user, 1, event_filter)}
  end

  # Load one page of the user's notification history into
  # `:history_items` / `:history_page` / `:history_total_pages` /
  # `:history_total`. Called from mount/3 and after every mutation
  # (delete, clear-all, paginate, new broadcast) so the UI always
  # reflects DB state without needing a local cache that could
  # drift. Page-clamping + total-pagination math lives in
  # `History.load/3`.
  defp assign_history(socket, user, page, event_filter) do
    {items, clamped_page, total_pages, total} =
      History.load(user, page, FilterHelpers.event_filter_to_query(event_filter))

    socket
    |> assign(:history_items, items)
    |> assign(:history_page, clamped_page)
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
      |> assign_history(
        socket.assigns.current_scope.user,
        socket.assigns.history_page,
        socket.assigns.history_event_filter
      )

    {:noreply, socket}
  end

  def handle_event("set_history_page", %{"page" => page}, socket) do
    user = socket.assigns.current_scope.user
    page = page |> to_string() |> String.to_integer()

    {:noreply, assign_history(socket, user, page, socket.assigns.history_event_filter)}
  end

  def handle_event("delete_notification", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    id = id |> to_string() |> String.to_integer()

    _ = Notifications.delete(user, id)

    # After deleting, the current page may now be empty. Stay on
    # the same page index; `assign_history/4` clamps it back into
    # range so we never render a phantom page.
    {:noreply,
     assign_history(
       socket,
       user,
       socket.assigns.history_page,
       socket.assigns.history_event_filter
     )}
  end

  def handle_event("clear_all_notifications", _payload, socket) do
    user = socket.assigns.current_scope.user
    _ = Notifications.clear_all(user)

    socket =
      socket
      |> assign_history(user, 1, socket.assigns.history_event_filter)
      |> put_flash(:info, gettext("Notification history cleared."))

    {:noreply, socket}
  end

  def handle_event("filter_history", %{"event" => value}, socket) do
    # `push_patch/2` updates the URL bar; Phoenix then dispatches
    # `handle_params/3` with the new params, which is what actually
    # reads the URL value back into the assign + history list.
    # We don't assign + reload here — the dispatch is the single
    # source of truth for URL-driven state, and doing the work in
    # both places would race on the assign.
    #
    # `value` is normalised inside `handle_params/3` so a forged
    # `phx-value-event` (no allow-list at the JS layer) still
    # falls back to "all" — see
    # `FilterHelpers.normalize_event_filter/1`.
    params =
      if FilterHelpers.normalize_event_filter(value) == "all",
        do: %{},
        else: %{"event" => value}

    {:noreply, push_patch(socket, to: ~p"/notifications?#{params}")}
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

          <label class="flex items-start gap-3 cursor-pointer">
            <.input
              type="checkbox"
              field={@form[:notify_yield_anomaly]}
              class="mt-1"
            />
            <span>
              <span class="block text-sm font-medium text-zinc-900 dark:text-white">
                {gettext("Mid-day yield collapse")}
              </span>
              <span class="block text-sm text-zinc-500 dark:text-zinc-400">
                {gettext(
                  "A heads-up if your fleet stops producing for over 15 minutes while the sun is up — even when no inverter reports an outage. Fires once per local day."
                )}
              </span>
            </span>
          </label>

          <div class="mt-6 border-t border-zinc-200 dark:border-zinc-700 pt-4">
            <h3 class="text-sm font-semibold text-zinc-900 dark:text-white">
              {gettext("Deliver via")}
            </h3>
            <p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
              {gettext(
                "Pick how you want to receive the notifications above. Email is a good fallback if native push is flaky on your device."
              )}
            </p>

            <div
              class="mt-3 inline-flex rounded-lg border border-zinc-200 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-900 p-1"
              role="radiogroup"
              aria-label={gettext("Deliver via")}
            >
              <%= for {value, label} <- [{"push", gettext("Notification")}, {"email", gettext("Email")}, {"both", gettext("Both")}] do %>
                <label class="cursor-pointer">
                  <input
                    type="radio"
                    name={@form[:notification_channel].name}
                    value={value}
                    checked={@form[:notification_channel].value == value}
                    class="peer sr-only"
                  />
                  <span class="block rounded-md px-3 py-1.5 text-sm font-medium text-zinc-600 dark:text-zinc-400 peer-checked:bg-white dark:peer-checked:bg-zinc-800 peer-checked:text-zinc-900 dark:peer-checked:text-white peer-checked:shadow-sm transition">
                    {label}
                  </span>
                </label>
              <% end %>
            </div>

            <%= if @form[:notification_channel].value in ["email", "both"] and
                  is_nil(@current_scope.user.confirmed_at) do %>
              <p class="mt-3 rounded-md border border-amber-300 bg-amber-50 dark:border-amber-700 dark:bg-amber-950/40 p-2 text-xs text-amber-800 dark:text-amber-200">
                {gettext(
                  "You picked email delivery, but your email address isn't confirmed. Visit account settings to confirm it, otherwise email notifications will be skipped."
                )}
              </p>
            <% end %>
          </div>

          <div class="flex justify-end">
            <.button
              class="inline-flex items-center gap-2 rounded-lg bg-emerald-500 hover:bg-emerald-400 px-4 py-2 text-sm font-semibold text-zinc-950 transition"
              phx-disable-with={gettext("Saving…")}
            >
              {gettext("Save preferences")}
            </.button>
          </div>
        </.form>

        <!-- Test notification: show whenever the user has at least one
             working delivery path. With browser permission granted, the
             click fires a real system notification. With email or
             "both" channel selected (regardless of browser permission),
             the click delivers a test email via the dispatcher's
             normal channel routing — so an email-only user can still
             verify their setup end-to-end without installing the PWA. -->
        <% notification_state_granted? = Map.get(@notification_state, "state") == "granted"
        email_capable? = @current_scope.user.notification_channel in ["email", "both"] %>
        <%= if notification_state_granted? or email_capable? do %>
          <div class="rounded-xl border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-800 p-6 space-y-2">
            <h2 class="text-lg font-semibold text-zinc-900 dark:text-white">
              {gettext("Test notification")}
            </h2>
            <p class="text-sm text-zinc-500 dark:text-zinc-400">
              {gettext(
                "Send a one-off test notification to verify your setup. It will appear in your browser if push is enabled, otherwise it will be delivered to your email address."
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

          <%!--
            Event filter chip row. One chip per known event type plus
            an "All" reset. Clicking a chip fires `filter_history` →
            `push_patch` so the URL carries `?event=...` (shareable /
            bookmarkable). The active chip is highlighted via the
            `aria-pressed` attribute the template picks up; using
            `aria-pressed` rather than plain `class="active"` keeps
            the visual state machine in one place (the attribute is
            set on the active chip, removed on the others).
          --%>
          <div
            id="notification-history-filters"
            role="group"
            aria-label={gettext("Filter notifications by event")}
            class="flex flex-wrap gap-2"
          >
            <%= for value <- @event_filters do %>
              <button
                type="button"
                phx-click="filter_history"
                phx-value-event={value}
                aria-pressed={to_string(@history_event_filter == value)}
                data-event-filter={value}
                class={[
                  "rounded-full px-3 py-1 text-xs font-medium transition",
                  @history_event_filter == value &&
                    "bg-emerald-500 text-zinc-950 hover:bg-emerald-400",
                  @history_event_filter != value &&
                    "bg-zinc-100 text-zinc-700 hover:bg-zinc-200 dark:bg-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-600"
                ]}
              >
                {FilterHelpers.filter_label(value)}
              </button>
            <% end %>
          </div>

          <%= if @history_total == 0 do %>
            <p class="text-sm text-zinc-500 dark:text-zinc-400">
              <%= if @history_event_filter == "all" do %>
                {gettext(
                  "No notifications yet. The list updates automatically the next time your devices trigger an event or you send a test notification above."
                )}
              <% else %>
                {gettext(
                  "No notifications in this filter yet. Pick a different event above or send a test notification to verify your setup."
                )}
              <% end %>
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
                        {FormatHelpers.format_relative_time(n.delivered_at)}
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
end
