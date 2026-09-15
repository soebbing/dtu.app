defmodule DtuAppWeb.DashboardToolbarTest do
  @moduledoc """
  Render tests for `DtuAppWeb.DashboardToolbar`.

  Pure render-only tests, no LiveView, no DB. The toolbar is
  a thin orchestrator over three sibling components
  (`<.dtu_switcher>`, `<.quick_range_switcher>`,
  `<.historical_stepper>`) so the tests focus on:

    - The outer vertical-stack wrapper and the
      horizontal-row wrapper around the (DTU switcher row,
      quick-range row, conditional stepper row).

    - DTU switcher rendering: hidden when 0 or 1 devices
      (`length(@devices) > 1` is the switcher's own gate);
      rendered when 2+ devices.

    - Quick-range switcher rendering: always rendered
      (`id="quick-range-switcher"`), independent of any
      other prop.

    - Historical stepper rendering: rendered only when
      `range_preset == "custom"`, never otherwise.

    - Live flag forwarding: `:live == false` lets the
      stepper's "No historical data" caption render;
      `:live == true` hides it.

  Sister to `DtuAppWeb.DashboardHeaderTest` and
  `DtuAppWeb.OnboardingPanelTest`.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DtuAppWeb.DashboardToolbar

  describe "outer wrapper" do
    test "renders a vertical-stack flex wrapper around the three sub-blocks" do
      html =
        render_component(&DashboardToolbar.dashboard_toolbar/1, %{
          devices: [],
          selected_dtu_id: nil,
          range_preset: "1d"
        })

      assert html =~ "flex flex-col gap-4"
    end
  end

  describe "DTU switcher (delegated to <.dtu_switcher>)" do
    test "renders NO switcher DOM when devices list is empty" do
      html =
        render_component(&DashboardToolbar.dashboard_toolbar/1, %{
          devices: [],
          selected_dtu_id: nil,
          range_preset: "1d"
        })

      refute html =~ ~s(id="dtu-switcher")
    end

    test "renders NO switcher DOM when devices list has one entry" do
      html =
        render_component(&DashboardToolbar.dashboard_toolbar/1, %{
          devices: [%{id: 1, name: "Garage"}],
          selected_dtu_id: 1,
          range_preset: "1d"
        })

      refute html =~ ~s(id="dtu-switcher")
    end

    test "renders the switcher when devices list has 2+ entries" do
      html =
        render_component(&DashboardToolbar.dashboard_toolbar/1, %{
          devices: [
            %{id: 1, name: "Garage"},
            %{id: 2, name: "Shed"}
          ],
          selected_dtu_id: 1,
          range_preset: "1d"
        })

      assert html =~ ~s(id="dtu-switcher")
      assert html =~ "Total (All DTUs)"
      assert html =~ "Garage"
      assert html =~ "Shed"
    end
  end

  describe "quick-range switcher (always rendered)" do
    test "renders the quick-range row regardless of range_preset" do
      for preset <- ["1d", "7d", "30d", "ytd", "custom"] do
        html =
          render_component(&DashboardToolbar.dashboard_toolbar/1, %{
            devices: [],
            selected_dtu_id: nil,
            range_preset: preset
          })

        assert html =~ ~s(id="quick-range-switcher"),
               "quick-range switcher missing for preset=#{inspect(preset)}"

        # Each preset is its own <button> child; checking the
        # literal text is sufficient because the IDs
        # (btn-range-1d, etc.) live in the same <button>s.
        assert html =~ ~s(id="btn-range-1d")
        assert html =~ ~s(id="btn-range-7d")
        assert html =~ ~s(id="btn-range-30d")
        assert html =~ ~s(id="btn-range-ytd")
        assert html =~ ~s(id="btn-range-custom")
      end
    end

    test "shares a single horizontal-row wrapper with the (conditional) stepper" do
      # The Quick Range row + (conditional) Historical stepper
      # share one `flex flex-wrap items-center gap-4` wrapper
      # so they read as one toolbar instead of two stacked
      # controls.
      html =
        render_component(&DashboardToolbar.dashboard_toolbar/1, %{
          devices: [],
          selected_dtu_id: nil,
          range_preset: "1d"
        })

      assert html =~ "flex flex-wrap items-center gap-4"
    end
  end

  describe "historical stepper (renders only when range_preset == \"custom\")" do
    test "renders NO stepper DOM for non-custom presets" do
      for preset <- ["1d", "7d", "30d", "ytd"] do
        html =
          render_component(&DashboardToolbar.dashboard_toolbar/1, %{
            devices: [],
            selected_dtu_id: nil,
            range_preset: preset
          })

        refute html =~ ~s(id="history-picker"),
               "stepper must not render for preset=#{inspect(preset)}"
      end
    end

    test "renders the stepper when range_preset is \"custom\"" do
      html =
        render_component(&DashboardToolbar.dashboard_toolbar/1, %{
          devices: [],
          selected_dtu_id: nil,
          range_preset: "custom",
          granularity: "day",
          selected_period: ~D[2026-09-15],
          selectable_dates: [~D[2026-09-15]],
          selectable_days: [~D[2026-09-15]],
          selectable_weeks: [],
          selectable_months: [],
          selectable_years: [],
          live: false
        })

      assert html =~ ~s(id="history-picker")
    end

    test "hides the stepper's \"No historical data\" caption when live is true" do
      # The <.historical_stepper> uses the @live flag to hide
      # its "No historical data for this period." caption in
      # the live view, because the live view simply doesn't
      # have a historical period to caption.
      html_with_empty_selectables =
        render_component(&DashboardToolbar.dashboard_toolbar/1, %{
          devices: [],
          selected_dtu_id: nil,
          range_preset: "custom",
          granularity: "day",
          selected_period: nil,
          selectable_dates: [],
          selectable_days: [],
          selectable_weeks: [],
          selectable_months: [],
          selectable_years: [],
          live: false
        })

      assert html_with_empty_selectables =~ "No historical data for this period."

      html_with_live_true =
        render_component(&DashboardToolbar.dashboard_toolbar/1, %{
          devices: [],
          selected_dtu_id: nil,
          range_preset: "custom",
          granularity: "day",
          selected_period: nil,
          selectable_dates: [],
          selectable_days: [],
          selectable_weeks: [],
          selectable_months: [],
          selectable_years: [],
          live: true
        })

      refute html_with_live_true =~ "No historical data for this period."
    end
  end

  describe "structure guards" do
    test "does NOT render chart, stat, or onboarding chrome" do
      # The toolbar is purely the switcher cluster — it must
      # not bleed into the rest of the dashboard.
      html =
        render_component(&DashboardToolbar.dashboard_toolbar/1, %{
          devices: [],
          selected_dtu_id: nil,
          range_preset: "1d"
        })

      refute html =~ "id=\"solar-chart-svg\""
      refute html =~ "id=\"stat-card-row\""
      refute html =~ "id=\"share-panel\""
      refute html =~ "id=\"onboarding-empty\""
      refute html =~ "id=\"device-status-grid\""
    end
  end
end
