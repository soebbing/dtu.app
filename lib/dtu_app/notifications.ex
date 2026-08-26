defmodule DtuApp.Notifications do
  @moduledoc """
  Façade for browser-notification events. The dashboard LiveView
  subscribes to per-user topics here so it can push events to the
  browser via `push_event/3`; the JS hook on the page (`Notifications`
  in `assets/js/notifications.js`) actually fires the browser
  notification, deduplicating per user-device via `localStorage`.

  This module is also the fan-out point for **native Web Push**
  (VAPID, RFC 8030/8291/8292). When `broadcast/2` fires we:

    1. PubSub-broadcast to the user's open LiveView (in-page hook),
       so users with the dashboard open get the OS notification via
       `new Notification(...)`.
    2. Look the user up, decide whether the event passes their
       preference gate (`notify_dtu_connection` / `notify_sun_down`),
       and call `DtuApp.Push.deliver/2` to push the same payload to
       their service worker via the push service. That delivers the
       OS banner even when the tab is closed.

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

  alias DtuApp.Accounts
  alias DtuApp.Accounts.User
  alias DtuApp.Notifications.Notification
  alias DtuApp.Push
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
  notifications) AND, in parallel, dispatch a VAPID-signed push to
  the user's service worker (native notifications when the tab is
  closed). Both paths are no-ops if the user has no active
  subscribers / no subscriptions — the fan-out is graceful.

  Per-event preference gating:

    * `event: "dtu_connection"` is suppressed unless the user has
      `notify_dtu_connection == true`.
    * `event: "sun_down"` is suppressed unless the user has
      `notify_sun_down == true`.
    * `event: "sun_up"` is suppressed unless the user has
      `notify_sun_up == true`.
    * Any other event (the `test` event from the test button,
      future event types) is delivered unconditionally — the user
      has already opted in to receiving those by interacting with
      the corresponding UI.

  Returns `:ok` once the in-page broadcast has been scheduled; the
  web-push fan-out runs on the calling process and is
  best-effort. Per-subscription failures are logged inside
  `DtuApp.Push.deliver/2`.
  """
  @spec broadcast(non_neg_integer(), map()) :: :ok | {:error, term()}
  def broadcast(user_id, payload) when is_integer(user_id) and is_map(payload) do
    PubSub.broadcast(@pubsub, user_topic(user_id), {:notification, payload})

    case safe_get_user(user_id) do
      nil ->
        :ok

      user ->
        if native_push_enabled?(user, payload) do
          # Spawn so a slow push service (Apple, FCM) can't back up
          # the caller's mailbox. Failures are logged inside the
          # dispatcher and never bubble up — broadcast/2's contract
          # is `:ok | {:error, term()}` for the PubSub side.
          #
          # The Task process has no inherited locale (it doesn't
          # share the caller's process dictionary), and the in-page
          # PubSub payload is already in the user's language by the
          # time it lands here — the notifier modules wrap their
          # gettext calls in `Gettext.with_locale/2` before invoking
          # broadcast/2. The service-worker push payload, by
          # contrast, is built fresh inside `Push.deliver/2`, so we
          # must set the locale in the spawned task too — otherwise
          # users with `User.locale == "de"` would receive an
          # English title/body in their closed-tab banner.
          _ =
            Task.start(fn ->
              Gettext.with_locale(DtuAppWeb.Gettext, user.locale || "en", fn ->
                Push.deliver(user, payload)
              end)
            end)
        end

        # Record the broadcast in the user's notification history.
        # The title/body are already localized by the caller (the
        # notifier modules wrap their gettext in with_locale), so
        # we persist them as-is — see `record/2` for the rationale.
        # Wrapped in try/rescue so a DB hiccup never breaks the
        # live in-page + native-push fan-out above.
        _ = record(user, payload)

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

  # TODO (Task 3): per-event preference gating moves to
  # `Push.native_enabled?/2`, which the new `Notifications.Dispatcher`
  # invokes before pushing. Delete these clauses once the dispatcher
  # is wired in and `broadcast/2` no longer references them.
  defp native_push_enabled?(%DtuApp.Accounts.User{} = user, %{"event" => event}) do
    cond do
      event == "dtu_connection" -> user.notify_dtu_connection == true
      event == "sun_down" -> user.notify_sun_down == true
      event == "sun_up" -> user.notify_sun_up == true
      true -> true
    end
  end

  # Same gate, but with atom keys (LiveView push_event payloads
  # default to string-keyed maps, but callers using atom-keyed
  # payloads also need to work).
  defp native_push_enabled?(%DtuApp.Accounts.User{} = user, %{event: event}) do
    cond do
      event == :dtu_connection -> user.notify_dtu_connection == true
      event == :sun_down -> user.notify_sun_down == true
      event == :sun_up -> user.notify_sun_up == true
      true -> true
    end
  end

  # Unknown payload shape — let everything through; the in-page
  # path will still render the title/body the caller supplied.
  defp native_push_enabled?(_user, _payload), do: true
end
