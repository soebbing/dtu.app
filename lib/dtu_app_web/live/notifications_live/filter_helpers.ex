defmodule DtuAppWeb.NotificationsLive.FilterHelpers do
  use Gettext, backend: DtuAppWeb.Gettext

  @moduledoc """
  Pure event-filter helpers for the `/notifications` page.

  The `:event` URL param drives both the chip-row's active state and
  the WHERE clause on `Notifications.count_user_notifications/2` /
  `Notifications.list_user_notifications/4`. Three tiny pure
  functions own that mapping:

    * `normalize_event_filter/1` — accept-list for URL params. A
      forged `?event=...` query (or a typo) falls back to `"all"`
      so a future event type that hasn't shipped to the UI yet
      can't be coerced into surfacing rows.
    * `event_filter_to_query/1` — translate the UI sentinel
      `"all"` (and `""`/nil, defensively) to `nil` so the
      underlying query stays `WHERE user_id = $1` (no event WHERE
      clause). The live-view + URL layer is the only thing that
      knows about the `"all"` label.
    * `filter_label/1` — chip-row display label.

  Sister module: `DtuAppWeb.NotificationsLive.FormatHelpers` owns
  the `format_relative_time/1` helper used by the history list.
  """

  @doc """
  Allow-list for event-filter URL params. Unknown values fall
  back to `"all"`.
  """
  @spec normalize_event_filter(String.t() | nil) :: String.t()
  def normalize_event_filter(value)
      when value in ["dtu_connection", "sun_down", "sun_up", "yield_anomaly", "test"],
      do: value

  def normalize_event_filter(_), do: "all"

  @doc """
  Translate the UI sentinel `"all"` (or `""`/nil, defensively) to
  `nil` so the DB query stays `WHERE user_id = $1`. Any other
  allowed filter value passes through unchanged.
  """
  @spec event_filter_to_query(String.t() | nil) :: String.t() | nil
  def event_filter_to_query(nil), do: nil
  def event_filter_to_query(""), do: nil
  def event_filter_to_query("all"), do: nil
  def event_filter_to_query(value), do: value

  @doc """
  Human-readable label for a filter chip. Unknown values fall
  back to `"All"` so a stale assign can never render an empty
  chip.
  """
  @spec filter_label(String.t()) :: String.t()
  def filter_label("all"), do: gettext("All")
  def filter_label("dtu_connection"), do: gettext("Connection")
  def filter_label("sun_down"), do: gettext("Sun down")
  def filter_label("sun_up"), do: gettext("Sun up")
  def filter_label("yield_anomaly"), do: gettext("Yield anomaly")
  def filter_label("test"), do: gettext("Test")
  def filter_label(_), do: gettext("All")
end
