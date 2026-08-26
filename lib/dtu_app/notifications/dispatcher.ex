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
  alias DtuApp.Emails.{ConnectionEmail, SunDownEmail, SunUpEmail}
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
  # The push payload shape stays byte-identical to what producers
  # already pass to `Notifications.broadcast/2`; we re-key the event
  # through `Push.native_enabled?/2`'s string-keyed clause (which
  # atom and string payloads both resolve through, because the
  # public predicate has explicit clauses for both).
  defp try_push(%User{} = user, event, payload) do
    try do
      Gettext.with_locale(DtuAppWeb.Gettext, user.locale || "en", fn ->
        Push.deliver(user, payload)
      end)
    rescue
      e ->
        Logger.warning(
          "[dispatcher] push failed event=#{event} user=#{user.id} reason=#{Exception.message(e)}"
        )

        :ok
    end
  end

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
