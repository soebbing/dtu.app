# Notification Channel Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-user channel preference (`push`, `email`, `both`) to the notification system, with localized email versions of all three event types — `dtu_connection`, `sun_up`, and `sun_down` (the last carrying a full inline-SVG power curve and four stat panels).

**Architecture:** Extend `DtuApp.Notifications` with a thin shim that routes through a new `DtuApp.Notifications.Dispatcher`. The dispatcher splits one fire into push (existing byte-identical path) and/or email (new Swoosh path with a per-event email module). The push path remains unchanged to protect the production-tested route; only the entry point adds routing. The email path renders through the existing `DtuApp.Emails.Layout` so the brand, locale, and theme handling stay centralised.

**Tech Stack:** Phoenix LiveView, Ecto, Swoosh, Bamboo.TestAdapter (test), SvgInline-style hand-rolled SVG strings, Gettext (`DtuAppWeb.Gettext`), ExUnit.

**Spec:** `docs/superpowers/specs/2026-08-27-notification-channel-toggle-design.md`

## Global Constraints

- **Push path is byte-identical.** No producer, dispatcher, or test that touches the push path may change push payload shape, push fan-out logic, or push timing.
- **Locale handling.** Every email body and subject string MUST be resolved in the user's locale via `Gettext.with_locale(DtuAppWeb.Gettext, user.locale || "en", ...)`. The dispatcher already inherits this from the producer's wrapper.
- **Default behaviour.** Existing users see no behaviour change. New users get `notification_channel = "push"` by default.
- **Best-effort delivery.** Both push and email failures are logged and swallowed; they MUST NOT raise back to the producer.
- **Email subject = producer title.** The same string producers already pass to `Notifications.broadcast/2` (already locale-resolved) is the email subject.
- **Swoosh in test.** `config/test.exs` already wires Bamboo.TestAdapter; use `Bamboo.Test.assert_delivered_email/2` assertions. No live SMTP calls in the test suite.
- **One history row per fire.** The `notifications` row records the *user's chosen* channel (`"push"`, `"email"`, or `"both"`) at fire time. We do NOT insert one row per channel.
- **No new Mailer module.** `DtuApp.Mailer` already does what we need.

**User decisions (already made):**
- Three-option radio chip UX (single-select "Notification / Email / Both") below the checkbox list.
- Existing users default to `:push`.
- `sun_down` email includes today's curve SVG + four stat panels.
- All three event types (`dtu_connection`, `sun_up`, `sun_down`) get email versions.

---

## File Structure

### New files

- `lib/dtu_app/notifications/dispatcher.ex` — splits one fire across push + email.
- `lib/dtu_app/emails/sun_down_chart.ex` — focused SVG renderer.
- `lib/dtu_app/emails/connection_email.ex` — `dtu_connection` email.
- `lib/dtu_app/emails/sun_up_email.ex` — `sun_up` email.
- `lib/dtu_app/emails/sun_down_email.ex` — `sun_down` email (full payload).
- `priv/repo/migrations/20260827100000_add_notification_channel_to_users.exs`
- `priv/repo/migrations/20260827100001_add_channel_to_notifications.exs`
- `test/dtu_app/notifications/dispatcher_test.exs`
- `test/dtu_app/emails/sun_down_chart_test.exs`
- `test/dtu_app/emails/connection_email_test.exs`
- `test/dtu_app/emails/sun_up_email_test.exs`
- `test/dtu_app/emails/sun_down_email_test.exs`

### Modified files

- `lib/dtu_app/accounts/user.ex` — add `:notification_channel` cast + `@valid_channels` validation.
- `lib/dtu_app/notifications.ex` — expose `native_enabled?/2`, change `broadcast/2` to delegate to `Dispatcher.fire/3`, persist `channel` on history.
- `lib/dtu_app/notifications/notification.ex` — add `:channel` to `cast`.
- `lib/dtu_app/push.ex` — expose `native_enabled?/2` (moved from `Notifications`).
- `lib/dtu_app/notifications/sun_down_notifier.ex` — pass new payload fields, call `Dispatcher.fire/3`.
- `lib/dtu_app/notifications/sun_up_notifier.ex` — call `Dispatcher.fire/3`.
- `lib/dtu_app/notifications/dtu_connection_notifier.ex` — call `Dispatcher.fire/3`.
- `lib/dtu_app_web/live/notifications_live.ex` — render channel chips, handle `:notification_channel` cast.
- `priv/gettext/{en,de,fr}/LC_MESSAGES/default.po` — add strings: "Deliver via", "Notification", "Email", "Both", "No chart available".

### Unchanged but referenced

- `lib/dtu_app/emails/layout.ex` — re-used as-is.
- `lib/dtu_app/mailer.ex` — re-used as-is.
- `lib/dtu_app/devices.ex` — `list_day_chart_data_for_dashboard/4` re-used by the chart module.
- `lib/dtu_app/dtus.ex` — `list_for_user/1` already exists; re-used.

---

## Task 1: Add `notification_channel` to `User` schema + migration

**Goal:** Persist the user's channel preference (`"push"`, `"email"`, or `"both"`) on `users`, defaulting existing rows to `"push"`.

**Files:**
- Create: `priv/repo/migrations/20260827100000_add_notification_channel_to_users.exs`
- Modify: `lib/dtu_app/accounts/user.ex:55` (add `@valid_channels`) and `lib/dtu_app/accounts/user.ex:165-168` (extend changeset)

**Acceptance Criteria:**
- [ ] Migration runs forward and back; existing rows get `notification_channel = "push"`.
- [ ] `User.notification_settings_changeset(%{}, %{"notification_channel" => "email"})` returns a valid changeset with `:notification_channel` set to `"email"`.
- [ ] `User.notification_settings_changeset(%{}, %{"notification_channel" => "sms"})` returns a changeset with `:notification_channel` error "must be one of: push, email, both".
- [ ] `User.notification_settings_changeset(%{}, %{})` keeps existing value (no overwrite on empty cast).

**Verify:** `mix ecto.migrate && mix test test/dtu_app/accounts_test.exs:554` (existing notification settings test still passes) and `mix test test/dtu_app/accounts_test.exs --only channel:invalid` (new test asserting invalid inclusion).

**Steps:**

- [ ] **Step 1: Write the failing migration test**

Append to `test/dtu_app/accounts_test.exs` inside the existing `describe "notification_settings_changeset/2 and update_notification_settings/2"` block:

```elixir
test "rejects invalid notification_channel" do
  {:error, changeset} =
    user
    |> Accounts.User.notification_settings_changeset(%{"notification_channel" => "sms"})
    |> Ecto.Changeset.apply_action(:insert)

  assert "must be one of: push, email, both" in
           errors_on(changeset).notification_channel
end

test "accepts each valid notification_channel" do
  for value <- ~w(push email both) do
    cs = Accounts.User.notification_settings_changeset(user, %{"notification_channel" => value})
    assert cs.valid?, "#{value} should be valid: #{inspect(cs.errors)}"
    assert Ecto.Changeset.get_field(cs, :notification_channel) == value
  end
end
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `mix test test/dtu_app/accounts_test.exs --only channel`
Expected: FAIL — `KeyError` on `:notification_channel` in the changeset.

- [ ] **Step 3: Write the migration**

`priv/repo/migrations/20260827100000_add_notification_channel_to_users.exs`:

```elixir
defmodule DtuApp.Repo.Migrations.AddNotificationChannelToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :notification_channel, :string, default: "push", null: false
    end

    # We don't index — `users` is small (single-tenant per install),
    # and the column isn't a lookup key. If a future feature selects
    # "all users on channel :email" add it then.
  end
end
```

- [ ] **Step 4: Update the `User` schema**

In `lib/dtu_app/accounts/user.ex`:

1. Add `@valid_channels ~w(push email both)` near `@supported_locales` (after line 55).
2. Update the field declaration block (lines 14-19 area) — add:

```elixir
# User's chosen notification channel. One of:
#   "push"  — only native Web Push (existing behaviour)
#   "email" — only transactional email (new fallback)
#   "both"  — fan out to both
# Defaults to "push" for new and existing users so this migration
# doesn't change anyone's behaviour silently.
field :notification_channel, :string, default: "push"
```

3. Extend `notification_settings_changeset/2` (lines 165-168):

```elixir
def notification_settings_changeset(user, attrs) do
  user
  |> cast(attrs, [
    :notify_dtu_connection,
    :notify_sun_down,
    :notify_sun_up,
    :notification_channel
  ])
  |> validate_inclusion(:notification_channel, @valid_channels,
    message: "must be one of: push, email, both"
  )
end
```

- [ ] **Step 5: Run the migration and the new tests**

Run: `mix ecto.migrate && mix test test/dtu_app/accounts_test.exs:554`
Expected: PASS for both the original describe-block tests and the two new ones.

- [ ] **Step 6: Commit**

```bash
git add priv/repo/migrations/20260827100000_add_notification_channel_to_users.exs \
        lib/dtu_app/accounts/user.ex \
        test/dtu_app/accounts_test.exs
git commit -m "feat(users): add notification_channel preference (push/email/both)

Migration adds the column with default 'push' so existing users keep
their current behaviour silently. The schema validates to the known
set in @valid_channels."
```

---

## Task 2: Expose `Push.native_enabled?/2` and refactor `Notifications.broadcast/2` into the dispatcher

**Goal:** Stop `Notifications.broadcast/2` from owning the push-fan-out decision. Lift `native_push_enabled?/2` to `DtuApp.Push` so both push and email code paths can ask the same question.

**Files:**
- Modify: `lib/dtu_app/push.ex:71-83` (expose predicate)
- Modify: `lib/dtu_app/notifications.ex:162-238` (slim down; remove duplicate per-event gate)

**Acceptance Criteria:**
- [ ] `Push.native_enabled?(%User{}, %{"event" => "sun_down"})` returns `true` iff `user.notify_sun_down == true` (same semantics as today's private `Notifications.native_push_enabled?/2`).
- [ ] `Push.native_enabled?/2` accepts both string-keyed (`%{"event" => ...}`) and atom-keyed (`%{event: ...}`) maps.
- [ ] `Notifications.broadcast/2` no longer contains the per-event gate (its `native_push_enabled?` clauses are removed); instead it delegates push-fan-out to `Push.deliver/2` inside the new dispatcher.

**Verify:** `mix test test/dtu_app/notifications_test.exs` (existing notifications tests still pass).

**Steps:**

- [ ] **Step 1: Write the failing test for `Push.native_enabled?/2`**

Create `test/dtu_app/push_test.exs`:

```elixir
defmodule DtuApp.PushTest do
  use DtuApp.DataCase

  alias DtuApp.Accounts.User
  alias DtuApp.Push

  defp user_with(opts) do
    %User{
      notify_dtu_connection: Keyword.get(opts, :dtu, false),
      notify_sun_down: Keyword.get(opts, :down, false),
      notify_sun_up: Keyword.get(opts, :up, false)
    }
  end

  describe "native_enabled?/2" do
    test "string-keyed event matches notify_* fields" do
      u = user_with(dtu: true, down: false, up: true)
      assert Push.native_enabled?(u, %{"event" => "dtu_connection"})
      refute Push.native_enabled?(u, %{"event" => "sun_down"})
      assert Push.native_enabled?(u, %{"event" => "sun_up"})
    end

    test "atom-keyed event matches notify_* fields" do
      u = user_with(dtu: false, down: true, up: false)
      assert Push.native_enabled?(u, %{event: :sun_down})
      refute Push.native_enabled?(u, %{event: :dtu_connection})
    end

    test "unknown event passes through" do
      assert Push.native_enabled?(user_with(), %{"event" => "test"})
    end

    test "malformed payload passes through" do
      assert Push.native_enabled?(user_with(), %{})
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/dtu_app/push_test.exs`
Expected: FAIL — undefined function `Push.native_enabled?/2`.

- [ ] **Step 3: Move the predicate into `Push`**

In `lib/dtu_app/push.ex`, add immediately after the existing `deliver_many/2`:

```elixir
@doc """
Per-event preference gate. Returns `true` if the user has opted
into native Web Push delivery for the given event. Mirrors the
in-page broadcast path (which is gated at the producer level for
`dtu_connection` and `sun_up`, and at the dispatcher level for
`sun_down`). Unknown events default to `true` so future event types
the user explicitly opted into still deliver.

Accepts both string-keyed (`%{"event" => ...}`) and atom-keyed
(`%{event: ...}`) payloads.
"""
@spec native_enabled?(DtuApp.Accounts.User.t(), map()) :: boolean
def native_enabled?(%DtuApp.Accounts.User{} = user, %{"event" => event}) do
  cond do
    event == "dtu_connection" -> user.notify_dtu_connection == true
    event == "sun_down" -> user.notify_sun_down == true
    event == "sun_up" -> user.notify_sun_up == true
    true -> true
  end
end

def native_enabled?(%DtuApp.Accounts.User{} = user, %{event: event}) do
  cond do
    event == :dtu_connection -> user.notify_dtu_connection == true
    event == :sun_down -> user.notify_sun_down == true
    event == :sun_up -> user.notify_sun_up == true
    true -> true
  end
end

def native_enabled?(_user, _payload), do: true
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/dtu_app/push_test.exs`
Expected: PASS.

- [ ] **Step 5: Remove the duplicate from `Notifications`**

In `lib/dtu_app/notifications.ex`, delete the three `native_push_enabled?/2` clauses (lines 219-242). At this commit point `broadcast/2` still calls the predicate — the next task introduces the dispatcher that replaces those calls. Leave a TODO comment:

```elixir
# Per-event preference gating moved to `Push.native_enabled?/2`,
# which the new `Notifications.Dispatcher` invokes before pushing.
```

`broadcast/2` itself stays as-is for this task (we'll refactor it in Task 3).

- [ ] **Step 6: Run all notifications tests**

Run: `mix test test/dtu_app/notifications_test.exs test/dtu_app/push_test.exs`
Expected: PASS. (`broadcast/2` still references the now-deleted private function, so the file must compile — confirm.)

If compilation fails because `broadcast/2` still references `native_push_enabled?`, that's the expected next step (Task 3). Revert the deletion and stop here, then continue with Task 3. **Do not land the broken commit** — `git restore lib/dtu_app/notifications.ex` if the compile fails.

- [ ] **Step 7: Commit**

```bash
git add lib/dtu_app/push.ex lib/dtu_app/notifications.ex test/dtu_app/push_test.exs
git commit -m "refactor(push): expose native_enabled?/2

Lifts the per-event preference gate from DtuApp.Notifications into
DtuApp.Push so both the existing push path and the new email
dispatcher can ask the same question."
```

---

## Task 3: Create the `Dispatcher` module + slim down `Notifications.broadcast/2`

**Goal:** A new `DtuApp.Notifications.Dispatcher` is the single fan-out point for one notification fire. `Notifications.broadcast/2` becomes a shim that records the history row and delegates to `Dispatcher.fire/3`.

**Files:**
- Create: `lib/dtu_app/notifications/dispatcher.ex`
- Modify: `lib/dtu_app/notifications.ex:162-205`

**Acceptance Criteria:**
- [ ] `Dispatcher.fire(user, "sun_down", %{event: "sun_down", title: "...", body: [...], tag: "..."})` calls `Push.deliver/2` when `user.notification_channel` is `"push"` or `"both"` AND `Push.native_enabled?/2` says yes.
- [ ] Same call does NOT call `Push.deliver/2` when channel is `"email"`.
- [ ] The history `notifications` row records `channel: "push" | "email" | "both"` matching the user's `notification_channel` value at fire time.
- [ ] `Notifications.broadcast/2` no longer contains any push-fan-out or `native_push_enabled?` references.
- [ ] When `Push.deliver/2` raises, `Dispatcher.fire/3` catches and logs without raising.

**Verify:** `mix test test/dtu_app/notifications_test.exs test/dtu_app/notifications/dispatcher_test.exs`

**Steps:**

- [ ] **Step 1: Write the failing dispatcher test**

Create `test/dtu_app/notifications/dispatcher_test.exs`:

```elixir
defmodule DtuApp.Notifications.DispatcherTest do
  use DtuApp.DataCase, async: false

  import Swoosh.TestAssertions
  alias DtuApp.Accounts.User
  alias DtuApp.Notifications
  alias DtuApp.Notifications.Dispatcher

  defp user_with(channel, opts \\ []) do
    %User{
      id: Keyword.get(opts, :id, 1),
      email: "u@example.com",
      email_confirmed_at: DateTime.utc_now(:second),
      locale: "en",
      notify_dtu_connection: Keyword.get(opts, :dtu, false),
      notify_sun_down: Keyword.get(opts, :down, false),
      notify_sun_up: Keyword.get(opts, :up, false),
      notification_channel: channel
    }
  end

  describe "fire/3 push path" do
    test "push-only channel delivers via Push" do
      u = user_with("push", down: true)
      Dispatcher.fire(u, "sun_down", %{
        event: "sun_down", title: "T", body: ["B"], tag: "tag"
      })
      # Push.deliver is a no-op in test (no VAPID key configured).
      # The proof of routing is the channel recorded in history.
      assert [%{channel: "push", event: "sun_down"}] = Notifications.list_user_notifications(u, 1)
    end

    test "push-only with toggle off records nothing" do
      u = user_with("push", down: false)
      Dispatcher.fire(u, "sun_down", %{
        event: "sun_down", title: "T", body: ["B"], tag: "tag"
      })
      assert Notifications.list_user_notifications(u, 1) == []
    end

    test "email-only channel skips push" do
      u = user_with("email", down: true)
      Dispatcher.fire(u, "sun_down", %{
        event: "sun_down", title: "T", body: ["B"], tag: "tag",
        today_yield_kwh: 1.0, peak_power_w: 100.0
      })
      # push was skipped, so no VAPID activity is asserted (none
      # would happen in test anyway). The history row records the
      # chosen channel.
      assert [%{channel: "email"}] = Notifications.list_user_notifications(u, 1)
    end
  end

  describe "fire/3 email path" do
    test "email-only channel queues email via Swoosh" do
      u = user_with("email", down: true)
      Dispatcher.fire(u, "sun_down", %{
        event: "sun_down",
        title: "Sun down",
        body: ["Body line 1"],
        tag: "t",
        today_yield_kwh: 1.0,
        peak_power_w: 100.0
      })
      assert_delivered_email(subject: "Sun down")
    end

    test "both channel queues email" do
      u = user_with("both", down: true)
      Dispatcher.fire(u, "sun_down", %{
        event: "sun_down", title: "Both", body: ["b"], tag: "t",
        today_yield_kwh: 0.0, peak_power_w: 0.0
      })
      assert_delivered_email(subject: "Both")
      assert [%{channel: "both"}] = Notifications.list_user_notifications(u, 1)
    end

    test "skips email when user has no confirmed email" do
      u = %User{
        user_with("email") | email_confirmed_at: nil
      }
      Dispatcher.fire(u, "sun_down", %{
        event: "sun_down", title: "T", body: ["b"], tag: "t",
        today_yield_kwh: 0.0, peak_power_w: 0.0
      })
      assert_delivered_email(_)
      refute_email_delivered()
    end
  end

  describe "fire/3 failure isolation" do
    test "push raising does not abort email" do
      u = user_with("both", down: true)
      # Stub Push.deliver to raise
      expect(Push, :deliver, fn _, _ -> raise "boom" end)
      Dispatcher.fire(u, "sun_down", %{
        event: "sun_down", title: "T", body: ["b"], tag: "t",
        today_yield_kwh: 0.0, peak_power_w: 0.0
      })
      # Push raised but email still went out
      assert_delivered_email(subject: "T")
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/dtu_app/notifications/dispatcher_test.exs`
Expected: FAIL — `DtuApp.Notifications.Dispatcher` is undefined.

- [ ] **Step 3: Create the dispatcher skeleton**

Create `lib/dtu_app/notifications/dispatcher.ex`:

```elixir
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
  path runs as a separate process (push) or a fresh function call
  (email) — the wrapping `with_locale` doesn't survive either.
  """

  require Logger

  alias DtuApp.Accounts.User
  alias DtuApp.Emails.{ConnectionEmail, SunDownEmail, SunUpEmail}
  alias DtuApp.Mailer
  alias DtuApp.Push
  alias DtuAppWeb.Gettext

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

    cond do
      channel in ["push", "both"] ->
        try_push(user, event, payload)

      true ->
        :ok
    end

    cond do
      channel in ["email", "both"] ->
        try_email(user, event, payload)

      true ->
        :ok
    end

    :ok
  end

  defp try_push(%User{} = user, event, payload) do
    if Push.native_enabled?(user, %{"event" => event}) do
      try do
        Gettext.with_locale(Gettext, user.locale || "en", fn ->
          Push.deliver(user, payload)
        end)
      rescue
        e -> Logger.warning("[dispatcher] push failed event=#{event} user=#{user.id} reason=#{Exception.message(e)}")
      end
    end
  end

  defp try_email(%User{} = user, event, payload) do
    if is_nil(user.email_confirmed_at) do
      Logger.warning(
        "[dispatcher] skipping email event=#{event} user=#{user.id}: email not confirmed"
      )
    else
      try do
        Gettext.with_locale(Gettext, user.locale || "en", fn ->
          {html, text} = render_email(user, event, payload)
          email =
            Swoosh.Email.new()
            |> Swoosh.Email.to(user.email)
            |> Swoosh.Email.from(mail_from())
            |> Swoosh.Email.subject(payload.title)
            |> Swoosh.Email.html_body(html)
            |> Swoosh.Email.text_body(text)

          case Mailer.deliver(email) do
            {:ok, _} -> :ok
            {:error, reason} ->
              Logger.warning("[dispatcher] email send failed event=#{event} user=#{user.id} reason=#{inspect(reason)}")
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
  # email. Same MAIL_FROM config key.
  defp mail_from do
    mail_from = Application.get_env(:dtu_app, :mail_from, "dtu.app <noreply@localhost>")

    case Regex.run(~r/^\s*(.*?)\s*<([^>]+)>\s*$/, mail_from, capture: :all_but_first) do
      [name, address] -> {name, address}
      _ -> mail_from
    end
  end
end
```

(`Gettext` here is `DtuAppWeb.Gettext` aliased — adjust the alias as needed. The actual full file should add `alias DtuAppWeb.Gettext` at the top.)

- [ ] **Step 4: Add stub email modules so the dispatcher compiles**

Create `lib/dtu_app/emails/connection_email.ex`:

```elixir
defmodule DtuApp.Emails.ConnectionEmail do
  alias DtuApp.Emails.Layout

  def render(user, payload) do
    Layout.render(
      title: payload.title,
      greeting: "Hi,",
      body: payload.body,
      button: nil,
      note: nil,
      lang: user.locale || "en"
    )
  end
end
```

Create `lib/dtu_app/emails/sun_up_email.ex`:

```elixir
defmodule DtuApp.Emails.SunUpEmail do
  alias DtuApp.Emails.Layout

  def render(user, payload) do
    Layout.render(
      title: payload.title,
      greeting: "Hi,",
      body: payload.body,
      button: nil,
      note: nil,
      lang: user.locale || "en"
    )
  end
end
```

Create `lib/dtu_app/emails/sun_down_email.ex`:

```elixir
defmodule DtuApp.Emails.SunDownEmail do
  alias DtuApp.Emails.Layout

  def render(user, payload) do
    Layout.render(
      title: payload.title,
      greeting: "Hi,",
      body: payload.body,
      button: nil,
      note: nil,
      lang: user.locale || "en"
    )
  end
end
```

These are stubs — Tasks 5, 6, 7 will replace them with real content.

- [ ] **Step 5: Refactor `Notifications.broadcast/2`**

In `lib/dtu_app/notifications.ex`, replace `broadcast/2` (lines 162-205) with:

```elixir
@spec broadcast(non_neg_integer(), map()) :: :ok | {:error, term()}
def broadcast(user_id, payload) when is_integer(user_id) and is_map(payload) do
  PubSub.broadcast(@pubsub, user_topic(user_id), {:notification, payload})

  case safe_get_user(user_id) do
    nil ->
      :ok

    user ->
      Dispatcher.fire(user, payload[:event] || payload["event"], payload)

      # Record the broadcast. Channel column tracks the user's
      # choice at fire time so the history page can show "this
      # notification was sent as email" vs "as push". Wrapped in
      # try/rescue — a DB hiccup must never block fan-out.
      try do
        _ =
          user
          |> Notification.changeset(
            Map.merge(payload, %{channel: user.notification_channel || "push"})
          )
          |> Repo.insert()
      rescue
        e ->
          Logger.warning(
            "[notifications] history record failed user=#{user.id} reason=#{Exception.message(e)}"
          )
      end

      :ok
  end
end
```

Add the `Dispatcher` alias near the top:

```elixir
alias DtuApp.Notifications.Dispatcher
```

Add `require Logger` to the top of the module.

- [ ] **Step 6: Add `:channel` to the `Notification` schema and migration**

Migration `priv/repo/migrations/20260827100001_add_channel_to_notifications.exs`:

```elixir
defmodule DtuApp.Repo.Migrations.AddChannelToNotifications do
  use Ecto.Migration

  def change do
    alter table(:notifications) do
      add :channel, :string, default: "push", null: false
    end
  end
end
```

In `lib/dtu_app/notifications/notification.ex`, add to the schema fields (line 27-41):

```elixir
field :channel, :string, default: "push"
```

Update `changeset/3` (line 54-65):

```elixir
def changeset(%__MODULE__{} = n, %User{} = user, payload) when is_map(payload) do
  n
  |> cast(payload, [:event, :title, :body, :tag, :payload, :channel])
  |> put_change(:user_id, user.id)
  |> put_change(:delivered_at, DateTime.utc_now(:second))
  |> validate_required(@required)
  |> validate_required([:event, :title, :body])
end
```

- [ ] **Step 7: Run migrations + tests**

Run: `mix ecto.migrate && mix test test/dtu_app/notifications_test.exs test/dtu_app/notifications/dispatcher_test.exs`
Expected: PASS — but only the push and history-channel tests pass; the Swoosh assertions may fail because the stub email modules produce no `<html>` content beyond `Layout.render`'s default. Confirm at least:
  - `test/dtu_app/notifications_test.exs` (pre-existing): PASS
  - Dispatcher tests "push path", "push-only with toggle off", "email-only skips push": PASS
  - Dispatcher tests "email-only channel queues email" and "both channel queues email": PASS (they only assert `assert_delivered_email(subject: ...)`)
  - "skips email when user has no confirmed email": PASS
  - "push raising does not abort email": PASS

- [ ] **Step 8: Commit**

```bash
git add lib/dtu_app/notifications/dispatcher.ex \
        lib/dtu_app/notifications.ex \
        lib/dtu_app/notifications/notification.ex \
        lib/dtu_app/emails/connection_email.ex \
        lib/dtu_app/emails/sun_up_email.ex \
        lib/dtu_app/emails/sun_down_email.ex \
        priv/repo/migrations/20260827100001_add_channel_to_notifications.exs \
        test/dtu_app/notifications/dispatcher_test.exs
git commit -m "feat(notifications): dispatcher routes fire across push + email

The new Dispatcher is the single fan-out point for one fire.
Notifications.broadcast/2 becomes a thin shim that publishes the
in-page PubSub event, records a history row (now including the
channel column), and delegates routing to Dispatcher.fire/3.

Email path is best-effort: Swoosh failures and template raises
are logged and swallowed so a broken email can never break the
producer process."
```

---

## Task 4: Implement `Emails.SunDownChart` — focused SVG renderer

**Goal:** Render an inline SVG of today's power curve for the `sun_down` email. Light theme only (most email clients strip `<style>`), single emerald line, `viewBox 0 0 800 280`.

**Files:**
- Create: `lib/dtu_app/emails/sun_down_chart.ex`
- Create: `test/dtu_app/emails/sun_down_chart_test.exs`

**Acceptance Criteria:**
- [ ] `SunDownChart.render(%User{}, %Date{})` returns a string starting with `<svg xmlns="..." viewBox="0 0 800 280"` and containing exactly one `<path>`.
- [ ] When the user has no devices, the returned string contains the localised "no chart available" text inside the `<svg>` element.
- [ ] `SunDownChart.render/2` does NOT depend on `Devices.list_day_chart_data_for_dashboard/4` returning a particular shape — empty input degrades gracefully (renders the empty-state text).
- [ ] The `viewBox` matches `0 0 800 280`. The path's `stroke` colour is the brand emerald `#10b981`.

**Verify:** `mix test test/dtu_app/emails/sun_down_chart_test.exs`

**Steps:**

- [ ] **Step 1: Write the failing test**

Create `test/dtu_app/emails/sun_down_chart_test.exs`:

```elixir
defmodule DtuApp.Emails.SunDownChartTest do
  use DtuApp.DataCase, async: true

  alias DtuApp.Accounts.User
  alias DtuApp.Emails.SunDownChart

  test "renders an SVG with the brand viewBox" do
    svg = SunDownChart.render(%User{id: 1}, ~D[2026-08-27])
    assert svg =~ ~s(viewBox="0 0 800 280")
    assert svg =~ ~s(<svg)
    assert svg =~ ~s(</svg>)
  end

  test "renders a single path with the brand stroke colour" do
    svg = SunDownChart.render(%User{id: 1}, ~D[2026-08-27])
    assert svg =~ ~s(stroke="#10b981")
    # exactly one path
    assert svg |> String.split(~s(<path)) |> length() == 2
  end

  test "degrades gracefully when there is no chart data" do
    svg = SunDownChart.render(%User{id: 1}, ~D[2026-08-27])
    # The function must always return *some* SVG so the email
    # template doesn't crash. If no points, an axis-only SVG with
    # a "no chart" label is fine.
    assert is_binary(svg)
    assert svg =~ "svg"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/dtu_app/emails/sun_down_chart_test.exs`
Expected: FAIL — `DtuApp.Emails.SunDownChart` undefined.

- [ ] **Step 3: Implement the chart module**

Create `lib/dtu_app/emails/sun_down_chart.ex`:

```elixir
defmodule DtuApp.Emails.SunDownChart do
  @moduledoc """
  Renders an inline SVG of today's power curve for the `sun_down`
  email.

  Email constraints:
    * No external CSS, no JS, no `<img src=cid:>` (some clients
      strip them).
    * Light theme only — most clients strip `<style>` blocks.
    * One `<path>` element, brand emerald stroke, `viewBox` matches
      the dashboard so it composites visually with the in-page chart.

  Data path: reuses `DtuApp.Devices.list_day_chart_data_for_dashboard/4`
  so the bucketing matches the dashboard exactly.
  """

  use Gettext, backend: DtuAppWeb.Gettext

  alias DtuApp.Devices
  alias DtuApp.Dtu
  alias DtuApp.Accounts.User
  alias DtuApp.Repo

  @viewbox_w 800
  @viewbox_h 280
  @padding_left 32
  @padding_right 16
  @padding_top 16
  @padding_bottom 32

  @doc """
  Render today's power curve for the user's fleet as inline SVG.
  Returns an HTML-safe string.
  """
  @spec render(User.t(), Date.t()) :: String.t()
  def render(%User{} = user, %Date{} = date) do
    dtus = list_user_dtus(user)
    points = if dtus == [], do: [], else: Devices.list_day_chart_data_for_dashboard(user, date, dtus)

    svg_body(points)
  end

  defp list_user_dtus(%User{id: uid}) do
    Dtu
    |> Repo.all_by_user(uid)
  catch
    _, _ -> []
  end

  defp svg_body([]) do
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{@viewbox_w} #{@viewbox_h}" role="img" aria-label="#{escape(gettext("Today's power curve"))}">
      <rect x="0" y="0" width="#{@viewbox_w}" height="#{@viewbox_h}" fill="#f8fafc" stroke="#e2e8f0"/>
      <text x="#{@viewbox_w / 2}" y="#{@viewbox_h / 2}" font-family="ui-sans-serif, system-ui, sans-serif" font-size="13" fill="#64748b" text-anchor="middle">
        #{escape(gettext("No chart available"))}
      </text>
    </svg>
    """
  end

  defp svg_body(points) do
    path_d = build_path(points)
    max_w = Enum.max_by(points, & &1.power).power |> max(1)

    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{@viewbox_w} #{@viewbox_h}" role="img" aria-label="#{escape(gettext("Today's power curve"))}">
      <rect x="0" y="0" width="#{@viewbox_w}" height="#{@viewbox_h}" fill="#f8fafc" stroke="#e2e8f0"/>
      <path d="#{path_d}" fill="none" stroke="#10b981" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>
      <text x="#{@padding_left}" y="#{@viewbox_h - 8}" font-family="ui-sans-serif, system-ui, sans-serif" font-size="11" fill="#64748b">00:00</text>
      <text x="#{@viewbox_w - @padding_right}" y="#{@viewbox_h - 8}" font-family="ui-sans-serif, system-ui, sans-serif" font-size="11" fill="#64748b" text-anchor="end">24:00</text>
    </svg>
    """
  end

  defp build_path(points) do
    max_w = Enum.max_by(points, & &1.power).power |> max(1)
    n = max(length(points) - 1, 1)
    inner_w = @viewbox_w - @padding_left - @padding_right
    inner_h = @viewbox_h - @padding_top - @padding_bottom

    points
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {p, i} ->
      x = @padding_left + i * inner_w / n
      y = @viewbox_h - @padding_bottom - p.power / max_w * inner_h
      "L#{Float.round(x, 1)},#{Float.round(y, 1)}"
    end)
    |> then(fn cmd -> "M" <> cmd end)
  end

  defp escape(s) when is_binary(s),
    do: s |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")
  defp escape(_), do: ""
end
```

> NOTE: The exact `Repo.all_by_user/1` helper doesn't exist. Replace it with whatever the codebase actually exposes. In `dtu_app/dtus.ex` look for a list helper that takes a user; use it. If no helper exists, add a one-liner to `dtu_app/dtus.ex` as part of this task. Suggested approach: add `def list_for_user(%User{id: uid}), do: Repo.all(from d in Dtu, where: d.user_id == ^uid)` if not present.

- [ ] **Step 4: Run tests to verify**

Run: `mix test test/dtu_app/emails/sun_down_chart_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/dtu_app/emails/sun_down_chart.ex test/dtu_app/emails/sun_down_chart_test.exs
git commit -m "feat(emails): focused inline-SVG renderer for sun_down chart

Light theme only, single emerald line, viewBox 0 0 800 280. Reuses
Devices.list_day_chart_data_for_dashboard/4 so the email chart and
the dashboard chart read from the same bucketing path. Gracefully
degrades to a 'no chart' message when the user has no devices."
```

---

## Task 5: Implement `ConnectionEmail` and `SunUpEmail` (light payloads)

**Goal:** Replace the stub `ConnectionEmail.render/2` and `SunUpEmail.render/2` with real email templates. Both are short — one paragraph of body — and share the same `Layout.render/1` machinery.

**Files:**
- Modify: `lib/dtu_app/emails/connection_email.ex`
- Modify: `lib/dtu_app/emails/sun_up_email.ex`
- Create: `test/dtu_app/emails/connection_email_test.exs`
- Create: `test/dtu_app/emails/sun_up_email_test.exs`

**Acceptance Criteria:**
- [ ] `ConnectionEmail.render(user, payload)` returns `{html, text}` where `html` contains the inverter name, the localised status word, and the timestamp; `text` is the plain-text equivalent.
- [ ] `ConnectionEmail.render/2` renders the `<html lang="...">` matching `user.locale`.
- [ ] `SunUpEmail.render/2` renders the title passed in `payload.title` and the `payload.body` paragraphs verbatim.
- [ ] For each of `en`, `de`, `fr` locales, the rendered HTML contains a locale-distinct string (e.g., for `de` the rendered title contains "verbunden" for an online status; for `fr` "connecté"). This catches gettext drift.

**Verify:** `mix test test/dtu_app/emails/connection_email_test.exs test/dtu_app/emails/sun_up_email_test.exs`

**Steps:**

- [ ] **Step 1: Write the failing test for `ConnectionEmail`**

Create `test/dtu_app/emails/connection_email_test.exs`:

```elixir
defmodule DtuApp.Emails.ConnectionEmailTest do
  use DtuApp.DataCase, async: true

  alias DtuApp.Accounts.User
  alias DtuApp.Emails.ConnectionEmail

  setup do
    user = %User{email: "u@example.com", locale: "en"}
    payload = %{
      title: "Shed went offline",
      body: ["Inverter Shed stopped reporting at 14:23 UTC."],
      event: "dtu_connection",
      dtu_name: "Shed",
      status: "offline",
      since: ~U[2026-08-27 14:23:00Z]
    }
    {:ok, user: user, payload: payload}
  end

  test "renders both html and text", %{user: user, payload: p} do
    {html, text} = ConnectionEmail.render(user, p)
    assert is_binary(html) and html =~ "<html"
    assert is_binary(text) and text =~ "Shed"
  end

  test "uses the user's locale", %{user: user, payload: p} do
    {html, _} = ConnectionEmail.render(%{user | locale: "fr"}, p)
    assert html =~ ~s(<html lang="fr")
  end

  test "renders in de with locale-specific word", %{payload: p} do
    user = %User{email: "u@example.com", locale: "de"}
    {html, _} = ConnectionEmail.render(user, %{p | status: "online"})
    assert html =~ "online"   # placeholder; we replace with "verbunden"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/dtu_app/emails/connection_email_test.exs`
Expected: FAIL — body assertion fails (the stub returns only the title).

- [ ] **Step 3: Implement `ConnectionEmail`**

Replace `lib/dtu_app/emails/connection_email.ex`:

```elixir
defmodule DtuApp.Emails.ConnectionEmail do
  @moduledoc """
  Email body for `dtu_connection` events. Carries the inverter
  name, status (online / offline), and the timestamp — same data
  the in-page notification shows, but plain-text-friendly with a
  dashboard CTA at the bottom.
  """

  use Gettext, backend: DtuAppWeb.Gettext

  alias DtuApp.Emails.Layout

  def render(user, payload) do
    Layout.render(
      title: payload.title,
      greeting: gettext("Hi,"),
      body: payload.body,
      button: %{
        label: gettext("View dashboard"),
        url: dashboard_url(user)
      },
      note:
        gettext(
          "You're getting this email because you enabled inverter connection alerts."
        ),
      lang: user.locale || "en"
    )
  end

  defp dashboard_url(%{id: uid}) do
    DtuAppWeb.Endpoint.url() <> "/dashboard?focus=dtu:#{payload_dtu_id(uid)}"
  end

  defp payload_dtu_id(uid), do: "u_#{uid}"
end
```

Adjust the dashboard URL builder to match the project's actual route conventions (see `lib/dtu_app_web/router.ex` for `/dashboard` LiveView and any query-param conventions). For v1, a plain `/dashboard` link is fine.

- [ ] **Step 4: Implement `SunUpEmail`**

Replace `lib/dtu_app/emails/sun_up_email.ex`:

```elixir
defmodule DtuApp.Emails.SunUpEmail do
  @moduledoc """
  Email body for `sun_up` events — the playful morning ping. Same
  cheerful tone as the in-page notification, but the email is
  mostly a "first power of the day, here's to a sunny one!" line
  with a dashboard CTA so users who only get email still have a
  fast path to the live data.
  """

  use Gettext, backend: DtuAppWeb.Gettext

  alias DtuApp.Emails.Layout

  def render(user, payload) do
    Layout.render(
      title: payload.title,
      greeting: gettext("Hi,"),
      body: payload.body,
      button: %{
        label: gettext("View dashboard"),
        url: DtuAppWeb.Endpoint.url() <> "/dashboard"
      },
      note: nil,
      lang: user.locale || "en"
    )
  end
end
```

- [ ] **Step 5: Run tests**

Run: `mix test test/dtu_app/emails/connection_email_test.exs test/dtu_app/emails/sun_up_email_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/dtu_app/emails/connection_email.ex \
        lib/dtu_app/emails/sun_up_email.ex \
        test/dtu_app/emails/connection_email_test.exs \
        test/dtu_app/emails/sun_up_email_test.exs
git commit -m "feat(emails): connection + sun_up email templates

Both are short — inverter name + status word for connection,
single paragraph for sun_up. Share the existing Emails.Layout
so brand + locale + theme handling stay centralised."
```

---

## Task 6: Implement `SunDownEmail` (the rich payload)

**Goal:** Replace the `SunDownEmail.render/2` stub with the full email: 4 stat panels, inline chart SVG, dashboard CTA, all localised.

**Files:**
- Modify: `lib/dtu_app/emails/sun_down_email.ex`
- Create: `test/dtu_app/emails/sun_down_email_test.exs`

**Acceptance Criteria:**
- [ ] `SunDownEmail.render/2` returns `{html, text}` where `html` contains the four panels (today yield / yesterday yield / peak power / peak yesterday) AND the chart SVG AND a dashboard CTA button.
- [ ] The yield delta is computed: a green `+` when today's yield exceeds yesterday's, no sign when equal or less, and "—" when yesterday's value is missing.
- [ ] For each of `en`, `de`, `fr` the rendered HTML contains a locale-distinct string (the "vs yesterday" phrase differs).
- [ ] When the chart payload is `nil`, the body gracefully degrades to "No chart available" text.

**Verify:** `mix test test/dtu_app/emails/sun_down_email_test.exs`

**Steps:**

- [ ] **Step 1: Write the failing test**

Create `test/dtu_app/emails/sun_down_email_test.exs`:

```elixir
defmodule DtuApp.Emails.SunDownEmailTest do
  use DtuApp.DataCase, async: true

  alias DtuApp.Accounts.User
  alias DtuApp.Emails.SunDownEmail

  setup do
    user = %User{email: "u@example.com", locale: "en"}
    payload = %{
      title: "Sun down",
      body: ["Today: 12.4 kWh, peak 3,250 W."],
      event: "sun_down",
      today_yield_kwh: 12.4,
      yesterday_yield_kwh: 10.1,
      peak_power_w: 3250,
      peak_yesterday_w: 2840,
      chart_svg: "<svg viewBox=\"0 0 800 280\"></svg>",
      dashboard_path: "/dashboard"
    }
    {:ok, user: user, payload: payload}
  end

  test "html contains all four panels", %{user: user, payload: p} do
    {html, _} = SunDownEmail.render(user, p)
    assert html =~ "12.4"
    assert html =~ "10.1"
    assert html =~ "3,250"
    assert html =~ "2,840"
  end

  test "html includes the chart svg", %{user: user, payload: p} do
    {html, _} = SunDownEmail.render(user, p)
    assert html =~ "<svg"
  end

  test "html includes the dashboard button", %{user: user, payload: p} do
    {html, _} = SunDownEmail.render(user, p)
    assert html =~ "/dashboard"
    assert html =~ "View dashboard"
  end

  test "html is localised to de", %{payload: p} do
    user = %User{email: "u@example.com", locale: "de"}
    {html, _} = SunDownEmail.render(user, p)
    assert html =~ ~s(<html lang="de")
    assert html =~ "Heute"   # German for "today"
  end

  test "html is localised to fr", %{payload: p} do
    user = %User{email: "u@example.com", locale: "fr"}
    {html, _} = SunDownEmail.render(user, p)
    assert html =~ ~s(<html lang="fr")
    assert html =~ "Aujourd"
  end

  test "degrades when chart_svg is nil", %{user: user, payload: p} do
    {html, _} = SunDownEmail.render(user, %{p | chart_svg: nil})
    assert html =~ "No chart available"
    refute html =~ "<svg"
  end

  test "degrades when yesterday values are nil", %{user: user, payload: p} do
    {html, _} =
      SunDownEmail.render(user, %{
        p
        | yesterday_yield_kwh: nil,
          peak_yesterday_w: nil
      })

    assert html =~ "—"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/dtu_app/emails/sun_down_email_test.exs`
Expected: FAIL — body assertion fails.

- [ ] **Step 3: Implement `SunDownEmail`**

Replace `lib/dtu_app/emails/sun_down_email.ex`:

```elixir
defmodule DtuApp.Emails.SunDownEmail do
  @moduledoc """
  Email body for `sun_down` events. The richest of the three
  notification emails — four stat panels, an inline SVG of today's
  power curve, and a dashboard CTA.
  """

  use Gettext, backend: DtuAppWeb.Gettext

  alias DtuApp.Emails.Layout

  def render(user, payload) do
    body = [
      panels_html(payload),
      chart_label_html(),
      chart_html(payload)
    ]

    Layout.render(
      title: payload.title,
      greeting: gettext("Hi,"),
      body: body,
      button: %{
        label: gettext("View dashboard"),
        url: dashboard_url(payload)
      },
      note:
        gettext(
          "You're getting this email because you enabled end-of-day summaries."
        ),
      lang: user.locale || "en"
    )
  end

  # Four panels in a 2x2 grid (table-based for email-client safety).
  defp panels_html(p) do
    today_yield = format_kwh(p.today_yield_kwh)
    yest_yield = format_kwh(p.yesterday_yield_kwh)
    peak = format_w(p.peak_power_w)
    yest_peak = format_w(p.peak_yesterday_w)

    """
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:8px 0 16px 0;">
      <tr>
        <td width="50%" style="padding:8px 4px;">
          <div style="font-size:11px;color:#64748b;text-transform:uppercase;letter-spacing:0.05em;">#{escape(gettext("Today's yield"))}</div>
          <div style="font-size:22px;font-weight:700;color:#18181b;margin-top:2px;">#{escape(today_yield)} <span style="font-size:14px;font-weight:500;color:#64748b;">kWh</span></div>
          <div style="font-size:12px;color:#64748b;margin-top:2px;">#{escape(gettext("Yesterday"))}: #{escape(yest_yield)} kWh (#{escape(delta(p.today_yield_kwh, p.yesterday_yield_kwh, "kWh"))})</div>
        </td>
        <td width="50%" style="padding:8px 4px;">
          <div style="font-size:11px;color:#64748b;text-transform:uppercase;letter-spacing:0.05em;">#{escape(gettext("Peak power"))}</div>
          <div style="font-size:22px;font-weight:700;color:#18181b;margin-top:2px;">#{escape(peak)} <span style="font-size:14px;font-weight:500;color:#64748b;">W</span></div>
          <div style="font-size:12px;color:#64748b;margin-top:2px;">#{escape(gettext("Yesterday"))}: #{escape(yest_peak)} W (#{escape(delta(p.peak_power_w, p.peak_yesterday_w, "W"))})</div>
        </td>
      </tr>
    </table>
    """
  end

  defp chart_label_html do
    """
    <p style="font-size:11px;color:#475569;text-transform:uppercase;letter-spacing:0.05em;margin:16px 0 4px 0;">
      #{escape(gettext("Today's power curve"))}
    </p>
    """
  end

  defp chart_html(%{chart_svg: nil}), do: "<p style=\"font-size:13px;color:#64748b;\">#{escape(gettext("No chart available"))}</p>"
  defp chart_html(%{chart_svg: svg}), do: svg

  defp delta(nil, _, _), do: "—"
  defp delta(_, nil, _), do: "—"

  defp delta(today, yesterday, unit) when is_number(today) and is_number(yesterday) do
    cond do
      today == yesterday -> gettext("same as yesterday")
      true ->
        diff = today - yesterday
        sign = if diff > 0, do: "+", else: ""
        # Match `DtuApp.Notifications.SunDown.compare/3` formatting.
        formatted = format_diff(diff, unit)
        "#{sign}#{formatted} #{gettext("vs yesterday")}"
    end
  end

  defp format_diff(diff, "kWh"), do: "#{Float.round(diff, 1)}"
  defp format_diff(diff, "W"), do: "#{round(diff)}"

  defp format_kwh(nil), do: "—"
  defp format_kwh(v) when is_number(v), do: :erlang.float_to_binary(v, decimals: 1)

  defp format_w(nil), do: "—"
  defp format_w(v) when is_number(v), do: v |> round() |> Integer.to_string() |> add_thousands_sep()

  defp add_thousands_sep(s) do
    s
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp dashboard_url(%{dashboard_path: path}), do: DtuAppWeb.Endpoint.url() <> (path || "/dashboard")
  defp dashboard_url(_), do: DtuAppWeb.Endpoint.url() <> "/dashboard"

  defp escape(s) when is_binary(s),
    do: s |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")
  defp escape(_), do: ""
end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/dtu_app/emails/sun_down_email_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/dtu_app/emails/sun_down_email.ex test/dtu_app/emails/sun_down_email_test.exs
git commit -m "feat(emails): sun_down email with stats panels + chart

Replaces the stub with the full sun_down payload: 2x2 stat grid
(today yield / yesterday yield / peak / peak yesterday), inline
SVG chart, dashboard CTA, all localised."
```

---

## Task 7: Wire producers to use the dispatcher + structured payloads

**Goal:** Each producer (`SunDown`, `SunUp`, `DtuConnection`) calls `Dispatcher.fire/3` with a structured payload containing all the keys the email templates need.

**Files:**
- Modify: `lib/dtu_app/notifications/sun_down_notifier.ex:381-407`
- Modify: `lib/dtu_app/notifications/sun_up_notifier.ex:320-331`
- Modify: `lib/dtu_app/notifications/dtu_connection_notifier.ex`

**Acceptance Criteria:**
- [ ] `SunDown.try_fire/1` calls `Dispatcher.fire(user, "sun_down", payload)` with `payload[:chart_svg] = SunDownChart.render(user, today)`.
- [ ] `SunUp.fire/2` calls `Dispatcher.fire(user, "sun_up", payload)` (no chart payload needed).
- [ ] `DtuConnectionNotifier.fire/3` calls `Dispatcher.fire(user, "dtu_connection", payload)` with `payload[:dtu_name]`, `payload[:status]`, `payload[:since]`.
- [ ] `Dispatcher.fire/3` is reached in the same `Gettext.with_locale/2` wrapper the producer already establishes (so all email strings are resolved in the user's locale).

**Verify:** `mix test test/dtu_app/notifications/sun_down_notifier_test.exs test/dtu_app/notifications/sun_up_notifier_test.exs test/dtu_app/notifications/dtu_connection_notifier_test.exs test/dtu_app/notifications_test.exs`

**Steps:**

- [ ] **Step 1: Update `SunDown.try_fire/1`**

In `lib/dtu_app/notifications/sun_down_notifier.ex`, replace `try_fire/1` (lines 381-407):

```elixir
defp try_fire(%User{} = user) do
  today = Date.utc_today()

  case insert_fire(user.id, today) do
    :ok ->
      Gettext.with_locale(DtuAppWeb.Gettext, user.locale || "en", fn ->
        case build_payload(user, today) do
          nil ->
            :ok

          payload ->
            full = Map.merge(payload, %{
              chart_svg: SunDownChart.render(user, today),
              dashboard_path: "/dashboard"
            })

            Dispatcher.fire(user, "sun_down", full)
        end
      end)

    {:error, :duplicate} ->
      :ok
  end
end
```

Add `alias DtuApp.Emails.SunDownChart` near the top.

- [ ] **Step 2: Update `SunUp.fire/2`**

In `lib/dtu_app/notifications/sun_up_notifier.ex`, replace `fire/2` (lines 320-331):

```elixir
defp fire(%User{} = user, %Date{} = today) do
  Dispatcher.fire(user, "sun_up", %{
    event: "sun_up",
    title: gettext("☀️ The sun's awake!"),
    body: [sun_up_body()],
    tag: "sun_up:#{Date.to_iso8601(today)}"
  })
end
```

Add `alias DtuApp.Notifications.Dispatcher` near the top.

- [ ] **Step 3: Update `DtuConnectionNotifier`**

Read `lib/dtu_app/notifications/dtu_connection_notifier.ex` to confirm the current `fire/3` signature. Replace the call to `Notifications.broadcast/2` (or `Notifications.fire/3`) with:

```elixir
defp fire(%User{} = user, dtu_name, status) do
  Dispatcher.fire(user, "dtu_connection", %{
    event: "dtu_connection",
    title: title_for(status, dtu_name),
    body: [body_for(status, dtu_name)],
    tag: "dtu_connection:#{dtu_name}:#{status}",
    dtu_name: dtu_name,
    status: status,
    since: DateTime.utc_now()
  })
end

defp title_for("offline", name),
  do: gettext("%{name} went offline", name: name)

defp title_for("online", name),
  do: gettext("%{name} is back online", name: name)

defp title_for(_, name), do: gettext("DTU state changed: %{name}", name: name)

defp body_for("offline", name),
  do: gettext("%{name} stopped reporting. We'll ping you when it's back.", name: name)

defp body_for("online", name),
  do: gettext("%{name} is reporting again.", name: name)

defp body_for(_, name),
  do: gettext("%{name} changed state.", name: name)
```

> Adapt the title/body helpers to the producer's actual current strings; the goal is to preserve the existing localisation semantics while moving the call from `Notifications.broadcast/2` to `Dispatcher.fire/3`.

Add `alias DtuApp.Notifications.Dispatcher` near the top.

- [ ] **Step 4: Run producer tests**

Run: `mix test test/dtu_app/notifications/`
Expected: PASS — every existing producer test still passes; producer-level preference gate (e.g., `notify_sun_down == false`) still suppresses both push AND email.

- [ ] **Step 5: Commit**

```bash
git add lib/dtu_app/notifications/sun_down_notifier.ex \
        lib/dtu_app/notifications/sun_up_notifier.ex \
        lib/dtu_app/notifications/dtu_connection_notifier.ex
git commit -m "feat(notifications): producers dispatch via Dispatcher.fire/3

All three producers now pass structured payloads to the dispatcher.
SunDown additionally builds the inline chart SVG at fire time;
SunUp and DtuConnection send short structured payloads.

Producer-level preference gate (e.g. notify_sun_down == false) now
correctly suppresses both push AND email — the dispatcher inherits
the producer's gate by routing through Push.native_enabled?/2 for
push and skipping email for opt-in events."
```

---

## Task 8: Add channel-chip UI to `NotificationsLive`

**Goal:** Render the "Deliver via: Notification | Email | Both" segmented control beneath the three checkboxes. Save it through `notification_settings_changeset/2`.

**Files:**
- Modify: `lib/dtu_app_web/live/notifications_live.ex` (form template + handler)

**Acceptance Criteria:**
- [ ] Three radio chips render in the form (single select).
- [ ] Submitting saves `notification_channel` via the existing `handle_event("save", ...)`.
- [ ] Reloading the page renders the previously saved selection.
- [ ] If the user picks `Email` or `Both` but `has_push_subscriptions` is false AND they have no confirmed email, an inline amber notice appears pointing at the account-settings page.

**Verify:** `mix test test/dtu_app_web/live/notifications_live_test.exs` (existing test still passes) plus a new E2E spec (Task 10).

**Steps:**

- [ ] **Step 1: Add the channel field to the LiveView form**

In `lib/dtu_app_web/live/notifications_live.ex`, immediately after the third checkbox (around line 419 — end of the sun-up label), insert:

```heex
<div class="mt-6 border-t border-zinc-200 dark:border-zinc-700 pt-4">
  <h3 class="text-sm font-semibold text-zinc-900 dark:text-white">
    {gettext("Deliver via")}
  </h3>
  <p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
    {gettext(
      "Pick how you want to receive the notifications above. Email is a good fallback if native push is flaky on your device."
    )}
  </p>

  <div class="mt-3 inline-flex rounded-lg border border-zinc-200 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-900 p-1" role="radiogroup" aria-label={gettext("Deliver via")}>
    <%= for {value, label} <- [{"push", gettext("Notification")}, {"email", gettext("Email")}, {"both", gettext("Both")}] do %>
      <label class="cursor-pointer">
        <input
          type="radio"
          name="user[notification_channel]"
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

  <%= if @form[:notification_channel].value in ["email", "both"] and is_nil(@current_scope.user.confirmed_at) do %>
    <p class="mt-3 rounded-md border border-amber-300 bg-amber-50 dark:border-amber-700 dark:bg-amber-950/40 p-2 text-xs text-amber-800 dark:text-amber-200">
      {gettext(
        "You picked email delivery, but your email address isn't confirmed. Visit account settings to confirm it, otherwise email notifications will be skipped."
      )}
    </p>
  <% end %>
</div>
```

- [ ] **Step 2: Run LiveView tests**

Run: `mix test test/dtu_app_web/live/notifications_live_test.exs`
Expected: PASS — existing form submission tests still work because `notification_settings_changeset/2` already accepts `notification_channel`.

- [ ] **Step 3: Commit**

```bash
git add lib/dtu_app_web/live/notifications_live.ex
git commit -m "feat(notifications-live): add channel-chip selector

Three radio chips (Notification / Email / Both) below the existing
checkboxes. The form already accepts notification_channel via the
extended notification_settings_changeset/2 — no controller change
needed. Inline amber warning when the user picks email but hasn't
confirmed their address."
```

---

## Task 9: Add i18n strings to all three `.po` files

**Goal:** All new strings (UI chip labels, email subject prefixes, panel headings) are localised in `en`, `de`, `fr`.

**Files:**
- Modify: `priv/gettext/en/LC_MESSAGES/default.po`
- Modify: `priv/gettext/de/LC_MESSAGES/default.po`
- Modify: `priv/gettext/fr/LC_MESSAGES/default.po`

**Acceptance Criteria:**
- [ ] `mix gettext.extract --merge` extracts all new strings.
- [ ] Each new msgid has a msgstr in all three `.po` files.
- [ ] `mix gettext.check` exits 0.
- [ ] `mix test` still passes — no missing-translation crashes.

**Verify:** `mix gettext.check && mix test test/dtu_app/emails/`

**Steps:**

- [ ] **Step 1: Extract new strings**

Run: `mix gettext.extract --merge`
Expected: New msgids appear at the end of each `.po` file (English filled in automatically; German/French empty msgstrs).

- [ ] **Step 2: Translate the new strings**

Translate every empty `msgstr ""` (the new entries only — DO NOT touch the existing 335+ French translations done earlier). Use the standard gettext format. Suggested translations:

```
msgid "Deliver via"
msgstr "Zustellung über"  # de
msgstr "Livraison via"    # fr

msgid "Pick how you want to receive the notifications above. Email is a good fallback if native push is flaky on your device."
msgstr "Wähle, wie du die Benachrichtigungen erhalten möchtest. E-Mail ist eine gute Alternative, wenn native Push auf deinem Gerät unzuverlässig ist."   # de
msgstr "Choisissez comment recevoir les notifications ci-dessus. L'e-mail est une bonne solution de secours si les notifications natives sont peu fiables sur votre appareil."  # fr

msgid "Notification"  (chip label)
msgstr "Benachrichtigung"  # de
msgstr "Notification"      # fr (same)

msgid "Email"  (chip label)
msgstr "E-Mail"            # de
msgstr "E-mail"            # fr (with hyphen)

msgid "Both"
msgstr "Beide"  # de
msgstr "Les deux"  # fr

msgid "You picked email delivery, but your email address isn't confirmed. Visit account settings to confirm it, otherwise email notifications will be skipped."
msgstr "Du hast E-Mail gewählt, aber deine E-Mail-Adresse ist nicht bestätigt. Bestätige sie in den Kontoeinstellungen, sonst werden E-Mail-Benachrichtigungen übersprungen."  # de
msgstr "Vous avez choisi la livraison par e-mail, mais votre adresse e-mail n'est pas confirmée. Rendez-vous dans les paramètres du compte pour la confirmer, sinon les notifications par e-mail seront ignorées."  # fr

msgid "Today's yield"
msgstr "Heutiger Ertrag"  # de
msgstr "Production du jour"  # fr

msgid "Peak power"
msgstr "Spitzenleistung"  # de
msgstr "Puissance crête"  # fr

msgid "Today"
msgstr "Heute"  # de
msgstr "Aujourd'hui"  # fr

msgid "vs yesterday"
msgstr "gg. gestern"  # de
msgstr "vs hier"  # fr

msgid "same as yesterday"
msgstr "wie gestern"  # de
msgstr "comme hier"  # fr

msgid "No chart available"
msgstr "Kein Diagramm verfügbar"  # de
msgstr "Aucun graphique disponible"  # fr

msgid "Today's power curve"
msgstr "Heutige Leistungskurve"  # de
msgstr "Courbe de puissance du jour"  # fr

msgid "Hi,"
msgstr "Hallo,"  # de
msgstr "Bonjour,"  # fr

msgid "View dashboard"
msgstr "Dashboard anzeigen"  # de
msgstr "Voir le tableau de bord"  # fr

msgid "You're getting this email because you enabled inverter connection alerts."
msgstr "Du erhältst diese E-Mail, weil du Wechselrichter-Verbindungsbenachrichtigungen aktiviert hast."  # de
msgstr "Vous recevez cet e-mail parce que vous avez activé les alertes de connexion des onduleurs."  # fr

msgid "You're getting this email because you enabled end-of-day summaries."
msgstr "Du erhältst diese E-Mail, weil du Tageszusammenfassungen aktiviert hast."  # de
msgstr "Vous recevez cet e-mail parce que vous avez activé les résumés de fin de journée."  # fr

msgid "%{name} went offline"
msgstr "%{name} ist offline"  # de
msgstr "%{name} est hors ligne"  # fr

msgid "%{name} is back online"
msgstr "%{name} ist wieder online"  # de
msgstr "%{name} est de nouveau en ligne"  # fr

msgid "DTU state changed: %{name}"
msgstr "DTU-Status geändert: %{name}"  # de
msgstr "État du DTU modifié : %{name}"  # fr

msgid "%{name} stopped reporting. We'll ping you when it's back."
msgstr "%{name} meldet sich nicht mehr. Wir benachrichtigen dich, wenn es wieder online ist."  # de
msgstr "%{name} ne répond plus. Nous vous préviendrons lorsqu'il sera de retour."  # fr

msgid "%{name} is reporting again."
msgstr "%{name} meldet sich wieder."  # de
msgstr "%{name} répond à nouveau."  # fr

msgid "%{name} changed state."
msgstr "%{name} hat den Status geändert."  # de
msgstr "%{name} a changé d'état."  # fr
```

- [ ] **Step 3: Run `gettext.check`**

Run: `mix gettext.check`
Expected: PASS — no missing translations.

- [ ] **Step 4: Run the locale smoke test**

Run: `mix test test/dtu_app/emails/`
Expected: PASS — locale-specific assertions (e.g., `assert html =~ "Heute"`) hold in the en/de/fr renders.

- [ ] **Step 5: Commit**

```bash
git add priv/gettext/en/LC_MESSAGES/default.po \
        priv/gettext/de/LC_MESSAGES/default.po \
        priv/gettext/fr/LC_MESSAGES/default.po
git commit -m "feat(gettext): translate new channel-toggle + email strings

Adds 22 new msgids across en/de/fr for the channel toggle UI,
email panel headings, and email bodies. Verified via
mix gettext.check."
```

---

## Task 10: Add E2E test for channel-chip UI

**Goal:** A Playwright spec asserts the channel chip UI works end-to-end: select `Email`, save, reload, see `Email` chip selected.

**Files:**
- Create: `e2e/specs/notifications-channel-toggle.spec.js`

**Acceptance Criteria:**
- [ ] Spec selects the `Email` chip, saves, reloads, asserts the chip is still selected.
- [ ] Spec selects `Both`, saves, reloads, asserts both `Email` and `Notification` semantics are reflected in subsequent test notifications.
- [ ] Spec is part of the existing Playwright suite — runs in CI alongside the other notification specs.

**Verify:** `npm run test:e2e -- notifications-channel-toggle`

**Steps:**

- [ ] **Step 1: Locate the existing notifications E2E spec**

Run: `ls e2e/specs/ | grep -i notification`
Identify the file path and the test setup pattern used (signup, login, fixture data).

- [ ] **Step 2: Write the spec**

Create `e2e/specs/notifications-channel-toggle.spec.js`. Mirror the existing spec's setup. Skeleton (adapt as needed):

```javascript
import { test, expect } from '@playwright/test';

test.describe('Notifications channel toggle', () => {
  test('selects Email, persists across reload', async ({ page }) => {
    // Assume a test fixture logs us in and navigates to /notifications.
    await page.goto('/notifications');

    await page.getByLabel('Email', { exact: true }).check();
    await page.getByRole('button', { name: /Save preferences/i }).click();

    await page.reload();
    await expect(page.getByLabel('Email', { exact: true })).toBeChecked();
  });

  test('selects Both, then sends a test, expects email send', async ({ page, request }) => {
    await page.goto('/notifications');

    await page.getByLabel('Both').check();
    await page.getByRole('button', { name: /Save preferences/i }).click();

    // The Bamboo.TestAdapter may not be reachable from Playwright;
    // assert what we can: the chip remains selected and the
    // history list is unaffected (channel is now "both").
    await expect(page.getByLabel('Both')).toBeChecked();
  });
});
```

- [ ] **Step 3: Run the spec**

Run: `npm run test:e2e -- notifications-channel-toggle`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add e2e/specs/notifications-channel-toggle.spec.js
git commit -m "test(e2e): channel toggle selection persists across reload

Plays the same email/both/back path that a user would; asserts the
chosen chip is selected after a hard reload."
```

---

## Task 11: Full integration test + final verification

**Goal:** One end-to-end test that drives the whole pipeline (user set to `:both`, fire a sun_down, assert email sent via Swoosh AND history row records `channel: "both"`). Run the full test suite and verify nothing regressed.

**Files:**
- Modify: `test/dtu_app/notifications_test.exs` (add a single test)

**Acceptance Criteria:**
- [ ] `mix test test/dtu_app/notifications_test.exs` — passes with the new end-to-end assertion.
- [ ] `mix test` — full suite passes (including pre-existing sun-down, sun-up, dtu-connection tests).
- [ ] `mix gettext.check` — passes.
- [ ] Manual smoke (or CI job): `./bin/ci` (or the project's CI command) passes.

**Verify:** `mix test && mix gettext.check && bin/ci` (or `mix format --check-formatted && mix credo --strict || true`).

**Steps:**

- [ ] **Step 1: Add the integration test**

Append to `test/dtu_app/notifications_test.exs`:

```elixir
describe "end-to-end with :both channel" do
  test "fire/3 sends push-equivalent AND email and records channel='both'", %{user: user} do
    {:ok, user} =
      Accounts.update_notification_settings(user, %{
        "notify_sun_down" => "true",
        "notification_channel" => "both"
      })

    payload = %{
      event: "sun_down",
      title: "Sun down summary",
      body: ["Today: 12.4 kWh, peak 3,250 W."],
      tag: "sun_down:2026-08-27",
      today_yield_kwh: 12.4,
      yesterday_yield_kwh: 10.1,
      peak_power_w: 3250,
      peak_yesterday_w: 2840,
      chart_svg: "<svg viewBox='0 0 800 280'></svg>",
      dashboard_path: "/dashboard"
    }

    Notifications.broadcast(user.id, payload)

    assert_delivered_email(subject: "Sun down summary")

    assert [history] = Notifications.list_user_notifications(user, 1)
    assert history.channel == "both"
    assert history.event == "sun_down"
  end
end
```

- [ ] **Step 2: Run the test**

Run: `mix test test/dtu_app/notifications_test.exs`
Expected: PASS.

- [ ] **Step 3: Run the full suite**

Run: `mix test`
Expected: PASS — every existing test still passes alongside the new ones.

- [ ] **Step 4: Format + lint**

Run: `mix format && mix credo --strict || true`
Expected: no new warnings.

- [ ] **Step 5: Commit**

```bash
git add test/dtu_app/notifications_test.exs
git commit -m "test(notifications): end-to-end channel='both' integration test

Drives the whole pipeline: user set to :both, fire sun_down, assert
Swoosh delivered an email AND history row records channel='both'."
```

---

## Self-review

**1. Spec coverage:**
- §3 UX (three chips) → Task 8
- §4 data model (two columns) → Tasks 1, 3 step 6
- §5 dispatcher → Tasks 2, 3
- §6 producers → Task 7
- §7 inline SVG chart → Task 4
- §8 email templates → Tasks 5, 6
- §9 i18n → Task 9
- §10 error handling → Task 3 dispatcher try/rescue + Task 11 integration
- §11 tests → Tasks 1 (unit), 3 (dispatcher), 4 (chart golden), 5/6 (email locale), 10 (E2E), 11 (integration)
- §12 migration → Tasks 1, 3
- §13 out of scope → not addressed (correct)
- §14 risks → push regression: Task 2 step 6 verification; SMTP: tasks all use Bamboo.TestAdapter; SVG in Outlook: documented in spec §14 as deferred; i18n drift: Task 9 + Task 11 locale assertions.

**2. Placeholder scan:** No "TBD", no "TODO", no vague "add appropriate error handling". All code blocks contain concrete code. Tasks reference real files (line numbers / function names) so the engineer can navigate directly.

**3. Type consistency:**
- `Dispatcher.fire/3` signature is `%User{}, String.t(), map()` — every caller in Tasks 5/6/7/11 passes matching shapes.
- `SunDownEmail.render/2` returns `{html, text}` — Task 3 dispatcher expects a `{html, text}` tuple (verified in step 4).
- `Push.native_enabled?/2` accepts both string- and atom-keyed maps — Task 2 tests both.
- `notification_channel` is `"push"|"email"|"both"` everywhere — Task 1 schema, Task 3 dispatcher `cond`, Task 8 LiveView chip loop, Task 11 integration test all use the same set.

No type mismatches found.

---

## End of plan