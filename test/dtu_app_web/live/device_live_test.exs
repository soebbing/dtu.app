defmodule DtuAppWeb.DeviceLiveTest do
  use DtuAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import DtuApp.DevicesFixtures

  setup :register_and_log_in_user

  describe "Index" do
    test "lists all devices", %{conn: conn, user: user} do
      _device = device_fixture(user, %{name: "Living Room Inverter"})

      {:ok, _index_live, html} = live(conn, ~p"/devices")

      assert html =~ "DTUs"
      assert html =~ "Living Room Inverter"
    end

    test "renders listing in German when accept-language is German", %{conn: conn, user: user} do
      device_fixture(user, %{name: "Living Room Inverter"})
      conn = Plug.Conn.put_req_header(conn, "accept-language", "de-DE,de;q=0.9")
      {:ok, _index_live, html} = live(conn, ~p"/devices")

      assert html =~ "DTUs"
      assert html =~ "Entfernen"
    end

    test "renders listing in French when accept-language is French", %{conn: conn, user: user} do
      device_fixture(user, %{name: "Living Room Inverter"})
      conn = Plug.Conn.put_req_header(conn, "accept-language", "fr-FR,fr;q=0.9")
      {:ok, _index_live, html} = live(conn, ~p"/devices")

      assert html =~ "DTU"
      assert html =~ "Supprimer"
    end

    test "saves new device with system-generated credentials", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/devices")

      assert index_live
             |> element("a[href=\"/devices/new\"]")
             |> render_click() =~ "Add DTU"

      assert_patch(index_live, ~p"/devices/new")

      assert index_live
             |> form("#device-form", dtu: %{name: ""})
             |> render_change() =~ "can&#39;t be blank"

      html =
        index_live
        |> form("#device-form",
          dtu: %{
            name: "Garage Inverter",
            kind: "opendtu"
          }
        )
        |> render_submit()

      # The save patches back to /devices and shows a "configured" modal
      assert html =~ "Garage Inverter"
      assert html =~ "DTU Configured Successfully!"
      assert html =~ "localhost"
      assert html =~ "1883"
      assert html =~ "solar"

      # Close the modal
      assert index_live
             |> element("#btn-close-created-modal")
             |> render_click()

      refute render(index_live) =~ "DTU Configured Successfully!"
    end

    test "shows both TLS and plain broker endpoints when MQTTS_HOST is set",
         %{conn: conn} do
      original_mqtts_host = Application.get_env(:dtu_app, :mqtts_host)
      original_mqtts_port = Application.get_env(:dtu_app, :mqtts_port)
      original_mqtt_host = Application.get_env(:dtu_app, :mqtt_host)

      try do
        Application.put_env(:dtu_app, :mqtts_host, "mqtt.example.com")
        Application.put_env(:dtu_app, :mqtts_port, 8883)
        # Match the TLS host so the fallback appears at the same address.
        Application.put_env(:dtu_app, :mqtt_host, "mqtt.example.com")

        {:ok, index_live, _html} = live(conn, ~p"/devices")

        index_live
        |> element("a[href=\"/devices/new\"]")
        |> render_click()

        assert_patch(index_live, ~p"/devices/new")

        html =
          index_live
          |> form("#device-form", dtu: %{name: "TLS Inverter", kind: "opendtu"})
          |> render_submit()

        # TLS endpoint shown first as the recommended option
        assert html =~ "mqtts://mqtt.example.com:8883"
        assert html =~ "TLS (recommended)"

        # Plain fallback still shown so DTUs without TLS support can connect
        assert html =~ "mqtt://mqtt.example.com:1883"
        assert html =~ "plain (fallback)"
      after
        if original_mqtts_host,
          do: Application.put_env(:dtu_app, :mqtts_host, original_mqtts_host),
          else: Application.delete_env(:dtu_app, :mqtts_host)

        if original_mqtts_port,
          do: Application.put_env(:dtu_app, :mqtts_port, original_mqtts_port),
          else: Application.delete_env(:dtu_app, :mqtts_port)

        if original_mqtt_host,
          do: Application.put_env(:dtu_app, :mqtt_host, original_mqtt_host),
          else: Application.delete_env(:dtu_app, :mqtt_host)
      end
    end

    test "shows only the plain broker endpoint when MQTTS_HOST is unset", %{conn: conn} do
      # Sanity-check the negative case so the two-endpoint behavior above
      # doesn't leak into the default config.
      Application.delete_env(:dtu_app, :mqtts_host)
      Application.delete_env(:dtu_app, :mqtts_port)

      {:ok, index_live, _html} = live(conn, ~p"/devices")

      index_live
      |> element("a[href=\"/devices/new\"]")
      |> render_click()

      assert_patch(index_live, ~p"/devices/new")

      html =
        index_live
        |> form("#device-form", dtu: %{name: "Plain Inverter", kind: "opendtu"})
        |> render_submit()

      assert html =~ "mqtt://localhost:1883"
      refute html =~ "mqtts://"
      refute html =~ "TLS (recommended)"
    end

    test "updates device in listing and shows read-only credentials", %{conn: conn, user: user} do
      device = device_fixture(user, %{name: "Kitchen Inverter"})

      {:ok, index_live, _html} = live(conn, ~p"/devices")

      assert index_live
             |> element("a[href=\"/devices/#{device.id}/edit\"]")
             |> render_click() =~ "Edit DTU"

      assert_patch(index_live, ~p"/devices/#{device.id}/edit")

      # Should render read-only details
      html = render(index_live)
      assert html =~ "MQTT Connection Details"
      assert html =~ device.mqtt_username
      assert html =~ device.mqtt_password
      assert html =~ device.base_topic

      html =
        index_live
        |> form("#device-form", dtu: %{name: "Kitchen Inverter Updated"})
        |> render_submit()

      assert html =~ "Kitchen Inverter Updated"
    end

    test "deletes device in listing after confirmation", %{conn: conn, user: user} do
      device = device_fixture(user, %{name: "Temp Inverter"})

      {:ok, index_live, _html} = live(conn, ~p"/devices")

      # Click remove to open the confirmation modal
      assert index_live
             |> element("#btn-delete-#{device.id}", "Remove")
             |> render_click() =~ "Delete DTU"

      assert has_element?(index_live, "#confirm-delete-modal")

      # Click cancel to verify cancellation works
      assert index_live
             |> element("#btn-cancel-delete", "Cancel")
             |> render_click()

      refute has_element?(index_live, "#confirm-delete-modal")

      # Click remove again and confirm deletion
      assert index_live
             |> element("#btn-delete-#{device.id}", "Remove")
             |> render_click()

      assert index_live
             |> element("#btn-confirm-delete", "Confirm Delete")
             |> render_click()

      refute has_element?(index_live, "#confirm-delete-modal")
      refute has_element?(index_live, "#devices-#{device.id}")
    end
  end
end
