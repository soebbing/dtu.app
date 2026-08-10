defmodule DtuApp.Push do
  @moduledoc """
  Native Web Push delivery (RFC 8030 + RFC 8291 + RFC 8292).

  The dashboard's in-page PubSub path (`DtuApp.Notifications`) only
  fires `new Notification(...)` for as long as the user has the
  dashboard tab open. This module fills the rest of the gap: it
  fans the same events out to the user's **service worker** via a
  VAPID-signed, AES-128-GCM-encrypted POST to the user's push
  service (FCM, Mozilla autopush, Apple), so the OS-level banner
  shows even when the tab is closed.

  Three things the module owns:

    1. **Public key exposure.** `public_key/0` is what the browser
       hands to `PushManager.subscribe({applicationServerKey})`. The
       value is the URL-safe base64 encoding of a 65-byte P-256
       point (per the W3C Push API spec).

    2. **Fan-out.** `deliver/2` looks up every subscription for a
       user, signs + encrypts + sends the payload via `web_push`,
       and cleans up dead rows (HTTP 404 / 410 → `delete_by_endpoint/1`).

    3. **Graceful degradation.** If no VAPID keys are configured
       (e.g. the operator hasn't provisioned them yet), `deliver/2`
       silently returns — the in-page path keeps working, and the
       dashboard's existing notification flow is unaffected. The
       user-facing effect is "OS banner doesn't show", which is
       exactly what we want when the operator hasn't opted in.

  The actual cryptography and HTTP work is delegated to
  `WebPush.{Encryption,Vapid}` and `web_push`/`Finch`; we own the
  Ecto row lifecycle and the per-user fan-out.
  """

  require Logger

  alias DtuApp.PushSubscriptions
  alias DtuApp.PushSubscriptions.PushSubscription

  @doc """
  The VAPID public key the browser needs to subscribe. URL-safe
  base64, 65-byte uncompressed P-256 point.

  Reads from `config :web_push, :vapid, :public_key`. Returns `nil`
  if no VAPID keypair is configured — callers should treat that as
  "native push is disabled in this deployment" rather than raising.
  """
  @spec public_key() :: String.t() | nil
  def public_key do
    case Application.get_env(:web_push, :vapid) do
      %{public_key: pk} when is_binary(pk) and pk != "" -> pk
      _ -> nil
    end
  end

  @doc """
  Push a notification payload to every active subscription of `user`.

  The payload is the same map the in-page `Notifications` hook
  consumes (event + title + body + tag, etc.); the service worker
  in `priv/static/service-worker.js` whitelist-merges the keys
  before passing them to `showNotification`. See the moduledoc on
  the SW for the full contract.

  Returns `:ok` once every subscription has been attempted. Per-row
  errors are logged and do not abort the fan-out — one dead
  subscription (a phone whose push service revoked the handle)
  must not stop notifications reaching the user's other devices.
  """
  @spec deliver(DtuApp.Accounts.User.t(), map()) :: :ok
  def deliver(%DtuApp.Accounts.User{} = user, payload) when is_map(payload) do
    if public_key() == nil do
      # VAPID not configured — silently skip. The caller is the
      # in-page PubSub broadcast which keeps working; we just don't
      # add native delivery on top.
      :ok
    else
      user
      |> PushSubscriptions.list_for_user()
      |> Enum.each(&send_to(&1, payload))
    end
  end

  @doc """
  Variant that takes an explicit list of subscriptions — used by
  the test suite to fan out without seeding Ecto rows.
  """
  @spec deliver_many([PushSubscription.t()], map()) :: :ok
  def deliver_many(subs, payload) when is_list(subs) and is_map(payload) do
    if public_key() == nil do
      :ok
    else
      Enum.each(subs, &send_to(&1, payload))
    end
  end

  # Send one payload to one subscription; delete the row on :gone,
  # log + move on for any other error.
  defp send_to(%PushSubscription{} = sub, payload) do
    case WebPush.send(PushSubscription.to_web_push(sub), payload) do
      :ok ->
        :ok

      {:error, :gone} ->
        # 404/410 — the push service has revoked this handle.
        # Garbage-collect the row so subsequent deliveries don't
        # waste a roundtrip.
        PushSubscriptions.delete_by_endpoint(sub.endpoint)

      {:error, reason} ->
        # Transport or unexpected status — log and move on. We
        # *don't* delete the row because it may succeed on a
        # retry; only a :gone is terminal.
        Logger.warning("[push] delivery failed for user_id=#{sub.user_id}: #{inspect(reason)}")
    end
  end
end
