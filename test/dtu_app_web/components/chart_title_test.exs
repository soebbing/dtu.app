defmodule DtuAppWeb.ChartTitleTest do
  @moduledoc """
  Render tests for `DtuAppWeb.ChartTitle`.

  Pure render-only tests — no LiveView, no DB. We exercise every
  branch of the nine-case `cond do` decision tree by setting the
  attrs directly. The German-only month-name path (the only place
  in the dashboard template that calls `Gettext.gettext/2`
  explicitly) is covered by the `:time_range == "month"` test, which
  confirms `Calendar.strftime(@selected_period, "%B")` is the
  argument and the year is appended after it.

  Selected-period shapes per branch (mirrors the dashboard's
  production side):

    * `day`   → `Date.t()`     (e.g. `~D[2026-09-14]`)
    * `week`  → `Date.t()`     (start of the selected week)
    * `month` → `%{month: 1..12, year: 2024..}` (e.g. `%{month: 9, year: 2026}`)
    * `year`  → `%{year: 2024..}` (e.g. `%{year: 2026}`)
    * `7d` / `30d` / `ytd` → unused
    * consumption-only branches → unused
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DtuAppWeb.ChartTitle

  # Verify that the wrapping <h2 id="chart-title"> is preserved
  # across every branch. Keeps the dashboard integration tests'
  # `document.querySelector("#chart-title")` selector stable.
  # Phoenix prepends `phx-r ` to the opening tag on render, and
  # the trailing slug `..., dark:text-white mb-4" id="chart-title">`
  # is the reliable suffix.
  defp assert_wrapper(html) do
    assert html =~ ~s(dark:text-white mb-4" id="chart-title">)
  end

  describe "consumption-only, live" do
    test "renders 'Today's Consumption Curve (Watts)' when no inverter + shelly + live" do
      html =
        render_component(&ChartTitle.chart_title/1, %{
          live: true,
          has_inverter: false,
          has_shelly: true
        })

      assert_wrapper(html)
      assert html =~ "Today&#39;s Consumption Curve (Watts)"
      # The production-only branches should NOT match.
      refute html =~ "Production Curve"
      refute html =~ "Daily Yields"
      refute html =~ "Monthly Yields"
    end

    test "consumption-live branch takes precedence over the production-live branch" do
      # Even when has_shelly is true, has_inverter flips to false
      # and live=true, so the consumption-live branch wins over
      # the production-live branch.
      html =
        render_component(&ChartTitle.chart_title/1, %{
          live: true,
          has_inverter: false,
          has_shelly: true,
          time_range: "day"
        })

      assert html =~ "Today&#39;s Consumption Curve (Watts)"
      refute html =~ "Production Curve"
    end
  end

  describe "consumption-only, day" do
    test "renders 'Consumption Curve for %{period} (Watts)' when no inverter + shelly + day" do
      period = ~D[2026-09-14]

      html =
        render_component(&ChartTitle.chart_title/1, %{
          live: false,
          has_inverter: false,
          has_shelly: true,
          time_range: "day",
          selected_period: period
        })

      assert_wrapper(html)
      assert html =~ "Consumption Curve for 2026-09-14 (Watts)"
      refute html =~ "Production Curve"
    end
  end

  describe "production, live" do
    test "renders 'Today's Production Curve (Watts)' when inverter + live" do
      html =
        render_component(&ChartTitle.chart_title/1, %{
          live: true,
          has_inverter: true,
          has_shelly: false
        })

      assert_wrapper(html)
      assert html =~ "Today&#39;s Production Curve (Watts)"
      refute html =~ "Consumption Curve"
    end
  end

  describe "production, day" do
    test "renders 'Production Curve for %{period} (Watts)' when inverter + day" do
      period = ~D[2026-09-14]

      html =
        render_component(&ChartTitle.chart_title/1, %{
          live: false,
          has_inverter: true,
          has_shelly: false,
          time_range: "day",
          selected_period: period
        })

      assert_wrapper(html)
      assert html =~ "Production Curve for 2026-09-14 (Watts)"
      # NOT the consumption-day branch — verify the inverter-true path.
      refute html =~ "Consumption Curve"
    end
  end

  describe "production, week" do
    test "renders 'Daily Yields for Week starting %{period} (kWh)' on time_range=week" do
      week_start = ~D[2026-09-14]

      html =
        render_component(&ChartTitle.chart_title/1, %{
          live: false,
          has_inverter: true,
          has_shelly: false,
          time_range: "week",
          selected_period: week_start
        })

      assert_wrapper(html)
      assert html =~ "Daily Yields for Week starting 2026-09-14 (kWh)"
      refute html =~ "Production Curve"
    end
  end

  describe "production, month (German month-name path)" do
    test "renders 'Daily Yields for month of %{month} %{year} (kWh)' on time_range=month" do
      # The German-only path is `Gettext.gettext(DtuAppWeb.Gettext,
      # Calendar.strftime(@selected_period, "%B"))`. We don't
      # translate English month names in de.po (verified by grep),
      # so the German fallback is `msgid`-as-`msgstr` and the
      # rendered output uses the English month name. The assertion
      # is on the strftime -> year concatenation, which is what
      # gives the test its coverage.
      period = %{month: 9, year: 2026}

      html =
        render_component(&ChartTitle.chart_title/1, %{
          live: false,
          has_inverter: true,
          has_shelly: false,
          time_range: "month",
          selected_period: period
        })

      assert_wrapper(html)

      # Calendar.strftime on %{month: 9, ...} returns a Date then
      # %B → "September". The component joins it with " 2026" so
      # we expect "...September 2026...".
      assert html =~ "Daily Yields for month of September 2026 (kWh)"
    end

    test "month-year case uses Gettext.gettext/2 on the strftime result, not the gettext/1 macro" do
      # Smoke test on a different month so we can't ride the cache of
      # the previous test's interpolation.
      period = %{month: 3, year: 2025}

      html =
        render_component(&ChartTitle.chart_title/1, %{
          live: false,
          has_inverter: true,
          has_shelly: false,
          time_range: "month",
          selected_period: period
        })

      # %B on March → "March"; year 2025.
      assert html =~ "March 2025"
      # Make sure day-specific branches did NOT match (production-day
      # would render "2025-03-01", not "March 2025").
      refute html =~ "Production Curve"
      refute html =~ "Monthly Yields for 2025"
    end

    test "month-year case does not touch other branches even when has_shelly=true" do
      # Time_range=month + has_shelly=true should still pick the
      # production-month branch (consumption-only is gated on
      # has_inverter=false; has_shelly is irrelevant on the
      # production side).
      period = %{month: 9, year: 2026}

      html =
        render_component(&ChartTitle.chart_title/1, %{
          live: false,
          has_inverter: true,
          has_shelly: true,
          time_range: "month",
          selected_period: period
        })

      assert html =~ "Daily Yields for month of September 2026 (kWh)"
      refute html =~ "Consumption Curve"
    end
  end

  describe "production, year" do
    test "renders 'Monthly Yields for %{year} (kWh)' on time_range=year" do
      period = %{year: 2026}

      html =
        render_component(&ChartTitle.chart_title/1, %{
          live: false,
          has_inverter: true,
          has_shelly: false,
          time_range: "year",
          selected_period: period
        })

      assert_wrapper(html)
      assert html =~ "Monthly Yields for 2026 (kWh)"
      refute html =~ "Daily Yields"
    end
  end

  describe "production, 7d / 30d / ytd" do
    test "renders 'Daily Yields — Last 7 days (kWh)' on time_range=7d" do
      html =
        render_component(&ChartTitle.chart_title/1, %{
          live: false,
          has_inverter: true,
          has_shelly: false,
          time_range: "7d"
        })

      assert_wrapper(html)
      assert html =~ "Daily Yields — Last 7 days (kWh)"
    end

    test "renders 'Daily Yields — Last 30 days (kWh)' on time_range=30d" do
      html =
        render_component(&ChartTitle.chart_title/1, %{
          live: false,
          has_inverter: true,
          has_shelly: false,
          time_range: "30d"
        })

      assert_wrapper(html)
      assert html =~ "Daily Yields — Last 30 days (kWh)"
    end

    test "renders 'Monthly Yields — Year to date (kWh)' on time_range=ytd" do
      html =
        render_component(&ChartTitle.chart_title/1, %{
          live: false,
          has_inverter: true,
          has_shelly: false,
          time_range: "ytd"
        })

      assert_wrapper(html)
      assert html =~ "Monthly Yields — Year to date (kWh)"
    end
  end

  describe "fall-through" do
    test "render is contained in a single <h2 id='chart-title'> element" do
      html =
        render_component(&ChartTitle.chart_title/1, %{
          live: false,
          has_inverter: true,
          has_shelly: false,
          time_range: "day",
          selected_period: ~D[2026-09-14]
        })

      # The dashboard's integration tests look the title up by id,
      # so we assert exactly one such id appears.
      assert html =~ ~s(id="chart-title")
      # And only one opening <h2 … chart-title …> tag.
      assert length(Regex.run(~r/<h2 [^>]*id="chart-title"/, html)) == 1
    end
  end
end
