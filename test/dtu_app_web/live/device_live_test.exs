defmodule DtuAppWeb.DeviceLiveTest do
  use DtuAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import DtuApp.DevicesFixtures

  alias DtuApp.Repo

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

    test "saves new device with system-generated credentials", %{conn: conn, user: user} do
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

      # Each `<span class="...select-all...">VALUE</span>` in the
      # "Configured Successfully" modal must contain exactly the value —
      # no surrounding whitespace. Chromium's double-click
      # word-selection algorithm extends to whitespace inside the inline
      # element, so a span rendered as "  mqtt_user  " would be copied
      # as " mqtt_user " when the user just wanted "mqtt_user".
      dtu_created =
        Repo.get_by!(DtuApp.Devices.Dtu, name: "Garage Inverter", user_id: user.id)

      for expected <- [
            # In the test env the endpoint URL has host: "localhost"
            # (DtuAppWeb.Endpoint.config(:url)); the device_live falls back to
            # that and there's no override configured.
            "localhost",
            "1883",
            dtu_created.mqtt_username,
            dtu_created.mqtt_password,
            dtu_created.base_topic
          ] do
        # The value must appear tightly bound to its surrounding tag —
        # i.e. the rendered HTML contains `>VALUE</span>` literally, with no
        # whitespace between `>` and `VALUE` and no whitespace between
        # `VALUE` and `</span>`. Anything else (eg. `> VALUE </span>`) means
        # Chromium's double-click word-selection algorithm copies the
        # surrounding whitespace along with the value.
        assert html =~ ">#{expected}</span>",
               "value #{inspect(expected)} is rendered with surrounding whitespace " <>
                 "in the modal — double-click would copy it along with the value"
      end

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
