defmodule DtuAppWeb.DashboardLive.PeriodSelectableTest do
  @moduledoc """
  Unit tests for the pure selectable-period + calendar-input helpers
  extracted from `DtuAppWeb.DashboardLive`. Every function in
  `PeriodSelectable` except `assign_selectable_periods/3` is pure
  — same inputs → same outputs, no LiveView, no DB — so this file
  pins their behaviour in isolation.

  `assign_selectable_periods/3` does a DB read
  (`DtuApp.Devices.list_selectable_dates/2`) and exercises a LiveView
  socket, so it's covered by `DtuAppWeb.DashboardLive`'s integration
  tests instead of here. The pure builders it calls
  (`build_selectable_days/weeks/months/years`) get exhaustive unit
  coverage below so the only thing integration has to verify is the
  socket plumbing.
  """

  use ExUnit.Case, async: true

  alias DtuAppWeb.DashboardLive.PeriodSelectable

  describe "build_selectable_days/1" do
    test "empty list → empty list" do
      assert PeriodSelectable.build_selectable_days([]) == []
    end

    test "preserves date order (no sort — caller iterates in input order)" do
      dates = [~D[2026-01-01], ~D[2026-01-02], ~D[2026-01-03]]

      assert PeriodSelectable.build_selectable_days(dates) == [
               {"2026-01-01", "2026-01-01"},
               {"2026-01-02", "2026-01-02"},
               {"2026-01-03", "2026-01-03"}
             ]
    end

    test "label and value are the same ISO string for day granularity" do
      # The stepper UI shows the label and posts the value; for
      # day granularity they coincide — the stepper pivots on the
      # date itself, not a friendlier representation.
      assert PeriodSelectable.build_selectable_days([~D[2026-06-21]]) == [
               {"2026-06-21", "2026-06-21"}
             ]
    end
  end

  describe "build_selectable_weeks/1" do
    test "groups dates into ISO weeks (Monday-keyed)" do
      # 2026-06-21 is a Sunday, so the week containing it
      # runs 2026-06-15 (Mon) → 2026-06-21 (Sun).
      dates = [
        ~D[2026-06-15],
        ~D[2026-06-16],
        ~D[2026-06-21]
      ]

      [{label, value}] = PeriodSelectable.build_selectable_weeks(dates)

      assert label =~ "Year 2026"
      assert label =~ "Week 25"
      assert value == "2026-06-15"
    end

    test "sorted newest-first" do
      dates = [
        # week 2
        ~D[2026-01-05],
        # week 11
        ~D[2026-03-09],
        # week 6
        ~D[2026-02-02]
      ]

      values =
        PeriodSelectable.build_selectable_weeks(dates)
        |> Enum.map(fn {_, v} -> v end)

      assert values == ["2026-03-09", "2026-02-02", "2026-01-05"]
    end

    test "empty list → empty list" do
      assert PeriodSelectable.build_selectable_weeks([]) == []
    end
  end

  describe "build_selectable_months/1" do
    test "collapses multiple dates in the same month into one entry" do
      dates = [~D[2026-06-01], ~D[2026-06-15], ~D[2026-06-30]]

      assert [{"June 2026", "2026-06-01"}] =
               PeriodSelectable.build_selectable_months(dates)
    end

    test "sorted newest-first across months" do
      dates = [~D[2026-01-15], ~D[2026-03-15], ~D[2026-02-15]]

      values =
        PeriodSelectable.build_selectable_months(dates)
        |> Enum.map(fn {_, v} -> v end)

      assert values == ["2026-03-01", "2026-02-01", "2026-01-01"]
    end

    test "value is the first-of-month ISO date, not the input date" do
      # User might have data on 2026-06-21, but the month stepper
      # posts the first of the month so the date input default
      # lands on a known anchor.
      [{_, "2026-06-01"}] =
        PeriodSelectable.build_selectable_months([~D[2026-06-21]])
    end

    test "empty list → empty list" do
      assert PeriodSelectable.build_selectable_months([]) == []
    end
  end

  describe "build_selectable_years/1" do
    test "collapses multiple dates in the same year" do
      dates = [~D[2026-01-15], ~D[2026-06-21], ~D[2026-12-31]]

      assert [{"2026", "2026"}] =
               PeriodSelectable.build_selectable_years(dates)
    end

    test "sorted newest-first" do
      dates = [~D[2024-06-01], ~D[2026-06-01], ~D[2025-06-01]]

      [{_, v1}, {_, v2}, {_, v3}] =
        PeriodSelectable.build_selectable_years(dates)

      assert {v1, v2, v3} == {"2026", "2025", "2024"}
    end

    test "empty list → empty list" do
      assert PeriodSelectable.build_selectable_years([]) == []
    end
  end

  describe "date_input_value/1" do
    test "Date → ISO yyyy-mm-dd" do
      assert PeriodSelectable.date_input_value(~D[2026-06-21]) == "2026-06-21"
    end

    test "integer year → first-of-year ISO" do
      assert PeriodSelectable.date_input_value(2026) == "2026-01-01"
    end

    test "anything else → today's ISO date" do
      # We can't pin "today" — but the fallback always produces a
      # valid yyyy-mm-dd string of the correct length and shape.
      today_iso = PeriodSelectable.date_input_value(:nonsense)

      assert String.length(today_iso) == 10
      assert {:ok, %Date{}} = Date.from_iso8601(today_iso)
    end
  end

  describe "date_min_bound/1 and date_max_bound/1" do
    test "empty list → nil (calendar renders unbounded)" do
      assert PeriodSelectable.date_min_bound([]) == nil
      assert PeriodSelectable.date_max_bound([]) == nil
    end

    test "min picks the earliest date, max the latest" do
      dates = [~D[2026-03-15], ~D[2026-06-21], ~D[2026-01-02]]

      assert PeriodSelectable.date_min_bound(dates) == "2026-01-02"
      assert PeriodSelectable.date_max_bound(dates) == "2026-06-21"
    end

    test "single date → both bounds equal that date" do
      assert PeriodSelectable.date_min_bound([~D[2026-06-21]]) == "2026-06-21"
      assert PeriodSelectable.date_max_bound([~D[2026-06-21]]) == "2026-06-21"
    end
  end

  describe "historical_empty?/5" do
    test "day granularity with empty list → true" do
      assert PeriodSelectable.historical_empty?("day", [], [], [], []) == true
    end

    test "day granularity with non-empty list → false" do
      assert PeriodSelectable.historical_empty?("day", [{"a", "b"}], [], [], []) ==
               false
    end

    test "week granularity: empty list → true, non-empty → false" do
      assert PeriodSelectable.historical_empty?("week", [], [], [], []) == true

      assert PeriodSelectable.historical_empty?("week", [], [{"a", "b"}], [], []) ==
               false
    end

    test "month granularity: empty list → true, non-empty → false" do
      assert PeriodSelectable.historical_empty?("month", [], [], [], []) == true

      assert PeriodSelectable.historical_empty?("month", [], [], [{"a", "b"}], []) ==
               false
    end

    test "year granularity: empty list → true, non-empty → false" do
      assert PeriodSelectable.historical_empty?("year", [], [], [], []) == true

      assert PeriodSelectable.historical_empty?("year", [], [], [], [{"2026", "2026"}]) ==
               false
    end

    test "unknown granularity (e.g. \"today\") → false (live view, not historical)" do
      assert PeriodSelectable.historical_empty?("today", [], [], [], []) == false
      assert PeriodSelectable.historical_empty?("live", [], [], [], []) == false
    end
  end
end
