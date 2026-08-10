defmodule DtuAppWeb.PushController do
  @moduledoc """
  HTTP endpoints for the browser-side Web Push subscription flow.

  The browser-side `PushSubscribe` hook (in `assets/js/push_subscribe.js`)
  drives three endpoints:

    * `GET  /push/vapid/public_key` — returns the server's VAPID
      public key so the browser can pass it to
      `PushManager.subscribe({applicationServerKey})`.
    * `POST /push/subscribe` — accepts the `PushSubscription#toJSON()`
      payload from the browser and persists it. Idempotent by
      `endpoint` (a re-subscribe with the same endpoint is an update,
      not a duplicate row).
    * `POST /push/unsubscribe` — accepts an `endpoint` and deletes the
      matching row.

  All three require an authenticated session. The `:require_authenticated_user`
  plug in the router enforces this; unauthenticated callers get a redirect
  to `/users/log-in` (the standard browser-pipeline response).

  CSRF note: these endpoints are reached from a same-origin `fetch` call
  initiated by the `PushSubscribe` JS hook. The hook reads the CSRF token
  from the `<meta name="csrf-token">` element in the root layout
  (`get_csrf_token/0`) and sends it as `X-CSRF-Token`. Phoenix's
  `:fetch_session` + `:protect_from_forgery` plugs check that header by
  default, so we don't disable CSRF here — we just verify it's present.
  """

  use DtuAppWeb, :controller

  alias DtuApp.PushSubscriptions
  alias DtuApp.PushSubscriptions.PushSubscription

  @doc """
  `GET /push/vapid/public_key` — returns the server's VAPID public key.

  Body: `{"public_key": "B..."}` (URL-safe base64, 65-byte P-256 point).
  When VAPID isn't configured (e.g. the operator hasn't provisioned
  keys), returns 503 so the JS hook can skip the subscribe step
  rather than crashing the page.
  """
  def vapid_public_key(conn, _params) do
    case DtuApp.Push.public_key() do
      nil ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "vapid_not_configured"})

      pk ->
        json(conn, %{public_key: pk})
    end
  end

  @doc """
  `POST /push/subscribe` — upsert the browser's push subscription.

  Body: `%{"endpoint" => "...", "keys" => %{"p256dh" => "...", "auth" => "..."}}`
  (the shape of `PushSubscription#toJSON()`).

  Returns:
    * `200 {"ok": true, "subscription": {...}}` on success (insert OR update)
    * `400 {"error": "..."}` if the payload is missing required fields
    * `422 {"errors": [...]}` if the changeset has validation errors
    * `401` redirect to log-in if the session is unauthenticated
  """
  def subscribe(conn, %{"endpoint" => endpoint, "keys" => %{"p256dh" => p256dh, "auth" => auth}}) do
    user = conn.assigns.current_scope.user

    attrs = %{
      "endpoint" => endpoint,
      "p256dh" => p256dh,
      "auth" => auth,
      "user_agent" => user_agent(conn)
    }

    case PushSubscriptions.upsert(user, attrs) do
      {:ok, %PushSubscription{} = sub} ->
        json(conn, %{ok: true, subscription: render_sub(sub)})

      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Ecto.Changeset.traverse_errors(cs, & &1)})
    end
  end

  def subscribe(conn, _params) do
    # Missing endpoint/keys — the browser posted a malformed
    # PushSubscription JSON. Don't reveal details; just reject.
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_subscription_payload"})
  end

  @doc """
  `POST /push/unsubscribe` — remove the subscription for `endpoint`.

  Body: `%{"endpoint" => "..."}`. Idempotent: deleting a missing row
  returns `200 {"ok": true}` without an error so a re-click on
  "Disable notifications" doesn't surface a 404 to the user.
  """
  def unsubscribe(conn, %{"endpoint" => endpoint}) when is_binary(endpoint) do
    user = conn.assigns.current_scope.user

    case PushSubscriptions.delete(user, endpoint) do
      :noop -> json(conn, %{ok: true})
      {:ok, _sub} -> json(conn, %{ok: true})
      {:error, cs} -> json(conn, %{ok: false, errors: Ecto.Changeset.traverse_errors(cs, & &1)})
    end
  end

  def unsubscribe(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "missing_endpoint"})
  end

  # Capture the user-agent for the settings UI's "which device has
  # push enabled?" list. Limited to 512 chars to keep the row small.
  defp user_agent(conn) do
    case get_req_header(conn, "user-agent") do
      [ua | _] -> String.slice(ua, 0, 512)
      _ -> nil
    end
  end

  # Shape the response so the JS hook can show "subscribed" feedback
  # without re-fetching. The `endpoint` is the only key the hook
  # actually reads; the rest is for diagnostics.
  defp render_sub(%PushSubscription{} = sub) do
    %{
      id: sub.id,
      endpoint: sub.endpoint,
      user_agent: sub.user_agent,
      inserted_at: DateTime.to_iso8601(sub.inserted_at)
    }
  end
end
