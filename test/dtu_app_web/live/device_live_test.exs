defmodule DtuAppWeb.DeviceLiveTest do
  use DtuAppWeb.ConnCase, async: true

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
