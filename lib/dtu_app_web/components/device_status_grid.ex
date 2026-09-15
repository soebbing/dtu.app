defmodule DtuAppWeb.DeviceStatusGrid do
  @moduledoc """
  The "Device Connection Status" panel — the bottom of the dashboard
  that shows one card per DTU with its live MQTT connection state.
  The wrapper has three layers:

    1. **White-card container** — `bg-white dark:bg-zinc-800`
       with `shadow rounded-lg border border-zinc-200 p-6`.
       Matches every other dashboard panel (chart panel, share
       panel, stat rows) so the dashboard reads as a stack of
       bordered cards with consistent chrome.
    2. **Heading** — `<h2>{gettext("Device Connection Status")}</h2>`
       so the section has its own title distinct from the
       toolbar above and the chart above.
    3. **Responsive grid** — `grid-cols-1 sm:grid-cols-2 lg:grid-cols-3`
       with a 6-unit `gap-6`. One column on phones, two on
       tablet, three on desktop. The grid carries
       `id="device-status-grid"` so the dashboard live-view
       tests can target it precisely.

  Each cell is `<.device_status_card>` (already extracted in
  PR #274). This component adds nothing on top of the card —
  it's the grid wrapper, the heading, and the per-device loop.

  The `:devices` list drives the inner `<%= for %>`; if the list
  is empty the loop body never executes and the grid renders
  empty (only the heading and white-card chrome are visible).
  Realistically the dashboard's outer `<%= if @devices == [] %>`
  gate means this component only mounts when there is at least
  one device to render, but the empty-list branch is still
  exercised in render-only tests.

  Was the inline block in
  `DtuAppWeb.DashboardLive.html.heex` (formerly lines 253-267).
  Extracted so the dashboard template keeps just the outer
  spacing wrapper and the grid/loop/heading bundle has its own
  render-only test surface.

  Sister to `DtuAppWeb.DeviceStatusCard` (PR #274),
  `DtuAppWeb.ConsumptionStatCards` (PR #275),
  `DtuAppWeb.NetFlowStatCards` (#276),
  `DtuAppWeb.ChartTitle` (#277),
  `DtuAppWeb.BarChartPanel` (#278),
  `DtuAppWeb.LineChartPanel` (#279),
  `DtuAppWeb.SharePanel` (#280),
  `DtuAppWeb.OnboardingPanel` (#281),
  `DtuAppWeb.DashboardHeader` (#282), and
  `DtuAppWeb.DashboardToolbar` (#283).
  """

  use DtuAppWeb, :html

  import DtuAppWeb.DeviceStatusCard, only: [device_status_card: 1]

  attr :devices, :list,
    default: [],
    doc: """
    The user's DTU list. Each device becomes one
    `<.device_status_card>` inside the responsive grid.
    An empty list renders the white-card chrome + heading
    but no per-device cells.
    """

  attr :error_counts, :map,
    default: %{},
    doc: """
    Map of `device.id => integer` carrying the rolling
    error count per device. Forwarded as `error_count` to
    each `<.device_status_card>` via
    `Map.get(@error_counts, device.id, 0)` — a missing key
    defaults to `0` so a device with no recorded errors
    still renders cleanly.
    """

  def device_status_grid(assigns) do
    ~H"""
    <div class="bg-white dark:bg-zinc-800 shadow rounded-lg border border-zinc-200 dark:border-zinc-700 p-6">
      <h2 class="text-lg font-medium text-zinc-900 dark:text-white mb-4">
        {gettext("Device Connection Status")}
      </h2>

      <div class="grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3" id="device-status-grid">
        <%= for device <- @devices do %>
          <.device_status_card
            device={device}
            error_count={Map.get(@error_counts, device.id, 0)}
          />
        <% end %>
      </div>
    </div>
    """
  end
end
