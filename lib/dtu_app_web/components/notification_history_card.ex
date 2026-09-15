defmodule DtuAppWeb.NotificationHistoryCard do
  @moduledoc """
  The notification history panel on the `/notifications` page.

  Bundles four layers:

    1. **Card chrome** — the `<div id="notification-history"
       class="rounded-xl ... p-6 space-y-4">` wrapper. Renders the
       heading + the conditional "Clear all" button. The Clear-all
       button is hidden when `@total == 0` (no point clearing an
       empty list).

    2. **Event filter chip row** — one chip per filter value, plus
       a "highlighted" state for the active filter (driven by
       `aria-pressed="true"` rather than a class swap — the
       visual state machine lives entirely on the
       `aria-pressed` attribute, so the active chip is
       distinguishable both visually and to assistive tech).

    3. **Empty state** — shown when `@total == 0`. The copy
       branches on `@event_filter == "all"` (no notifications
       ever) vs any other value (no notifications in this
       filter yet). The two branches steer the user to
       different actions (wait for an event vs pick a
       different filter / send a test).

    4. **Notification list + per-row + pagination** — when
       `@total > 0`, renders a `<ul role="list">` of rows.
       Each row carries `id="notification-row-<n.id>"` so
       live updates can target it; the per-row markup is
       inline (it's only ~30 lines and only used here, so
       extracting a `NotificationHistoryRow` would be a
       single-caller abstraction). The pagination bar at the
       bottom shows Previous / Page N of M / Next, hidden
       when `@total_pages <= 1`.

  Was the inline `<div id="notification-history">` block in
  `notifications_live.html.heex` (formerly lines 324-460,
  ~136 lines). Extracted so the empty-state branch
  (all vs filtered), the chip-row `aria-pressed`
  state machine, the Clear-all visibility gate, and the
  pagination disabled-state wiring each get their own
  render-only test surface — all four are invisible at a
  glance and easy to regress.
  """

  use DtuAppWeb, :html

  attr :items, :list,
    default: [],
    doc: """
    The current page of notification history rows. Each row
    is a map (or struct) with at least the keys `id`,
    `event`, `title`, `body`, `delivered_label`. The LV
    formats `delivered_label` (via
    `DtuAppWeb.NotificationsLive.FormatHelpers.format_relative_time/1`,
    which depends on the DB-backed `DtuApp.Time.utc_now/0`)
    before handing the item to the component — keeping the
    component pure so it can be exercised by sandbox-free
    render-only tests.
    """

  attr :total, :integer,
    required: true,
    doc: """
    Total number of notifications the user has (across all
    pages and all filters). Drives the empty-state branch
    AND the Clear-all button's visibility (hidden when 0).
    """

  attr :total_pages, :integer,
    required: true,
    doc: """
    Total number of history pages. The pagination bar is
    hidden when `<= 1` and the Next button is disabled
    when `@page >= @total_pages`.
    """

  attr :page, :integer,
    required: true,
    doc: """
    Current history page (1-indexed). The Previous button
    is disabled when `@page <= 1`; the pagination footer
    shows `Page N of M`.
    """

  attr :event_filter, :string,
    required: true,
    doc: """
    The active filter chip's value (one of the values in
    `:filters`, or `"all"`). Drives:

      * The chip row's `aria-pressed` highlight (one chip
        matches; the rest carry `aria-pressed="false"`).
      * The empty state's copy branch (different text
        for `event_filter == "all"` vs any other value).
    """

  attr :filters, :list,
    required: true,
    doc: """
    The full chip-row source list, as a list of
    `{value, label}` tuples. Built by the LV from
    `DtuAppWeb.NotificationsLive.FilterHelpers.filter_label/1`
    + the canonical `@event_filters` module attribute so a
    new event type ships in one LV-level edit. Keeping the
    component filter-agnostic (vs. importing `FilterHelpers`
    directly) means the component has no coupling to the
    notification-specific helper module.
    """

  def notification_history_card(assigns) do
    ~H"""
    <div
      id="notification-history"
      class="rounded-xl border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-800 p-6 space-y-4"
    >
      <div class="flex items-center justify-between gap-3">
        <h2 class="text-lg font-semibold text-zinc-900 dark:text-white">
          {gettext("Recent notifications")}
        </h2>
        <%= if @total > 0 do %>
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

      <div
        id="notification-history-filters"
        role="group"
        aria-label={gettext("Filter notifications by event")}
        class="flex flex-wrap gap-2"
      >
        <%= for {value, label} <- @filters do %>
          <button
            type="button"
            phx-click="filter_history"
            phx-value-event={value}
            aria-pressed={to_string(@event_filter == value)}
            data-event-filter={value}
            class={[
              "rounded-full px-3 py-1 text-xs font-medium transition",
              @event_filter == value &&
                "bg-emerald-500 text-zinc-950 hover:bg-emerald-400",
              @event_filter != value &&
                "bg-zinc-100 text-zinc-700 hover:bg-zinc-200 dark:bg-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-600"
            ]}
          >
            {label}
          </button>
        <% end %>
      </div>

      <%= if @total == 0 do %>
        <p class="text-sm text-zinc-500 dark:text-zinc-400">
          <%= if @event_filter == "all" do %>
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
          <%= for n <- @items do %>
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
                    {n.delivered_label}
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

        <%= if @total_pages > 1 do %>
          <div class="flex items-center justify-between border-t border-zinc-100 dark:border-zinc-700 pt-3 text-sm">
            <button
              type="button"
              phx-click="set_history_page"
              phx-value-page={@page - 1}
              disabled={@page <= 1}
              class="inline-flex items-center gap-1 rounded-md px-2 py-1 text-zinc-600 hover:bg-zinc-100 disabled:opacity-40 disabled:cursor-not-allowed dark:text-zinc-300 dark:hover:bg-zinc-700 transition"
            >
              <.icon name="hero-chevron-left" class="h-4 w-4" />
              {gettext("Previous")}
            </button>
            <span class="text-xs text-zinc-500 dark:text-zinc-400">
              {gettext("Page %{page} of %{total}",
                page: @page,
                total: @total_pages
              )}
            </span>
            <button
              type="button"
              phx-click="set_history_page"
              phx-value-page={@page + 1}
              disabled={@page >= @total_pages}
              class="inline-flex items-center gap-1 rounded-md px-2 py-1 text-zinc-600 hover:bg-zinc-100 disabled:opacity-40 disabled:cursor-not-allowed dark:text-zinc-300 dark:hover:bg-zinc-700 transition"
            >
              {gettext("Next")}
              <.icon name="hero-chevron-right" class="h-4 w-4" />
            </button>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end
end
