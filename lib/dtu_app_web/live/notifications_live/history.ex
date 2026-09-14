defmodule DtuAppWeb.NotificationsLive.History do
  @moduledoc """
  Pure history-list helpers for the `/notifications` page.

  Wraps `DtuApp.Notifications.count_user_notifications/2` and
  `DtuApp.Notifications.list_user_notifications/4` with:

    * page-clamping (the requested page is pinned into
      `[1, total_pages]` so a user deleting the last row on
      page 3 doesn't render a phantom page 3 with zero rows)
    * empty-state clamping (`total_pages` is at least 1 so
      the pagination footer never displays "Page 1 of 0")
    * total-pagination math (`total + size - 1) div size`
      rounding up)

  All functions are pure — same inputs → same outputs, no
  LiveView state, no socket manipulation. The LiveView
  assigns the returned tuple's four elements into
  `:history_items` / `:history_page` / `:history_total_pages`
  / `:history_total` (see `assign_history/4` in the parent
  module). Tests can call `load/4` directly and assert on the
  tuple without standing up a LiveView.

  The `total` returned by `Notifications.count_user_notifications/2`
  is the *filtered* total (per-filter pagination), NOT the
  global total — a user with 200 `dtu_connection` rows + 3
  `sun_down` rows sees "Page 1 of 1 within Sun down", not
  "Page 4 of 8".
  """

  alias DtuApp.Accounts.User
  alias DtuApp.Notifications

  @history_page_size 50

  @doc """
  Load one page of the user's notification history.

  Returns `{items, clamped_page, total_pages, total}`. The
  page index is clamped into `[1, total_pages]` so callers
  never need to re-clamp on the LiveView side.
  """
  @spec load(User.t(), pos_integer(), String.t() | nil) ::
          {[map()], pos_integer(), pos_integer(), non_neg_integer()}
  def load(user, page, event_filter) do
    total = Notifications.count_user_notifications(user, event_filter)
    total_pages = max(1, div(total + @history_page_size - 1, @history_page_size))
    clamped_page = min(max(1, page), total_pages)

    items =
      Notifications.list_user_notifications(user, clamped_page, @history_page_size, event_filter)

    {items, clamped_page, total_pages, total}
  end

  @doc """
  Page size used for the pagination footer. Exposed so
  consumers (the parent LiveView's `:event_filters` docblock)
  can reference the constant without redefining it.
  """
  @spec page_size() :: pos_integer()
  def page_size, do: @history_page_size
end
