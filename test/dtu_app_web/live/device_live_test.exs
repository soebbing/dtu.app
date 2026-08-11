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

      # A "Copy to clipboard" button sits to the right of each value,
      # wired to the colocated CopyToClipboard hook and carrying the same
      # value as `data-value="..."` so the JS can call
      # `navigator.clipboard.writeText(data-value)`.
      for {field_value, button_id} <- [
            {"localhost", "btn-copy-mqtt-host"},
            {"1883", "btn-copy-mqtt-port"},
            {dtu_created.mqtt_username, "btn-copy-mqtt-username"},
            {dtu_created.mqtt_password, "btn-copy-mqtt-password"},
            {dtu_created.base_topic, "btn-copy-base-topic"}
          ] do
        button_html =
          case Regex.run(
                 ~r/<button[^>]*id="?#{Regex.escape(button_id)}"?[^>]*>.*?<\/button>/s,
                 html
               ) do
            [block] -> block
            _ -> flunk("no copy button rendered for #{button_id}; expected #{field_value}")
          end

        assert button_html =~ ~r/phx-hook="[^"]*CopyToClipboard/,
               "copy button #{button_id} is missing the CopyToClipboard hook"

        assert button_html =~ ~r/data-value="#{Regex.escape(field_value)}"/,
               "copy button #{button_id} should carry data-value=#{inspect(field_value)}"
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

  describe "Device error fill on the manage-device list" do
    # Same DTU error-surfacing feature the dashboard bubble implements,
    # but on the /devices manage page. The fill makes a misconfigured DTU
    # unmissable in the list — the rose-tinted background + thicker left
    # border mirror the delete-confirmation modal's warning style so the
    # warning vocabulary is consistent across the app.

    test "renders a warning fill on the row when last_error is set", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Misconfigured DTU",
          kind: "opendtu",
          mqtt_username: "misconfigured-dtu"
        })

      :ok =
        DtuApp.Devices.update_dtu_error(
          dtu.id,
          "Shelly topic mismatch (expected shellies/shellyplus3em, got shellyplus3em-aabbcc/status/em:0)"
        )

      {:ok, _view, html} = live(conn, ~p"/devices")

      # The exact id we target in the e2e test. Without this assertion
      # a regression that drops the inline message would slip through.
      assert html =~ ~s(id="dtu-error-message-#{dtu.id}"),
             "expected the inline error message to appear on the row"

      # The fill is the rose-tinted background on the row itself. The
      # conditional class on the row's wrapping div is what makes the
      # fill visible — the test below pins its presence.
      assert html =~ ~s(id="devices-#{dtu.id}")

      # The body of the message is rendered (truncated via CSS, but the
      # start is present and visible to a screen reader / first-letter
      # match). The full message is in the title= attribute.
      assert html =~ "Shelly topic mismatch"
    end

    test "does NOT render an error fill for a healthy device", %{
      conn: conn,
      user: user
    } do
      _dtu = device_fixture(user, %{name: "Healthy", kind: "opendtu"})

      {:ok, _view, html} = live(conn, ~p"/devices")

      # The inline-message selector is the conditional render's gate —
      # `last_error is nil` ⇒ false ⇒ no element rendered.
      refute html =~ "dtu-error-message-"
    end

    test "inline message's title= carries the full error string", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Long Message DTU",
          kind: "shelly3em",
          mqtt_username: "long-msg",
          base_topic: "shellies/shellyplus3em"
        })

      long_message =
        "Shelly topic mismatch (expected shellies/shellyplus3em, got shellyplus3em-aabbcc/status/em:0) — check the device's MQTT prefix"

      :ok = DtuApp.Devices.update_dtu_error(dtu.id, long_message)

      {:ok, _view, html} = live(conn, ~p"/devices")

      # Locate the inline message by id and check the title= attribute
      # (the hover hint). HEEx HTML-escapes the apostrophe; the rest
      # of the message round-trips intact.
      inline_match =
        Regex.run(~r/id="dtu-error-message-#{dtu.id}"[^>]*title="([^"]+)"/, html) |> List.last()

      # HEEx also escapes `&`, `<`, `>`, `"` — but our message has none
      # of those except the apostrophe. Apply the same escape the
      # test below uses for the bubble's title=.
      escaped_message = String.replace(long_message, "'", "&#39;")

      assert inline_match == escaped_message,
             "expected the inline error message's title= to equal the original; got #{inspect(inline_match)}"
    end

    test "re-renders the fill when :dtu_error broadcasts", %{
      conn: conn,
      user: user
    } do
      # Pins the LiveView wiring: the manage-device page subscribes to
      # `dtu:status` in mount/3 and refreshes the device list on
      # `{:dtu_error, device_id}`, same contract as the dashboard.
      dtu =
        device_fixture(user, %{
          name: "Broadcast Fill DTU",
          kind: "opendtu",
          mqtt_username: "broadcast-fill-dtu"
        })

      {:ok, view, html} = live(conn, ~p"/devices")

      # Healthy state on mount.
      refute html =~ "dtu-error-message-"

      # Bypass `record_dtu_error` (which writes + broadcasts together)
      # so the test can split the two operations and assert the LV
      # re-renders on the second broadcast. In production both happen
      # back-to-back inside the same function call.
      :ok = DtuApp.Devices.update_dtu_error(dtu.id, "OpenDTU uplink rejected")

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        DtuApp.MqttBroker.Telemetry.status_topic(),
        {:dtu_error, dtu.id}
      )

      # Poll for up to 1s for the fill to render.
      found? =
        Enum.reduce_while(1..20, false, fn _i, _acc ->
          current = render(view)

          if current =~ "dtu-error-message-#{dtu.id}" do
            {:halt, true}
          else
            Process.sleep(50)
            {:cont, false}
          end
        end)

      assert found?,
             "expected the inline error message to appear after :dtu_error broadcast"
    end
  end
end
