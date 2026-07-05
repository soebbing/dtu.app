defmodule DtuAppWeb.DashboardLiveTest do
  use DtuAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DtuApp.AccountsFixtures
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
      assert html =~ "No power readings logged today yet."
    end

    test "renders connected devices and dynamically updates power stats", %{conn: conn, user: user} do
      dtu = device_fixture(user, %{name: "Dashboard Inverter", kind: "opendtu", mqtt_username: "dash-inv"})

      # Seed cached credentials so verification works and registers device
      DtuApp.MqttBroker.Credentials.refresh(dtu.mqtt_username)

      {:ok, view, html} = live(conn, ~p"/dashboard")

      # Initially 0.0 W
      assert html =~ "0.0 W"
      assert html =~ "Dashboard Inverter"

      # Simulate reading ingestion
      {:ok, _reading} = Devices.create_reading(%{
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
  end
end
