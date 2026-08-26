defmodule DtuApp.Notifications do
  @moduledoc """
  Façade for browser-notification events. The dashboard LiveView
  subscribes to per-user topics here so it can push events to the
  browser via `push_event/3`; the JS hook on the page (`Notifications`
  in `assets/js/notifications.js`) actually fires the browser
  notification, deduplicating per user-device via `localStorage`.

  This module is also the entry point for delivery. When `broadcast/2`
  fires we:

    1. PubSub-broadcast to the user's open LiveView (in-page hook),
       so users with the dashboard open get the OS notification via
       `new Notification(...)`.
    2. Look the user up and delegate the actual fan-out — push
       (existing `DtuApp.Push.deliver/2`), email, AND the history
       row write — to `DtuApp.Notifications.Dispatcher.fire/3`.

  Gating rationale: the in-page hook already de-duplicates by tag
  in `localStorage`, so a user with the dashboard open doesn't see
  double banners (the in-page path fires; the OS-level `tag`
  coalesces repeats that arrive while the in-page path is also
  running). The two paths are independent and safe to fire
  simultaneously.

  Why per-user topics instead of broadcast? Two reasons:
    1. Privacy: only the user's own LiveView receives their events.
    2. Liveness: the topic is only subscribed while the user's
       LiveView is connected, so server-side dedup against a stale
       tab is unnecessary.
  """

  require Logger

  alias DtuApp.Accounts
  alias DtuApp.Accounts.User
  alias DtuApp.Notifications.Dispatcher
  alias DtuApp.Notifications.Notification
  alias DtuApp.Repo
  alias Phoenix.PubSub

  import Ecto.Query

  @pubsub DtuApp.PubSub

  @default_page_size 50

  @spec user_topic(non_neg_integer()) :: String.t()
  def user_topic(user_id), do: "user:notification:#{user_id}"

  @doc """
  Record a notification broadcast for the given user. Called from
  `broadcast/2` after the in-page + native-push fan-out so the
  history page can show what the server actually sent.

  Returns `{:ok, notification}` on success or
  `{:error, changeset}` on validation failure. The broadcast
  wrapper deliberately catches these errors — a failed history
  write must never break the live notification path.
  """
  @spec record(User.t(), map()) :: {:ok, Notification.t()} | {:error, Ecto.Changeset.t()}
  def record(%User{} = user, payload) when is_map(payload) do
    %Notification{}
    # The whole payload is persisted as `:payload` (jsonb), so we
    # pass `{event, title, body, tag, payload: <whole payload>}`
    # to the changeset — cast lifts the same-named keys out for
    # column-level indexing while the full jsonb stays in
    # `:payload` for future drill-down.
    |> Notification.changeset(user, Map.put(payload, :payload, payload))
    |> Repo.insert()
  end

  @doc """
  List a page of notifications for the given user, newest-first.

  `page` is 1-indexed. `per_page` defaults to #{@default_page_size}
  (the value the history UI uses). Pass a smaller value from the
  LiveView when rendering a partial page during pagination.
  """
  @spec list_user_notifications(User.t(), pos_integer(), pos_integer()) :: [Notification.t()]
  def list_user_notifications(%User{id: user_id}, page, per_page \\ @default_page_size)
      when is_integer(page) and page > 0 and is_integer(per_page) and per_page > 0 do
    offset = (page - 1) * per_page

    Notification
    |> where([n], n.user_id == ^user_id)
    |> order_by([n], desc: n.delivered_at, desc: n.id)
    |> limit(^per_page)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc "Total count of notifications for the user (used to render pagination totals)."
  @spec count_user_notifications(User.t()) :: non_neg_integer()
  def count_user_notifications(%User{id: user_id}) do
    Notification
    |> where([n], n.user_id == ^user_id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Delete a single notification row. Only deletes the row when it
  belongs to the supplied user — returns `:noop` for either an
  unknown id or a row owned by someone else, so a forged delete
  request from the LiveView can't wipe another user's history.
  """
  @spec delete(User.t(), pos_integer()) ::
          {:ok, Notification.t()} | :noop
  def delete(%User{id: user_id}, id) when is_integer(id) do
    case Repo.get(Notification, id) do
      %Notification{user_id: ^user_id} = n -> Repo.delete(n)
      _ -> :noop
    end
  end

  @doc """
  Delete every notification row for the user. Returns the number
  of rows deleted.
  """
  @spec clear_all(User.t()) :: {non_neg_integer(), nil | [term()]}
  def clear_all(%User{id: user_id}) do
    Notification
    |> where([n], n.user_id == ^user_id)
    |> Repo.delete_all()
  end

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
  Fire a `:notification` event to the user's LiveView (in-page
  notifications) AND, in parallel, delegate the actual delivery —
  push (existing `DtuApp.Push.deliver/2`) and/or email — to
  `DtuApp.Notifications.Dispatcher.fire/3`. The dispatcher also
  records the history row (with the user's chosen `channel`
  column) inside its own try/rescue. Both paths are no-ops if the
  user has no active subscribers / no subscriptions / no
  confirmed email — the fan-out is graceful.

  Per-event preference gating is the dispatcher's responsibility:
  `DtuApp.Push.native_enabled?/2` filters the push path by the
  user's `notify_*` flags, and the dispatcher skips email when the
  address is unconfirmed.

  Returns `:ok` once the in-page broadcast has been scheduled; the
  push + email fan-out runs on the calling process and is
  best-effort. Per-channel failures are logged inside
  `Dispatcher.fire/3` and never bubble up.
  """
  @spec broadcast(non_neg_integer(), map()) :: :ok | {:error, term()}
  def broadcast(user_id, payload) when is_integer(user_id) and is_map(payload) do
    PubSub.broadcast(@pubsub, user_topic(user_id), {:notification, payload})

    case safe_get_user(user_id) do
      nil ->
        :ok

      user ->
        # The dispatcher reads `user.notification_channel` to
        # decide whether to invoke push, email, or both. Per-event
        # preference gating (notify_sun_down etc.) is applied
        # inside the dispatcher via `Push.native_enabled?/2`.
        Dispatcher.fire(user, payload[:event] || payload["event"], payload)

        :ok
    end
  end

  # A user-deleted-before-broadcast race is benign: the in-page
  # broadcast is a no-op (no LiveView subscribed), and we just
  # skip the web-push fan-out. `Accounts.get_user!/1` would raise;
  # we want a quiet `nil` instead.
  defp safe_get_user(user_id) do
    Accounts.get_user!(user_id)
  rescue
    Ecto.NoResultsError -> nil
  end
end
