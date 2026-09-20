defmodule DtuApp.Notifications.DtuConnection.PayloadTest do
  @moduledoc """
  Unit tests for `DtuApp.Notifications.DtuConnection.Payload` —
  the pure payload-building + gettext helpers extracted from
  `DtuApp.Notifications.DtuConnection`.

  No DB or GenServer needed: every function here is a pure
  gettext lookup (`title/2`, `body/2`) or a struct shape
  constructor (`build/3`). The `:since` field on `build/3`
  accepts a caller-supplied `DateTime` so tests can pin
  the timestamp rather than racing the system clock.
  """

  use DtuApp.DataCase, async: false

  alias DtuApp.Notifications.DtuConnection.Payload

  describe "title/2" do
    test "returns the :went_offline title" do
      assert Payload.title(:went_offline, "Garage Inverter") == "DTU went offline"
    end

    test "returns the :back_online title" do
      assert Payload.title(:back_online, "Garage Inverter") == "DTU back online"
    end

    test "falls back to the generic %{name} title for an unknown status" do
      assert Payload.title(:some_future_status, "Garage Inverter") ==
               "DTU status changed for Garage Inverter"
    end

    test "interpolates %{name} in the fallback for non-ASCII names" do
      assert Payload.title(:unknown, "Wechselrichter") ==
               "DTU status changed for Wechselrichter"
    end
  end

  describe "body/2" do
    test "returns the :went_offline body with %{name} interpolated" do
      assert Payload.body(:went_offline, "Garage Inverter") ==
               "Your inverter Garage Inverter has gone offline."
    end

    test "returns the :back_online body with %{name} interpolated" do
      assert Payload.body(:back_online, "Garage Inverter") ==
               "Your inverter Garage Inverter is publishing telemetry again."
    end

    test "returns nil for an unknown status (no generic body fallback)" do
      # Unlike `title/2`, `body/2` has no generic fallback — an
      # unknown status returns `nil` so the caller's `if body, do: ...`
      # guards short-circuit cleanly.
      assert Payload.body(:some_future_status, "Garage Inverter") == nil
    end
  end

  describe "build/3" do
    setup do
      now = ~U[2026-09-15 12:00:00.000000Z]
      {:ok, now: now}
    end

    test "returns a map with all expected keys for :went_offline", %{now: now} do
      payload = Payload.build(:went_offline, "Garage Inverter", now, last_seen_at: nil)

      assert payload.event == "dtu_connection"
      assert payload.status == :went_offline
      assert payload.dtu_name == "Garage Inverter"
      assert payload.since == now
    end

    test "returns a map with all expected keys for :back_online", %{now: now} do
      payload = Payload.build(:back_online, "Garage Inverter", now, last_seen_at: nil)

      assert payload.event == "dtu_connection"
      assert payload.status == :back_online
      assert payload.dtu_name == "Garage Inverter"
      assert payload.since == now
    end

    test "title matches the :went_offline gettext title", %{now: now} do
      payload = Payload.build(:went_offline, "Garage Inverter", now, last_seen_at: nil)
      assert payload.title == "DTU went offline"
    end

    test "title matches the :back_online gettext title", %{now: now} do
      payload = Payload.build(:back_online, "Garage Inverter", now, last_seen_at: nil)
      assert payload.title == "DTU back online"
    end

    test ":went_offline body contains a diagnostic paragraph with the last reading time", %{
      now: now
    } do
      last_seen_at = DateTime.add(now, -12 * 60, :second)
      payload = Payload.build(:went_offline, "Garage Inverter", now, last_seen_at: last_seen_at)

      assert is_list(payload.body)
      assert length(payload.body) == 2
      # Second paragraph is the diagnostic — case-insensitive on
      # "reading" to match both the en ("Last reading") and the
      # de/fr catalogs (where the noun may differ).
      assert Enum.any?(payload.body, &String.downcase(&1) =~ "reading")
    end

    test ":back_online body contains a diagnostic paragraph with the offline duration", %{
      now: now
    } do
      # The notifier passes `since` for the back-online path as
      # "when did the disconnect happen" — see
      # `DtuConnection.fire_for_status/2`. The diagnostic paragraph
      # should reference that duration so the user knows how long
      # the outage was.
      disconnected_at = DateTime.add(now, -7 * 60, :second)
      payload = Payload.build(:back_online, "Garage Inverter", now, since: disconnected_at)

      assert is_list(payload.body)
      assert length(payload.body) == 2
      assert Enum.any?(payload.body, &String.downcase(&1) =~ "offline")
    end

    test ":went_offline body omits the diagnostic paragraph when no last_seen_at is provided", %{
      now: now
    } do
      # Edge case: if the producer never had a live reading for
      # this device (e.g. the very first sighting was the
      # disconnect), the diagnostic paragraph has no useful data
      # and is omitted — the user gets a one-line body that still
      # says "your inverter has gone offline".
      payload = Payload.build(:went_offline, "Garage Inverter", now, last_seen_at: nil)

      assert is_list(payload.body)
      assert length(payload.body) == 1
      refute Enum.any?(payload.body, &String.downcase(&1) =~ "reading")
    end

    test "body list first element matches the :went_offline gettext body", %{now: now} do
      payload = Payload.build(:went_offline, "Garage Inverter", now, last_seen_at: nil)

      assert is_list(payload.body)

      assert hd(payload.body) ==
               "Your inverter Garage Inverter has gone offline."
    end

    test "body list first element matches the :back_online gettext body", %{now: now} do
      payload = Payload.build(:back_online, "Garage Inverter", now, last_seen_at: nil)

      assert is_list(payload.body)

      assert hd(payload.body) ==
               "Your inverter Garage Inverter is publishing telemetry again."
    end

    test "tag is 'dtu:<name>' without the :status suffix (dedup relies on producer gates)", %{
      now: now
    } do
      payload = Payload.build(:went_offline, "Garage Inverter", now, last_seen_at: nil)
      assert payload.tag == "dtu:Garage Inverter"
    end

    test ":since is the caller-supplied now, not DateTime.utc_now()", %{now: now} do
      # If `build/4` ignored its `now` arg and stamped `DateTime.utc_now()`
      # inline, this assertion would fail (the two clocks diverge within
      # seconds).
      payload = Payload.build(:went_offline, "Garage Inverter", now, last_seen_at: nil)
      assert payload.since == now
    end
  end
end
