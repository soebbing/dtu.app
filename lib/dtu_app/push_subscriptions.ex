defmodule DtuApp.PushSubscriptions do
  @moduledoc """
  CRUD for Web Push subscriptions.

  Each user can have many subscriptions (one per browser, per
  device, per push service — i.e. a user with Chrome on macOS and
  Firefox on iOS gets two rows). The dispatcher in `DtuApp.Push`
  fans out to all of a user's rows; the controller in
  `DtuAppWeb.PushController` upserts by `endpoint` (the globally
  unique handle the push service returns).

  All functions take an owning `%DtuApp.Accounts.User{}` and never
  touch another user's subscriptions — there's no admin path here,
  only per-user self-service. The `delete_by_endpoint/2` helper is
  the only exception: it accepts a raw `endpoint` string for the
  service worker (which has no user context when it auto-cleans
  via `DtuApp.Push`).
  """

  import Ecto.Query, warn: false

  alias DtuApp.Accounts.User
  alias DtuApp.PushSubscriptions.PushSubscription
  alias DtuApp.Repo

  @doc "All of a user's *live* subscriptions, newest first. Soft-deleted rows are excluded."
  @spec list_for_user(User.t()) :: [PushSubscription.t()]
  def list_for_user(%User{} = user) do
    PushSubscription
    |> where([s], s.user_id == ^user.id and is_nil(s.deleted_at))
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns `true` if any of the user's subscriptions were soft-deleted
  within the last `days` days.

  The capability card uses this to surface a one-click "your browser
  cleared your push subscription" prompt when the user has browser
  permission = `granted` but no live subscription row exists. The
  window bounds false-positives for users who lost a single
  multi-device subscription but still get push on another device.

  Soft-deleted rows live indefinitely (a future periodic prune task
  can hard-delete rows older than 30 days); this query is cheap
  because the partial index `push_subscriptions_revoked_user_id_deleted_at_index`
  only indexes the `deleted_at IS NOT NULL` slice.
  """
  @spec revoked_within_days?(User.t(), non_neg_integer()) :: boolean
  def revoked_within_days?(%User{} = user, days) when is_integer(days) and days >= 0 do
    cutoff = DateTime.add(DateTime.utc_now(:second), -days * 86_400, :second)

    PushSubscription
    |> where([s], s.user_id == ^user.id and not is_nil(s.deleted_at) and s.deleted_at > ^cutoff)
    |> Repo.exists?()
  end

  @doc """
  Upsert a subscription by `endpoint`. The browser may POST a
  fresh `PushSubscription` JSON after a service-worker restart, and
  the endpoint handle is stable across that — so we treat the same
  endpoint from the same user as "update user_agent + last_seen,
  keep p256dh/auth as-is" (the keys never change for a given
  endpoint, so any inbound change is a hint that something's
  drifted; we still overwrite because the browser is the source of
  truth).

  Returns `{:ok, subscription}` or `{:error, changeset}`.
  """
  @spec upsert(User.t(), map()) :: {:ok, PushSubscription.t()} | {:error, Ecto.Changeset.t()}
  def upsert(%User{} = user, attrs) do
    endpoint = attrs["endpoint"] || attrs[:endpoint]

    # Ecto's `cast/3` rejects maps with mixed atom + string keys.
    # The browser JSON body is string-keyed; the controller's
    # `Map.put(attrs, :user_id, user.id)` would otherwise mix the two
    # worlds. Normalize to string keys here so callers can pass
    # either shape.
    attrs =
      attrs
      |> Map.new(fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
        {k, v} -> {k, v}
      end)
      |> Map.put("user_id", user.id)

    case get_by_endpoint(endpoint) do
      nil ->
        %PushSubscription{}
        |> PushSubscription.changeset(attrs)
        |> Repo.insert()

      %PushSubscription{user_id: owner_id} = existing when owner_id == user.id ->
        # If this row was soft-deleted (the dispatcher hit a 404/410
        # from the push service), the browser coming back with the
        # same endpoint means the handle is alive again — reactivate
        # the row by clearing `deleted_at` so the dispatcher fans
        # out to it on the next push AND the capability card's
        # "recently revoked" prompt stops firing. The changeset
        # allow-list doesn't include `:deleted_at`, so we thread it
        # in via `Ecto.Changeset.change/2` after the cast.
        existing
        |> PushSubscription.changeset(attrs)
        |> Ecto.Changeset.change(deleted_at: nil)
        |> Repo.update()

      # Endpoint owned by a different user — happens when the same
      # browser profile is used to log in as a second account.
      # Move ownership to the new caller; the encryption keys are
      # endpoint-bound, not user-bound, so they're unchanged. Same
      # reactivation rule applies: if the row was soft-deleted,
      # the new owner is telling us the endpoint works again.
      %PushSubscription{} = existing ->
        existing
        |> PushSubscription.changeset(attrs)
        |> Ecto.Changeset.change(deleted_at: nil)
        |> Repo.update()
    end
  end

  @doc "Delete a subscription owned by the given user. No-op if not found."
  @spec delete(User.t(), String.t()) ::
          {:ok, PushSubscription.t()} | {:error, Ecto.Changeset.t()} | :noop
  def delete(%User{} = user, endpoint) when is_binary(endpoint) do
    case get_for_user(user, endpoint) do
      nil -> :noop
      sub -> Repo.delete(sub)
    end
  end

  @doc """
  Soft-delete by endpoint, regardless of owner. Used by the
  dispatcher after a `:gone` from the push service.

  Unlike `delete/2` (a per-user explicit remove), this is the
  *system-initiated* prune path: the push service has revoked the
  endpoint (HTTP 404/410), the dispatcher needs to stop fanning out
  to it, but we want to keep enough server-side state for the
  capability card to detect "this user's subscription was working
  recently and isn't now" and surface a one-click re-subscribe
  prompt. A hard delete would erase that signal.

  The row is hidden from `list_for_user/1` (and therefore from the
  dispatcher's fan-out) by the `WHERE deleted_at IS NULL` filter.
  The row stays in the table until a future periodic prune task
  hard-deletes it; for now the soft-delete tail is bounded (a user
  only generates a handful of `:gone` events per device lifetime).
  """
  @spec delete_by_endpoint(String.t()) :: :ok
  def delete_by_endpoint(endpoint) when is_binary(endpoint) do
    now = DateTime.utc_now(:second)

    {count, _} =
      PushSubscription
      |> where([s], s.endpoint == ^endpoint and is_nil(s.deleted_at))
      |> Repo.update_all(set: [deleted_at: now])

    # We deliberately swallow the row count — the caller's only
    # branching is "did we send another push?" and the answer is
    # always "no, because we just deleted the only handle".
    _ = count
    :ok
  end

  defp get_by_endpoint(endpoint) when is_binary(endpoint) do
    Repo.get_by(PushSubscription, endpoint: endpoint)
  end

  defp get_for_user(%User{} = user, endpoint) do
    PushSubscription
    |> where([s], s.user_id == ^user.id and s.endpoint == ^endpoint)
    |> Repo.one()
  end
end
