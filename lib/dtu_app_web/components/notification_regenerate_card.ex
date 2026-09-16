defmodule DtuAppWeb.NotificationRegenerateCard do
  @moduledoc """
  The "Regenerate summary" card on the Notifications page. Lets
  the user manually request a `sun_down` summary for any past
  date in the last 30 days.

  Re-firing for a missed day is the UX resolution recommended by
  `docs/debug/2026-09-16-sun-down-silent-skip.md` (Bug 3
  conclusion): producer-side retro-fire was rejected as too
  brittle, so the user gets a form to ask the dispatcher to
  compute the payload for a chosen date and broadcast it.

  The form's `<input type="date">` carries `min=` and `max=`
  attributes so the browser greys out out-of-range dates before
  the user submits. The server-side validation in
  `NotificationsLive.handle_event("regenerate_sun_down", ...)`
  is the authoritative gate — `min/max` only affect the native
  picker; bypassing them (e.g. via curl) still hits the same
  error flashes.

  Was the inline `<form phx-submit="regenerate_sun_down">` block
  that lived in `notifications_live.html.heex`. Extracted so the
  card chrome, the date input attributes, and the submit-button
  label each get their own stable render-only test surface.
  """

  use DtuAppWeb, :html

  attr :min_date, Date,
    required: true,
    doc: """
    The earliest date the user is allowed to pick — passed
    straight to the `<input type="date" min=...>` attribute so
    the native picker disables earlier days. Matches the
    `today - 30` window enforced server-side.
    """

  attr :max_date, Date,
    required: true,
    doc: """
    The latest date the user is allowed to pick — passed
    straight to the `<input type="date" max=...>` attribute so
    the native picker disables today and future days. Matches
    the `today - 1` (yesterday) bound enforced server-side.
    """

  def notification_regenerate_card(assigns) do
    ~H"""
    <div
      id="notification-regenerate"
      class="space-y-4 rounded-xl border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-800 p-6"
    >
      <h2 class="text-lg font-semibold text-zinc-900 dark:text-white">
        {gettext("Missed a day?")}
      </h2>
      <p class="text-sm text-zinc-500 dark:text-zinc-400">
        {gettext(
          "Pick a day from the last 30 to regenerate the end-of-day summary for that day — useful if the daily notification didn't fire because the inverter was offline or the page was closed."
        )}
      </p>

      <.form
        for={%{}}
        phx-submit="regenerate_sun_down"
        id="notification-regenerate-form"
        class="flex flex-col gap-3 sm:flex-row sm:items-end"
      >
        <label class="flex-1 space-y-1">
          <span class="block text-sm font-medium text-zinc-700 dark:text-zinc-200">
            {gettext("Date")}
          </span>
          <input
            type="date"
            name="date"
            min={Date.to_iso8601(@min_date)}
            max={Date.to_iso8601(@max_date)}
            required
            class="block w-full rounded-md border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-900 px-3 py-2 text-sm text-zinc-900 dark:text-white focus:border-emerald-500 focus:ring-emerald-500"
          />
        </label>

        <button
          type="submit"
          class="inline-flex items-center gap-2 rounded-lg bg-emerald-500 hover:bg-emerald-400 px-4 py-2 text-sm font-semibold text-zinc-950 transition"
        >
          <.icon name="hero-arrow-path" class="h-4 w-4" />
          {gettext("Regenerate summary")}
        </button>
      </.form>
    </div>
    """
  end
end
