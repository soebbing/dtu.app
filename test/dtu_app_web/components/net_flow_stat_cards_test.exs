defmodule DtuAppWeb.NetFlowStatCardsTest do
  @moduledoc """
  Render tests for `DtuAppWeb.NetFlowStatCards`.

  Pure render-only tests — no LiveView, no DB. The
  `net_flow_stats` map is constructed by hand because the
  component only reads five numeric keys off it; we don't
  need the live `ConsumptionChartData.get_net_flow_stats/3`
  machinery to exercise the render branches.

  The outer guard (paired inverter + shelly + nonzero stats)
  stays in the dashboard template — this component is the
  inner block, so we test it on its own with whatever the
  caller has already validated.

  Covers the four cards and the sign-aware colour/label
  switch on the first card (Current Net Flow):

    * Current Net Flow — emerald when `current_net_flow >= 0`
      ("Net export"), rose when negative ("Net import").
      Always renders the absolute value.
    * Exported today — emerald always.
    * Imported today — rose always.
    * Peak power — blue, shows `max(peak_export, peak_import)`.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DtuAppWeb.NetFlowStatCards

  defp stats(overrides \\ %{}) do
    defaults = %{
      # Positive = exporting; this default is "currently exporting
      # at 850 W".
      current_net_flow: 850.0,
      today_net_export: 12.45,
      today_net_import: 3.21,
      peak_export: 2_400.0,
      peak_import: 1_100.0
    }

    Map.merge(defaults, overrides)
  end

  describe "section header" do
    test "renders the 'Net flow' heading" do
      html =
        render_component(&NetFlowStatCards.net_flow_stat_cards/1, %{
          net_flow_stats: stats()
        })

      assert html =~ "Net flow"
    end
  end

  describe "current net flow card (sign-aware)" do
    test "positive current_net_flow renders 'Net export' label and emerald palette" do
      html =
        render_component(&NetFlowStatCards.net_flow_stat_cards/1, %{
          net_flow_stats: stats(%{current_net_flow: 850.0})
        })

      assert html =~ "Net export"
      refute html =~ "Net import"

      # First-card icon container: the arrows-right-left icon is
      # unique to this card (the other three cards use
      # arrow-up-right / arrow-down-left / chart-bar), so we
      # scope the palette assertion to "emerald … followed by
      # arrows-right-left" to verify the sign-aware switch hit
      # the export branch.
      assert html =~
               ~s(bg-emerald-50 dark:bg-emerald-950/30 text-emerald-600 dark:text-emerald-400">\n            <span phx-r class="hero-arrows-right-left)

      assert html =~ ~s(id="stat-net-flow")
      assert html =~ "850 W"
    end

    test "negative current_net_flow renders 'Net import' label and rose palette" do
      html =
        render_component(&NetFlowStatCards.net_flow_stat_cards/1, %{
          net_flow_stats: stats(%{current_net_flow: -1_250.0})
        })

      assert html =~ "Net import"
      refute html =~ "Net export"

      # Same scoping trick — pair the rose palette with the
      # arrows-right-left icon to scope to the first card.
      assert html =~
               ~s(bg-rose-50 dark:bg-rose-950/30 text-rose-600 dark:text-rose-400">\n            <span phx-r class="hero-arrows-right-left)

      # Absolute value (no minus sign in the rendered output).
      assert html =~ "1,250 W"
      refute html =~ "-1,250 W"
    end

    test "zero current_net_flow still picks the 'export' branch (>= 0, not > 0)" do
      html =
        render_component(&NetFlowStatCards.net_flow_stat_cards/1, %{
          net_flow_stats: stats(%{current_net_flow: 0.0})
        })

      # The original code uses `>= 0`, so zero is treated as export.
      assert html =~ "Net export"
      assert html =~ "bg-emerald-50"
    end

    test "uses the arrows-right-left icon on the sign-aware card" do
      html =
        render_component(&NetFlowStatCards.net_flow_stat_cards/1, %{
          net_flow_stats: stats()
        })

      assert html =~ ~s(class="hero-arrows-right-left )
    end
  end

  describe "exported today card" do
    test "renders the kWh value with 2 decimals and emerald palette" do
      html =
        render_component(&NetFlowStatCards.net_flow_stat_cards/1, %{
          net_flow_stats: stats(%{today_net_export: 12.45}),
          locale: "en"
        })

      assert html =~ ~s(id="stat-net-export")
      assert html =~ "12.45 kWh"
      assert html =~ "Exported today"
      assert html =~ "bg-emerald-50"
      # Arrow-up icon (separate from the arrows-right-left icon
      # used on the first card).
      assert html =~ ~s(class="hero-arrow-up-right )
    end
  end

  describe "imported today card" do
    test "renders the kWh value with 2 decimals and rose palette" do
      html =
        render_component(&NetFlowStatCards.net_flow_stat_cards/1, %{
          net_flow_stats: stats(%{today_net_import: 3.21}),
          locale: "en"
        })

      assert html =~ ~s(id="stat-net-import")
      assert html =~ "3.21 kWh"
      assert html =~ "Imported today"
      assert html =~ "bg-rose-50"
      assert html =~ ~s(class="hero-arrow-down-left )
    end
  end

  describe "peak power card" do
    test "renders max(peak_export, peak_import) with the blue palette" do
      # peak_export (2400) > peak_import (1100) → 2400.
      html =
        render_component(&NetFlowStatCards.net_flow_stat_cards/1, %{
          net_flow_stats: stats(),
          locale: "en"
        })

      assert html =~ ~s(id="stat-net-peak")
      assert html =~ "2,400 W"
      assert html =~ "Peak power"
      assert html =~ "bg-blue-50 dark:bg-blue-950/30 text-blue-600 dark:text-blue-400"
    end

    test "falls back to peak_import when peak_export is smaller" do
      html =
        render_component(&NetFlowStatCards.net_flow_stat_cards/1, %{
          net_flow_stats: stats(%{peak_export: 800.0, peak_import: 1_750.0}),
          locale: "en"
        })

      assert html =~ "1,750 W"
    end
  end
end
