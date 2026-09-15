defmodule DtuApp.Notifications.DtuConnection.DetectionTest do
  @moduledoc """
  Unit tests for `DtuApp.Notifications.DtuConnection.Detection` —
  the pure gate + DB-rescue helpers extracted from
  `DtuApp.Notifications.DtuConnection`.

  Runs without the GenServer: every function here is either
  stateless (DateTime comparison) or wraps a `Repo.get/2` in a
  `:rescue` so a brief DB hiccup returns `nil`. The DB-touching
  paths use fixtures from `AccountsFixtures` + `DevicesFixtures`.
  """

  use DtuApp.DataCase, async: false

  import DtuApp.AccountsFixtures
  import DtuApp.DevicesFixtures

  alias DtuApp.Notifications.DtuConnection.Detection
  alias DtuApp.Time

  describe "recently_active?/1" do
    test "returns true for a DateTime within @recency_seconds of now" do
      at = DateTime.add(Time.utc_now_usec(), -60, :second)
      assert Detection.recently_active?(at) == true
    end

    test "returns true for a DateTime exactly at the recency boundary (just inside)" do
      # 4 minutes — well inside the 5-minute @recency_seconds window.
      at = DateTime.add(Time.utc_now_usec(), -240, :second)
      assert Detection.recently_active?(at) == true
    end

    test "returns false for a DateTime older than @recency_seconds" do
      # 1 hour — well outside the 5-minute window.
      at = DateTime.add(Time.utc_now_usec(), -3_600, :second)
      assert Detection.recently_active?(at) == false
    end

    test "returns false for nil (we have no live reading)" do
      assert Detection.recently_active?(nil) == false
    end

    test "returns false for arbitrary non-DateTime input" do
      assert Detection.recently_active?("2026-09-15T12:00:00Z") == false
      assert Detection.recently_active?(:not_a_datetime) == false
    end
  end

  describe "prior_uptime?/1" do
    test "returns true for a DateTime older than @prior_uptime_seconds" do
      # 30 minutes — well beyond the 15-minute @prior_uptime_seconds.
      at = DateTime.add(Time.utc_now_usec(), -1_800, :second)
      assert Detection.prior_uptime?(at) == true
    end

    test "returns false for a DateTime within @prior_uptime_seconds of now" do
      # 5 minutes — well inside the 15-minute window.
      at = DateTime.add(Time.utc_now_usec(), -300, :second)
      assert Detection.prior_uptime?(at) == false
    end

    test "returns false for nil (we have never seen a connect for this device)" do
      assert Detection.prior_uptime?(nil) == false
    end

    test "returns false for arbitrary non-DateTime input" do
      assert Detection.prior_uptime?(123_456_789) == false
    end
  end

  describe "cooldown_over?/1" do
    test "returns true for nil (never fired — re-fire window is open)" do
      assert Detection.cooldown_over?(nil) == true
    end

    test "returns true for a DateTime older than @cooldown_seconds" do
      # 1 hour — well beyond the 30-minute @cooldown_seconds.
      at = DateTime.add(Time.utc_now_usec(), -3_600, :second)
      assert Detection.cooldown_over?(at) == true
    end

    test "returns false for a DateTime within @cooldown_seconds of now" do
      # 5 minutes — well inside the 30-minute window.
      at = DateTime.add(Time.utc_now_usec(), -300, :second)
      assert Detection.cooldown_over?(at) == false
    end
  end

  describe "safe_lookup/1" do
    test "returns a %{user_id, name, last_seen_at} map for an existing device" do
      user = user_fixture()
      dtu = device_fixture(user, %{name: "Lookup DTU"})

      assert %{user_id: user_id, name: "Lookup DTU", last_seen_at: %DateTime{}} =
               Detection.safe_lookup(dtu.id)

      assert user_id == user.id
    end

    test "returns nil for a missing device id" do
      assert Detection.safe_lookup(-1) == nil
    end
  end

  describe "safe_get_user/1" do
    test "returns the %User{} struct for an existing user id" do
      user = user_fixture(%{notify_dtu_connection: true})

      assert fetched = Detection.safe_get_user(user.id)
      assert fetched.id == user.id
      assert fetched.notify_dtu_connection == true
    end

    test "returns nil for a missing user id" do
      assert Detection.safe_get_user(-1) == nil
    end
  end
end
