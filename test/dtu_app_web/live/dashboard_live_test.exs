defmodule DtuAppWeb.DashboardLiveTest do
  use DtuAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DtuApp.DevicesFixtures

  alias DtuApp.MqttBroker.Telemetry
  alias DtuApp.Devices

  setup :register_and_log_in_user

  describe "Dashboard Index" do
    test "renders empty dashboard stats and empty state message", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "PV Power Dashboard"
      assert html =~ "Current Generation"
      assert html =~ "0.0 W"
      assert html =~ "0.0 kWh"
      assert html =~ "No power readings logged for this day."
    end

    test "renders dashboard in German when accept-language is German", %{conn: conn} do
      conn = Plug.Conn.put_req_header(conn, "accept-language", "de-DE,de;q=0.9")
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "PV-Power-Dashboard"
      assert html =~ "Aktuelle Erzeugung"
    end

    test "renders dashboard in French when accept-language is French", %{conn: conn} do
      conn = Plug.Conn.put_req_header(conn, "accept-language", "fr-FR,fr;q=0.9")
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Tableau de bord de puissance photovoltaïque"
      assert html =~ "Génération actuelle"
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

      # Simulate reading ingestion
      {:ok, _reading} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "123456",
          ac_power: 350.0,
          yield_day: 1.25,
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

      # Seed readings for DTU 1 and DTU 2
      {:ok, _r1} =
        Devices.create_reading(%{
          dtu_id: dtu1.id,
          inverter_serial: "123",
          ac_power: 100.0,
          yield_day: 1.0,
          inserted_at: DateTime.utc_now()
        })

      {:ok, _r2} =
        Devices.create_reading(%{
          dtu_id: dtu2.id,
          inverter_serial: "456",
          ac_power: 200.0,
          yield_day: 2.0,
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
  end
end
