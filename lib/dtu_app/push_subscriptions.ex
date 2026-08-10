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

  @doc "All of a user's subscriptions, newest first."
  @spec list_for_user(User.t()) :: [PushSubscription.t()]
  def list_for_user(%User{} = user) do
    PushSubscription
    |> where([s], s.user_id == ^user.id)
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
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
        existing
        |> PushSubscription.changeset(attrs)
        |> Repo.update()

      # Endpoint owned by a different user — happens when the same
      # browser profile is used to log in as a second account.
      # Move ownership to the new caller; the encryption keys are
      # endpoint-bound, not user-bound, so they're unchanged.
      %PushSubscription{} = existing ->
        existing
        |> PushSubscription.changeset(attrs)
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

  @doc "Delete by endpoint, regardless of owner. Used by the dispatcher after a :gone."
  @spec delete_by_endpoint(String.t()) :: :ok
  def delete_by_endpoint(endpoint) when is_binary(endpoint) do
    {count, _} =
      PushSubscription
      |> where([s], s.endpoint == ^endpoint)
      |> Repo.delete_all()

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
