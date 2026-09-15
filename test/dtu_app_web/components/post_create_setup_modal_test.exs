defmodule DtuAppWeb.PostCreateSetupModalTest do
  @moduledoc """
  Render tests for `DtuAppWeb.PostCreateSetupModal`.

  Pure render-only tests — no LiveView, no DB. The component
  consumes a `%DtuApp.Devices.Dtu{}-shaped` map plus a
  `mqtt_host` string, so we build a fixture with the four
  fields the component reads (`kind`, `mqtt_username`,
  `mqtt_password`, `base_topic`) and call the function
  component directly.

  Covers:

    - Modal chrome: `id="created-device-modal"` outer overlay
      + `id="created-device-modal-title"` heading + emerald
      check-circle icon.
    - Subtitle carries the firmware kind rendered as a
      capitalised noun.
    - Five copy fields render with their stable button ids
      (`btn-copy-mqtt-host`, `btn-copy-mqtt-port`,
      `btn-copy-mqtt-username`, `btn-copy-mqtt-password`,
      `btn-copy-base-topic`).
    - Each value sits in a span rendered as `>VALUE</span>`
      with NO surrounding whitespace — the existing e2e
      `device_live_test.exs` test pins the same constraint;
      this test pins it at the component boundary so a
      regression here is caught before reaching e2e.
    - Each copy button carries `phx-hook="[^"]*CopyToClipboard"`
      and the matching `data-value="VALUE"`.
    - Hardware setup instructions block (4 bullets) renders.
    - Shelly-specific notes block renders for
      `kind == :shelly3em` and is hidden for other kinds
      (OpenDTU, AhoyDTU).
    - Dismiss button: `id="btn-close-created-modal"` +
      `phx-click="close_created_modal"`.
    - The colocated `.CopyToClipboard` JS hook block is
      rendered (the `name=".CopyToClipboard"` attribute
      pairs with the buttons' `phx-hook=".CopyToClipboard"`).
  """

  # Pure render — no DB, no LV. Use plain `ExUnit.Case`.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DtuApp.Devices.Dtu
  alias DtuAppWeb.PostCreateSetupModal

  defp dtu(attrs) do
    defaults = %{
      id: 7,
      kind: :opendtu,
      mqtt_username: "dtu_abc123",
      mqtt_password: "secret_pw_value",
      base_topic: "solar/inv-a/realtime"
    }

    struct(Dtu, Map.merge(defaults, Map.new(attrs)))
  end

  defp render_modal(assigns) do
    render_component(&PostCreateSetupModal.post_create_setup_modal/1, assigns)
  end

  describe "modal chrome" do
    test "renders outer overlay with id=created-device-modal" do
      html = render_modal(%{device: dtu([]), mqtt_host: "localhost"})

      assert html =~ ~s(id="created-device-modal")
    end

    test "renders inner heading with id=created-device-modal-title" do
      html = render_modal(%{device: dtu([]), mqtt_host: "localhost"})

      assert html =~ ~s(id="created-device-modal-title")
    end

    test "renders the success icon (hero-check-circle)" do
      html = render_modal(%{device: dtu([]), mqtt_host: "localhost"})

      # `<.icon name="hero-check-circle" />` renders as
      # `<span class="hero-check-circle h-6 w-6"></span>` —
      # the icon name is converted to a Tailwind class on the
      # underlying span rather than preserved as a `name=` attr.
      assert html =~ ~r/class="hero-check-circle/
    end

    test "renders the success heading text" do
      html = render_modal(%{device: dtu([]), mqtt_host: "localhost"})

      assert html =~ "DTU Configured Successfully!"
    end
  end

  describe "firmware-kind subtitle" do
    test "shows the kind capitalised in the subtitle" do
      html = render_modal(%{device: dtu([]), mqtt_host: "localhost"})

      # The kind is :opendtu → "Opendtu" after the
      # `Atom.to_string |> String.capitalize` pipeline.
      assert html =~ "Opendtu"
    end

    test "renders :ahoydtu as 'Ahoydtu'" do
      html = render_modal(%{device: dtu(%{kind: :ahoydtu}), mqtt_host: "localhost"})

      assert html =~ "Ahoydtu"
    end

    test "renders :shelly3em as 'Shelly3em'" do
      html = render_modal(%{device: dtu(%{kind: :shelly3em}), mqtt_host: "localhost"})

      assert html =~ "Shelly3em"
    end
  end

  describe "copy fields (no-whitespace span contract)" do
    # The existing e2e test (`device_live_test.exs:80-108`)
    # pins the `>VALUE</span>` contract end-to-end. This test
    # pins it at the component boundary — the no-whitespace
    # rule is invisible at a glance (a regression that adds
    # whitespace between `>` and `{value}` silently breaks
    # the user's double-click copy workflow), so a focused
    # render test catches the regression before it reaches e2e.

    test "each value sits flush against its surrounding span tag" do
      device = dtu([])
      mqtt_host = "localhost"

      html = render_modal(%{device: device, mqtt_host: mqtt_host})

      for expected <- [
            mqtt_host,
            "1883",
            device.mqtt_username,
            device.mqtt_password,
            device.base_topic
          ] do
        assert html =~ ">#{expected}</span>",
               "value #{inspect(expected)} is rendered with surrounding whitespace " <>
                 "in the modal — double-click would copy it along with the value"
      end
    end
  end

  describe "copy buttons (stable ids + hook + data-value)" do
    test "each copy button has its stable id, the CopyToClipboard hook, and a matching data-value" do
      device = dtu([])
      mqtt_host = "localhost"

      html = render_modal(%{device: device, mqtt_host: mqtt_host})

      for {value, button_id} <- [
            {mqtt_host, "btn-copy-mqtt-host"},
            {"1883", "btn-copy-mqtt-port"},
            {device.mqtt_username, "btn-copy-mqtt-username"},
            {device.mqtt_password, "btn-copy-mqtt-password"},
            {device.base_topic, "btn-copy-base-topic"}
          ] do
        button_html =
          case Regex.run(
                 ~r/<button[^>]*id="?#{Regex.escape(button_id)}"?[^>]*>.*?<\/button>/s,
                 html
               ) do
            [block] -> block
            _ -> flunk("no copy button rendered for #{button_id}; expected #{value}")
          end

        assert button_html =~ ~r/phx-hook="[^"]*CopyToClipboard/,
               "copy button #{button_id} is missing the CopyToClipboard hook"

        assert button_html =~ ~r/data-value="#{Regex.escape(value)}"/,
               "copy button #{button_id} should carry data-value=#{inspect(value)}"
      end
    end
  end

  describe "hardware setup instructions" do
    test "renders the four bullet points" do
      html = render_modal(%{device: dtu([]), mqtt_host: "localhost"})

      assert html =~ "Hardware setup instructions:"
      # The apostrophe in "DTU's" is HTML-escaped to `&#39;`
      # in the rendered output, and `->` may be entity-escaped
      # as well — match on stable substrings instead of the
      # raw gettext strings.
      assert html =~ "Open your DTU"
      assert html =~ "web interface in a browser"
      assert html =~ "Navigate to Settings"
      assert html =~ "MQTT"
      assert html =~ "Fill in the server details"
      assert html =~ "Ensure MQTT is enabled"
    end
  end

  describe "Shelly-specific notes branch" do
    test "renders the Shelly notes block when kind == :shelly3em" do
      device = dtu(%{kind: :shelly3em})
      html = render_modal(%{device: device, mqtt_host: "localhost"})

      assert html =~ "Shelly-specific notes:"
      assert html =~ "Telemetry is published as a single JSON object"
      # The notes paragraph interpolates the device's base_topic into
      # the topic example — exercise that interpolation.
      assert html =~ "#{device.base_topic}/status/em:0"
    end

    test "hides the Shelly notes block when kind is :opendtu" do
      html = render_modal(%{device: dtu(%{kind: :opendtu}), mqtt_host: "localhost"})

      refute html =~ "Shelly-specific notes:"
      refute html =~ "Telemetry is published as a single JSON object"
    end

    test "hides the Shelly notes block when kind is :ahoydtu" do
      html = render_modal(%{device: dtu(%{kind: :ahoydtu}), mqtt_host: "localhost"})

      refute html =~ "Shelly-specific notes:"
    end
  end

  describe "What happens next footer" do
    test "renders the next-steps paragraph" do
      html = render_modal(%{device: dtu([]), mqtt_host: "localhost"})

      assert html =~ "What happens next"
      assert html =~ "live power data starts flowing within seconds"
    end
  end

  describe "dismiss button" do
    test "renders the dismiss button with the stable id and phx-click" do
      html = render_modal(%{device: dtu([]), mqtt_host: "localhost"})

      assert html =~ ~s(id="btn-close-created-modal")
      assert html =~ ~s(phx-click="close_created_modal")
    end
  end

  describe "colocated CopyToClipboard hook" do
    test "each copy button's phx-hook is qualified to the component module" do
      # Phoenix colocated hooks are registered under
      # `<ModuleName>.<HookName>` when the component is rendered —
      # `name=".CopyToClipboard"` inside `PostCreateSetupModal`
      # resolves to `phx-hook="DtuAppWeb.PostCreateSetupModal.CopyToClipboard"`
      # on the rendered buttons. The script tag itself is compiled
      # out and shipped as a JS asset, so it's not in the rendered HTML.
      html = render_modal(%{device: dtu([]), mqtt_host: "localhost"})

      assert html =~ ~s(phx-hook="DtuAppWeb.PostCreateSetupModal.CopyToClipboard"),
             "phx-hook on the rendered buttons should be qualified to " <>
               "DtuAppWeb.PostCreateSetupModal.CopyToClipboard (got: #{html})"
    end
  end
end
