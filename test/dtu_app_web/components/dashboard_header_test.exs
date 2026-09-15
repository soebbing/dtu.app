defmodule DtuAppWeb.DashboardHeaderTest do
  @moduledoc """
  Render tests for `DtuAppWeb.DashboardHeader`.

  Pure render-only tests, no LiveView, no DB. The component
  reads two keys (`locale`, `no_devices?`) and runs no domain
  logic — both flags render their full content when invoked,
  and only the right-side `Manage Devices` button toggles off
  when `no_devices?` is false.

  Covers the two branches:

    - Title-always: the dashboard heading (`PV Power Dashboard`)
      and its one-line subtitle render regardless of
      `no_devices?`.

    - Manage-Devices button (no_devices? == true): the
      conditional `<.link>` with id `btn-manage-devices` that
      navigates to `/devices`. When `false`, neither the link
      id nor the "Manage Devices" text render — the right
      side of the flex row collapses to nothing.

  Sister to `DtuAppWeb.OnboardingPanelTest` and
  `DtuAppWeb.SharePanelTest`.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DtuAppWeb.DashboardHeader

  describe "title + subtitle (always rendered)" do
    test "renders the dashboard heading with the expected style and copy" do
      html =
        render_component(&DashboardHeader.dashboard_header/1, %{
          locale: "en",
          no_devices?: false
        })

      assert html =~ "PV Power Dashboard"
      assert html =~ "text-3xl font-extrabold tracking-tight"
      assert html =~ "text-zinc-900 dark:text-white"
    end

    test "renders the one-line subtitle paragraph about real-time and historic stats" do
      html =
        render_component(&DashboardHeader.dashboard_header/1, %{
          locale: "en",
          no_devices?: false
        })

      assert html =~ "Real-time and historic generation stats for your solar converter system."
      assert html =~ "text-sm text-zinc-500 dark:text-zinc-400"
    end

    test "wraps both in a flex row that collapses on mobile and lays out on md:" do
      html =
        render_component(&DashboardHeader.dashboard_header/1, %{
          locale: "en",
          no_devices?: false
        })

      assert html =~ "flex flex-col md:flex-row md:items-center md:justify-between"
    end
  end

  describe "Manage Devices button (renders only when no_devices? == true)" do
    test "does NOT render the button when no_devices? is false" do
      html =
        render_component(&DashboardHeader.dashboard_header/1, %{
          locale: "en",
          no_devices?: false
        })

      refute html =~ "btn-manage-devices"
      refute html =~ "Manage Devices"
    end

    test "renders the button (and only the button) when no_devices? is true" do
      html =
        render_component(&DashboardHeader.dashboard_header/1, %{
          locale: "en",
          no_devices?: true
        })

      assert html =~ ~s(id="btn-manage-devices")
      assert html =~ "Manage Devices"
      # The cog icon used as the button's leading visual.
      assert html =~ "hero-cog-6-tooth"
    end

    test "the button navigates to /devices (the device-index page, not /devices/new)" do
      # The OnboardingPanel's CTA sends the user to
      # /devices/new (the create form) because that's the
      # onboarding primary action. This header button sends
      # the user to /devices (the index page) because the
      # existing user who already explored via the burger
      # menu needs the read-only overview + setup hints, not
      # the create form.
      html =
        render_component(&DashboardHeader.dashboard_header/1, %{
          locale: "en",
          no_devices?: true
        })

      assert html =~ ~s(href="/devices")
      refute html =~ ~s(href="/devices/new")
    end

    test "the button uses the white-card button styling (not the emerald-primary CTA tint)" do
      # This CTA is a secondary action — the emerald primary
      # tint is reserved for the OnboardingPanel's "Add your
      # first DTU" button. This button should use the muted
      # white-card chrome so the two CTAs don't compete.
      html =
        render_component(&DashboardHeader.dashboard_header/1, %{
          locale: "en",
          no_devices?: true
        })

      assert html =~ "border-zinc-300 dark:border-zinc-700"
      assert html =~ "bg-white dark:bg-zinc-800"
      refute html =~ "bg-emerald-500"
    end
  end

  describe "structure" do
    test "renders the title in BOTH no_devices? states (true and false)" do
      for no_devices? <- [true, false] do
        html =
          render_component(&DashboardHeader.dashboard_header/1, %{
            locale: "en",
            no_devices?: no_devices?
          })

        assert html =~ "PV Power Dashboard",
               "title missing in no_devices?=#{inspect(no_devices?)} branch"

        assert html =~ "Real-time and historic generation stats",
               "subtitle missing in no_devices?=#{inspect(no_devices?)} branch"
      end
    end

    test "does NOT render any chart, stat, or device-card elements" do
      # The header is the highest-visibility block above the
      # fold — it must not bleed into the rest of the page's
      # chrome.
      html =
        render_component(&DashboardHeader.dashboard_header/1, %{
          locale: "en",
          no_devices?: true
        })

      refute html =~ "id=\"share-panel\""
      refute html =~ "id=\"onboarding-empty\""
      refute html =~ "id=\"solar-chart-svg\""
      refute html =~ "id=\"device-status-grid\""
      refute html =~ "stat_card_row"
    end
  end
end
