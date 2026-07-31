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
end
