defmodule DtuApp.Notifications.Dispatcher do
  @moduledoc """
  Single fan-out point for one notification fire. Splits a fire
  across the user's chosen channels: native Web Push, transactional
  email, or both. Push and email are independent — neither failure
  blocks the other, and neither raises back to the caller.

  Routing logic:

    * `user.notification_channel == "push"`  → push only
    * `user.notification_channel == "email"`  → email only
    * `user.notification_channel == "both"`  → push + email
    * Any other value (shouldn't happen — schema validates it) →
      treat as `"push"` so users never silently lose notifications.

  Both paths are best-effort: `Push.deliver/2` is called inside a
  try/rescue; the email sender also runs inside a try/rescue so a
  malformed template can't crash the producer process.

  Locale handling: callers are expected to wrap their gettext in
  `Gettext.with_locale/2` against `user.locale`. We re-resolve the
  locale inside both the push and email wrappers because the email
  path runs as a fresh function call — the wrapping `with_locale`
  doesn't survive the producer process boundary.
  """

  use Gettext, backend: DtuAppWeb.Gettext

  require Logger

  alias DtuApp.Accounts.User
  alias DtuApp.Emails.{ConnectionEmail, Layout, SunDownEmail, SunUpEmail, YieldAnomalyEmail}
  alias DtuApp.Mailer
  alias DtuApp.Notifications.Notification
  alias DtuApp.Push
  alias DtuApp.Repo

  @telemetry_event [:dtu_app, :notifications, :dispatch]

  @doc """
  Fire a notification across the user's chosen channels.

  `payload` MUST contain at least:
    * `:event` — one of "dtu_connection", "sun_up", "sun_down"
    * `:title` — already-localized subject line
    * `:body`  — list of already-localized paragraphs
    * `:tag`   — OS-level notification coalescing tag

  For `sun_down` it additionally expects:
    * `:today_yield_kwh`, `:yesterday_yield_kwh`,
      `:peak_power_w`, `:peak_yesterday_w`, `:chart_svg`,
      `:dashboard_path`

  For `dtu_connection` it additionally expects:
    * `:dtu_name`, `:status`, `:since`

  Returns `:ok` once both paths have been attempted. Per-channel
  failures are logged and swallowed.

  ## Push → email fallback

  `user.notification_channel` defaults to `"push"` (the schema
  default) and `Push.deliver/2` reports `delivered: 0` whenever
  no live banner was actually shown — VAPID not configured, the
  user has zero `PushSubscriptions` rows, or every live row got a
  404/410 mid-fleet-revoke. The user's chosen channel is `push`,
  so the cond-clause that would otherwise fire email never runs,
  and the notification evaporates.

  To stop that, when `channel == "push"` and the push fan-out
  delivered zero banners we additionally fire the email path —
  gated by the same `user.confirmed_at != nil` check `try_email/3`
  already enforces for explicit `"email"` / `"both"` channels
  (so a typo'd signup address still can't be mailed). The
  `try_email/3` `try/rescue` swallows any template-render or
  Swoosh-transport failure, so the fallback is strictly best-
  effort; the user with no confirmed email sees the same one-row
  push history either way.

  ## Force-fire (preference bypass)

  `opts[:force] == true` skips the per-event preference gate
  (`Push.native_enabled?/2` asking "did the user opt into THIS
  event?"). Channel routing + email fallback + history row
  insert still run as normal. The single caller exercising this
  today is the `/notifications` regenerate form, which is a
  USER-INITIATED fire — a user who explicitly clicked the button
  should get a summary even if they previously opted out of the
  *automatic* daily fire (otherwise the "Summary sent" flash
  would lie: no push, no email, no history row). All other
  producers (the daily sun_down / sun_up / yield_anomaly /
  dtu_connection producers + the /notifications "Test
  notification" button) keep the gate as the default.
  """
  @spec fire(User.t(), String.t(), map(), keyword()) :: :ok
  def fire(%User{} = user, event, payload, opts \\ []) when is_map(payload) do
    channel = user.notification_channel || "push"

    # Per-event preference gate. Mirrors the old
    # `Notifications.native_push_enabled?/2` semantics: if the user
    # has the event toggle off, the entire fire (push + history) is
    # silent. Email is a separate channel; the dispatcher still
    # honours "both" but only fires the email side when the user
    # opted into the event at all (otherwise we'd be sending an
    # unsolicited email to a user who said "no thanks" to the
    # notification).
    #
    # `opts[:force]` bypasses this gate for user-initiated fires
    # (currently the /notifications regenerate button) — see the
    # "Force-fire" section in the moduledoc for the contract.
    push_enabled? =
      if Keyword.get(opts, :force, false) do
        true
      else
        Push.native_enabled?(user, %{"event" => event})
      end

    push_should_fire? = channel in ["push", "both"] and push_enabled?

    push_delivered =
      if push_should_fire? do
        try_push(user, event, payload)
      else
        0
      end

    # Email routing. Three reasons to send:
    #   1. The user picked `channel in ["email", "both"]` and the
    #      event is enabled (explicit email path).
    #   2. The user picked `channel == "push"` but the push fan-out
    #      delivered zero banners — fall back to email so the
    #      notification doesn't silently disappear (the case that
    #      caused the missing-connection-notifications report).
    # `try_email/3` enforces `user.confirmed_at != nil`, so case 2
    # never emails a typo'd signup address — a user with no
    # confirmed email still gets the one-row history and no banner.
    email? =
      cond do
        channel in ["email", "both"] and push_enabled? ->
          true

        channel == "push" and push_should_fire? and push_delivered == 0 ->
          true

        true ->
          false
      end

    if email?, do: try_email(user, event, payload)

    # Record the history row (with `channel` = user's chosen
    # channel at fire time). Skipped when the per-event gate is
    # off — a user with `notify_sun_down: false` should see no
    # history rows for sun_down. Wrapped in try/rescue so a DB
    # hiccup never blocks fan-out. One row per fire, NOT one row
    # per channel — the column records the user's choice, not
    # which paths actually fired.
    if push_enabled? do
      try do
        {:ok, _} =
          %Notification{}
          |> Notification.changeset(user, build_history_attrs(payload, channel))
          |> Repo.insert()
      rescue
        e ->
          Logger.warning(
            "[dispatcher] history record failed user=#{user.id} reason=#{Exception.message(e)}"
          )

          :ok
      end
    end

    :ok
  end

  # Builds the attrs map for the history insert. Two normalisations:
  #
  #   1. The full payload (including `body`) is stored as `:payload`
  #      jsonb so future drill-down UIs can read raw event-specific
  #      keys (today_yield_kwh, peak_power_w, etc.) without a schema
  #      migration. `body` is also lifted to its own column for the
  #      history-page summary line.
  #
  #   2. `body` is coerced to a string (column is `:string`). Producers
  #      currently pass single strings (`gettext(...)` returns a
  #      `binary`); the email-renderer pipeline expects a list of
  #      paragraphs. We accept either shape and write the joined
  #      form to the DB.
  defp build_history_attrs(payload, channel) do
    body = stringify_body(payload[:body] || payload["body"])

    payload
    |> Map.put(:payload, payload)
    |> Map.put(:body, body)
    |> Map.put(:channel, channel)
  end

  defp stringify_body(b) when is_binary(b), do: b
  defp stringify_body(b) when is_list(b), do: Enum.join(b, "\n\n")
  defp stringify_body(_), do: ""

  # Push path. `Push.native_enabled?/2` does the per-event preference
  # gate (asks "did the user opt into native push for THIS event?"),
  # so a user with `notify_sun_down == false` routes through this
  # branch but is silently skipped — exactly mirroring the
  # pre-dispatcher `native_push_enabled?/2` semantics.
  #
  # We DO NOT forward the producer's full payload to `Push.deliver`.
  # The service worker (`priv/static/service-worker.js`) whitelist-
  # merges the inbound JSON keys (`title`, `body`, `tag`, `url`,
  # `icon`) and the `body` check is `typeof incoming.body === "string"`.
  # Producers (Task 7) emit `body` as a list of paragraphs — passing
  # the list unchanged would silently fall back to the SW's
  # `"New event from dtu.app"` default. We collapse the list to a
  # newline-joined string here, AND trim to exactly the SW contract
  # (5 keys: event, title, body, tag, date). Extra producer keys
  # (today_yield_kwh, chart_svg, dashboard_path, …) would be
  # silently dropped by the SW but cost wire bytes and are a tiny
  # info-leak vector, so we trim eagerly. Date is the push fire time.
  #
  # Returns the number of banners the push fan-out actually
  # delivered (0 when VAPID isn't configured, the user has zero
  # `PushSubscriptions` rows, every live row got a 404/410 mid-
  # fan-out, or the dispatch raised). `fire/3` reads this to
  # decide whether to fall through to the email path when the
  # user's chosen channel is `"push"` and we don't want them to
  # silently lose a notification — see the "Push → email fallback"
  # section on `fire/3`'s moduledoc.
  defp try_push(%User{} = user, event, payload) do
    wire = push_payload(event, payload)

    try do
      Gettext.with_locale(DtuAppWeb.Gettext, user.locale || "en", fn ->
        case Push.deliver(user, wire) do
          {:ok, %{delivered: delivered}} when delivered > 0 ->
            emit_dispatch_telemetry(user, event, "push", :push_ok)
            delivered

          {:ok, %{delivered: _zero}} ->
            # The "silent drop" case the dispatcher exists to guard
            # against: VAPID unconfigured, zero live subscriptions,
            # or every live row 404/410 mid-fan-out. The dispatcher's
            # email-fallback in `fire/3` keys on `delivered == 0` so
            # the user gets a banner one way or another; the counter
            # here surfaces the rate so an iOS subscription-rotation
            # regression doesn't quietly blow up overnight.
            emit_dispatch_telemetry(user, event, "push", :push_zero)
            0

          _unexpected ->
            # Any non-`{:ok, _}` shape (currently impossible per the
            # `Push.deliver/2` spec but defensive against future
            # library changes) is treated as a silent drop and
            # emitted under the same outcome for telemetry parity.
            emit_dispatch_telemetry(user, event, "push", :push_zero)
            0
        end
      end)
    rescue
      e ->
        Logger.warning(
          "[dispatcher] push failed event=#{event} user=#{user.id} reason=#{Exception.message(e)}"
        )

        emit_dispatch_telemetry(user, event, "push", :push_error)
        0
    end
  end

  @doc """
  Build the push payload the service worker consumes.

  Two normalisations from the producer-side shape:

    1. `body` is collapsed from a list of paragraphs to a single
       newline-joined string. The SW's whitelist merge gates on
       `typeof incoming.body === "string"` and falls back to its
       default `"New event from dtu.app"` otherwise — passing the
       raw list silently ships the wrong body to every banner.

    2. Only the SW contract keys are emitted
       (`event`, `title`, `body`, `tag`, `date`). Producer keys like
       `today_yield_kwh`, `chart_svg`, `dashboard_path` are dropped
       eagerly — the SW ignores them, but they cost bytes and are
       a small info-leak vector. `date` is the dispatch fire time.

  Pure function (no side effects) so tests can assert on the
  input→output contract directly. `nil` / non-list bodies
  defensively collapse to `""`; binary bodies pass through.
  Accepts both atom-keyed and string-keyed payloads (producers use
  atom keys; spec §5 used string keys).
  """
  @spec push_payload(String.t(), map()) :: map()
  def push_payload(event, payload) when is_map(payload) do
    %{
      event: event,
      title: payload[:title] || payload["title"],
      body: normalise_push_body(payload[:body] || payload["body"]),
      tag: payload[:tag] || payload["tag"],
      date: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp normalise_push_body(b) when is_binary(b), do: b
  defp normalise_push_body(b) when is_list(b), do: Enum.join(b, "\n")
  defp normalise_push_body(_), do: ""

  # Email path. Two guards gate this branch:
  #
  #   1. `confirmed_at != nil` — the user has verified their
  #      address. Without this we could deliver mail to a typo'd
  #      signup or a stale secondary address. Logged at `:warning`
  #      so the operator can spot mis-configured users.
  #   2. The whole send runs inside `try/rescue` so a malformed
  #      template or Swoosh transport hiccup never bubbles back to
  #      the producer (a `DtuConnection` reconnect storm should
  #      never crash the broker because the email module crashed).
  defp try_email(%User{} = user, event, payload) do
    if is_nil(user.confirmed_at) do
      Logger.warning(
        "[dispatcher] skipping email event=#{event} user=#{user.id}: email not confirmed"
      )

      emit_dispatch_telemetry(user, event, "email", :email_skipped)
    else
      try do
        Gettext.with_locale(DtuAppWeb.Gettext, user.locale || "en", fn ->
          {html, text, attachments} = render_email(user, event, payload)

          email =
            Swoosh.Email.new()
            |> Swoosh.Email.to(user.email)
            |> Swoosh.Email.from(mail_from())
            |> Swoosh.Email.subject(payload.title)
            |> Swoosh.Email.html_body(html)
            |> Swoosh.Email.text_body(text)
            |> add_attachments(attachments)

          case Mailer.deliver(email) do
            {:ok, _meta} ->
              emit_dispatch_telemetry(user, event, "email", :email_sent)
              :ok

            {:error, reason} ->
              Logger.warning(
                "[dispatcher] email send failed event=#{event} user=#{user.id} reason=#{inspect(reason)}"
              )

              emit_dispatch_telemetry(user, event, "email", :email_failed)
              :ok
          end
        end)
      rescue
        e ->
          Logger.warning(
            "[dispatcher] email render/raise event=#{event} user=#{user.id} reason=#{Exception.message(e)}"
          )

          emit_dispatch_telemetry(user, event, "email", :email_rescued)
          :ok
      end
    end
  end

  # Swoosh's `Email.attachment/2` only accepts a single attachment at a
  # time (no list-arity). Fold the caller's attachment list into the
  # email struct one attachment at a time. Empty list is a no-op.
  defp add_attachments(email, []), do: email

  defp add_attachments(email, attachments),
    do: Enum.reduce(attachments, email, &Swoosh.Email.attachment(&2, &1))

  defp render_email(user, "sun_down", p), do: SunDownEmail.render(user, p)
  defp render_email(user, "sun_up", p), do: SunUpEmail.render(user, p)
  defp render_email(user, "dtu_connection", p), do: ConnectionEmail.render(user, p)
  defp render_email(user, "yield_anomaly", p), do: YieldAnomalyEmail.render(user, p)

  # Synthetic "test" event fired from the `/notifications` LiveView
  # "Send test notification" button. Renders a minimal brand-styled
  # email with the producer-supplied title + body (already localised
  # by the LiveView handler under `Gettext.with_locale/2`). When the
  # user has `notification_channel in ["email", "both"]` AND no
  # browser notification permission, this is the path that actually
  # delivers the "is my setup working?" signal — without it the test
  # button silently no-ops for email-only users (the `rescue` in
  # `try_email/3` would otherwise swallow a `FunctionClauseError`).
  defp render_email(%User{} = user, "test", p) do
    title = p[:title] || p["title"] || ""
    body = List.wrap(p[:body] || p["body"] || [])

    Layout.render(
      title: title,
      greeting: gettext("Hi,"),
      body: body,
      lang: user.locale || "en"
    )
  end

  # Same shape as `DtuApp.Accounts.UserNotifier.mail_from/0`. We don't
  # reuse that helper because it's private and the notifier module
  # owns account-lifecycle email; the dispatcher owns notification
  # email. Same `MAIL_FROM` config key.
  defp mail_from do
    mail_from = Application.get_env(:dtu_app, :mail_from, "dtu.app <noreply@localhost>")

    case Regex.run(~r/^\s*(.*?)\s*<([^>]+)>\s*$/, mail_from, capture: :all_but_first) do
      [name, address] -> {name, address}
      _ -> mail_from
    end
  end

  # Emits one `:telemetry.execute/3` per dispatched channel. Each
  # helper (`try_push/3`, `try_email/3`) calls this exactly once per
  # fire with the outcome it observed. Tags carry the slice axes
  # useful for dashboards:
  #
  #   * `:event` — the producer event ("sun_down", "dtu_connection",
  #     "yield_anomaly", "test"). Tagged at the fire-event level so
  #     sun_down → push_zero can be split from dtu_connection →
  #     push_zero without parsing logs.
  #   * `:channel` — the path that actually fired ("push" or "email").
  #     The user's *chosen* `notification_channel` ("push", "email",
  #     "both") is one fire upstream and not tagged here; we already
  #     have the email-fallback telemetry from counting
  #     `channel="email"` events with `outcome=:email_sent` that
  #     follow a `channel="push", outcome=:push_zero` on the same
  #     fire, so the cross-tag cardinality is bounded.
  #   * `:outcome` — what happened (`:push_ok` / `:push_zero` /
  #     `:push_error` / `:email_sent` / `:email_failed` /
  #     `:email_skipped` / `:email_rescued`). Tagged so a rate of
  #     `:push_zero` per `event` answers "is iOS subscription
  #     rotation getting worse for sun_down?".
  #
  # `:user_id` stays in metadata (not tags) to keep tag cardinality
  # bounded — one tag tuple per `(event, channel, outcome)` rather
  # than one per user. Operators who want per-user slicing can attach
  # a handler that reads `:user_id` from metadata.
  #
  # The `count: 1` measurement is the inc-value the
  # `Telemetry.Metrics.counter/2` definition in
  # `DtuAppWeb.Telemetry.metrics/0` sums. Including `system_time`
  # lets percentile-style reporters (e.g. `last_value`) keep their
  # tags alive even when no `:telemetry.execute/3` matches the
  # event for a while.
  defp emit_dispatch_telemetry(%User{} = user, event, channel, outcome)
       when is_binary(channel) and is_atom(outcome) do
    # `event` is allowed to be nil / non-binary at this boundary:
    # `Notifications.broadcast/2` reads it from a producer-supplied
    # payload, and a producer that omits it (e.g. the broadcast-
    # isolation test in mqtt_broker_test.exs:2246) would otherwise
    # crash here even though the fire is a no-op for both push and
    # email. We coerce anything non-binary to "unknown" so the
    # metric tag stays a string — `outcome` already carries the
    # dispatch-decision signal, so the unknown bucket is a
    # low-cardinality safety net for misbehaving callers rather
    # than a new high-cardinality axis.
    :telemetry.execute(
      @telemetry_event,
      %{count: 1, system_time: System.system_time()},
      %{
        event: if(is_binary(event), do: event, else: "unknown"),
        channel: channel,
        outcome: outcome,
        user_id: user.id
      }
    )
  end
end
