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

  # `async: false` — the populated-state describe block inserts
  # `users` + `dtus` + `readings` during setup. Concurrent tests in
  # other `async: true` modules that touch the same tables acquire
  # `ShareRowExclusiveLock` on the FK-referenced rows; the two
  # transactions can deadlock when they reference parents in opposite
  # orders. Both of the previous ExUnit-PostgreSQL 40P01/57P03 CI
  # deadlocks landed on this file (sun_down_chart_test:90) and on
  # devices_test.exs:49 (`shelly_consumption_row/4`). See
  # `docs/dtu-app-exunit-recovery-mode-flake` memory note — wait-step
  # fixes made things worse (PRs #118/#122); `async: false` is the
  # only durable fix without rewriting the fixtures.
  use DtuApp.DataCase, async: false

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

      {:ok, user: user, device: device}
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
      # Post-PR the x-axis has four evenly-spaced labels (00:00, 06:00,
      # 12:00, 18:00) — the pre-PR "24:00" corner label is gone.
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

      for label <- ["00:00", "06:00", "12:00", "18:00"] do
        assert svg =~ ~s(>#{label}</text>),
               "expected x-axis label #{inspect(label)} in SVG"
      end
    end

    # ── Visual enrichment: filled area, gridlines, peak marker ──────────
    #
    # Pre-PR the chart was a single polyline with two corner time
    # labels — useful for a glance, useless for reading magnitudes.
    # These tests pin the post-PR enrichment: the area under the
    # curve is filled at low opacity so the visual weight matches
    # the dashboard chart; horizontal gridlines + y-axis watt
    # labels let the eye read magnitudes; a peak marker highlights
    # the day's max with both a dot and a label.
    test "path is filled under the curve (not just stroked)", %{user: user} do
      svg = SunDownChart.render(user, Date.utc_today())
      # The single `<path>` now closes back to the baseline so it
      # accepts a fill. Pre-PR this was `fill="none"`.
      assert svg =~ ~r|<path[^>]*fill="#10b981"[^>]*fill-opacity="0\.\d+"|
    end

    test "renders horizontal gridlines for y-axis", %{user: user} do
      svg = SunDownChart.render(user, Date.utc_today())
      # Five horizontal gridlines: 0 W, max/4, max/2, 3max/4, max.
      # Each is rendered as a `<line>` element with stroke="#e2e8f0".
      gridline_count =
        svg
        |> String.split(~r|<line[^>]*stroke="#e2e8f0"|)
        |> length()
        |> Kernel.-(1)

      assert gridline_count == 5,
             "expected 5 horizontal gridlines, got #{gridline_count}"
    end

    test "y-axis tick labels show watt values (locale-formatted)", %{user: user} do
      svg = SunDownChart.render(user, Date.utc_today())
      # The y-axis tick labels include "0" (zero baseline) and the
      # peak watt formatted via `Devices.format_number/3`. The test
      # reads the test locale (no .po loaded → falls through to the
      # source msgid / default locale formatting), so we assert on
      # the unit suffix rather than exact digits.
      assert svg =~ ~r|<text[^>]*>0\s*W</text>|
      assert svg =~ ~r|<text[^>]*>\d[\d,]*\s*W</text>|
    end

    test "x-axis shows four time labels across the bottom", %{user: user} do
      svg = SunDownChart.render(user, Date.utc_today())
      # Pre-PR had only "00:00" + "24:00" at the corners. Post-PR
      # shows 00:00, 06:00, 12:00, 18:00 evenly spaced. The corner
      # labels are dropped because the evenly-spaced quartet is
      # more useful for reading the time of day.
      for label <- ["00:00", "06:00", "12:00", "18:00"] do
        assert svg =~ ~s(>#{label}</text>),
               "expected x-axis label #{inspect(label)} in SVG"
      end

      # The pre-PR corner label "24:00" is gone.
      refute svg =~ ~s(>24:00</text>)
    end

    test "renders a peak-power marker (circle + label) at the day's max", %{user: user} do
      svg = SunDownChart.render(user, Date.utc_today())
      # The fixture seeds 4 readings going up: 100, 200, 300, 400 W.
      # The max is 400 W at the last point. Post-PR the chart draws
      # a small filled `<circle>` at that point and a label like
      # "Peak: 400 W".
      assert svg =~ ~r|<circle[^>]*r="3"[^>]*fill="#10b981"|

      assert svg =~ ~r|<text[^>]*>\s*Peak:\s*\d[\d,]*\s*W\s*</text>|
    end

    test "axis title 'Power' appears on the left side", %{user: user} do
      svg = SunDownChart.render(user, Date.utc_today())
      assert svg =~ ~r|<text[^>]*>\s*Power\s*</text>|
    end

    test "renders a dashed gray yesterday overlay when yesterday has data", %{
      user: user,
      device: device
    } do
      # The populated-state setup seeds today's data only; the dashboard
      # ghost line is rendered when `list_yesterday_chart_data_for_dashboard/4`
      # returns a non-empty list, so we need to seed yesterday too.
      # The dashboard uses `stroke-dasharray="4 3"` + `stroke-opacity="0.35"`
      # + a zinc-400 / gray-500 fallback (`#6b7280`) — pin those three
      # so the email chart composites visually with the dashboard.
      yesterday_base =
        Date.utc_today()
        |> DateTime.new!(~T[12:00:00.000000])
        |> DateTime.add(-86_400, :second)

      for i <- 0..3 do
        DevicesFixtures.reading_fixture(device, %{
          inverter_serial: "INV-A",
          mppt_index: 0,
          ac_power: 80.0 + i * 80.0,
          inserted_at: DateTime.add(yesterday_base, i * 60, :second)
        })
      end

      svg = SunDownChart.render(user, Date.utc_today())

      assert svg =~ ~r|<path[^>]*stroke="#6b7280"|
      assert svg =~ ~r|stroke-dasharray="4 3"|
      assert svg =~ ~r|stroke-opacity="0.35"|
    end

    test "omits the yesterday overlay when yesterday has no data", %{user: user} do
      # Pre-PR-equivalent: today's readings exist (from the populated-state
      # setup) but yesterday's are absent. The overlay MUST be dropped
      # entirely — a degenerate `<path>` with a single point would still
      # be stroked by Chromium and look like an accidental dot.
      svg = SunDownChart.render(user, Date.utc_today())

      refute svg =~ ~r|stroke="#6b7280"|
      refute svg =~ ~r|stroke-dasharray="4 3"|
    end
  end

  describe "render/2 — defensive contract" do
    test "always returns a binary" do
      svg = SunDownChart.render(%User{id: 1}, ~D[2026-08-27])
      assert is_binary(svg)
    end
  end

  # Localization: every user-facing string in the chart (y-axis unit,
  # x-axis time labels, peak marker, rotated axis title) is now wrapped
  # in `gettext/1`. DE/FR share the same msgid for SI units ("%{n} W")
  # and 24h times (no leading-zero variants in either locale) but
  # differ on the axis title and the peak-marker label. These tests
  # lock the per-locale msgstrs so a future merge that re-introduces
  # a fuzzy match (or that drops a translation) fails loudly.
  describe "render/2 — localization" do
    setup do
      user = DtuApp.AccountsFixtures.user_fixture()
      device = DevicesFixtures.device_fixture(user)

      base =
        Date.utc_today()
        |> DateTime.new!(~T[12:00:00.000000])

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

    test "renders English (default locale) chart text", %{user: user} do
      svg = SunDownChart.render(user, Date.utc_today())
      assert svg =~ ~s(>0 W</text>)
      assert svg =~ ~r|>\s*Peak:\s*\d[\d,]*\s*W\s*</text>|
      assert svg =~ ~s(>Power</text>)

      for label <- ["00:00", "06:00", "12:00", "18:00"] do
        assert svg =~ ~s(>#{label}</text>)
      end
    end

    test "renders German chart text under locale=de", %{user: user} do
      svg =
        Gettext.with_locale(DtuAppWeb.Gettext, "de", fn ->
          SunDownChart.render(user, Date.utc_today())
        end)

      assert svg =~ ~s(>Leistung</text>)
      assert svg =~ ~r|>\s*Spitze:\s*\d[\d,]*\s*W\s*</text>|
      # SI unit and 24h times are identical across DE/EN/FR.
      assert svg =~ ~s(>0 W</text>)

      for label <- ["00:00", "06:00", "12:00", "18:00"] do
        assert svg =~ ~s(>#{label}</text>)
      end
    end

    test "renders French chart text under locale=fr", %{user: user} do
      svg =
        Gettext.with_locale(DtuAppWeb.Gettext, "fr", fn ->
          SunDownChart.render(user, Date.utc_today())
        end)

      assert svg =~ ~s(>Puissance</text>)
      assert svg =~ ~r|>\s*Pic :\s*\d[\d,]*\s*W\s*</text>|
      assert svg =~ ~s(>0 W</text>)

      for label <- ["00:00", "06:00", "12:00", "18:00"] do
        assert svg =~ ~s(>#{label}</text>)
      end
    end
  end

  # `render_svg/1` is the pure points → SVG renderer (public-but-internal
  # so the nil-power guard can be unit-tested without the DB). The
  # pre-PR version crashed with `ArithmeticError: bad argument in
  # arithmetic expression` from `Kernel./(1)` when the points list
  # contained nil-power entries (a partially-populated live-tail
  # bucket, or a NULL `avg_ac_power` from the `readings_5m`
  # continuous aggregate). Reproduced in prod on 2026-09-16 against
  # CEST user picking 2026-09-15 via the Regenerate button; the same
  # path exists on the daily producer's `try_fire/1` and would have
  # crashed silently.
  describe "render_svg/1 — nil-power guard" do
    test "filters nil-power entries and renders the surviving points" do
      # Mixed list — the nil-power entry must be dropped, the
      # numeric entries must render the same SVG as a pure list.
      points = [
        %{time: ~U[2026-09-15 10:00:00Z], series: {1, "INV-A", 0, "Garage"}, power: nil},
        %{time: ~U[2026-09-15 10:05:00Z], series: {1, "INV-A", 0, "Garage"}, power: 100.0},
        %{time: ~U[2026-09-15 10:10:00Z], series: {1, "INV-A", 0, "Garage"}, power: nil},
        %{time: ~U[2026-09-15 10:15:00Z], series: {1, "INV-A", 0, "Garage"}, power: 200.0}
      ]

      svg = SunDownChart.render_svg(points)

      assert is_binary(svg)
      assert svg =~ ~r|<svg[^>]+viewBox="0 0 800 280"|
      # Two surviving points → one `<path>` with two `L` segments.
      assert svg =~ ~r|<path d="M[^"]+"|
      assert svg =~ ~r|L\d+\.\d+,\d+\.\d+ L\d+\.\d+,\d+\.\d+|
    end

    test "all-nil-power list falls back to the empty-state SVG (no crash)" do
      # The pre-PR crash signature: a list where every entry has
      # `power: nil`. `Enum.max/1` of `[nil, nil]` raises
      # `ArgumentError` (comparison); `Enum.max/1` of `[nil]`
      # raises `ArgumentError` too. The crash path that hit prod
      # was a list where one entry's `power` decoded to a
      # non-numeric (e.g. NULL → `:unsupported` representation, or
      # an `avg_ac_power` returning `:undefined` in some PG
      # decoder path). Whatever the exact type, the contract is:
      # never raise, always return a usable SVG.
      points = [
        %{time: ~U[2026-09-15 10:00:00Z], series: {1, "INV-A", 0, "Garage"}, power: nil},
        %{time: ~U[2026-09-15 10:05:00Z], series: {1, "INV-A", 0, "Garage"}, power: nil}
      ]

      svg = SunDownChart.render_svg(points)

      assert is_binary(svg)
      assert svg =~ "No chart available"
      # Empty state has NO `<path>` (only the empty-state label).
      refute svg =~ ~r|<path d="M|
    end

    test "empty list falls back to the empty-state SVG (regression guard)" do
      # The pre-PR private `render_svg/1` already handled `[]` via
      # a dedicated clause; pinning the public version does the
      # same so a future refactor that drops the filter keeps the
      # empty-list path intact.
      svg = SunDownChart.render_svg([])

      assert is_binary(svg)
      assert svg =~ "No chart available"
      refute svg =~ ~r|<path d="M|
    end

    test "all-numeric list renders the populated SVG (regression guard)" do
      # Sanity check: the filter must not regress the happy path.
      points = [
        %{time: ~U[2026-09-15 10:00:00Z], series: {1, "INV-A", 0, "Garage"}, power: 100.0},
        %{time: ~U[2026-09-15 10:05:00Z], series: {1, "INV-A", 0, "Garage"}, power: 200.0}
      ]

      svg = SunDownChart.render_svg(points)

      assert is_binary(svg)
      assert svg =~ ~r|<path d="M[^"]+"|
      refute svg =~ "No chart available"
    end
  end
end
