defmodule DtuAppWeb.DashboardLiveTest do
  use DtuAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import DtuApp.DevicesFixtures

  alias DtuApp.MqttBroker.Telemetry
  alias DtuApp.Devices

  setup :register_and_log_in_user

  describe "Dashboard Index" do
    test "renders empty dashboard stats and empty state message", %{conn: conn, user: user} do
      _dtu =
        device_fixture(user, %{name: "Test Inverter", kind: "opendtu", mqtt_username: "test-inv"})

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "PV Power Dashboard"
      assert html =~ "Current Generation"
      assert html =~ "0.0 W"
      assert html =~ "0.0 kWh"
      assert html =~ "No power readings logged for this day."
    end

    test "renders dashboard in German when accept-language is German", %{conn: conn, user: user} do
      _dtu =
        device_fixture(user, %{name: "Test Inverter", kind: "opendtu", mqtt_username: "test-inv"})

      conn = Plug.Conn.put_req_header(conn, "accept-language", "de-DE,de;q=0.9")
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "PV-Power-Dashboard"
      assert html =~ "Aktuelle Erzeugung"
    end

    test "renders dashboard in French when accept-language is French", %{conn: conn, user: user} do
      _dtu =
        device_fixture(user, %{name: "Test Inverter", kind: "opendtu", mqtt_username: "test-inv"})

      conn = Plug.Conn.put_req_header(conn, "accept-language", "fr-FR,fr;q=0.9")
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Tableau de bord de puissance photovoltaïque"
      assert html =~ "Génération actuelle"
    end

    test "device card shows 'time ago' last seen and hides verbose fields", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Tiny Inverter",
          kind: :ahoydtu,
          mqtt_username: "tiny-inv",
          base_topic: "balcony"
        })

      # Simulate the broker reporting the device online a couple of seconds ago.
      # Uses the same `Ecto.Changeset.change/2` path as `update_dtu_status/2`
      # in `lib/dtu_app/mqtt_broker/telemetry.ex` — `update_changeset/2` only
      # allows user-editable fields.
      dtu
      |> Ecto.Changeset.change(%{
        online: true,
        last_seen_at: DateTime.utc_now()
      })
      |> DtuApp.Repo.update()

      {:ok, _view, html} = live(conn, ~p"/dashboard?range=today")

      # Time-ago label is rendered, with the absolute timestamp as a hover hint.
      assert html =~ "just now"
      assert Regex.match?(~r/title="[^"]*UTC"/, html)

      # Verbose fields are no longer in the card body.
      refute html =~ "Base Topic"
      refute html =~ "Firmware"
      refute html =~ "MQTT Username"
    end

    test "renders connected devices and dynamically updates power stats", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Dashboard Inverter",
          kind: "opendtu",
          mqtt_username: "dash-inv"
        })

      {:ok, view, html} = live(conn, ~p"/dashboard")

      # Initially 0.0 W
      assert html =~ "0.0 W"
      assert html =~ "Dashboard Inverter"

      # Simulate reading ingestion. yield_day is in Wh (per OpenDTU/
      # AhoyDTU firmware); get_daily_stats/2 converts to kWh before the
      # dashboard renders it.
      {:ok, _reading} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "123456",
          ac_power: 350.0,
          yield_day: 1_250.0,
          inserted_at: DateTime.utc_now()
        })

      # Broadcast the reading update
      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        Telemetry.reading_topic(),
        {:reading, "client_1", %{dtu_id: dtu.id}}
      )

      # Assert the view received the update and shows 350.0 W
      html = render(view)
      assert html =~ "350.0 W"
      assert html =~ "1.25 kWh"
      assert html =~ "solar-chart-svg"
    end

    test "renders multiple DTUs and switches display between total and specific DTUs", %{
      conn: conn,
      user: user
    } do
      dtu1 =
        device_fixture(user, %{name: "DTU One", kind: "opendtu", mqtt_username: "dtu-one-user"})

      dtu2 =
        device_fixture(user, %{name: "DTU Two", kind: "ahoydtu", mqtt_username: "dtu-two-user"})

      # Seed readings for DTU 1 and DTU 2 (yield_day in Wh).
      {:ok, _r1} =
        Devices.create_reading(%{
          dtu_id: dtu1.id,
          inverter_serial: "123",
          ac_power: 100.0,
          yield_day: 1_000.0,
          inserted_at: DateTime.utc_now()
        })

      {:ok, _r2} =
        Devices.create_reading(%{
          dtu_id: dtu2.id,
          inverter_serial: "456",
          ac_power: 200.0,
          yield_day: 2_000.0,
          inserted_at: DateTime.utc_now()
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # 1. Verify "Total" view on mount (Sum of both DTUs)
      assert has_element?(view, "#dtu-switcher")
      assert has_element?(view, "#btn-select-total")
      assert has_element?(view, "#btn-select-dtu-#{dtu1.id}")
      assert has_element?(view, "#btn-select-dtu-#{dtu2.id}")

      assert element(view, "#stat-current-power") |> render() =~ "300.0 W"
      assert element(view, "#stat-today-yield") |> render() =~ "3.0 kWh"

      # 2. Click "DTU One" and verify stats filter down to DTU One's values
      view
      |> element("#btn-select-dtu-#{dtu1.id}")
      |> render_click()

      assert element(view, "#stat-current-power") |> render() =~ "100.0 W"
      assert element(view, "#stat-today-yield") |> render() =~ "1.0 kWh"

      # 3. Click "DTU Two" and verify stats filter down to DTU Two's values
      view
      |> element("#btn-select-dtu-#{dtu2.id}")
      |> render_click()

      assert element(view, "#stat-current-power") |> render() =~ "200.0 W"
      assert element(view, "#stat-today-yield") |> render() =~ "2.0 kWh"

      # 4. Click "Total" again and verify totals are displayed
      view
      |> element("#btn-select-total")
      |> render_click()

      assert element(view, "#stat-current-power") |> render() =~ "300.0 W"
      assert element(view, "#stat-today-yield") |> render() =~ "3.0 kWh"
    end

    test "renders one chart legend entry per (inverter, MPPT) series", %{
      conn: conn,
      user: user
    } do
      # Two inverters; the second one has two MPPT channels. The legend
      # should expose a friendly label per series so the chart reader can
      # tell the lines apart.
      dtu =
        device_fixture(user, %{
          name: "Multi MPPT Inverter",
          kind: "opendtu",
          mqtt_username: "multi-mppt"
        })

      now = DateTime.utc_now()

      for {serial, mppt_index, name, power} <- [
            {"INV-1", 0, "East Array", 200.0},
            {"INV-2", 1, "West Array", 80.0},
            {"INV-2", 2, "West Array", 70.0}
          ] do
        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: dtu.id,
            inverter_serial: serial,
            mppt_index: mppt_index,
            inverter_name: name,
            ac_power: power,
            inserted_at: now
          })
      end

      {:ok, view, html} = live(conn, ~p"/dashboard")

      # Legend is rendered with one swatch per series.
      assert has_element?(view, "#chart-legend")

      # Three legend entries — one per (inverter, MPPT) pair. The label
      # uses the user-set `inverter_name` and tags the AC line with
      # "(AC)" and the per-MPPT lines with "— MPPT N".
      assert html =~ "East Array (AC)"
      assert html =~ "West Array — MPPT 1"
      assert html =~ "West Array — MPPT 2"

      # The chart SVG carries one path per series, tagged with the inverter
      # serial + MPPT index so tests and any future JS hook can address
      # them. Three distinct paths total — one per (inverter, MPPT) pair.
      path_count = html |> String.split(~s(data-series=)) |> length() |> Kernel.-(1)
      assert path_count == 3

      # And each serial appears at least once (rough sanity check that all
      # three series made it into the rendered SVG, not just the first).
      assert html =~ "INV-1"
      assert html =~ "INV-2"
    end
  end

  describe "Online badge staleness" do
    # The dashboard subscribes to `dtu:status` and refreshes the device
    # card list when the periodic sweep in `Telemetry` flips any DTU
    # to `online: false`. Without this refresh, a DTU that dropped
    # off the network silently would stay "online" in the badge even
    # though "Last seen: 49 minutes ago" sits right next to it.
    #
    # Note: a full LiveView + PubSub integration test would require
    # the connected LiveView process to actually receive broadcasts.
    # Phoenix.LiveViewTest's `live/2` returns a static-rendered LiveView
    # whose handle_info wiring is exercised by the existing
    # `renders connected devices and dynamically updates power stats`
    # test (same pattern with `dtu:reading`). The
    # `Devices.mark_stale_dtus_offline/1` + `Telemetry.run_stale_dtu_sweep/0`
    # tests in the other files cover the sweep → broadcast wiring; this
    # describe block covers the dashboard's render-side contract: a
    # DTU with `online: false` renders the offline badge.

    test "renders 'online' badge for a fresh DTU with recent uplink", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Fresh DTU",
          kind: "opendtu",
          mqtt_username: "fresh-dtu",
          base_topic: "solar"
        })

      {:ok, _} =
        DtuApp.Repo.update(
          Ecto.Changeset.change(dtu, %{online: true, last_seen_at: DateTime.utc_now()})
        )

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Fresh DTU"
      assert html =~ "online"
    end

    test "renders 'offline' badge for a DTU with online: false in the DB", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Already Offline",
          kind: "opendtu",
          mqtt_username: "already-offline",
          base_topic: "solar"
        })

      {:ok, _} =
        DtuApp.Repo.update(
          Ecto.Changeset.change(dtu, %{online: false, last_seen_at: DateTime.utc_now()})
        )

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The badge text is `offline` when `device.online == false`.
      assert html =~ "Already Offline"
      assert html =~ "offline"
    end
  end

  describe "Dynamic chart X-axis range" do
    # The chart used to render with a fixed X-axis spanning 00:00–24:00
    # regardless of where the data was. That's wasteful when the data
    # only covers, say, 06:00–19:00 — half the chart is empty space on
    # both sides. Now the X-axis zooms to the data: from the floor of
    # the hour of the first data point to the next full hour after the
    # last data point. The labels adapt accordingly.

    test "zoomed chart renders hour-aligned labels at the start, middle, and end of the data range",
         %{conn: conn, user: user} do
      dtu =
        device_fixture(user, %{
          name: "Daytime Inverter",
          kind: "opendtu",
          mqtt_username: "daytime-inv",
          base_topic: "solar"
        })

      today = Date.utc_today()

      # 06:00–19:00 sine-arc shape with 30-min buckets, so 27 buckets.
      # Last bucket exactly on the 19:00 hour boundary; chart's end_hour
      # becomes 20:00 (next full hour after 19:00).
      minutes = Enum.filter((6 * 60)..(19 * 60), &(rem(&1, 30) == 0))

      for minute <- minutes do
        hour = div(minute, 60)
        min = rem(minute, 60)

        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: dtu.id,
            inverter_serial: "INV-1",
            mppt_index: 0,
            ac_power: 200.0,
            inserted_at:
              DateTime.new!(today, Time.new!(hour, min, 0))
              |> Map.put(:microsecond, {0, 6})
          })
      end

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The data spans 06:00–19:00. Chart range is 06:00–20:00
      # (total_hours = 14, step = 6).
      assert html =~ ">06:00<"
      assert html =~ ">12:00<"
      assert html =~ ">18:00<"
      assert html =~ ">20:00<"

      # The full-day markers should NOT be present in a zoomed chart —
      # they're replaced by the zoomed labels.
      refute html =~ ">00:00<"
      refute html =~ ">24:00<"
    end

    test "narrow single-bucket range renders start and end labels only", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Short Burst",
          kind: "opendtu",
          mqtt_username: "short-burst",
          base_topic: "solar"
        })

      today = Date.utc_today()

      # Two readings at 12:00 and 12:30 — single-bucket range.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "BURST",
          mppt_index: 0,
          ac_power: 100.0,
          inserted_at:
            DateTime.new!(today, ~T[12:00:00])
            |> Map.put(:microsecond, {0, 6})
        })

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "BURST",
          mppt_index: 0,
          ac_power: 80.0,
          inserted_at:
            DateTime.new!(today, ~T[12:30:00])
            |> Map.put(:microsecond, {0, 6})
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Chart range is 12:00–13:00 (end_hour = 12 + 1 = 13, since the
      # last bucket minute > 0). total_hours = 1, step = 1, so labels at
      # 12:00 and 13:00 only.
      assert html =~ ">12:00<"
      assert html =~ ">13:00<"

      # No other labels
      refute html =~ ">00:00<"
      refute html =~ ">11:00<"
      refute html =~ ">14:00<"
      refute html =~ ">24:00<"
    end

    test "end_hour is capped at 24 when last data is past 23:00", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Late Producer",
          kind: "opendtu",
          mqtt_username: "late-producer",
          base_topic: "solar"
        })

      today = Date.utc_today()

      # Reading at 23:30 — end_hour would be 24 (min(23+1, 24)).
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "LATE",
          mppt_index: 0,
          ac_power: 50.0,
          inserted_at:
            DateTime.new!(today, ~T[23:30:00])
            |> Map.put(:microsecond, {0, 6})
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Range: 23:00–24:00 (end_hour capped at 24). Labels at 23:00 and 24:00.
      assert html =~ ">23:00<"
      assert html =~ ">24:00<"
      refute html =~ ">00:00<"
    end

    test "chart point X coordinates scale to the dynamic range, not the fixed 00:00–24:00 range",
         %{conn: conn, user: user} do
      dtu =
        device_fixture(user, %{
          name: "Mid Day",
          kind: "opendtu",
          mqtt_username: "mid-day",
          base_topic: "solar"
        })

      today = Date.utc_today()

      # 06:00–19:00 sine arc. With dynamic range 06:00–20:00, the 06:00
      # point is at x = 0 (left edge) and the 19:00 point is at
      # x = (19-6) / 14 * 800 ≈ 742.9. Pre-fix the 06:00 point was at
      # x = (6/24) * 800 = 200 — well inside the chart with empty space
      # to its left.
      minutes = Enum.filter((6 * 60)..(19 * 60), &(rem(&1, 15) == 0))

      for minute <- minutes do
        hour = div(minute, 60)
        min = rem(minute, 60)

        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: dtu.id,
            inverter_serial: "MID",
            mppt_index: 0,
            ac_power: 250.0,
            inserted_at:
              DateTime.new!(today, Time.new!(hour, min, 0))
              |> Map.put(:microsecond, {0, 6})
          })
      end

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Pull the first path's `d` attribute. It should start with
      # `M 0.0 ` (first data point at the left edge of the zoomed range).
      first_d = extract_first_path_d(html)
      assert first_d != nil, "expected at least one <path data-series=...>"

      assert String.starts_with?(first_d, "M 0.0 "),
             "first data point should be at x=0 in a zoomed range, got: #{first_d}"

      # And the last point in the path should be near x ≈ 742.9 (19:00
      # of a 06:00–20:00 zoomed range). Allow ±1 px for rounding.
      coords = extract_xy_coords(first_d)
      assert length(coords) > 0
      {last_x, _last_y} = List.last(coords)
      assert_in_delta last_x, 742.9, 1.5
    end

    # Helpers used by the dynamic-chart tests above.
  end

  defp extract_first_path_d(html) do
    # Find each <path> tag with data-series and extract the `d` attribute.
    # `data-series` and `d` can appear in either order in the rendered HTML.
    # `Regex.scan/2` returns a list of capture-group lists — pull the
    # full match out of each with `hd/1` before regexing on it.
    Regex.scan(~r/<path\b[^>]*\/?>/, html)
    |> Enum.find_value(fn [path_tag | _] ->
      cond do
        Regex.match?(~r/data-series="/, path_tag) ->
          case Regex.run(~r/\sd="([^"]+)"/, path_tag) do
            [_, d] -> d
            _ -> nil
          end

        true ->
          nil
      end
    end)
  end

  defp extract_xy_coords(d) do
    d
    |> String.split(["M ", "L "], trim: true)
    |> Enum.map(fn segment ->
      case String.split(segment, " ") do
        [x, y] -> {Float.parse(x) |> elem(0), Float.parse(y) |> elem(0)}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
