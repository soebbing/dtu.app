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

  describe "decorate_for_dispatch/3" do
    # The bare `build_payload/3` output uses the JS-hook key names
    # (`today_yield_yesterday_kwh` / `peak_power_yesterday_w`); the
    # email renderer reads the renamed keys (`yesterday_yield_kwh`
    # / `peak_yesterday_w`), an inline `chart_svg`, and a
    # `dashboard_path`. Without the augmentation the SunDownEmail
    # rendered "Yesterday: — kWh" / "No chart available" for any
    # broadcast that came from a path other than the producer's
    # `try_fire/1` — most visibly the regenerate handler on
    # `/notifications`. The helper below guarantees the augmentation
    # is applied uniformly; both call sites now go through it.
    setup do
      # Use a persisted fixture user — `SunDownChart.render/2`
      # queries `Devices.Credentials.list_devices/1` to build the
      # inline SVG, and that query crashes on a nil user_id (Ecto's
      # nil-safety guard). A bare struct without an id is enough to
      # break the augmentation path the test is meant to cover;
      # the fixture gives us a real, empty user with an id.
      user = DtuApp.AccountsFixtures.user_fixture()

      bare_payload = %{
        event: "sun_down",
        title: "Sun's down — daily summary",
        body: "Today: 5.0 kWh, peak 1000.0 W.",
        tag: "sun_down:2026-09-15",
        date: "2026-09-15",
        today_yield_kwh: 5.0,
        peak_power_w: 1000.0,
        today_yield_yesterday_kwh: 4.0,
        peak_power_yesterday_w: 800.0
      }

      {:ok, user: user, bare: bare_payload}
    end

    test "mirrors the JS-hook diff keys to the email-renderer keys", %{
      user: user,
      bare: bare
    } do
      augmented = Payload.decorate_for_dispatch(bare, user, ~D[2026-09-15])

      assert augmented.yesterday_yield_kwh == bare.today_yield_yesterday_kwh
      assert augmented.peak_yesterday_w == bare.peak_power_yesterday_w
    end

    test "wraps body in a single-element list (dispatcher / email layout contract)", %{
      user: user,
      bare: bare
    } do
      augmented = Payload.decorate_for_dispatch(bare, user, ~D[2026-09-15])

      assert augmented.body == [bare.body]
    end

    test "attaches a dashboard_path of '/dashboard'", %{user: user, bare: bare} do
      augmented = Payload.decorate_for_dispatch(bare, user, ~D[2026-09-15])

      assert augmented.dashboard_path == "/dashboard"
    end

    test "attaches a chart_svg (string or nil — never missing)", %{user: user, bare: bare} do
      # The chart render hits the cached daily series; if no device
      # fetched a chart today the renderer returns an empty SVG
      # string. Either way the key MUST be present so the email
      # renderer's `payload[:chart_svg] || payload["chart_svg"]`
      # branch resolves cleanly — the bug we're guarding against is
      # the bare payload not having the key AT ALL.
      augmented = Payload.decorate_for_dispatch(bare, user, ~D[2026-09-15])

      assert Map.has_key?(augmented, :chart_svg),
             "expected `chart_svg` key to be present on the dispatched payload"
    end

    test "preserves the JS-hook keys verbatim (no stripping of today_yield_yesterday_kwh)", %{
      user: user,
      bare: bare
    } do
      # The augmentation ADDS email keys — it must NOT remove the
      # JS-hook keys the in-page browser formatter
      # (`formatPayload`) consumes.
      augmented = Payload.decorate_for_dispatch(bare, user, ~D[2026-09-15])

      assert augmented.today_yield_yesterday_kwh == bare.today_yield_yesterday_kwh
      assert augmented.peak_power_yesterday_w == bare.peak_power_yesterday_w
      assert augmented.today_yield_kwh == bare.today_yield_kwh
      assert augmented.peak_power_w == bare.peak_power_w
      assert augmented.title == bare.title
      assert augmented.tag == bare.tag
      assert augmented.date == bare.date
      assert augmented.event == bare.event
    end
  end

  describe "build_payload/3 — silent-drop regression (per-MPPT-only fleet)" do
    # Regression: a user with devices whose firmware publishes
    # per-MPPT rows (`mppt_index >= 1`) but never the synthesised
    # AC-aggregate row (`mppt_index = 0`) used to get a
    # "Your devices haven't reported any readings today" history
    # row on every sunset — even though their devices were
    # actively reporting all day. The producer's
    # `try_fire/1` writes that row when `build_payload/3` returns
    # `nil`, and the OLD predicate
    # (`current_power == 0.0 and per_series == []`) tripped
    # exactly when:
    #
    #   * `current_power == 0.0` — true at sunset (idle window
    #     has elapsed, the inverter's last AC uplink is past the
    #     2-minute "recent" slice), AND
    #   * `per_series == []` — `ac_latest_per_inverter` filters
    #     to `mppt_index = 0` (the AC aggregate row); on a
    #     per-MPPT-only fleet that DISTINCT ON is empty even when
    #     the per-MPPT rows are flowing.
    #
    # The corrected predicate checks `today.has_readings` from the
    # stats struct, which runs the same DISTINCT ON without the
    # `mppt_index = 0` filter — so a per-MPPT-only fleet correctly
    # reports `has_readings == true` and the producer no longer
    # writes the misleading "no readings" row.

    # Pick a timestamp that's reliably within today's local-day
    # window (UTC for the test environment). Wall-clock-agnostic
    # via the same `< today_start ? bump forward : keep` shim used
    # by the chart-regression tests — straddling midnight UTC is
    # the failure mode, not the happy path.
    defp reading_within_today_local(seconds_ago) do
      reading_at =
        DateTime.utc_now()
        |> DateTime.truncate(:second)
        |> DateTime.add(-seconds_ago, :second)

      case DateTime.compare(reading_at, DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")) do
        :lt -> DateTime.add(reading_at, 2 * 3600, :second)
        _ -> reading_at
      end
    end

    test "returns a non-nil payload when the fleet only emitted per-MPPT rows today (no mppt_index = 0)" do
      user = DtuApp.AccountsFixtures.user_fixture()
      dtu = DtuApp.DevicesFixtures.device_fixture(user, %{name: "Per-MPPT Inverter"})

      # Per-MPPT row (`mppt_index: 1`) — what AhoyDTU-style
      # firmware emits when it has multiple MPPT channels but no
      # synthesised AC aggregate row. `ac_power` is still
      # populated on the ch1 row in the parser's current
      # implementation (AhoyDTU's `ACPower` field is mapped onto
      # `ac_power` regardless of channel), but the
      # `ac_latest_per_inverter` DISTINCT ON inside
      # `production_stats.ex` filters it out via
      # `r.mppt_index == 0`. That's exactly the bug: a fleet with
      # 100 W of per-MPPT data registers as "no readings today"
      # to the producer.
      reading_at = reading_within_today_local(15 * 60)

      {:ok, _} =
        DtuApp.Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV",
          mppt_index: 1,
          ac_power: 100.0,
          inserted_at: reading_at
        })

      payload = Payload.build_payload(user, Date.utc_today(), 0)

      assert payload != nil,
             "expected build_payload/3 to return a real payload — " <>
               "the device reported per-MPPT rows earlier today; " <>
               "the OLD `per_series == []` predicate tripped on the " <>
               "mppt_index = 0 filter even though readings exist"

      assert payload.event == "sun_down"
      assert payload.tag == "sun_down:#{Date.to_iso8601(Date.utc_today())}"
    end

    test "still returns nil when the user has devices but no readings at all today" do
      # Negative control for the regression above: when there are
      # genuinely no readings, `has_readings == false` MUST still
      # short-circuit to `nil`. A user with a freshly-created
      # device that never uplinked is the canonical case — the
      # silent-day history row is the correct UX here (see
      # `silent drop when build_payload/2 returns nil` in the
      # notifier test), the regression is only that the predicate
      # was firing it for fleets that DID report.
      user = DtuApp.AccountsFixtures.user_fixture()
      _dtu = DtuApp.DevicesFixtures.device_fixture(user, %{name: "Silent DTU"})

      assert Payload.build_payload(user, Date.utc_today(), 0) == nil
    end
  end
end
