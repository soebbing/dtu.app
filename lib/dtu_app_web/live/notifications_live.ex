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

  # Function-component imports. The three extracted components
  # used to live as inline blocks in `notifications_live.html.heex`;
  # they're now standalone modules under
  # `DtuAppWeb.Components.*` so each block (capability card,
  # preferences form, history card) gets its own render-only
  # test surface.
  import DtuAppWeb.NotificationCapabilityCard, only: [notification_capability_card: 1]
  import DtuAppWeb.NotificationHistoryCard, only: [notification_history_card: 1]
  import DtuAppWeb.NotificationPreferencesForm, only: [notification_preferences_form: 1]
  import DtuAppWeb.NotificationRegenerateCard, only: [notification_regenerate_card: 1]

  # The Regenerate-summary card and its handler should both honour
  # the *user's* "today" — the same one the dispatcher's normal
  # sun_down fire uses via `DtuAppWeb.DashboardLive.TimeHelpers`.
  # Anchoring on `Date.utc_today()` produced two bugs:
  #   1. The form's `min=`/`max=` attributes greyed out the wrong
  #      day for any user not on UTC (so a CEST user at 23:00 local
  #      lost the ability to pick "yesterday" through the picker).
  #   2. The handler's `today` baseline mismatched the dispatcher's,
  #      so a user on a positive offset who picked a calendar day
  #      that *was* a valid local yesterday got a bogus "past dates
  #      only" flash.
  # The shared `local_today/1` helper unifies all three sites.
  import DtuAppWeb.DashboardLive.TimeHelpers, only: [local_today: 1]

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

    # Server-side signal: did the dispatcher recently soft-delete
    # one of this user's push subscriptions (FCM/APNS returned 404/410)?
    # The capability card uses this to surface a "your browser cleared
    # its push subscription" prompt when permission is still `granted`
    # but no live row exists. Refreshed on `push_subscribed` so the
    # prompt disappears the moment the user re-subscribes.
    recently_revoked = PushSubscriptions.revoked_within_days?(user, 7)

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
     |> assign(:recently_revoked_subscription, recently_revoked)
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
     # `:history_filters` is the chip-row source list, pre-built
     # as `{value, label}` tuples so the history-card component
     # doesn't need to call `FilterHelpers.filter_label/1`
     # itself. Building it once at mount (vs. recomputing on
     # every render) also keeps the chip-row stable across
     # URL-driven `handle_params/3` reloads — only the active
     # filter chip's `aria-pressed` flips, never the source
     # list itself.
     |> assign(:history_filters, Enum.map(@event_filters, &{&1, FilterHelpers.filter_label(&1)}))
     # The Regenerate-summary card's date input `min=` / `max=`
     # bounds — same [today-30, today-1] window the server enforces.
     # Anchored at the *user's* local "today" (via `tz_offset_seconds`)
     # so the picker matches the dispatcher's local-day convention;
     # a UTC-anchored value would grey out the wrong day for any
     # non-UTC user near the midnight boundary. Re-anchored at mount
     # only — a long-lived socket that crosses midnight would let
     # the user pick a date that's "now the future" until reload;
     # the server-side handler still rejects those, so the
     # staleness is a UX hint, not a correctness bug.
     |> assign(:regenerate_min_date, Date.add(local_today(user.tz_offset_seconds || 0), -30))
     |> assign(:regenerate_max_date, Date.add(local_today(user.tz_offset_seconds || 0), -1))
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

    # `delivered_label` is the pre-formatted relative-time string
    # the history card renders next to each row's event chip.
    # We format here (not inside the component) because
    # `FormatHelpers.format_relative_time/1` bottoms out in the
    # DB-backed `DtuApp.Time.utc_now/0` — pushing the call to
    # the LV keeps the card sandbox-free so its tests can be
    # `async: true` render-only.
    items =
      Enum.map(
        items,
        &Map.put(&1, :delivered_label, FormatHelpers.format_relative_time(&1.delivered_at))
      )

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
  #
  # Recomputes `recently_revoked_subscription` too: `upsert/2` clears
  # `deleted_at` on the re-activated endpoint, so the prompt should
  # stop firing on this same render.
  @impl true
  def handle_event("push_subscribed", %{"endpoint" => _endpoint}, socket) do
    user = socket.assigns.current_scope.user

    {:noreply,
     socket
     |> assign(:has_push_subscriptions, true)
     |> assign(:recently_revoked_subscription, PushSubscriptions.revoked_within_days?(user, 7))}
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

  # User-initiated re-fire of a previously-missed daily `sun_down`
  # summary. Triggered by the "Regenerate summary" form on
  # `/notifications` (rendered via the
  # `DtuAppWeb.NotificationRegenerateCard` component). The
  # designer-side rationale lives in
  # `docs/debug/2026-09-16-sun-down-silent-skip.md` (Bug 3
  # conclusion): producer-side retro-fire was rejected as too
  # brittle, so the user can ask the dispatcher to compute the
  # payload for any past date in the last 30 days.
  #
  # Why no `sun_down_fires` dedup row? Only
  # `DtuApp.Notifications.SunDown.try_fire/1` writes that table;
  # `Notifications.broadcast/2` doesn't, so a regenerate doesn't
  # suppress the producer's *next* normal fire if the date happens
  # to overlap. The `tag` carries the user-chosen date so the JS
  # hook's localStorage dedup also stays correct per-date.
  #
  # Cooldown: 30 s in-process (a single-user-per-socket handler
  # doesn't need an external rate limiter — the assign guards the
  # only vector, a stuck double-click). Tests cover the cooldown
  # at `notifications_live_test.exs`.
  @regenerate_cooldown_ms 30_000

  @impl true
  def handle_event(
        "regenerate_sun_down",
        %{"date" => date_str},
        socket
      ) do
    user = socket.assigns.current_scope.user
    # Must use the user's local "today", not `Date.utc_today()` —
    # the same day the dispatcher uses for `sun_down_fires` and the
    # date-bucketing inside `build_payload/3`. A UTC-anchored
    # baseline here would mismatch the dispatcher's notion of
    # "past today" for any user whose local day differs from UTC's,
    # which is most of them near the midnight boundary.
    today = local_today(user.tz_offset_seconds || 0)

    cond do
      not is_binary(date_str) or date_str == "" ->
        {:noreply, put_flash(socket, :error, gettext("Pick a date first."))}

      # Cooldown check: refuse a re-click within `30 s` of the last
      # regeneration. The timestamp is set on success and on every
      # attempt that produces a flash, so click-spam is bounded
      # even when the underlying build_payload is fast.
      cooldown_active?(socket) ->
        {:noreply, put_flash(socket, :error, cooldown_flash())}

      Date.from_iso8601(date_str) |> elem(0) != :ok ->
        {:noreply,
         socket
         |> assign(:last_regenerated_at, monotonic_ms())
         |> put_flash(:error, gettext("Couldn't parse that date. Use YYYY-MM-DD."))}

      true ->
        handle_regenerate(socket, user, today, date_str)
    end
  end

  # LiveView dispatches this when the form is submitted with a date
  # that passed syntactic + cooldown gates. Parses the date (already
  # `:ok` from the calling clause), enforces the [today-30, today-1]
  # window, calls `SunDown.Payload.build_payload/3` (already takes a
  # date — no producer changes), and either broadcasts or flashes
  # "no data". Records `:last_regenerated_at` on every terminal
  # branch so the next click respects the cooldown.
  defp handle_regenerate(socket, user, today, date_str) do
    {:ok, parsed_date} = Date.from_iso8601(date_str)
    now = monotonic_ms()

    cond do
      Date.compare(parsed_date, today) in [:gt, :eq] ->
        {:noreply,
         socket
         |> assign(:last_regenerated_at, now)
         |> put_flash(
           :error,
           gettext("Pick past dates only — today's summary will fire on its own.")
         )}

      Date.compare(parsed_date, Date.add(today, -30)) == :lt ->
        {:noreply,
         socket
         |> assign(:last_regenerated_at, now)
         |> put_flash(
           :error,
           gettext(
             "Pick a date within the last 30 days — earlier days no longer have their reading cache in memory."
           )
         )}

      true ->
        tz_offset = user.tz_offset_seconds || 0

        case DtuApp.Notifications.SunDown.Payload.build_payload(user, parsed_date, tz_offset) do
          nil ->
            {:noreply,
             socket
             |> assign(:last_regenerated_at, now)
             |> put_flash(
               :info,
               gettext("No data for %{date} — your inverters didn't report anything that day.",
                 date: Date.to_iso8601(parsed_date)
               )
             )}

          payload ->
            _ = Notifications.broadcast(user.id, payload)

            {:noreply,
             socket
             |> assign(:last_regenerated_at, now)
             |> put_flash(
               :info,
               gettext("Summary for %{date} sent.", date: Date.to_iso8601(parsed_date))
             )}
        end
    end
  end

  defp cooldown_active?(socket) do
    case socket.assigns[:last_regenerated_at] do
      nil -> false
      last -> monotonic_ms() - last < @regenerate_cooldown_ms
    end
  end

  # `System.monotonic_time/0` is what GenServer timeouts use; the
  # 30 s window doesn't need wall-clock accuracy (a click spanning
  # a leap-second correction is acceptable).
  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp cooldown_flash do
    gettext("Please wait a few seconds before regenerating another summary.")
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: :user))
  end
end
