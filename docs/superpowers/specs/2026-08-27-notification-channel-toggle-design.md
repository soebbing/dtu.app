# Notification channel toggle (push / email / both)

**Status:** Approved design
**Branch:** `feature/notification-channel-toggle`
**Date:** 2026-08-27
**Calver tag:** TBD on merge (likely `2026-08-27-2`)

## 1. Problem

Native web-push delivery is the only channel for in-app notifications today, and
the user's pre-existing `notification-delivery-silent-drop` memory already
documents that iOS-PWA installs, dedup TTL, and stale push endpoints make push
delivery flaky in the field. We need an email fallback that fires the same
events with richer content (especially a real chart for the end-of-day
summary), without removing push.

## 2. Goals & non-goals

**Goals**

- Per-user channel choice: `push`, `email`, or `both`.
- Email versions of all three current notification events: `dtu_connection`,
  `sun_up`, `sun_down`.
- The `sun_down` email carries the same four panels as the in-page dashboard
  (today's yield, yesterday's yield, peak power, peak yesterday) plus an
  inline SVG of today's power curve.
- All email content respects `users.locale` — English, German, and French.
- Existing users keep their current behavior unchanged by default.

**Non-goals**

- Per-event channel choice (always push+email or push only). We keep the
  three event on/off checkboxes independent; the channel is global.
- Digest / batched emails. One email per fired event.
- User-controlled email templates. Layout is owned by the app.
- Resending or retrying failed emails beyond Swoosh's per-attempt logging.
- Adding SMS, Telegram, or webhook channels.

## 3. UX

In `NotificationsLive`, immediately below the three existing
`<.input type="checkbox">` rows:

```
☑ Inverter connection state
☑ End-of-day summary
☑ Morning sun-up ping

Deliver via:  [Notification] [Email] [Both]
              ●────────────
```

A segmented control (single select) under the heading "Deliver via:" / `dgettext("notifications", "Deliver via")`. Three options, mutually exclusive. Default for new users and existing users on migration is `:push`.

If the user picks `Email` or `Both` but has no confirmed email address, we render an inline warning above the toggle (not a hard block) pointing them to the account settings page. The form still saves the selection; the email send will skip and log a warning.

## 4. Data model

### `users` — new column

```elixir
# migration: add_notification_channel.exs
alter table(:users) do
  add :notification_channel, :string, default: "push", null: false
end

# also tighten existing settings changeset
create index(:users, [:notification_channel])   # for fan-out queries, future use
```

`null: false` with default `"push"` so the migration is safe to run against
existing rows without `update_all`. The column is a string so we can keep
extending without further migrations; we validate it to the known set in the
schema (`@valid_channels ~w(push email both)`).

### `User` schema changes (`lib/dtu_app/accounts/user.ex`)

```elixir
@valid_channels ~w(push email both)

def notification_settings_changeset(user, attrs) do
  user
  |> cast(attrs, [:notify_dtu_connection, :notify_sun_down, :notify_sun_up,
                  :notification_channel])
  |> validate_inclusion(:notification_channel, @valid_channels)
end
```

### `notifications` history table

Unchanged. We add a `channel` field that records which channels were
attempted:

```elixir
# migration: add_channel_to_notifications.exs
alter table(:notifications) do
  add :channel, :string, default: "push", null: false
end
```

Possible values: `"push"`, `"email"`, `"both"`. We only insert one row per
fire (not one per channel) — it records the user's intent at fire time.

## 5. Dispatcher

`DtuApp.Notifications.broadcast/2` stays the single entry point for both
producers (push path) and the new email path. We extend it to accept the
full payload (instead of computing strings inside the dispatcher, the
producers pass them already localized), and we call into a new
`DtuApp.Notifications.Dispatcher` module that knows how to split delivery
across channels.

```elixir
# lib/dtu_app/notifications/dispatcher.ex
defmodule DtuApp.Notifications.Dispatcher do
  @moduledoc """
  Splits a single notification fire across the user's chosen channels.
  Push fan-out and email send are independent and best-effort — neither
  failure blocks the other, and neither raises back to the producer.
  """

  alias DtuApp.{Mailer, Push}
  alias DtuApp.Emails.{Layout, SunDownEmail, SunUpEmail, ConnectionEmail}
  alias DtuAppWeb.Gettext

  @doc """
  fire(user, event, payload)
    payload: %{
      title:         gettext-resolved title,
      body:          gettext-resolved body paragraph list,
      event:         "dtu_connection" | "sun_up" | "sun_down",
      tag:           deduplication tag (event-specific),
      # sun_down-only keys:
      today_yield_kwh: float | nil,
      yesterday_yield_kwh: float | nil,
      peak_power_w: integer | nil,
      peak_yesterday_w: integer | nil,
      chart_svg:      safe-rendered SVG string | nil,
      dashboard_path: "/dashboard" | dtu-scoped,
      # dtu_connection-only:
      dtu_name: String.t() | nil,
      status:  "online" | "offline" | nil,
      since:   DateTime.t() | nil
    }
  """
  def fire(user, event, payload) do
    channel = user.notification_channel || "push"

    cond do
      channel in ["push", "both"] ->
        deliver_push(user, event, payload)

      true ->
        :ok
    end

    cond do
      channel in ["email", "both"] ->
        deliver_email(user, event, payload)

      true ->
        :ok
    end

    :ok
  end

  defp deliver_push(user, event, payload) do
    if Push.native_enabled?(user, %{"event" => event}) do
      Gettext.with_locale(DtuAppWeb.Gettext, user.locale || "en", fn ->
        Push.deliver(user, %{
          "event" => event,
          "title" => payload.title,
          "body"  => Enum.join(payload.body, "\n"),
          "tag"   => payload.tag,
          "date"  => DateTime.utc_now() |> DateTime.to_iso8601()
        })
      end)
    else
      :ok
    end
  end

  defp deliver_email(user, event, payload) do
    if is_nil(user.email_confirmed_at) do
      Logger.warning(
        "skipping email for user=#{user.id} event=#{event}: email not confirmed"
      )
      :ok
    else
      Gettext.with_locale(DtuAppWeb.Gettext, user.locale || "en", fn ->
        {html, text} = build_email(user, event, payload)
        Mailer.deliver(
          user.email,
          payload.title,
          html,
          text
        )
      end)
    end
  end

  defp build_email(user, "sun_down", p),
    do: SunDownEmail.render(user, p)
  defp build_email(user, "sun_up", p),
    do: SunUpEmail.render(user, p)
  defp build_email(user, "dtu_connection", p),
    do: ConnectionEmail.render(user, p)
end
```

The existing `DtuApp.Push.native_enabled?/2` is hoisted from
`DtuApp.Notifications` (where it was private) and made public. The push path
stays byte-for-byte equivalent to today's behaviour. The
`Notifications.broadcast/2` function gets a thin shim that calls
`Dispatcher.fire/3` for backwards compatibility (existing tests).

## 6. Producers

Each producer already runs inside `Gettext.with_locale/2`. We keep that and
extend the payload they build.

### `DtuApp.Notifications.SunDownNotifier` — change

Today the producer builds the title and body strings inline and passes them
to `Notifications.broadcast/2`. We keep the existing `build_payload/2` and
`body_for/2` helpers; we change `try_fire/1` to construct the dispatch
payload instead of a flat keyword list:

```elixir
data    = build_payload(user, now)               # existing
title   = gettext("End-of-day summary")
body    = body_for(data, gettext) |> List.wrap()  # today's one-liner

dispatch_payload = %{
  event:               "sun_down",
  title:               title,
  body:                body,
  tag:                 "sun_down_#{user.id}",
  today_yield_kwh:     data.today_yield_kwh,
  yesterday_yield_kwh: data.today_yield_yesterday_kwh,
  peak_power_w:        data.peak_power_w,
  peak_yesterday_w:    data.peak_power_yesterday_w,
  chart_svg:           SunDownChart.render(user, Date.utc_today()),
  dashboard_path:      "/dashboard"
}

Dispatcher.fire(user, "sun_down", dispatch_payload)
```

`build_email_chart_svg/1` queries
`Devices.list_day_chart_data_for_dashboard(user, today, dtu_ids)` and renders
a lightweight SVG. See §7.

### `DtuApp.Notifications.SunUpNotifier` — change

Pass `event: "sun_up"`, `title: gettext("The sun is up!")`, `body: [gettext("Your panels started producing power.")]`, `tag: "sun_up_#{user.id}"`. No chart, just a friendly ping.

### `DtuApp.Notifications.DtuConnectionNotifier` — change

Pass `event: "dtu_connection"`, `dtu_name`, `status`, `since`, `tag: "dtu_#{dtu.id}_#{status}"`, plus a translated title and body. No chart.

## 7. Inline SVG chart for the `sun_down` email

### Goals

- Reuse the existing chart-data path so we don't fork the bucketing logic.
- Stay inside the email-client envelope: no external CSS, no JS, no `<img>`
  with `src=cid:` (Swoosh + many clients don't inline images cleanly), no
  data URLs (some clients strip them).
- One `viewBox="0 0 800 280"` SVG, light theme only — most clients strip
  `<style>` tags or ignore `@media (prefers-color-scheme)` in email.
- Single emerald line for the day's power curve; no per-inverter overlay.

### Where it lives

`lib/dtu_app/emails/sun_down_chart.ex`:

```elixir
defmodule DtuApp.Emails.SunDownChart do
  alias DtuApp.Devices

  @viewbox_w 800
  @viewbox_h 280
  @padding_left 32
  @padding_right 16
  @padding_top 16
  @padding_bottom 32

  def render(user, today \\ Date.utc_today()) do
    dtus   = DtuApp.Dtus.list_for_user(user)             # existing helper
    points = Devices.list_day_chart_data_for_dashboard(user, today, dtus)

    path_d = build_path(points)
    ticks  = build_axis_ticks(points)

    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{@viewbox_w} #{@viewbox_h}" role="img" aria-label="Today's power curve">
      <rect x="0" y="0" width="#{@viewbox_w}" height="#{@viewbox_h}" fill="#f8fafc" stroke="#e2e8f0"/>
      #{ticks}
      <path d="#{path_d}" fill="none" stroke="#10b981" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>
      <text x="#{@padding_left}" y="#{@viewbox_h - 8}" font-family="ui-sans-serif, system-ui, sans-serif" font-size="11" fill="#64748b">00:00</text>
      <text x="#{@viewbox_w - @padding_right}" y="#{@viewbox_h - 8}" font-family="ui-sans-serif, system-ui, sans-serif" font-size="11" fill="#64748b" text-anchor="end">24:00</text>
    </svg>
    """
  end

  defp build_path(points) do
    max_w = Enum.max_by(points, & &1.power).power |> max(1)
    n = length(points) - 1

    points
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {p, i} ->
      x = @padding_left + i * (@viewbox_w - @padding_left - @padding_right) / n
      y = @viewbox_h - @padding_bottom - p.power / max_w * (@viewbox_h - @padding_top - @padding_bottom)
      "L#{Float.round(x, 1)},#{Float.round(y, 1)}"
    end)
    |> then(fn cmd -> "M" <> cmd end)
  end

  defp build_axis_ticks(_points), do: ""  # keep simple for v1
end
```

V1 keeps the chart deliberately plain. We'll iterate to add gridlines + a peak marker in a follow-up if users ask for it. **Goal of v1: prove the pipeline works.**

### Why a separate renderer

The dashboard's chart renderer (`DashboardLive`) is tuned for the
LiveView/JS lifecycle, with debounced redraws, JS hooks, and per-inverter
overlay. Lifting it into a one-shot email path means dragging along
dependencies that have no business in email. A 100-line focused renderer is
easier to test, easier to read, and easier to evolve independently.

## 8. Email templates

Three modules under `lib/dtu_app/emails/`:

- `ConnectionEmail` — small: inverter name, status, timestamp.
- `SunUpEmail` — small: cheerful one-liner.
- `SunDownEmail` — full: 4 stat panels + chart + dashboard CTA.

Each module exposes `render(user, payload) :: {html, text}`. HTML goes
through `Emails.Layout.render/1` (the existing layout, with `:lang =>
user.locale`); text is hand-written plain text. We do **not** use
`Phoenix.HTML` for the chart panel — that mixes the chart data into the
template. Instead, `SunDownEmail.render/2` builds the `:body` list as a list
of raw-HTML strings (panels + SVG) and `Layout.render` interpolates them.
Plain-text path strips tags via `HtmlSanitizeEx.strip_tags/1`.

Sample `SunDownEmail.render/2`:

```elixir
def render(user, p) do
  html_body = [
    stats_panel(p),
    "<p style=\"margin:24px 0 8px;font-size:13px;color:#475569;\">#{escape(gettext("Today's power curve"))}</p>",
    p.chart_svg
  ]

  text_body = [
    stats_panel_text(p),
    "",
    gettext("View the live dashboard: %{url}", url: dashboard_url(user))
  ]

  {html, _} = Layout.render(
    title: p.title,
    greeting: greeting_for(user),
    body: html_body,
    button: %{label: gettext("View dashboard"), url: dashboard_url(user)},
    note: gettext("You're getting this email because you enabled End-of-day summaries."),
    lang: user.locale || "en"
  )

  text = Layout.render_text(
    title: p.title,
    body: text_body,
    lang: user.locale || "en"
  )

  {html, text}
end
```

We extend `Layout.render/1` with a `Layout.render_text/1` sibling that
returns only the plain-text body — same keyword shape as `render/1`, minus
`:button` (a plain-text CTA is a URL on its own line). Centralising it
means we can rewrite one place instead of every email module.

## 9. i18n

All email strings live in `priv/gettext/{en,de,fr}/LC_MESSAGES/default.po`
under the existing `notifications` and new `emails` domains. We do not
introduce a separate `.po` file for emails — the volume doesn't justify the
friction.

Email subject = `payload.title` already resolved in the producer's locale.
Email body = producer's `gettext(...)` calls already resolved in locale.
Chart's `<text>` axis labels are pre-resolved strings handed to
`SunDownChart.render/3`.

We add a smoke test that renders every email module under each locale and
asserts the returned HTML contains a recognizable locale-specific substring
(e.g., the German "Heute" or the French "Aujourd'hui") — this catches
regressions where a new gettext string was added to a producer but the
email template was not updated.

## 10. Error handling

| Failure                                   | Behavior                                           |
|-------------------------------------------|----------------------------------------------------|
| Swoosh can't reach SMTP                   | logged, producer continues (best-effort)           |
| User has no confirmed email + email mode  | logged warn, no email sent                         |
| User has no push subscription + push mode | push fan-out silently does nothing (today's path)  |
| Both channels fail                        | producer doesn't know — `notifications` row exists |
| Mailer raises                             | caught in `Dispatcher.deliver_email/3`, logged     |
| Chart query fails                         | email sends with chart omitted, body says "chart unavailable" |

We add a thin try/rescue in `Dispatcher.deliver_email/3` so a malformed
payload or template doesn't crash the producer process. Producer crashes
would silently drop the in-page PubSub broadcast for *all* users, which is
the failure mode we want to avoid most.

## 11. Tests

### Unit

- `Notifications.DispatcherTest` — table-driven over
  `(user, channel, event)`, asserts which side-effects fire.
- `Emails.SunDownEmailTest` — renders under `en/de/fr` for a seeded user
  with chart data; asserts locale string + presence of `<svg>` + presence
  of all four panels.
- `Emails.SunDownChartTest` — golden-test the SVG path string for a
  fixed input.
- `UserNotificationSettingsChangesetTest` — invalid `notification_channel`
  is rejected; default is `"push"`.

### Integration

- Extend `NotificationsIntegrationTest` (or its moral equivalent) with a
  user set to `:both`: fire a `sun_down`, assert `notifications` row +
  asserted email was sent via `Bamboo.TestAdapter` (already configured).
- Assert push fan-out did not regress: today a `Bamboo.TestAdapter`
  equivalent for push (`Push.deliver/2` is mocked); we keep one
  `Push.deliver/2` mock test that asserts the same args as today.

### E2E

Add a Playwright spec for the `/notifications` page: toggle between the
three segmented-control options, save, reload, assert the choice persisted.

## 12. Migration plan

1. Migration `add_notification_channel_to_users.exs` adds the column with
   default `"push"`. Safe on existing rows.
2. Migration `add_channel_to_notifications.exs` adds the `channel` column
   with default `"push"`. Backfill via `update_all` is unnecessary because
   we want *historical* rows to read `"push"` even if the user later
   switched to `:both`.
3. Existing users see no behavior change. They have to opt in by visiting
   `/notifications` and selecting `Email` or `Both`.

## 13. Out of scope / future work

- Per-event channel choice (always coupled for v1).
- Email digest mode (one email per day, summary of all events).
- iCalendar attachments so `sun_down` shows up in users' calendars.
- Reply-to / unsubscribe headers — desirable but the email is
  transactional and from a no-reply address; v2.
- Resend-on-bounce logic; SMTP bounce handling isn't a problem today
  because the app is single-tenant.

## 14. Risks

- **Push regression risk.** The push path is the only production-tested
  path today. Mitigation: keep the push call byte-identical, add a
  regression test before changing the dispatcher.
- **SMTP not configured in dev.** Today no dev sends mail. Mitigation:
  keep `Bamboo.TestAdapter` in test config and add an explicit
  `DtuApp.Mailer.deliver/4` wrapper in test mode that records sent emails.
- **SVG in email clients.** Outlook (Windows) historically refuses SVG.
  Mitigation: render an HTML fallback (`<img alt="Today's power curve">`
  with a static PNG generated on the fly) — **deferred**. V1 ships with
  SVG only and we monitor for user complaints; if Outlook shows up we'll
  add the PNG fallback.
- **i18n drift.** Producers and email templates share strings. Mitigation:
  the smoke test in §11.