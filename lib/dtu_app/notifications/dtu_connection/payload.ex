defmodule DtuApp.Notifications.DtuConnection.Payload do
  @moduledoc """
  Pure payload builders extracted from
  `DtuApp.Notifications.DtuConnection`.

  Owns the three pure helpers that shape a `dtu_connection`
  notification payload:

    * `title/2` — the gettext-scoped notification title for a
      given status (`DTU went offline`, `DTU back online`, or
      the generic `DTU status changed for %{name}` fallback for
      unknown statuses)
    * `body/2` — the gettext-scoped notification body
    * `build/3` — the full payload map the
      `Notifications.Dispatcher` and the in-page PubSub
      broadcast both consume

  Split mirrors `DtuApp.Notifications.SunDown.Payload`. Re-
  exposed through `DtuApp.Notifications.DtuConnection` via
  `defdelegate` so the notifier's call sites and the existing
  test surface stay unchanged.

  ## Why these live in a sibling module

  These three functions were the only non-state-mutation logic
  in a 594-line notifier module, and they had no live
  dependencies on GenServer state, the `Repo`, or `User` —
  they only need a status atom, a device name, and (for
  `build/3`) the current time. Splitting them lets a unit test
  exercise the title/body/build shapes without booting a
  GenServer, and keeps the notifier's moduledoc focused on
  state-machine + persistence behaviour.

  The `build/3` map shape is the contract `Notifications.broadcast/2`
  and `Dispatcher.fire/3` consume — `event`, `title`, `body`,
  `tag`, `dtu_name`, `status`, `since`. Changing the keys here
  is a downstream-visible change.

  ## Why `build/3` takes `now` as an argument

  The `:since` field on the payload is read by the email
  subject + body lines and by history drill-down UIs to render
  "at HH:MM" or "at YYYY-MM-DD". Stamping `DateTime.utc_now()`
  inline would make the payload time-sensitive to test
  ordering — a test asserting `since: ~U[...]` would flake.
  Taking `now` as an argument lets the producer pass
  `DateTime.utc_now()` once per fire and lets unit tests pass
  a fixed `DateTime` for deterministic assertions.
  """

  use Gettext, backend: DtuAppWeb.Gettext

  @doc """
  Notification title for a given status.

  Returns the localized title (`DTU went offline` for
  `:went_offline`, `DTU back online` for `:back_online`). The
  fallback clause is the generic `DTU status changed for
  %{name}` — the producer only ever emits the two known atoms,
  but the fallback keeps an unknown future status from
  crashing the producer.
  """
  def title(:went_offline, _name), do: gettext("DTU went offline")
  def title(:back_online, _name), do: gettext("DTU back online")
  def title(_status, name), do: gettext("DTU status changed for %{name}", name: name)

  @doc """
  Notification body for a given status.

  Returns the localized body string for `:went_offline` or
  `:back_online`. Unlike `title/2`, there is no generic
  fallback — an unknown status returns `nil` so the caller's
  existing `if body, do: ...` guards short-circuit cleanly.
  The dispatcher coerces a `nil` body to an empty list before
  inserting the history row.
  """
  def body(:went_offline, name),
    do: gettext("Your inverter %{name} has gone offline.", name: name)

  def body(:back_online, name),
    do: gettext("Your inverter %{name} is publishing telemetry again.", name: name)

  def body(_status, _name), do: nil

  @doc """
  Build the full `dtu_connection` payload map the dispatcher
  and the in-page PubSub broadcast consume.

  `name` is the device name (e.g. `"Garage Inverter"`); `status`
  is `:went_offline` / `:back_online`; `now` is stamped on the
  `:since` field so tests can pass a fixed `DateTime` rather
  than racing the system clock.

  The `body` field is a list (the email/layout pipeline expects
  a list of paragraphs; the dispatcher's history-row insert
  coerces it back to a single string for the `:body` column).
  The `:tag` uses the device name without the `:status` suffix
  — the producer-side `not was_disconnected?` /
  `disconnected?: true` gates already suppress duplicate fires
  within a single offline period, so a status-suffixed tag
  would be redundant.
  """
  @spec build(atom(), String.t(), DateTime.t()) :: map()
  def build(status, name, %DateTime{} = now) do
    %{
      event: "dtu_connection",
      title: title(status, name),
      body: [body(status, name)],
      tag: "dtu:#{name}",
      dtu_name: name,
      status: status,
      since: now
    }
  end
end
