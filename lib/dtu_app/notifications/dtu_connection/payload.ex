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
  Diagnostic second paragraph for the `:went_offline` body —
  "last reading from the inverter was HH:MM (X min/h ago)".

  `nil` when no `last_seen_at` is available (the very first
  sighting of the device was the disconnect — no reading
  history to report on).
  """
  def last_seen_paragraph(%DateTime{} = last_seen_at, %DateTime{} = now) do
    seconds = DateTime.diff(now, last_seen_at, :second)

    {amount, unit} =
      cond do
        seconds < 60 -> {seconds, "second"}
        seconds < 3600 -> {div(seconds, 60), "minute"}
        true -> {div(seconds, 3600), "hour"}
      end

    unit_plural = pluralize(unit, amount)
    time_str = Calendar.strftime(last_seen_at, "%H:%M")

    gettext(
      "Last reading from the inverter was at %{time} (%{amount} %{unit} ago).",
      time: time_str,
      amount: amount,
      unit: unit_plural
    )
  end

  def last_seen_paragraph(_last_seen_at, _now), do: nil

  @doc """
  Diagnostic second paragraph for the `:back_online` body —
  "the inverter was offline for X minutes/hours".

  `nil` when no `:since` value is supplied (the notifier
  passes the prior disconnect timestamp here so the user can
  see how long the outage was).
  """
  def offline_duration_paragraph(%DateTime{} = offline_at, %DateTime{} = now) do
    seconds = max(DateTime.diff(now, offline_at, :second), 0)

    {amount, unit} =
      cond do
        seconds < 60 -> {seconds, "second"}
        seconds < 3600 -> {div(seconds, 60), "minute"}
        true -> {div(seconds, 3600), "hour"}
      end

    unit_plural = pluralize(unit, amount)

    gettext(
      "Inverter was offline for %{amount} %{unit}.",
      amount: amount,
      unit: unit_plural
    )
  end

  def offline_duration_paragraph(_offline_at, _now), do: nil

  defp pluralize(unit, 1), do: unit
  defp pluralize(unit, _amount), do: unit <> "s"

  @doc """
  Build the full `dtu_connection` payload map the dispatcher
  and the in-page PubSub broadcast consume.

  `name` is the device name (e.g. `"Garage Inverter"`); `status`
  is `:went_offline` / `:back_online`; `now` is stamped on the
  `:since` field so tests can pass a fixed `DateTime` rather
  than racing the system clock. `opts` carries the diagnostic
  timestamps the producer threads through:

    * `:last_seen_at` — for `:went_offline`, the most recent
      reading timestamp we observed before the disconnect.
      Drives the "last reading was at HH:MM (X min ago)" second
      paragraph. `nil` to omit the diagnostic.
    * `:since` — for `:back_online`, the time the disconnect
      fired. Drives the "was offline for X min" second paragraph.
      Falls back to `now` if not provided.

  The `body` field is a list (the email/layout pipeline expects
  a list of paragraphs; the dispatcher's history-row insert
  coerces it back to a single string for the `:body` column).
  The `:tag` uses the device name without the `:status` suffix
  — the producer-side `not was_disconnected?` /
  `disconnected?: true` gates already suppress duplicate fires
  within a single offline period, so a status-suffixed tag
  would be redundant.
  """
  @spec build(atom(), String.t(), DateTime.t(), keyword()) :: map()
  def build(status, name, %DateTime{} = now, opts \\ []) do
    %{
      event: "dtu_connection",
      title: title(status, name),
      body: body_paragraphs(status, name, now, opts),
      tag: "dtu:#{name}",
      dtu_name: name,
      status: status,
      since: now
    }
  end

  defp body_paragraphs(status, name, now, opts) do
    base = body(status, name)

    case diagnostic_paragraph(status, name, now, opts) do
      nil -> [base]
      para -> [base, para]
    end
  end

  defp diagnostic_paragraph(:went_offline, _name, now, opts) do
    last_seen_paragraph(Keyword.get(opts, :last_seen_at), now)
  end

  defp diagnostic_paragraph(:back_online, _name, now, opts) do
    offline_duration_paragraph(Keyword.get(opts, :since, now), now)
  end

  defp diagnostic_paragraph(_status, _name, _now, _opts), do: nil
end
