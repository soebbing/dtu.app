defmodule DtuApp.Notifications.Notification do
  @moduledoc """
  A single broadcast recorded for the user. One row per call to
  `DtuApp.Notifications.broadcast/2`, regardless of which
  notification producer triggered it.

  The persisted `title`/`body` are the **already-localized**
  strings the user saw in their notification — the notifier
  modules wrap their `gettext/1` calls in
  `Gettext.with_locale/2` against `User.locale` before invoking
  `broadcast/2`. Storing the localized text means the history
  page reads back the same language the user actually saw, even
  if they later change their locale.

  See `DtuApp.Notifications` (the context) for the query API and
  `priv/repo/migrations/20260825140000_create_notifications.exs`
  for the storage layout.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias DtuApp.Accounts.User

  @required ~w(user_id event title body payload delivered_at)a

  schema "notifications" do
    belongs_to :user, User
    field :event, :string
    field :title, :string
    field :body, :string
    # The OS-level `tag` for browser notification coalescing.
    # Optional — some future event types may not set one.
    field :tag, :string
    # The raw payload as jsonb. We accept any shape so future
    # event types don't require a schema migration.
    field :payload, :map
    field :delivered_at, :utc_datetime

    # Which channel the user had selected at fire time
    # (`"push"`, `"email"`, or `"both"`). One history row per fire,
    # not one row per channel — the column records the user's
    # chosen channel, not which paths actually fired (a user on
    # `"both"` whose `notify_sun_down` was false still records
    # `"both"`).
    field :channel, :string, default: "push"

    timestamps(type: :utc_datetime)
  end

  @doc """
  Build a changeset from a payload map produced by
  `DtuApp.Notifications.broadcast/2`. The user is supplied
  separately from the payload so the foreign key is always set,
  even if a caller forgets to include it.

  The `event` / `title` / `body` fields are pulled from the payload
  (with sensible fallbacks) so they're never blank, which would
  otherwise leave an empty row in the history.
  """
  @spec changeset(%__MODULE__{}, User.t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = n, %User{} = user, payload) when is_map(payload) do
    n
    |> cast(payload, [:event, :title, :body, :tag, :payload, :channel])
    |> put_change(:user_id, user.id)
    # `delivered_at` is server-stamped at record time, not at
    # changeset-construction time, so two inserts in the same
    # millisecond don't collide on the index. broadcast/2 sets it
    # explicitly via put_change before insert.
    |> put_change(:delivered_at, DateTime.utc_now(:second))
    |> validate_required(@required)
    |> validate_required([:event, :title, :body])
  end
end
