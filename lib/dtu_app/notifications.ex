defmodule DtuApp.Notifications do
  @moduledoc """
  Façade for browser-notification events. The dashboard LiveView
  subscribes to per-user topics here so it can push events to the
  browser via `push_event/3`; the JS hook on the page (`Notifications`
  in `assets/js/notifications.js`) actually fires the browser
  notification, deduplicating per user-device via `localStorage`.

  Why per-user topics instead of broadcast? Two reasons:
    1. Privacy: only the user's own LiveView receives their events.
    2. Liveness: the topic is only subscribed while the user's
       LiveView is connected, so server-side dedup against a stale
       tab is unnecessary.
  """

  alias Phoenix.PubSub

  @pubsub DtuApp.PubSub

  @spec user_topic(non_neg_integer()) :: String.t()
  def user_topic(user_id), do: "user:notification:#{user_id}"

  @doc """
  Subscribe the calling process to a user's notification events. The
  dashboard's `handle_event("connect_params", ...)` and
  `mount/3` calls this so the LiveView's mailbox receives events.
  """
  @spec subscribe(non_neg_integer()) :: :ok | {:error, term()}
  def subscribe(user_id) do
    PubSub.subscribe(@pubsub, user_topic(user_id))
  end

  @doc """
  Fire a `:notification` event to the user's LiveView. The browser
  notification itself is created by the JS hook on the page.
  """
  @spec broadcast(non_neg_integer(), map()) :: :ok | {:error, term()}
  def broadcast(user_id, payload) do
    PubSub.broadcast(@pubsub, user_topic(user_id), {:notification, payload})
  end
end
