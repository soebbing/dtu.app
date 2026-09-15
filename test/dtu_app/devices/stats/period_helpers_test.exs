defmodule DtuApp.Devices.Stats.PeriodHelpersTest do
  use ExUnit.Case, async: true

  alias DtuApp.Devices.Stats.PeriodHelpers

  describe "last_n_days_window/2" do
    test "returns (today, today) for n=1" do
      today_start = DateTime.new!(~D[2026-09-15], ~T[00:00:00], "Etc/UTC")
      assert PeriodHelpers.last_n_days_window(1, today_start) == {~D[2026-09-15], ~D[2026-09-15]}
    end

    test "returns (today, today-6) for n=7" do
      today_start = DateTime.new!(~D[2026-09-15], ~T[00:00:00], "Etc/UTC")
      assert PeriodHelpers.last_n_days_window(7, today_start) == {~D[2026-09-15], ~D[2026-09-09]}
    end

    test "returns (today, today-29) for n=30" do
      today_start = DateTime.new!(~D[2026-09-15], ~T[00:00:00], "Etc/UTC")
      assert PeriodHelpers.last_n_days_window(30, today_start) == {~D[2026-09-15], ~D[2026-08-17]}
    end

    test "crosses month boundary correctly" do
      today_start = DateTime.new!(~D[2026-03-05], ~T[00:00:00], "Etc/UTC")
      assert PeriodHelpers.last_n_days_window(7, today_start) == {~D[2026-03-05], ~D[2026-02-27]}
    end
  end

  describe "zero_period_stats/0" do
    test "returns the all-zero map with nil peak_date" do
      assert PeriodHelpers.zero_period_stats() == %{
               current_consumption: 0.0,
               today_consumption: 0.0,
               peak_consumption: 0.0,
               period_total_consumption: 0.0,
               period_peak_consumption: 0.0,
               peak_date: nil
             }
    end
  end

  describe "resolve_consumption_period_date/2" do
    test "nil input resolves to (today_utc_start, today_date)" do
      today_start = DateTime.new!(~D[2026-09-15], ~T[00:00:00], "Etc/UTC")

      {date_utc, date_local} = PeriodHelpers.resolve_consumption_period_date(nil, today_start)

      assert date_utc == today_start
      # The local-date resolves to Date.utc_today/0's value at the time
      # the test runs, not the injected today_start — call sites care
      # only that this is a real Date. We just check it's today.
      assert date_local == Date.utc_today()
    end

    test "%Date{} input passes through unchanged" do
      today_start = DateTime.new!(~D[2026-09-15], ~T[00:00:00], "Etc/UTC")

      assert PeriodHelpers.resolve_consumption_period_date(~D[2026-08-01], today_start) ==
               {~D[2026-08-01], ~D[2026-08-01]}
    end

    test "unexpected input falls back to (today_utc_start, today_date)" do
      today_start = DateTime.new!(~D[2026-09-15], ~T[00:00:00], "Etc/UTC")

      assert PeriodHelpers.resolve_consumption_period_date("garbage", today_start) ==
               {today_start, Date.utc_today()}
    end
  end

  describe "week_range/2" do
    test "explicit %Date{} Monday returns (Monday, Sunday)" do
      today_start = DateTime.new!(~D[2026-09-15], ~T[00:00:00], "Etc/UTC")

      # 2026-09-15 is a Tuesday
      assert PeriodHelpers.week_range(~D[2026-09-15], today_start) ==
               {~D[2026-09-14], ~D[2026-09-20]}
    end

    test "explicit %Date{} Sunday returns the same week's (Monday, Sunday)" do
      today_start = DateTime.new!(~D[2026-09-15], ~T[00:00:00], "Etc/UTC")

      # 2026-09-20 is a Sunday
      assert PeriodHelpers.week_range(~D[2026-09-20], today_start) ==
               {~D[2026-09-14], ~D[2026-09-20]}
    end

    test "explicit %Date{} Saturday returns (Mon before, Sun after)" do
      today_start = DateTime.new!(~D[2026-09-15], ~T[00:00:00], "Etc/UTC")

      # 2026-09-19 is a Saturday
      assert PeriodHelpers.week_range(~D[2026-09-19], today_start) ==
               {~D[2026-09-14], ~D[2026-09-20]}
    end

    test "cross-month week returns Mon..Sun across the boundary" do
      today_start = DateTime.new!(~D[2026-09-15], ~T[00:00:00], "Etc/UTC")

      # 2026-09-30 is a Wednesday
      assert PeriodHelpers.week_range(~D[2026-09-30], today_start) ==
               {~D[2026-09-28], ~D[2026-10-04]}
    end
  end

  describe "month_range/2" do
    test "explicit %Date{} returns first and last day of that month" do
      today_start = DateTime.new!(~D[2026-09-15], ~T[00:00:00], "Etc/UTC")

      assert PeriodHelpers.month_range(~D[2026-08-15], today_start) ==
               {~D[2026-08-01], ~D[2026-08-31]}
    end

    test "February in a leap year returns 29 days" do
      today_start = DateTime.new!(~D[2026-09-15], ~T[00:00:00], "Etc/UTC")

      assert PeriodHelpers.month_range(~D[2024-02-15], today_start) ==
               {~D[2024-02-01], ~D[2024-02-29]}
    end

    test "February in a non-leap year returns 28 days" do
      today_start = DateTime.new!(~D[2026-09-15], ~T[00:00:00], "Etc/UTC")

      assert PeriodHelpers.month_range(~D[2025-02-15], today_start) ==
               {~D[2025-02-01], ~D[2025-02-28]}
    end
  end

  describe "year_value/1" do
    test "integer passthrough" do
      assert PeriodHelpers.year_value(2024) == 2024
    end

    test "%Date{} returns the year" do
      assert PeriodHelpers.year_value(~D[2026-08-15]) == 2026
    end

    test "nil returns the current year" do
      assert PeriodHelpers.year_value(nil) == Date.utc_today().year
    end
  end
end
