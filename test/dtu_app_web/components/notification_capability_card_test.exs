defmodule DtuAppWeb.NotificationCapabilityCardTest do
  @moduledoc """
  Render tests for `DtuAppWeb.NotificationCapabilityCard`.

  Pure render-only — no LV, no DB. The component takes a `state`
  map (with `"state"`, `"device"`, `"installed"` keys), a
  `has_push_subscriptions` boolean, and a `user_id`. We exercise
  each of the six rendered variants plus the nested iOS edge-case
  branch inside `:granted`.

  Covers:

    - Wrapper contract: `id="notifications-permission"` +
      `phx-hook="NotificationPermission"` + `data-user-id`.
    - Each of the six `:state` values renders a distinct panel:
        * `"unsupported"`  — amber-50 panel, no enable button
        * `"not_installed"` — amber-50 panel, install hint
        * `"denied"`       — rose-50 panel, "blocked" copy
        * `"default"`      — zinc panel, `#notifications-enable` button
        * `"granted"`      — emerald-50 panel, nested iOS edge case
        * `nil` / `""`     — zinc "Checking browser capabilities…"
    - `:default + device="desktop"` uses the desktop copy;
      `:default + device=nil` (mobile-or-unknown) uses the PWA copy.
    - `:granted` inner branches:
        * `:granted + has_push_subscriptions + mobile + not_installed`
          → amber inset (iOS edge case)
        * `:granted + has_push_subscriptions + anything-else`
          → "Native push is on" emerald text
        * `:granted + no-subscriptions + desktop + recently_revoked_subscription`
          → amber inset + re-subscribe button
          (overrides the "keep tab open" hint)
        * `:granted + no-subscriptions + desktop`
          → "Keep this tab open" emerald text
        * `:granted + no-subscriptions + mobile + recently_revoked_subscription`
          → amber inset + re-subscribe button
          (overrides the base-copy-only fallback)
        * `:granted + no-subscriptions + mobile`
          → just the base "Notifications are enabled…" line, no
            inner hint
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DtuAppWeb.NotificationCapabilityCard

  defp state(overrides) do
    Map.merge(%{"state" => nil, "device" => nil, "installed" => nil}, Map.new(overrides))
  end

  defp render_card(assigns) do
    render_component(&NotificationCapabilityCard.notification_capability_card/1, assigns)
  end

  describe "wrapper contract" do
    test "renders id=notifications-permission + phx-hook=NotificationPermission + data-user-id" do
      html =
        render_card(%{
          state: state([]),
          has_push_subscriptions: false,
          user_id: 42
        })

      assert html =~ ~s(id="notifications-permission")
      assert html =~ ~s(phx-hook="NotificationPermission")
      assert html =~ ~s(data-user-id="42")
    end
  end

  describe "state variants" do
    test ":unsupported renders the amber PWA-install panel" do
      html =
        render_card(%{
          state: state(%{"state" => "unsupported"}),
          has_push_subscriptions: false,
          user_id: 1
        })

      assert html =~ "Browsers must be installed as a PWA"
      assert html =~ "border-amber-300"
    end

    test ":not_installed renders the amber install-hint panel" do
      html =
        render_card(%{
          state: state(%{"state" => "not_installed"}),
          has_push_subscriptions: false,
          user_id: 1
        })

      assert html =~ "Install this site as a PWA first"
      assert html =~ "border-amber-300"
    end

    test ":denied renders the rose blocked panel" do
      html =
        render_card(%{
          state: state(%{"state" => "denied"}),
          has_push_subscriptions: false,
          user_id: 1
        })

      assert html =~ "Notifications are blocked in your browser settings"
      assert html =~ "border-rose-300"
    end

    test ":granted renders the emerald panel + base copy" do
      html =
        render_card(%{
          state: state(%{"state" => "granted"}),
          has_push_subscriptions: false,
          user_id: 1
        })

      assert html =~ "Notifications are enabled."
      assert html =~ "border-emerald-300"
    end

    test "missing/nil state renders the loading placeholder" do
      html =
        render_card(%{
          state: state(%{"state" => nil}),
          has_push_subscriptions: false,
          user_id: 1
        })

      assert html =~ "Checking browser capabilities…"
    end
  end

  describe ":default variant" do
    test "renders the #notifications-enable button" do
      html =
        render_card(%{
          state: state(%{"state" => "default"}),
          has_push_subscriptions: false,
          user_id: 1
        })

      assert html =~ ~s(id="notifications-enable")
      assert html =~ "Enable notifications"
    end

    test "desktop device uses the desktop copy (no PWA install required)" do
      html =
        render_card(%{
          state: state(%{"state" => "default", "device" => "desktop"}),
          has_push_subscriptions: false,
          user_id: 1
        })

      assert html =~ "Desktop browsers do not require a PWA install"
    end

    test "non-desktop device uses the PWA copy" do
      html =
        render_card(%{
          state: state(%{"state" => "default", "device" => "mobile"}),
          has_push_subscriptions: false,
          user_id: 1
        })

      refute html =~ "Desktop browsers do not require a PWA install"
      assert html =~ "browser will ask whether to allow notifications for this PWA"
    end
  end

  describe ":granted variant — nested iOS edge case" do
    test "granted + mobile + not_installed + subscriptions → amber inset" do
      html =
        render_card(%{
          state:
            state(%{
              "state" => "granted",
              "device" => "mobile",
              "installed" => false
            }),
          has_push_subscriptions: true,
          user_id: 1
        })

      assert html =~ "iOS only fires OS notifications from the home-screen app"
      assert html =~ "border-amber-300"
    end

    test "granted + subscriptions + (mobile + installed=true) → emerald 'Native push is on'" do
      html =
        render_card(%{
          state:
            state(%{
              "state" => "granted",
              "device" => "mobile",
              "installed" => true
            }),
          has_push_subscriptions: true,
          user_id: 1
        })

      assert html =~ "Native push is on for this device"
      refute html =~ "iOS only fires OS notifications from the home-screen app"
    end

    test "granted + subscriptions + desktop → emerald 'Native push is on'" do
      html =
        render_card(%{
          state: state(%{"state" => "granted", "device" => "desktop"}),
          has_push_subscriptions: true,
          user_id: 1
        })

      assert html =~ "Native push is on for this device"
      refute html =~ "Keep this tab open"
    end

    test "granted + no-subscriptions + desktop → emerald 'Keep this tab open'" do
      html =
        render_card(%{
          state: state(%{"state" => "granted", "device" => "desktop"}),
          has_push_subscriptions: false,
          user_id: 1
        })

      assert html =~ "Keep this tab open to receive notifications"
      refute html =~ "Native push is on for this device"
    end

    test "granted + no-subscriptions + mobile → base copy only, no inner hint" do
      html =
        render_card(%{
          state: state(%{"state" => "granted", "device" => "mobile"}),
          has_push_subscriptions: false,
          user_id: 1
        })

      assert html =~ "Notifications are enabled."
      refute html =~ "Keep this tab open to receive notifications"
      refute html =~ "Native push is on for this device"
      refute html =~ "iOS only fires OS notifications"
    end
  end

  describe ":granted variant — recently-revoked subscription prompt" do
    test "granted + no-subscriptions + recently_revoked_subscription=true → amber inset + re-subscribe button" do
      html =
        render_card(%{
          state: state(%{"state" => "granted", "device" => "desktop"}),
          has_push_subscriptions: false,
          recently_revoked_subscription: true,
          user_id: 1
        })

      assert html =~ "Your browser cleared its push subscription"
      assert html =~ "border-amber-300"
      # Replaces the existing "Keep this tab open" hint — silent
      # drop is more urgent than a tab-open reminder.
      refute html =~ "Keep this tab open to receive notifications"
      # Wires the existing PushSubscribe JS hook to re-subscribe
      # without the user having to revoke + re-grant permission.
      assert html =~ ~s(id="notifications-re-subscribe")
    end

    test "granted + no-subscriptions + recently_revoked_subscription=true + mobile → still amber inset" do
      html =
        render_card(%{
          state: state(%{"state" => "granted", "device" => "mobile"}),
          has_push_subscriptions: false,
          recently_revoked_subscription: true,
          user_id: 1
        })

      assert html =~ "Your browser cleared its push subscription"
      assert html =~ ~s(id="notifications-re-subscribe")
    end

    test "granted + no-subscriptions + recently_revoked_subscription=false → existing green hint (no regression)" do
      html =
        render_card(%{
          state: state(%{"state" => "granted", "device" => "desktop"}),
          has_push_subscriptions: false,
          recently_revoked_subscription: false,
          user_id: 1
        })

      assert html =~ "Keep this tab open to receive notifications"
      refute html =~ "Your browser cleared its push subscription"
      refute html =~ ~s(id="notifications-re-subscribe")
    end

    test "granted + subscriptions + recently_revoked_subscription=true → no amber inset (iOS edge case still wins)" do
      # If the user has a live subscription, the recently-revoked
      # signal is irrelevant — they're still getting push. Only the
      # iOS edge case applies.
      html =
        render_card(%{
          state:
            state(%{
              "state" => "granted",
              "device" => "mobile",
              "installed" => false
            }),
          has_push_subscriptions: true,
          recently_revoked_subscription: true,
          user_id: 1
        })

      assert html =~ "iOS only fires OS notifications from the home-screen app"
      refute html =~ "Your browser cleared its push subscription"
      refute html =~ ~s(id="notifications-re-subscribe")
    end
  end
end
