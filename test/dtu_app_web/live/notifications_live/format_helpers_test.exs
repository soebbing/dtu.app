defmodule DtuAppWeb.NotificationsLive.FormatHelpersTest do
  use ExUnit.Case, async: true

  alias DtuAppWeb.NotificationsLive.FormatHelpers

  # The production 1-arg form reads `DtuApp.Time.utc_now/0` (the DB
  # clock) — see `DtuApp.Time` moduledoc for why. The DB clock
  # lives in a long-running cache process whose SQL.Sandbox
  # ownership can't be transferred into a non-`DataCase` test, so
  # we exercise the bucketing math by calling the 2-arg form with a
  # fixed `now`. The LiveView's `notifications_live_test.exs`
  # covers the rendered end-to-end path with the production clock.

  defp now, do: ~U[2026-09-15 12:00:00Z]

  describe "format_relative_time/2 (injected now)" do
    test "renders sub-minute deltas as 'just now'" do
      dt = DateTime.add(now(), -30, :second)
      assert FormatHelpers.format_relative_time(dt, now()) =~ "just now"
    end

    test "renders deltas under 1h as 'N minutes ago'" do
      dt = DateTime.add(now(), -5 * 60, :second)
      assert FormatHelpers.format_relative_time(dt, now()) =~ "5 minutes ago"
    end

    test "renders deltas under 24h as 'N hours ago'" do
      dt = DateTime.add(now(), -3 * 3600, :second)
      assert FormatHelpers.format_relative_time(dt, now()) =~ "3 hours ago"
    end

    test "renders deltas >= 24h as 'N days ago'" do
      dt = DateTime.add(now(), -2 * 86_400, :second)
      assert FormatHelpers.format_relative_time(dt, now()) =~ "2 days ago"
    end

    test "clamps future-dated DateTimes to 'just now' (clock-skew defence)" do
      # A user with a stale device clock can land notifications
      # whose `delivered_at` is a few seconds ahead of the server
      # clock. Without the `max(0)` clamp, the diff goes negative
      # and the rendered string would either crash or render an
      # awkward "−5 minutes ago" label.
      dt = DateTime.add(now(), 60, :second)
      assert FormatHelpers.format_relative_time(dt, now()) =~ "just now"
    end
  end
end
