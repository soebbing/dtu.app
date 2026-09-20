defmodule DtuApp.Notifications.YieldAnomaly.PayloadTest do
  @moduledoc """
  Unit tests for `DtuApp.Notifications.YieldAnomaly.Payload` —
  the pure payload builders extracted from the YieldAnomaly
  GenServer (mirrors the DtuConnection.Payload split).

  No DB or GenServer needed: every function here is a pure
  gettext lookup (`title/0`, `body/1`) or a struct shape
  constructor (`build/3`). The `:since` field on `build/3`
  accepts a caller-supplied `DateTime` so tests can pin the
  timestamp rather than racing the system clock.
  """

  use DtuApp.DataCase, async: false

  alias DtuApp.Notifications.YieldAnomaly.Payload

  describe "title/0" do
    test "returns the alert-tone title" do
      assert Payload.title() =~ "Production"
      assert Payload.title() =~ "stalled"
    end
  end

  describe "body/2" do
    test "returns the alert body for the default collapse window" do
      body = Payload.body(60, 15.0)
      assert is_binary(body)
      assert body =~ "panels"
    end
  end

  describe "build/4" do
    setup do
      now = ~U[2026-09-15 12:00:00.000000Z]
      {:ok, now: now, tag_date: ~D[2026-09-15]}
    end

    test "returns a map with all expected keys for a fired collapse", %{now: now, tag_date: tag_date} do
      payload = Payload.build(now, 60, 15.0, tag_date)

      assert payload.event == "yield_anomaly"
      assert payload.title =~ "Production"
      assert is_list(payload.body)
      assert Enum.any?(payload.body, &(&1 =~ "panels"))
      assert payload.tag =~ "yield_anomaly:"
      assert payload.since == now
    end

    test "tag uses the supplied tag_date as the dedup key (not derived from now)", %{
      now: now,
      tag_date: tag_date
    } do
      payload = Payload.build(now, 60, 15.0, tag_date)
      assert payload.tag == "yield_anomaly:#{Date.to_iso8601(tag_date)}"
    end

    test "tag_date can differ from the UTC date (e.g. user-local date around midnight)", %{
      now: now
    } do
      # Imagine a user in UTC-5: their collapse fires at
      # 04:30 UTC on the 16th, but locally it's still the
      # 15th. Producer passes the local date so the tag
      # matches the dedup row's `fired_on`.
      payload = Payload.build(now, 60, 15.0, ~D[2026-09-15])
      assert DateTime.to_date(now) == ~D[2026-09-15]

      assert payload.tag == "yield_anomaly:2026-09-15"
    end
  end
end
