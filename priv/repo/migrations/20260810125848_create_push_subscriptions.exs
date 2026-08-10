defmodule DtuApp.Repo.Migrations.CreatePushSubscriptions do
  use Ecto.Migration

  @moduledoc """
  Persists Web Push subscriptions for the user.

  Each row is one (browser, device, push service) triple that the
  user's service worker is registered with. The service worker
  periodically re-registers, so multiple rows per user are normal —
  we dedup by `endpoint` (globally unique across push services)
  rather than by user.

  The browser-side subscription payload shape from
  `PushSubscription#toJSON()` is:

      {
        "endpoint": "https://fcm.googleapis.com/fcm/send/...",
        "expirationTime": null,
        "keys": {
          "p256dh": "<base64url-encoded EC public key>",
          "auth":   "<base64url-encoded shared-auth secret>"
        }
      }

  `p256dh` and `auth` are required by RFC 8291 (Message Encryption
  for Web Push) — they're the ECDH public key and the shared auth
  secret the push service uses to encrypt the payload, and `web_push`
  hands them straight to `WebPush.Encryption` when sending.

  `user_agent` is captured for diagnostics only — the dashboard
  lists "devices with push enabled" per-user so we can tell the user
  "your iPhone in Firefox has push enabled" vs "your desktop in
  Chrome has it" and let them prune a row if needed.
  """

  def change do
    create table(:push_subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :endpoint, :text, null: false
      add :p256dh, :text, null: false
      add :auth, :text, null: false
      add :user_agent, :text

      timestamps(type: :utc_datetime)
    end

    # `endpoint` is the push-service-assigned URL — globally unique
    # by construction (it's the subscription handle returned by FCM /
    # Mozilla autopush / Apple). The unique index is the primary
    # mechanism for upsert-by-endpoint from the subscribe endpoint.
    create unique_index(:push_subscriptions, [:endpoint])

    # List-by-user queries (the dispatcher fans out to every row for
    # a user, and the settings UI lists a user's devices-with-push).
    create index(:push_subscriptions, [:user_id])
  end
end
