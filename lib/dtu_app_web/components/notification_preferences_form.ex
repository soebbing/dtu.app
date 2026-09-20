defmodule DtuAppWeb.NotificationPreferencesForm do
  @moduledoc """
  The `<.form id="notifications-form">` block on the Notifications
  page. Lets the user opt in/out of each notification event type
  and pick the delivery channel.

  Bundles five layers:

    1. **Form chrome** — the `<.form phx-submit="save"
       id="notifications-form">` wrapper with the rounded-xl card
       classes. The form is always rendered, regardless of browser
       permission state, so the user's preferences are saved even
       before they enable notifications.

    2. **Four event-type toggles** — one `<label>` per `:notify_*`
       field with a title and a one-line description. The four
       toggles (`:notify_dtu_connection`, `:notify_sun_down`,
       `:notify_sun_up`, `:notify_yield_anomaly`) are structurally
       identical: checkbox + label + description. Rendering them
       inline (vs. a separate per-toggle component) keeps the
       form's shape obvious and avoids a 4× abstraction overhead
       for ~60 lines of HTML.

    3. **Channel radio group** — a 3-button segmented control
       (push / email / both) under the "Deliver via" header.
       Uses the `peer-checked:` Tailwind variant so the selected
       radio's `<span>` lights up without JS. The radios are
       `sr-only` (visually hidden) — the labels are the visible
       targets. The selected radio's `checked` attribute is bound
       to `@form[:notification_channel].value`.

    4. **Email-not-confirmed warning** — a conditional amber inset
       rendered when the user picked email or both AND the user's
       `confirmed_at` is `nil`. Prevents silent-drop of email
       notifications when the address isn't verified yet.

    5. **Save button** — the `<.button phx-disable-with={...}>`
       at the bottom. `phx-disable-with` swaps the label to
       "Saving…" for the duration of the request so double-clicks
       don't double-submit.

  Was the inline `<.form id="notifications-form">` block in
  `notifications_live.html.heex` (formerly lines 152-283,
  ~131 lines). Extracted so the four event toggles, the
  segmented channel control, and the email-not-confirmed
  warning branch each get their own stable render-only
  test surface — the warning branch in particular is a
  silently-no-ops-otherwise bug if the condition flips.
  """

  use DtuAppWeb, :html

  attr :form, :map,
    required: true,
    doc: """
    The `Phoenix.HTML.Form` built from
    `Accounts.User.notification_settings_changeset/2`. The
    component reads:

      * `form[:notify_dtu_connection]`, `form[:notify_sun_down]`,
        `form[:notify_sun_up]`, `form[:notify_yield_anomaly]` —
        one checkbox each, value drives the `checked` state.
      * `form[:notification_channel]` — a 3-value radio whose
        `.name` and `.value` are used to render the segmented
        control's `<input type="radio">` elements.

    The LV builds the form via
    `assign_form(Accounts.User.notification_settings_changeset(user, %{}))`
    on mount and on every successful save.
    """

  attr :confirmed?, :boolean,
    required: true,
    doc: """
    Whether the current user has confirmed their email address.
    When `false`, an amber inset is rendered below the channel
    selector whenever the picked channel is `"email"` or `"both"`
    — email notifications are silently dropped on unconfirmed
    addresses, so the warning prevents a confusing "I picked
    email but nothing arrives" UX.
    """

  def notification_preferences_form(assigns) do
    ~H"""
    <.form
      for={@form}
      phx-submit="save"
      id="notifications-form"
      class="space-y-4 rounded-xl border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-800 p-6"
    >
      <h2 class="text-lg font-semibold text-zinc-900 dark:text-white">
        {gettext("What to notify about")}
      </h2>

      <label class="flex items-start gap-3 cursor-pointer">
        <.input
          type="checkbox"
          field={@form[:notify_dtu_connection]}
          class="mt-1"
        />
        <span>
          <span class="block text-sm font-medium text-zinc-900 dark:text-white">
            {gettext("Inverter connection state")}
          </span>
          <span class="block text-sm text-zinc-500 dark:text-zinc-400">
            {gettext(
              "A notification whenever an inverter goes offline or comes back online. The notification names the inverter."
            )}
          </span>
        </span>
      </label>

      <label class="flex items-start gap-3 cursor-pointer">
        <.input
          type="checkbox"
          field={@form[:notify_sun_down]}
          class="mt-1"
        />
        <span>
          <span class="block text-sm font-medium text-zinc-900 dark:text-white">
            {gettext("End-of-day summary")}
          </span>
          <span class="block text-sm text-zinc-500 dark:text-zinc-400">
            {gettext(
              "When the sun goes down, get today's total yield compared to yesterday and the peak power from today compared to yesterday, if yesterday's data is available."
            )}
          </span>
        </span>
      </label>

      <label class="flex items-start gap-3 cursor-pointer">
        <.input
          type="checkbox"
          field={@form[:notify_sun_up]}
          class="mt-1"
        />
        <span>
          <span class="block text-sm font-medium text-zinc-900 dark:text-white">
            {gettext("Morning sun-up ping")}
          </span>
          <span class="block text-sm text-zinc-500 dark:text-zinc-400">
            {gettext(
              "A cheerful one-off when your panels start producing for the day. Fires once per day, in your local timezone, the moment your fleet wakes up."
            )}
          </span>
        </span>
      </label>

      <label class="flex items-start gap-3 cursor-pointer">
        <.input
          type="checkbox"
          field={@form[:notify_yield_anomaly]}
          class="mt-1"
        />
        <span>
          <span class="block text-sm font-medium text-zinc-900 dark:text-white">
            {gettext("Mid-day yield collapse")}
          </span>
          <span class="block text-sm text-zinc-500 dark:text-zinc-400">
            {gettext(
              "A heads-up if your fleet stops producing for over 1 hour while the sun is up — even when no inverter reports an outage. Fires once per local day."
            )}
          </span>
        </span>
      </label>

      <div class="mt-6 border-t border-zinc-200 dark:border-zinc-700 pt-4">
        <h3 class="text-sm font-semibold text-zinc-900 dark:text-white">
          {gettext("Deliver via")}
        </h3>
        <p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
          {gettext(
            "Pick how you want to receive the notifications above. Email is a good fallback if native push is flaky on your device."
          )}
        </p>

        <div
          class="mt-3 inline-flex rounded-lg border border-zinc-200 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-900 p-1"
          role="radiogroup"
          aria-label={gettext("Deliver via")}
        >
          <%= for {value, label} <- [{"push", gettext("Notification")}, {"email", gettext("Email")}, {"both", gettext("Both")}] do %>
            <label class="cursor-pointer">
              <input
                type="radio"
                name={@form[:notification_channel].name}
                value={value}
                checked={@form[:notification_channel].value == value}
                class="peer sr-only"
              />
              <span class="block rounded-md px-3 py-1.5 text-sm font-medium text-zinc-600 dark:text-zinc-400 peer-checked:bg-white dark:peer-checked:bg-zinc-800 peer-checked:text-zinc-900 dark:peer-checked:text-white peer-checked:shadow-sm transition">
                {label}
              </span>
            </label>
          <% end %>
        </div>

        <%= if @form[:notification_channel].value in ["email", "both"] and not @confirmed? do %>
          <p class="mt-3 rounded-md border border-amber-300 bg-amber-50 dark:border-amber-700 dark:bg-amber-950/40 p-2 text-xs text-amber-800 dark:text-amber-200">
            {gettext(
              "You picked email delivery, but your email address isn't confirmed. Visit account settings to confirm it, otherwise email notifications will be skipped."
            )}
          </p>
        <% end %>
      </div>

      <div class="flex justify-end">
        <.button
          class="inline-flex items-center gap-2 rounded-lg bg-emerald-500 hover:bg-emerald-400 px-4 py-2 text-sm font-semibold text-zinc-950 transition"
          phx-disable-with={gettext("Saving…")}
        >
          {gettext("Save preferences")}
        </.button>
      </div>
    </.form>
    """
  end
end
