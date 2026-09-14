defmodule DtuAppWeb.NotificationsLive.FilterHelpersTest do
  use ExUnit.Case, async: true

  alias DtuAppWeb.NotificationsLive.FilterHelpers

  describe "normalize_event_filter/1" do
    test "passes known event values through unchanged" do
      for v <- ["dtu_connection", "sun_down", "sun_up", "yield_anomaly", "test"] do
        assert FilterHelpers.normalize_event_filter(v) == v
      end
    end

    test "accepts the 'all' sentinel" do
      assert FilterHelpers.normalize_event_filter("all") == "all"
    end

    test "falls back to 'all' for nil" do
      assert FilterHelpers.normalize_event_filter(nil) == "all"
    end

    test "falls back to 'all' for an empty string" do
      assert FilterHelpers.normalize_event_filter("") == "all"
    end

    test "falls back to 'all' for unknown values (forged URL params)" do
      for v <- ["admin", "../etc/passwd", "Dtu_Connection", "ALL", "drop table"] do
        assert FilterHelpers.normalize_event_filter(v) == "all"
      end
    end
  end

  describe "event_filter_to_query/1" do
    test "translates 'all' to nil so DB queries stay unfiltered" do
      assert FilterHelpers.event_filter_to_query("all") == nil
    end

    test "translates nil and '' to nil defensively" do
      assert FilterHelpers.event_filter_to_query(nil) == nil
      assert FilterHelpers.event_filter_to_query("") == nil
    end

    test "passes specific event values through unchanged" do
      for v <- ["dtu_connection", "sun_down", "sun_up", "yield_anomaly", "test"] do
        assert FilterHelpers.event_filter_to_query(v) == v
      end
    end
  end

  describe "filter_label/1" do
    test "renders each known event with its human label" do
      assert FilterHelpers.filter_label("all") =~ "All"
      assert FilterHelpers.filter_label("dtu_connection") =~ "Connection"
      assert FilterHelpers.filter_label("sun_down") =~ "Sun down"
      assert FilterHelpers.filter_label("sun_up") =~ "Sun up"
      assert FilterHelpers.filter_label("yield_anomaly") =~ "Yield anomaly"
      assert FilterHelpers.filter_label("test") =~ "Test"
    end

    test "falls back to 'All' for unknown values" do
      assert FilterHelpers.filter_label("bogus") =~ "All"
      assert FilterHelpers.filter_label("") =~ "All"
    end
  end
end
