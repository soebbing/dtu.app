defmodule DtuAppWeb.DeviceStatusGridTest do
  @moduledoc """
  Render tests for `DtuAppWeb.DeviceStatusGrid`.

  Pure render-only tests, no LiveView, no DB. The component is a
  thin wrapper over `<.device_status_card>` that adds the
  white-card chrome, the "Device Connection Status" heading,
  and the responsive grid around the per-device loop. Tests
  focus on:

    - Outer white-card chrome (the dashboard's shared panel
      style: `bg-white dark:bg-zinc-800 shadow rounded-lg
      border`).

    - Heading text + style class (always rendered).

    - Responsive grid: column count breakpoints at
      `grid-cols-1 / sm:grid-cols-2 / lg:grid-cols-3`.

    - Per-device loop: one `<.device_status_card>` per
      `device` entry, with `error_count` looked up from
      `error_counts` via `Map.get(..., device.id, 0)`.

    - Empty-device list: white-card chrome + heading still
      render; the inner grid div renders with `id` but
      contains no cards.

  Sister to `DtuAppWeb.DashboardHeaderTest` and
  `DtuAppWeb.DashboardToolbarTest`.
  """

  # Not `async: true` — `<.device_status_card>` (the inner card
  # this grid wraps) calls `Dtu.online?/1` and `Dtu.nighttime?/1`,
  # which both hit the database through `DtuApp.Time.utc_now()`.
  # DataCase sets up an Ecto sandbox checkout per test.
  use DtuApp.DataCase, async: false

  import Phoenix.LiveViewTest

  alias DtuApp.Devices.Dtu
  alias DtuAppWeb.DeviceStatusGrid

  # Build a `Dtu` struct with the three fields the predicates
  # consult. `id` is what the link target + dom-id fragments
  # use; `name` is what renders in the card title. We set the
  # bare minimum to make the predicates return an "offline /
  # not nighttime" answer (the conservative default for a
  # test that doesn't care about liveness).
  defp dtu(attrs) do
    defaults = %{
      id: 42,
      name: "Test Inverter",
      kind: :opendtu,
      last_seen_at: nil,
      last_power_at: nil
    }

    struct(Dtu, Map.merge(defaults, Map.new(attrs)))
  end

  describe "outer white-card chrome" do
    test "wraps everything in a bordered rounded shadow card (dashboard panel style)" do
      html =
        render_component(&DeviceStatusGrid.device_status_grid/1, %{
          devices: [dtu(id: 1, name: "Garage")],
          error_counts: %{}
        })

      assert html =~ "bg-white dark:bg-zinc-800 shadow rounded-lg"
      assert html =~ "border border-zinc-200 dark:border-zinc-700"
      assert html =~ "p-6"
    end
  end

  describe "heading" do
    test "renders the \"Device Connection Status\" heading" do
      html =
        render_component(&DeviceStatusGrid.device_status_grid/1, %{
          devices: [dtu(id: 1, name: "Garage")],
          error_counts: %{}
        })

      assert html =~ "Device Connection Status"
    end

    test "renders the heading as an h2 (sibling level to chart panel + share panel headings)" do
      html =
        render_component(&DeviceStatusGrid.device_status_grid/1, %{
          devices: [dtu(id: 1, name: "Garage")],
          error_counts: %{}
        })

      assert html =~ "<h2"
      assert html =~ "text-lg font-medium text-zinc-900 dark:text-white"
    end

    test "renders the heading even when the device list is empty" do
      html =
        render_component(&DeviceStatusGrid.device_status_grid/1, %{
          devices: [],
          error_counts: %{}
        })

      assert html =~ "Device Connection Status"
    end
  end

  describe "responsive grid" do
    test "uses the standard 1 / 2 / 3 column responsive breakpoints" do
      html =
        render_component(&DeviceStatusGrid.device_status_grid/1, %{
          devices: [dtu(id: 1, name: "Garage")],
          error_counts: %{}
        })

      assert html =~ "grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3"
    end

    test "carries id=\"device-status-grid\" so dashboard tests can target the grid" do
      html =
        render_component(&DeviceStatusGrid.device_status_grid/1, %{
          devices: [dtu(id: 1, name: "Garage")],
          error_counts: %{}
        })

      assert html =~ ~s(id="device-status-grid")
    end
  end

  describe "per-device loop" do
    test "renders one <.device_status_card> per device" do
      html =
        render_component(&DeviceStatusGrid.device_status_grid/1, %{
          devices: [
            dtu(id: 1, name: "Garage"),
            dtu(id: 2, name: "Shed")
          ],
          error_counts: %{}
        })

      # Both device names render through their cards.
      assert html =~ "Garage"
      assert html =~ "Shed"
    end

    test "forwards the per-device error_count from the error_counts map" do
      # A device whose id is in error_counts gets its integer
      # forwarded as error_count; a device absent from
      # error_counts gets the default 0.
      html =
        render_component(&DeviceStatusGrid.device_status_grid/1, %{
          devices: [
            dtu(id: 1, name: "Garage"),
            dtu(id: 2, name: "Shed")
          ],
          error_counts: %{1 => 5}
        })

      # Garage (id=1) carries the explicit 5 error count; Shed
      # (id=2) isn't in error_counts so it shows 0 errors.
      # Both numbers must appear in the rendered HTML.
      assert html =~ "Garage"
      assert html =~ "Shed"
      assert html =~ "5"
      assert html =~ "0"
    end

    test "renders NO card cells when devices list is empty" do
      html =
        render_component(&DeviceStatusGrid.device_status_grid/1, %{
          devices: [],
          error_counts: %{}
        })

      # The grid div still renders (so dashboard tests can
      # target its id) but it contains no device cards.
      assert html =~ ~s(id="device-status-grid")
      refute html =~ "Garage"
      refute html =~ "Shed"
    end
  end

  describe "structure guards" do
    test "does NOT render dashboard chrome from sibling components" do
      html =
        render_component(&DeviceStatusGrid.device_status_grid/1, %{
          devices: [dtu(id: 1, name: "Garage")],
          error_counts: %{}
        })

      refute html =~ "id=\"solar-chart-svg\""
      refute html =~ "id=\"share-panel\""
      refute html =~ "id=\"onboarding-empty\""
      refute html =~ "id=\"dtu-switcher\""
      refute html =~ "id=\"quick-range-switcher\""
      refute html =~ "id=\"history-picker\""
    end
  end
end
