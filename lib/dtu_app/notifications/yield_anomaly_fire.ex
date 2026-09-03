defmodule DtuApp.Notifications.YieldAnomalyFire do
  @moduledoc """
  Schema for the `yield_anomaly_fires` dedup table.

  Each row records "this user has already received a
  `yield_anomaly` notification on this local date." Used by
  `DtuApp.Notifications.YieldAnomaly` to suppress duplicate
  fires across GenServer restarts and redeploys (the
  producer's earlier in-memory dedup cache was lost on every
  restart, producing real duplicate mid-day banners).

  Composite primary key `(user_id, fired_on)` ensures the
  table holds at most one row per user per local date. No
  serial `id`.

  `fired_on` is the producer's view of the user's local date
  (computed from `user.tz_offset_seconds`), not wall-clock UTC.
  The mid-day check (between local sunrise and sunset) needs
  a stable local date — using UTC would let a Berlin user see
  two fires on the day after their local midnight + UTC
  midnight gap.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  schema "yield_anomaly_fires" do
    belongs_to :user, DtuApp.Accounts.User, primary_key: true
    field :fired_on, :date, primary_key: true
    # Wall-clock UTC when the producer fired. DB clock via
    # `DEFAULT now()` so the producer doesn't have to read it
    # back. Useful for debugging ("did this fire today? at
    # what UTC instant?") without joining to `notifications`.
    field :inserted_at, :utc_datetime_usec
  end

  @doc """
  Build a changeset from `attrs`. Only `user_id` and `fired_on`
  are user-supplied; `inserted_at` is filled by the DB.
  """
  def changeset(%__MODULE__{} = row, attrs) do
    row
    |> cast(attrs, [:user_id, :fired_on])
    |> validate_required([:user_id, :fired_on])
  end
end
