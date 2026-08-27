defmodule DtuApp.Emails.SunDownChartTest do
  @moduledoc """
  Tests for `DtuApp.Emails.SunDownChart.render/2`.

  The chart module is a pure renderer: it accepts a `%User{}` and a
  `%Date{}` and returns an inline SVG string. Two paths:

    * No devices / no readings → empty-state SVG with a centred
      `gettext("No chart available")` label. The empty-state SVG MUST
      still start with the brand viewBox prefix so the email template
      can drop it in verbatim.
    * Devices + readings → the SVG contains a single `<path>` stroked
      in the brand emerald `#10b981`.
  """

  use DtuApp.DataCase, async: true

  alias DtuApp.Accounts.User
  alias DtuApp.DevicesFixtures
  alias DtuApp.Emails.SunDownChart

  describe "render/2 — empty-state SVG" do
    test "starts with the brand viewBox prefix" do
      # `id: 1` doesn't own anything in the test DB, so we hit the
      # empty-state path. The brand prefix MUST survive the empty
      # state so email templates can drop the SVG in verbatim.
      svg = SunDownChart.render(%User{id: 1}, ~D[2026-08-27])
      assert svg =~ ~s(viewBox="0 0 800 280")
      assert svg =~ ~s(<svg)
      assert svg =~ ~s(</svg>)
    end

    test "localises the empty-state label via gettext" do
      svg = SunDownChart.render(%User{id: 1}, ~D[2026-08-27])
      # Source msgid falls through verbatim when no .po translation
      # is loaded for the test locale.
      assert svg =~ "No chart available"
    end
  end

  describe "render/2 — populated-state SVG" do
    setup do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      # Always land inside today (anchored at noon UTC) so the chart query
      # matches regardless of when the test runs.
      base =
        Date.utc_today()
        |> DateTime.new!(~T[12:00:00.000000])

      # 4 readings, 1 minute apart, going up — enough for a non-degenerate
      # SVG path. `list_day_chart_data_for_dashboard/4`'s aggregate path
      # needs the rows to be > 5 minutes in the past to land in the
      # closed-aggregate bucket; the live-tail fallback walks raw rows
      # directly though, so any timestamp works for the chart to find
      # at least one point.

      for i <- 0..3 do
        DevicesFixtures.reading_fixture(device, %{
          inverter_serial: "INV-A",
          mppt_index: 0,
          ac_power: 100.0 + i * 100.0,
          inserted_at: DateTime.add(base, i * 60, :second)
        })
      end

      {:ok, user: user}
    end

    test "rendered SVG starts with the brand viewBox prefix", %{user: user} do
      svg = SunDownChart.render(user, Date.utc_today())

      assert String.starts_with?(
               svg,
               ~s(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 280")
             )

      assert svg =~ ~s(viewBox="0 0 800 280")
    end

    test "contains a single <path> stroked in the brand emerald", %{user: user} do
      svg = SunDownChart.render(user, Date.utc_today())
      assert svg =~ ~s(stroke="#10b981")

      # Exactly one `<path` opening tag.
      assert svg |> String.split(~s(<path)) |> length() == 2
    end

    test "axis labels are ASCII literals, not gettext'd" do
      # The empty-state SVG (no devices) intentionally drops the axis;
      # only render it when there are actually points to plot.
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      DevicesFixtures.reading_fixture(device, %{
        inverter_serial: "INV-A",
        mppt_index: 0,
        ac_power: 200.0,
        inserted_at:
          Date.utc_today()
          |> DateTime.new!(~T[12:00:00.000000])
      })

      svg = SunDownChart.render(user, Date.utc_today())
      assert svg =~ "00:00"
      assert svg =~ "24:00"
    end
  end

  describe "render/2 — defensive contract" do
    test "always returns a binary" do
      svg = SunDownChart.render(%User{id: 1}, ~D[2026-08-27])
      assert is_binary(svg)
    end
  end
end
