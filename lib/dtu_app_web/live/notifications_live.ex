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

  This module owns the LiveView orchestration (mount, handle_*).
  The page template is colocated as
  `notifications_live.html.heex` (resolved automatically by
  Phoenix LiveView 1.2.5's `template_filename/1`). Pure helpers
  and stateless data loaders live under
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
end
