defmodule DtuAppWeb.DeviceRowTest do
  @moduledoc """
  Render tests for `DtuAppWeb.DeviceRow`.

  Pure render-only tests — no LiveView, no GenServer. We build a
  lightweight `%Dtu{}` struct directly (skipping the
  `device_fixture/2` DB round-trip) because the predicates this
  component consults (`Dtu.producing_power?/1`) only read
  `last_power_at` from the struct — the same fields a render-only
  test can fill in by hand.

  Uses `DtuApp.DataCase` because `Dtu.producing_power?/1` calls
  `DtuApp.Time.utc_now()` which queries the database through the
  time cache. The sandbox checkout is the same one DataCase sets
  up for any DB-using test; render-only here just means "no
  LiveView socket, no PubSub".

  Covers:

    - Outer chrome: healthy vs. rose-tinted warning fill (driven
      by `device.last_error`).
    - Online dot: green + tooltip when `producing_power?/1` returns
      true; zinc + longer offline tooltip when it returns false.
    - Inline error message strip: rendered only when
      `device.last_error` is set; carries the full message on the
      `title=` attribute.
    - Action cluster: Details (navigate to `/devices/:id/details`),
      Edit (patch to `/devices/:id/edit`), Remove (phx-click to
      `confirm_delete` with the row's id).
    - ARIA: `aria-expanded` + accessible name flip between
      "Show/Hide error history" based on `@expanded?`.
  """

  # Not `async: true` — `Dtu.producing_power?/1` calls
  # `DtuApp.Time.utc_now()` which queries the database through the
  # time cache, so this test needs a sandbox connection. DataCase
  # sets up an Ecto sandbox checkout per test.
  use DtuApp.DataCase, async: false

  import Phoenix.LiveViewTest

  alias DtuApp.Devices.Dtu
  alias DtuAppWeb.DeviceRow

  # Build a Dtu struct with the fields the component reads.
  # `id` is what the dom-id fragments + action targets use;
  # `name`, `kind`, `mqtt_username` render to the user;
  # `last_power_at` drives the green/grey online dot;
  # `last_error` drives the rose-tinted warning fill + the
  # inline error strip. We set the bare minimum to make the
  # predicates return the desired truthy / falsy answer.
  defp dtu(attrs) do
    now = DateTime.utc_now()

    defaults = %{
      id: 42,
      name: "Test Inverter",
      kind: :opendtu,
      mqtt_username: "test-inverter-42",
      last_power_at: now,
      last_error: nil
    }

    struct(Dtu, Map.merge(defaults, Map.new(attrs)))
  end

  describe "outer chrome" do
    test "healthy device renders with the neutral background, no rose tint" do
      html =
        render_component(&DeviceRow.device_row/1, %{
          device: dtu(%{last_error: nil}),
          expanded?: false
        })

      assert html =~ ~s(id="devices-42")
      assert html =~ "bg-white dark:bg-zinc-900"
      refute html =~ "bg-rose-50/60"
      refute html =~ "border-rose-500"
    end

    test "device with last_error renders with the rose warning fill" do
      html =
        render_component(&DeviceRow.device_row/1, %{
          device: dtu(%{last_error: "Shelly topic mismatch"}),
          expanded?: false
        })

      # The rose background + thicker left border — same warning style
      # as the delete-confirmation modal.
      assert html =~ "bg-rose-50/60 dark:bg-rose-950/30"
      assert html =~ "border-l-4 border-rose-500"
      refute html =~ "bg-white dark:bg-zinc-900"
    end
  end

  describe "online dot" do
    test "green dot + online tooltip when last_power_at is fresh" do
      now = DateTime.utc_now()

      html =
        render_component(&DeviceRow.device_row/1, %{
          device: dtu(%{last_power_at: now}),
          expanded?: false
        })

      assert html =~ "bg-emerald-500"
      refute html =~ "bg-zinc-300 dark:bg-zinc-600"
      assert html =~ "Online — this DTU has reported AC power within the last 2 minutes"
    end

    test "grey dot + offline tooltip when last_power_at is stale" do
      # 1 hour ago — well past the 2-minute producing_power? threshold.
      stale = DateTime.add(DateTime.utc_now(), -3_600, :second)

      html =
        render_component(&DeviceRow.device_row/1, %{
          device: dtu(%{last_power_at: stale}),
          expanded?: false
        })

      assert html =~ "bg-zinc-300 dark:bg-zinc-600"
      refute html =~ "bg-emerald-500"
      assert html =~ "Offline — no AC power reading has arrived in the last 2 minutes"
    end

    test "grey dot + offline tooltip when last_power_at is nil" do
      # Brand-new device, never produced — same conservative "offline"
      # answer as a stale reading.
      html =
        render_component(&DeviceRow.device_row/1, %{
          device: dtu(%{last_power_at: nil}),
          expanded?: false
        })

      assert html =~ "bg-zinc-300 dark:bg-zinc-600"
      refute html =~ "bg-emerald-500"
    end
  end

  describe "name + credentials line" do
    test "renders the device name" do
      html =
        render_component(&DeviceRow.device_row/1, %{
          device: dtu(%{name: "Roof Inverter"}),
          expanded?: false
        })

      assert html =~ "Roof Inverter"
    end

    test "renders the kind and mqtt_username on the credentials line" do
      html =
        render_component(&DeviceRow.device_row/1, %{
          device: dtu(%{kind: :ahoydtu, mqtt_username: "ahoy-roof"}),
          expanded?: false
        })

      assert html =~ "ahoydtu"
      assert html =~ "ahoy-roof"
    end
  end

  describe "inline error message strip" do
    test "omits the strip when last_error is nil" do
      html =
        render_component(&DeviceRow.device_row/1, %{
          device: dtu(%{last_error: nil}),
          expanded?: false
        })

      refute html =~ "dtu-error-message-"
    end

    test "renders the strip with the message + title= when last_error is set" do
      html =
        render_component(&DeviceRow.device_row/1, %{
          device: dtu(%{id: 7, last_error: "Shelly topic mismatch"}),
          expanded?: false
        })

      assert html =~ ~s(id="dtu-error-message-7")
      assert html =~ "Shelly topic mismatch"
      # Full message also carried on the title= attribute for hover.
      assert html =~ ~s(title="Shelly topic mismatch")
    end
  end

  describe "action cluster" do
    test "Details link navigates to /devices/:id/details" do
      html =
        render_component(&DeviceRow.device_row/1, %{
          device: dtu(%{id: 99}),
          expanded?: false
        })

      # The Details link uses `navigate` (a full LV lifecycle)
      # rather than `patch` so the device-details LiveView
      # gets a fresh topic-tree subscription.
      assert html =~ ~s(href="/devices/99/details")
      assert html =~ "Details"
    end

    test "Edit link patches to /devices/:id/edit" do
      html =
        render_component(&DeviceRow.device_row/1, %{
          device: dtu(%{id: 99}),
          expanded?: false
        })

      assert html =~ ~s(href="/devices/99/edit")
      assert html =~ "Edit"
    end

    test "Remove button triggers confirm_delete with the row's id" do
      html =
        render_component(&DeviceRow.device_row/1, %{
          device: dtu(%{id: 99}),
          expanded?: false
        })

      assert html =~ ~s(id="btn-delete-99")
      # phx-click + phx-value-id render as data attributes on the
      # button. Phoenix escapes the phx-click string verbatim.
      assert html =~ ~s(phx-click="confirm_delete")
      assert html =~ ~s(phx-value-id="99")
      assert html =~ "Remove"
    end
  end

  describe "ARIA / clickable content area" do
    test "clickable area carries phx-click toggle_expanded_errors with the row's id" do
      html =
        render_component(&DeviceRow.device_row/1, %{
          device: dtu(%{id: 99}),
          expanded?: false
        })

      assert html =~ ~s(id="device-row-content-99")
      assert html =~ ~s(phx-click="toggle_expanded_errors")
      assert html =~ ~s(phx-value-id="99")
    end

    test "aria-expanded is \"false\" when the row is collapsed" do
      html =
        render_component(&DeviceRow.device_row/1, %{
          device: dtu(%{name: "Roof"}),
          expanded?: false
        })

      assert html =~ ~s(aria-expanded="false")
      assert html =~ "Show error history for Roof"
    end

    test "aria-expanded is \"true\" and label flips when the row is expanded" do
      html =
        render_component(&DeviceRow.device_row/1, %{
          device: dtu(%{name: "Roof"}),
          expanded?: true
        })

      assert html =~ ~s(aria-expanded="true")
      assert html =~ "Hide error history for Roof"
      refute html =~ "Show error history for Roof"
    end

    test "clickable area has role=\"button\" + tabindex for keyboard activation" do
      html =
        render_component(&DeviceRow.device_row/1, %{
          device: dtu(%{}),
          expanded?: false
        })

      assert html =~ ~s(role="button")
      assert html =~ ~s(tabindex="0")
    end
  end
end
