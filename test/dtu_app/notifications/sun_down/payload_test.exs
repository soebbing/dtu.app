defmodule DtuApp.Notifications.SunDown.PayloadTest do
  @moduledoc """
  Unit tests for `DtuApp.Notifications.SunDown.Payload` —
  the pure payload-building + formatting helpers extracted
  from the SunDown GenServer.

  These don't depend on the GenServer: the only DB read goes
  through `DtuApp.Devices.get_daily_stats/3` which is exercised
  in the existing notifier tests; here we exercise the
  formatting helpers (`body_for/2`, `compare/3`, `format_kwh/1`,
  `format_w/1`) directly with fixture-shaped maps.
  """

  use DtuApp.DataCase, async: false

  alias DtuApp.Notifications.SunDown.Payload

  describe "body_for/2" do
    test "appends '(same as yesterday)' when today matches yesterday" do
      today = %{today_yield: 5.0, peak_power: 1000.0}
      yesterday = %{today_yield: 5.0, peak_power: 1000.0}

      body = Payload.body_for(today, yesterday)

      assert body =~ "Today: 5.0 kWh (same as yesterday)"
      assert body =~ "peak 1000.0 W (same as yesterday)"
    end

    test "formats a '+' diff when today is higher than yesterday" do
      today = %{today_yield: 6.5, peak_power: 1100.0}
      yesterday = %{today_yield: 5.0, peak_power: 1000.0}

      body = Payload.body_for(today, yesterday)

      assert body =~ "+1.5 kWh vs yesterday"
      assert body =~ "+100.0 W vs yesterday"
    end

    test "formats a diff without '+' sign when today is lower than yesterday" do
      today = %{today_yield: 4.0, peak_power: 800.0}
      yesterday = %{today_yield: 5.0, peak_power: 1000.0}

      body = Payload.body_for(today, yesterday)

      assert body =~ "-1.0 kWh vs yesterday"
      assert body =~ "-200.0 W vs yesterday"
    end

    test "renders an em-dash fallback for non-numeric stats" do
      today = %{today_yield: nil, peak_power: nil}
      yesterday = %{today_yield: 5.0, peak_power: 1000.0}

      body = Payload.body_for(today, yesterday)

      assert body =~ "Today: — kWh"
      assert body =~ "peak — W"
    end
  end

  describe "compare/3 (exercised via body_for, but pinned directly for clarity)" do
    test "returns '(same as yesterday)' for equal values" do
      # `compare/3` is private; cover via the public body_for/2 path
      today = %{today_yield: 5.0, peak_power: 1000.0}
      yesterday = %{today_yield: 5.0, peak_power: 1000.0}

      body = Payload.body_for(today, yesterday)
      assert body =~ "(same as yesterday)"
    end

    test "returns '' when yesterday is nil (no comparison available)" do
      today = %{today_yield: 5.0, peak_power: 1000.0}
      yesterday = %{today_yield: nil, peak_power: nil}

      body = Payload.body_for(today, yesterday)

      assert body =~ "Today: 5.0 kWh"
      # No diff clause when yesterday stats are missing.
      refute body =~ "vs yesterday"
    end
  end

  describe "format_kwh/1 (covered via body_for, with direct em-dash check)" do
    test "renders non-numeric values as an em-dash" do
      today = %{today_yield: nil, peak_power: 1000.0}
      yesterday = %{today_yield: 5.0, peak_power: 1000.0}

      body = Payload.body_for(today, yesterday)
      assert body =~ "Today: — kWh"
    end
  end

  describe "format_w/1 (covered via body_for, with direct em-dash check)" do
    test "renders non-numeric values as an em-dash" do
      today = %{today_yield: 5.0, peak_power: nil}
      yesterday = %{today_yield: 5.0, peak_power: 1000.0}

      body = Payload.body_for(today, yesterday)
      assert body =~ "peak — W"
    end
  end
end
