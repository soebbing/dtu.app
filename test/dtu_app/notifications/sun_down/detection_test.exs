defmodule DtuApp.Notifications.SunDown.DetectionTest do
  @moduledoc """
  Unit tests for `DtuApp.Notifications.SunDown.Detection` —
  the pure fleet-power + sunset-gate analysis helpers extracted
  from the SunDown GenServer.

  These run without the GenServer: every function here is
  either stateless (struct accessors) or takes a fully-formed
  state map and a clock instant. The DB-touching path
  (`past_sunset?/2`) uses `safe_get_user/1` which wraps the
  lookup in `:rescue` so a brief DB hiccup returns `nil` —
  same shape as the notifier's defensive twin.
  """

  use DtuApp.DataCase, async: false

  import DtuApp.AccountsFixtures

  alias DtuApp.Accounts
  alias DtuApp.Accounts.User
  alias DtuApp.Notifications.SunDown.Detection
  alias DtuApp.Repo

  describe "reading_dtu_id/1" do
    test "extracts integer dtu_id from a struct-like map" do
      assert Detection.reading_dtu_id(%{dtu_id: 42}) == 42
    end

    test "extracts string-cast dtu_id from a stripped test fixture" do
      assert Detection.reading_dtu_id(%{dtu_id: "abc-1"}) == "abc-1"
    end

    test "returns nil when dtu_id is nil (synthetic disconnect fixture)" do
      assert Detection.reading_dtu_id(%{dtu_id: nil}) == nil
    end

    test "returns nil when reading is not a map" do
      assert Detection.reading_dtu_id(nil) == nil
      assert Detection.reading_dtu_id(:not_a_map) == nil
    end
  end

  describe "reading_ac_power/1" do
    test "returns numeric ac_power when mppt_index is 0" do
      assert Detection.reading_ac_power(%{mppt_index: 0, ac_power: 123.4}) == 123.4
    end

    test "returns 0.0 when mppt_index is 0 and ac_power is nil" do
      assert Detection.reading_ac_power(%{mppt_index: 0, ac_power: nil}) == 0.0
    end

    test "returns :ignore for non-AC-aggregate rows (mppt_index >= 1)" do
      assert Detection.reading_ac_power(%{mppt_index: 1, ac_power: 50.0}) == :ignore
      assert Detection.reading_ac_power(%{mppt_index: 2, ac_power: nil}) == :ignore
    end

    test "returns :ignore for shapes that don't carry ac_power at all" do
      assert Detection.reading_ac_power(%{dtu_id: 1}) == :ignore
      assert Detection.reading_ac_power(nil) == :ignore
    end
  end

  describe "active_fleet_w/2" do
    test "sums power_w for devices with fresh readings" do
      now = DateTime.utc_now()
      devices = %{1 => %{power_w: 100.0, last_reading_at: now}}

      assert Detection.active_fleet_w(devices, now) == 100.0
    end

    test "excludes devices whose last reading is older than the stale window" do
      now = DateTime.utc_now()
      stale = DateTime.add(now, -400, :second)

      devices = %{
        1 => %{power_w: 100.0, last_reading_at: now},
        2 => %{power_w: 200.0, last_reading_at: stale}
      }

      assert Detection.active_fleet_w(devices, now) == 100.0
    end

    test "returns 0.0 when there are no devices" do
      assert Detection.active_fleet_w(%{}, DateTime.utc_now()) == 0.0
    end
  end

  describe "all_devices_silent?/2" do
    test "is vacuously true when the user has no devices" do
      assert Detection.all_devices_silent?(%{devices: []}, DateTime.utc_now()) == true
    end

    test "is true when every device's last reading is stale" do
      now = DateTime.utc_now()
      stale = DateTime.add(now, -400, :second)

      user_state = %{
        devices: %{
          1 => %{power_w: 100.0, last_reading_at: stale},
          2 => %{power_w: 50.0, last_reading_at: stale}
        }
      }

      assert Detection.all_devices_silent?(user_state, now) == true
    end

    test "is false when at least one device has a fresh reading" do
      now = DateTime.utc_now()
      stale = DateTime.add(now, -400, :second)

      user_state = %{
        devices: %{
          1 => %{power_w: 100.0, last_reading_at: now},
          2 => %{power_w: 50.0, last_reading_at: stale}
        }
      }

      assert Detection.all_devices_silent?(user_state, now) == false
    end
  end

  describe "past_sunset?/2" do
    test "is true for a user with no coordinates (fallback contract)" do
      user = user_fixture(%{latitude: nil, longitude: nil})

      assert Detection.past_sunset?(user.id, DateTime.utc_now()) == true
    end

    test "is true for a user whose coordinates are missing one axis" do
      user = user_fixture(%{latitude: 52.5, longitude: nil})

      assert Detection.past_sunset?(user.id, DateTime.utc_now()) == true
    end

    test "is true for a user with coordinates and a 'now' well past today's sunset" do
      user = user_fixture()
      :ok = Accounts.update_user_location(user, %{latitude: 52.5, longitude: 13.4})
      user = Repo.get!(User, user.id)

      # 23:00 UTC is well past Berlin's ~17:30 UTC sunset in September.
      now = ~U[2026-09-15 23:00:00Z]
      assert Detection.past_sunset?(user.id, now) == true
    end

    test "is false for a user with coordinates and a 'now' before today's sunset" do
      user = user_fixture()
      :ok = Accounts.update_user_location(user, %{latitude: 52.5, longitude: 13.4})
      user = Repo.get!(User, user.id)

      # 12:00 UTC is well before Berlin's ~17:30 UTC sunset in September.
      now = ~U[2026-09-15 12:00:00Z]
      assert Detection.past_sunset?(user.id, now) == false
    end

    test "is true for a vanished user id (deletion race)" do
      assert Detection.past_sunset?(999_999_999, DateTime.utc_now()) == true
    end

    # Negative-UTC-offset regression: a PDT user (Los Angeles,
    # UTC-7) at UTC 03:00 Sep 15 is on LOCAL Sep 14 20:00, which
    # is 30 minutes past their local sunset (~19:30 PDT). The
    # current code uses `DateTime.to_date(now)` → UTC Sep 15 and
    # then computes LA's Sep 15 sunset (UTC Sep 16 02:30) — so
    # `now < future_sunset` and the gate blocks. The gate should
    # translate `now` to the user's local date first and use that
    # for the sunset lookup, mirroring the fix for the SunDown
    # fire date in `Notifications.SunDown`.
    test "is true for a negative-offset user in their local evening (UTC morning)" do
      user = user_fixture()
      # LA: ~34.05°N, ~-118.24°E (negative longitude)
      :ok = Accounts.update_user_location(user, %{latitude: 34.05, longitude: -118.24})
      user = Repo.get!(User, user.id)

      # UTC Sep 15 03:00 = PDT Sep 14 20:00. PDT sunset on Sep 14
      # is around UTC Sep 15 02:30 (PDT 19:30), so the user is
      # ~30 minutes past local sunset.
      now = ~U[2026-09-15 03:00:00Z]
      assert Detection.past_sunset?(user.id, now) == true
    end

    test "is false for a negative-offset user in their local mid-afternoon (UTC late evening)" do
      user = user_fixture()
      :ok = Accounts.update_user_location(user, %{latitude: 34.05, longitude: -118.24})
      user = Repo.get!(User, user.id)

      # UTC Sep 15 22:00 = PDT Sep 15 15:00 — mid-afternoon local,
      # ~4.5 hours before PDT sunset (~19:30). Gate must return false.
      now = ~U[2026-09-15 22:00:00Z]
      assert Detection.past_sunset?(user.id, now) == false
    end
  end

  describe "read_now/0" do
    test "returns the configured DateTime when :sun_down_now is set" do
      configured = ~U[2026-09-15 14:30:00Z]
      Application.put_env(:dtu_app, :sun_down_now, configured)

      on_exit(fn -> Application.delete_env(:dtu_app, :sun_down_now) end)

      assert Detection.read_now() == configured
    end

    test "falls back to wall-clock time when :sun_down_now is unset" do
      Application.delete_env(:dtu_app, :sun_down_now)

      # `DtuApp.Time.utc_now/0` caches the value, so the result can
      # be at-or-before the test's wall-clock capture (the cache may
      # have been populated earlier in the suite). Assert the
      # returned value is a sane, recent DateTime instead of an
      # ordering relation.
      result = Detection.read_now()
      assert %DateTime{} = result
      # No more than 1 hour stale — the cache TTL bounds it well
      # below this in practice.
      assert DateTime.diff(DateTime.utc_now(), result, :second) < 3_600
    end
  end
end
