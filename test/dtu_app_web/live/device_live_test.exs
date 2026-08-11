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

  describe "Deep-link expansion from ?expand=ID" do
    # The dashboard's edge badge links to `/devices?expand=<id>`. The
    # manage-device page reads that query param in `handle_params/3`
    # and renders the matching row's full error panel inline (see
    # `DeviceLive.Index.assign_expansion/2`). The URL is bookmarkable:
    # a refresh reopens the same panel. Bogus ids (non-integer,
    # not-owned, foreign device) collapse to no expansion rather
    # than 404-ing the page.

    test "mount/3 with ?expand=<id> shows the error panel expanded by default",
         %{conn: conn, user: user} do
      dtu =
        device_fixture(user, %{
          name: "Expandable",
          kind: "shelly3em",
          mqtt_username: "expandable",
          base_topic: "shellies/shellyplus3em"
        })

      :ok = DtuApp.Devices.record_dtu_error(dtu.id, "Shelly topic mismatch")

      {:ok, _view, html} = live(conn, ~p"/devices?expand=#{dtu.id}")

      # The expansion panel is rendered.
      assert html =~ ~s(id="device-error-panel-#{dtu.id}")

      # The error group itself is in the panel.
      assert html =~ "Shelly topic mismatch"
    end

    test "renders an empty-state message when the expanded device has no errors",
         %{conn: conn, user: user} do
      dtu =
        device_fixture(user, %{
          name: "Healthy Expanded",
          kind: "opendtu",
          mqtt_username: "healthy-expanded"
        })

      {:ok, _view, html} = live(conn, ~p"/devices?expand=#{dtu.id}")

      # Panel renders even when the device has no errors — the user
      # deep-linked to it explicitly, so the empty-state message
      # explains "no errors recorded" rather than silently hiding the
      # panel.
      assert html =~ ~s(id="device-error-panel-#{dtu.id}")
      assert html =~ "No errors recorded for this DTU yet."
    end

    test "groups repeated messages in the panel with their occurrence count", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Repeating Expanded",
          kind: "shelly3em",
          mqtt_username: "repeating-expanded",
          base_topic: "shellies/shellyplus3em"
        })

      # 3 identical errors + 1 different = 2 groups, with occurrences
      # 3 and 1.
      for _ <- 1..3 do
        :ok = DtuApp.Devices.record_dtu_error(dtu.id, "Shelly topic mismatch")
      end

      :ok = DtuApp.Devices.record_dtu_error(dtu.id, "Different error")

      {:ok, _view, html} = live(conn, ~p"/devices?expand=#{dtu.id}")

      # The header line shows the distinct + total counts.
      assert html =~ "2 distinct"
      assert html =~ "4 total occurrences"

      # The repeated message shows its occurrence count.
      assert html =~ "3 occurrences"
      # The unique message shows its occurrence count.
      assert html =~ "1 occurrence"
    end

    test "?expand=<id> for a non-owned device is silently ignored", %{
      conn: conn,
      user: _user
    } do
      # Two users; user A owns the device, user B tries to expand it
      # via the URL. The page renders user B's (empty) device list
      # rather than 404'ing — the deep-link is dropped.
      other_user = DtuApp.AccountsFixtures.user_fixture()
      _dtu = device_fixture(other_user, %{name: "Foreign"})

      # Hand-roll an id we know doesn't belong to `user`.
      {:ok, _view, html} = live(conn, ~p"/devices?expand=99999999")

      refute html =~ "device-error-panel-"
    end

    test "?expand=<not-an-integer> is silently ignored (no panel, no 500)", %{
      conn: conn,
      user: _user
    } do
      {:ok, _view, html} = live(conn, ~p"/devices?expand=abc")

      refute html =~ "device-error-panel-"
    end

    test "closing the panel pushes a patch to /devices without expand param", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Closable",
          kind: "opendtu",
          mqtt_username: "closable"
        })

      :ok = DtuApp.Devices.record_dtu_error(dtu.id, "Some error")

      {:ok, view, _html} = live(conn, ~p"/devices?expand=#{dtu.id}")

      # Click the close button — should trigger the
      # `close_expanded_errors` event handler which clears the
      # `expand` param via `push_patch`.
      view
      |> element("#btn-close-error-panel-#{dtu.id}")
      |> render_click()

      # The handler calls `push_patch(to: ~p"/devices")` — pin the
      # URL change. The rendered HTML update happens at the same
      # time; the panel's `<%= if @expanded_dtu_id == device.id %>`
      # guard is false once the patch lands.
      assert_patch(view, ~p"/devices")
    end

    test "the close button survives a :dtu_seen broadcast that races the click",
         %{conn: conn, user: user} do
      # Regression test for a production-only bug: the close button
      # didn't reliably close the panel when a `:dtu_seen` broadcast
      # fired between the click and the resulting `push_patch` patch
      # reaching the client. Root cause was that the expansion panel
      # was rendered as a non-id child of the same `<div phx-update="stream">`
      # container as the device rows, so `stream/3 reset: true` would
      # wipe the panel's DOM nodes — including any pending
      # `phx-click` handler — every time the device list refreshed.
      #
      # The fix moves the panel out of the stream container so the
      # stream owns only the row elements; the panel survives every
      # stream reset untouched.
      dtu =
        device_fixture(user, %{
          name: "Race DTU",
          kind: "opendtu",
          mqtt_username: "race-dtu"
        })

      :ok = DtuApp.Devices.record_dtu_error(dtu.id, "Stale error")

      {:ok, view, html} = live(conn, ~p"/devices?expand=#{dtu.id}")

      assert html =~ ~s(id="device-error-panel-#{dtu.id}"),
             "expected the panel to be visible before the click"

      # Click close, then immediately fire a `:dtu_seen` broadcast
      # (this is what `stream/3 reset: true` on the live view does in
      # production when a per-MQTT-uplink `last_seen_at` arrives). The
      # close click and the broadcast must both win: the panel must be
      # gone and the URL must be back to bare `/devices`.
      view
      |> element("#btn-close-error-panel-#{dtu.id}")
      |> render_click()

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        DtuApp.MqttBroker.Telemetry.status_topic(),
        {:dtu_seen, dtu.id}
      )

      # Pin both: the patch landed AND the panel is gone.
      assert_patch(view, ~p"/devices")

      closed? =
        Enum.reduce_while(1..20, false, fn _i, _acc ->
          current = render(view)

          if current =~ "device-error-panel-" do
            Process.sleep(50)
            {:cont, false}
          else
            {:halt, true}
          end
        end)

      assert closed?,
             "expected the panel to disappear after close + :dtu_seen broadcast"
    end

    test "the expansion panel refreshes when :dtu_error broadcasts for the expanded device",
         %{conn: conn, user: user} do
      # The :dtu_error broadcast handler re-fetches the affected
      # device's `list_dtu_error_groups/1` only when the device is the
      # currently-expanded one. Pins the wiring so a freshly-fired
      # error appears in the panel without a refresh.
      dtu =
        device_fixture(user, %{
          name: "Live Expanded",
          kind: "opendtu",
          mqtt_username: "live-expanded"
        })

      {:ok, view, html} = live(conn, ~p"/devices?expand=#{dtu.id}")

      # Initial state: empty panel.
      assert html =~ "No errors recorded for this DTU yet."

      # Trigger an error via the writer + broadcast (mirroring what
      # `record_dtu_error/2` does in production, but split so the
      # test exercises each leg independently).
      :ok = DtuApp.Devices.record_dtu_error(dtu.id, "Fresh error")

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        DtuApp.MqttBroker.Telemetry.status_topic(),
        {:dtu_error, dtu.id}
      )

      # Poll for up to 1s for the new error to appear in the panel.
      found? =
        Enum.reduce_while(1..20, false, fn _i, _acc ->
          current = render(view)

          if current =~ "Fresh error" do
            {:halt, true}
          else
            Process.sleep(50)
            {:cont, false}
          end
        end)

      assert found?,
             "expected the new error to appear in the expansion panel after :dtu_error broadcast"
    end
  end

  describe "Click a device row to toggle the error panel" do
    # The manage-device page's main interaction: clicking the device
    # row's content area toggles the error expansion panel for that
    # device. Same open/close semantic as the dashboard's deep-link
    # (`?expand=<id>`) and the close button — the panel state and
    # the URL's `?expand=<id>` query param stay in sync.
    #
    # `phx-click` lives on the row's content area (the flex-1 left
    # column with the device name + kind + inline error message). Edit
    # and Remove buttons are nested children — they route their
    # clicks to themselves and don't fire the row's handler.

    test "clicking a closed row opens the error panel + patches ?expand=<id>",
         %{conn: conn, user: user} do
      dtu =
        device_fixture(user, %{
          name: "Clickable",
          kind: "opendtu",
          mqtt_username: "clickable"
        })

      :ok = DtuApp.Devices.record_dtu_error(dtu.id, "Some error")

      {:ok, view, _html} = live(conn, ~p"/devices")

      # No panel rendered before the click.
      refute render(view) =~ "device-error-panel-"

      view
      |> element("#device-row-content-#{dtu.id}")
      |> render_click()

      # URL gets the expand param + the panel renders.
      assert_patch(view, ~p"/devices?expand=#{dtu.id}")

      opened? =
        Enum.reduce_while(1..20, false, fn _i, _acc ->
          current = render(view)

          if current =~ "device-error-panel-" do
            Process.sleep(50)
            {:cont, false}
          else
            {:halt, true}
          end
        end)

      assert opened?,
             "expected the panel to appear after clicking the row"
    end

    test "clicking a healthy device row opens the panel and shows the 'no errors' empty state",
         %{conn: conn, user: user} do
      # The user's request: "Show 'no errors' (translated) when none
      # exist" — clicking a device that has no error history must
      # still open the panel, and the panel must render the
      # translated empty-state message rather than appear empty.
      dtu =
        device_fixture(user, %{
          name: "Healthy but clickable",
          kind: "opendtu",
          mqtt_username: "healthy-clickable"
        })

      {:ok, view, _html} = live(conn, ~p"/devices")

      view
      |> element("#device-row-content-#{dtu.id}")
      |> render_click()

      assert_patch(view, ~p"/devices?expand=#{dtu.id}")

      # The "no errors recorded" message is the empty-state copy —
      # the German/French translations live in `default.po` (added
      # in MR #89, kept in MR #90).
      found? =
        Enum.reduce_while(1..20, false, fn _i, _acc ->
          current = render(view)

          if current =~ "No errors recorded for this DTU yet." do
            Process.sleep(50)
            {:cont, false}
          else
            {:halt, true}
          end
        end)

      assert found?,
             "expected the 'no errors' empty-state message after clicking a healthy device"
    end

    test "clicking an open row closes the panel + patches /devices (no expand)",
         %{conn: conn, user: user} do
      dtu =
        device_fixture(user, %{
          name: "Toggleable",
          kind: "opendtu",
          mqtt_username: "toggleable"
        })

      :ok = DtuApp.Devices.record_dtu_error(dtu.id, "Some error")

      {:ok, view, _html} = live(conn, ~p"/devices?expand=#{dtu.id}")

      # Panel is open on mount.
      assert render(view) =~ "device-error-panel-#{dtu.id}"

      view
      |> element("#device-row-content-#{dtu.id}")
      |> render_click()

      # The toggle handler clears `?expand` and the panel disappears.
      assert_patch(view, ~p"/devices")

      closed? =
        Enum.reduce_while(1..20, false, fn _i, _acc ->
          current = render(view)

          if current =~ "device-error-panel-#{dtu.id}" do
            Process.sleep(50)
            {:cont, false}
          else
            {:halt, true}
          end
        end)

      assert closed?,
             "expected the panel to disappear after clicking the open row"
    end

    test "clicking the row does NOT trigger the Edit or Remove buttons", %{
      conn: conn,
      user: user
    } do
      # The Edit and Remove buttons are nested inside the row. Their
      # own click handlers must take precedence over the row's —
      # the user clicking Edit should patch to /devices/N/edit, not
      # toggle the panel. Browsers handle this naturally because
      # inner elements route the click to themselves first.
      dtu =
        device_fixture(user, %{
          name: "Edit-Clickable",
          kind: "opendtu",
          mqtt_username: "edit-clickable"
        })

      :ok = DtuApp.Devices.record_dtu_error(dtu.id, "Some error")

      {:ok, view, _html} = live(conn, ~p"/devices")

      # Click the Edit link — should patch to the edit URL, NOT
      # open the error panel.
      view
      |> element("a[href='/devices/#{dtu.id}/edit']")
      |> render_click()

      # The LiveView's URL must be the edit URL (not the devices
      # page with expand=<id>).
      assert_patch(view, ~p"/devices/#{dtu.id}/edit")

      # And the panel must NOT have opened.
      refute render(view) =~ "device-error-panel-#{dtu.id}"
    end
  end
end
