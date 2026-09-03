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
  """
  @spec fire(User.t(), String.t(), map()) :: :ok
  def fire(%User{} = user, event, payload) when is_map(payload) do
    channel = user.notification_channel || "push"

    # Per-event preference gate. Mirrors the old
    # `Notifications.native_push_enabled?/2` semantics: if the user
    # has the event toggle off, the entire fire (push + history) is
    # silent. Email is a separate channel; the dispatcher still
    # honours "both" but only fires the email side when the user
    # opted into the event at all (otherwise we'd be sending an
    # unsolicited email to a user who said "no thanks" to the
    # notification).
    push_enabled? = Push.native_enabled?(user, %{"event" => event})

    cond do
      channel in ["push", "both"] and push_enabled? ->
        try_push(user, event, payload)

      true ->
        :ok
    end

    cond do
      channel in ["email", "both"] and push_enabled? ->
        try_email(user, event, payload)

      true ->
        :ok
    end

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
  defp try_push(%User{} = user, event, payload) do
    wire = push_payload(event, payload)

    try do
      Gettext.with_locale(DtuAppWeb.Gettext, user.locale || "en", fn ->
        Push.deliver(user, wire)
      end)
    rescue
      e ->
        Logger.warning(
          "[dispatcher] push failed event=#{event} user=#{user.id} reason=#{Exception.message(e)}"
        )

        :ok
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
    else
      try do
        Gettext.with_locale(DtuAppWeb.Gettext, user.locale || "en", fn ->
          {html, text} = render_email(user, event, payload)

          email =
            Swoosh.Email.new()
            |> Swoosh.Email.to(user.email)
            |> Swoosh.Email.from(mail_from())
            |> Swoosh.Email.subject(payload.title)
            |> Swoosh.Email.html_body(html)
            |> Swoosh.Email.text_body(text)

          case Mailer.deliver(email) do
            {:ok, _meta} ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "[dispatcher] email send failed event=#{event} user=#{user.id} reason=#{inspect(reason)}"
              )

              :ok
          end
        end)
      rescue
        e ->
          Logger.warning(
            "[dispatcher] email render/raise event=#{event} user=#{user.id} reason=#{Exception.message(e)}"
          )

          :ok
      end
    end
  end

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
end
