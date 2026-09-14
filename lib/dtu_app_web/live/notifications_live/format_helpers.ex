defmodule DtuAppWeb.NotificationsLive.FormatHelpers do
  use Gettext, backend: DtuAppWeb.Gettext

  @moduledoc """
  Pure formatting helpers for the `/notifications` page.

  Currently just `format_relative_time/1` — the "X ago" label
  for a notification's `delivered_at`. Mirrors
  `DtuAppWeb.DeviceLive.Details.format_relative_time/1` so the
  history page reads consistently with the device-details "last
  seen" column.

  Future-dated rows (clock skew between DB and a user's
  browser) are clamped to `"just now"` rather than rendering
  negative values.
  """

  @doc """
  Human-readable "X ago" label for a notification's
  `delivered_at`. Bucketed: < 60s = "just now", < 1h = "N
  minutes ago", < 24h = "N hours ago", else "N days ago".

  Future-dated `DateTime`s (clock skew between DB and a user's
  browser) are clamped to "just now" via `max(0, diff)`.

  `now \\ DtuApp.Time.utc_now()` lets unit tests inject a
  deterministic clock — the production DB clock lives in a
  long-running cache process whose SQL.Sandbox ownership can't
  be transferred into a non-`DataCase` test, so the
  default-argument form (called by the template) reads from
  `DtuApp.Time.utc_now/0` while tests call `format_relative_time/2`
  directly with a fixed `now`.
  """
  @spec format_relative_time(DateTime.t()) :: String.t()
  def format_relative_time(%DateTime{} = dt) do
    format_relative_time(dt, DtuApp.Time.utc_now())
  end

  @spec format_relative_time(DateTime.t(), DateTime.t()) :: String.t()
  def format_relative_time(%DateTime{} = dt, %DateTime{} = now) do
    diff = DateTime.diff(now, dt, :second) |> max(0)

    cond do
      diff < 60 -> gettext("just now")
      diff < 3600 -> gettext("%{n} minutes ago", n: div(diff, 60))
      diff < 86_400 -> gettext("%{n} hours ago", n: div(diff, 3600))
      true -> gettext("%{n} days ago", n: div(diff, 86_400))
    end
  end
end
