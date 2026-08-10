defmodule DtuApp.PushSubscriptions.PushSubscription do
  @moduledoc """
  A single Web Push subscription — one (user × device × push service)
  triple. The browser's `PushSubscription#toJSON()` payload is
  persisted as-is (minus the per-rebind `expirationTime`, which is
  handled by the browser and not useful server-side):

      %{
        endpoint: "https://fcm.googleapis.com/fcm/send/<token>",
        keys: %{
          p256dh: "<base64url EC public key>",
          auth:   "<base64url shared auth secret>"
        }
      }

  `endpoint` is the globally-unique handle the push service returns;
  it's the natural primary key for upsert and the index the
  dispatcher uses to delete dead rows (HTTP 404 / 410 from the push
  service means the subscription has been revoked server-side).

  See `DtuApp.PushSubscriptions` for the context API.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @required ~w(user_id endpoint p256dh auth)a

  schema "push_subscriptions" do
    belongs_to :user, DtuApp.Accounts.User
    field :endpoint, :string
    # The ECDH public key the push service uses to derive the
    # payload-encryption key. base64url-encoded (no padding).
    field :p256dh, :string
    # The shared auth secret — 16 random bytes, base64url-encoded.
    # Used in the HKDF info string when deriving the content-encryption
    # key per RFC 8291 §5.
    field :auth, :string
    # Captured server-side from the `User-Agent` header on the
    # subscribe POST so the settings UI can show "Firefox on macOS"
    # etc. Diagnostic only; never sent to the push service.
    field :user_agent, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Build a subscription changeset from a `PushSubscription#toJSON()`
  payload posted by the browser (a flat map with `endpoint` and
  nested `keys.p256dh` / `keys.auth`). The caller is expected to
  pass the resolved `user_id` and optionally a `user_agent` for
  diagnostics.

  Both `endpoint` and the nested keys are required; the changeset
  surfaces a clear error if the browser posts a malformed payload
  (we have seen partial bodies from older mobile WebViews).
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = sub, attrs) do
    sub
    |> cast(attrs, [:user_id, :endpoint, :p256dh, :auth, :user_agent])
    |> validate_required(@required)
    # A real Web Push endpoint is an absolute https URL — anything
    # else is either a malicious POST or a truncated payload from a
    # buggy browser; reject before it reaches the push service.
    |> validate_format(:endpoint, ~r{^https://}, message: "must be an absolute https URL")
    |> unique_constraint(:endpoint)
  end

  @doc """
  Map a stored subscription row into the struct `WebPush.send/3`
  expects. Kept here so the context layer doesn't depend on the
  shape of the persisted row.
  """
  @spec to_web_push(%__MODULE__{}) :: WebPush.Subscription.t()
  def to_web_push(%__MODULE__{endpoint: endpoint, p256dh: p256dh, auth: auth}) do
    %WebPush.Subscription{endpoint: endpoint, p256dh: p256dh, auth: auth}
  end
end
