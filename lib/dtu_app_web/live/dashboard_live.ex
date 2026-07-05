defmodule DtuAppWeb.DashboardLive do
  use DtuAppWeb, :live_view

  alias DtuApp.Devices
  alias DtuApp.MqttBroker.Telemetry
  alias DtuApp.MqttBroker.Broker

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Telemetry.subscribe()
      Broker.subscribe_presence()
    end

    user = socket.assigns.current_scope.user

    socket =
      socket
      |> assign(:devices, Devices.list_devices(user))
      |> assign(:stats, Devices.get_daily_stats(user))
      |> assign_chart_data(user)

    {:ok, socket}
  end

  @impl true
  def handle_info({:reading, _client_id, _reading}, socket) do
    user = socket.assigns.current_scope.user

    {:noreply,
     socket
     |> assign(:stats, Devices.get_daily_stats(user))
     |> assign_chart_data(user)}
  end

  @impl true
  def handle_info({:dtu_connected, _client_id, _device_id}, socket) do
    user = socket.assigns.current_scope.user
    {:noreply, assign(socket, :devices, Devices.list_devices(user))}
  end

  @impl true
  def handle_info({:dtu_disconnected, _client_id, _device_id}, socket) do
    user = socket.assigns.current_scope.user
    {:noreply, assign(socket, :devices, Devices.list_devices(user))}
  end

  # Helper to construct SVG chart coordinates and range
  defp assign_chart_data(socket, user) do
    chart_points = Devices.list_today_chart_data(user)

    max_power =
      chart_points
      |> Enum.map(fn {_, power} -> power end)
      |> Enum.max(fn -> 100.0 end)
      |> max(100.0)
      |> Float.ceil()

    # Scale max power to next multiple of 100
    y_max = Float.ceil(max_power / 100) * 100

    # Build SVG points
    # Chart dimensions: width 800, height 250
    # X range: 0 (midnight) to 86400 (next midnight)
    points =
      chart_points
      |> Enum.map(fn {time, power} ->
        seconds = time.hour * 3600 + time.minute * 60 + time.second
        x = (seconds / 86400.0) * 800.0
        y = 250.0 - (power / y_max) * 230.0 # leave 20px padding at top
        {Float.round(x, 1), Float.round(y, 1)}
      end)

    path_data =
      case points do
        [] -> ""
        [{first_x, first_y} | rest] ->
          "M #{first_x} #{first_y} " <> (rest |> Enum.map_join(" ", fn {x, y} -> "L #{x} #{y}" end))
      end

    area_path_data =
      case points do
        [] -> ""
        [{first_x, first_y} | rest] ->
          # Start at bottom left, line to first point, trace points, line to bottom right, close path
          "M #{first_x} 250 L #{first_x} #{first_y} " <>
            (rest |> Enum.map_join(" ", fn {x, y} -> "L #{x} #{y}" end)) <>
            " L #{elem(List.last(points), 0)} 250 Z"
      end

    socket
    |> assign(:chart_points, chart_points)
    |> assign(:y_max, y_max)
    |> assign(:path_data, path_data)
    |> assign(:area_path_data, area_path_data)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} class="max-w-7xl">
      <div class="space-y-6 py-4">
        <!-- Title & Action -->
        <div class="flex flex-col md:flex-row md:items-center md:justify-between space-y-4 md:space-y-0">
          <div>
            <h1 class="text-3xl font-extrabold tracking-tight text-zinc-900 dark:text-white">
              PV Power Dashboard
            </h1>
            <p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
              Real-time generation stats for your solar converter system.
            </p>
          </div>
          <div>
            <.link
              navigate={~p"/devices"}
              id="btn-manage-devices"
              class={[
                "inline-flex items-center px-4 py-2 border rounded-md shadow-sm text-sm font-medium transition",
                "border-zinc-300 dark:border-zinc-700 text-zinc-700 dark:text-zinc-200 bg-white dark:bg-zinc-800",
                "hover:bg-zinc-50 dark:hover:bg-zinc-700 focus:outline-none"
              ]}
            >
              <.icon name="hero-cog-6-tooth" class="-ml-1 mr-2 h-5 w-5 text-zinc-400" />
              Manage Devices
            </.link>
          </div>
        </div>

        <!-- Stats Grid -->
        <div class="grid grid-cols-1 gap-5 sm:grid-cols-3">
          <!-- Current Power -->
          <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
            <div class="px-4 py-5 sm:p-6">
              <div class="flex items-center">
                <div class="p-3 rounded-md bg-emerald-50 dark:bg-emerald-950/30 text-emerald-600 dark:text-emerald-400">
                  <.icon name="hero-bolt" class="h-6 w-6" />
                </div>
                <div class="ml-5 w-0 flex-1">
                  <dl>
                    <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                      Current Generation
                    </dt>
                    <dd class="flex items-baseline space-x-2">
                      <div class="text-3xl font-semibold text-zinc-900 dark:text-white" id="stat-current-power">
                        {@stats.current_power} W
                      </div>
                      <%= if @stats.current_power > 0 do %>
                        <span class="flex h-2 w-2 relative" id="pulse-current-power">
                          <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75"></span>
                          <span class="relative inline-flex rounded-full h-2 w-2 bg-emerald-500"></span>
                        </span>
                      <% end %>
                    </dd>
                  </dl>
                </div>
              </div>
            </div>
          </div>

          <!-- Today's Yield -->
          <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
            <div class="px-4 py-5 sm:p-6">
              <div class="flex items-center">
                <div class="p-3 rounded-md bg-amber-50 dark:bg-amber-950/30 text-amber-600 dark:text-amber-400">
                  <.icon name="hero-sun" class="h-6 w-6" />
                </div>
                <div class="ml-5 w-0 flex-1">
                  <dl>
                    <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                      Today's Total Yield
                    </dt>
                    <dd class="flex items-baseline">
                      <div class="text-3xl font-semibold text-zinc-900 dark:text-white" id="stat-today-yield">
                        {@stats.today_yield} kWh
                      </div>
                    </dd>
                  </dl>
                </div>
              </div>
            </div>
          </div>

          <!-- Peak Power Today -->
          <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
            <div class="px-4 py-5 sm:p-6">
              <div class="flex items-center">
                <div class="p-3 rounded-md bg-blue-50 dark:bg-blue-950/30 text-blue-600 dark:text-blue-400">
                  <.icon name="hero-chart-bar" class="h-6 w-6" />
                </div>
                <div class="ml-5 w-0 flex-1">
                  <dl>
                    <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                      Peak Power Today
                    </dt>
                    <dd class="flex items-baseline">
                      <div class="text-3xl font-semibold text-zinc-900 dark:text-white" id="stat-peak-power">
                        {@stats.peak_power} W
                      </div>
                    </dd>
                  </dl>
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- Chart Panel -->
        <div class="bg-white dark:bg-zinc-800 shadow rounded-lg border border-zinc-200 dark:border-zinc-700 p-6">
          <h2 class="text-lg font-medium text-zinc-900 dark:text-white mb-4">
            Today's Production Curve
          </h2>
          
          <%= if @path_data == "" do %>
            <div class="flex flex-col items-center justify-center h-64 border-2 border-dashed border-zinc-300 dark:border-zinc-700 rounded-lg" id="empty-chart">
              <.icon name="hero-presentation-chart-line" class="h-12 w-12 text-zinc-400 mb-2" />
              <p class="text-sm text-zinc-500 dark:text-zinc-400">No power readings logged today yet.</p>
              <p class="text-xs text-zinc-400 dark:text-zinc-500 mt-1">Connect your DTU and publish data to start tracking.</p>
            </div>
          <% else %>
            <div class="relative w-full overflow-hidden" id="solar-chart-container">
              <!-- Chart SVG -->
              <svg viewBox="0 0 800 280" class="w-full h-auto overflow-visible" id="solar-chart-svg">
                <defs>
                  <linearGradient id="chartGrad" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0%" stop-color="#10b981" stop-opacity="0.25"/>
                    <stop offset="100%" stop-color="#10b981" stop-opacity="0.00"/>
                  </linearGradient>
                </defs>

                <!-- Grid Lines -->
                <line x1="0" y1="20" x2="800" y2="20" stroke="#f4f4f5" class="dark:stroke-zinc-700" stroke-width="1" />
                <line x1="0" y1="77.5" x2="800" y2="77.5" stroke="#f4f4f5" class="dark:stroke-zinc-700" stroke-width="1" />
                <line x1="0" y1="135" x2="800" y2="135" stroke="#f4f4f5" class="dark:stroke-zinc-700" stroke-width="1" stroke-dasharray="4" />
                <line x1="0" y1="192.5" x2="800" y2="192.5" stroke="#f4f4f5" class="dark:stroke-zinc-700" stroke-width="1" />
                <line x1="0" y1="250" x2="800" y2="250" stroke="#e4e4e7" class="dark:stroke-zinc-600" stroke-width="1.5" />

                <!-- Y-Axis Labels -->
                <text x="5" y="32" class="text-[10px] font-medium fill-zinc-400">{@y_max} W</text>
                <text x="5" y="147" class="text-[10px] font-medium fill-zinc-400">{div(round(@y_max), 2)} W</text>
                <text x="5" y="245" class="text-[10px] font-medium fill-zinc-400">0 W</text>

                <!-- X-Axis Labels (Time slots) -->
                <text x="0" y="270" class="text-[10px] font-medium fill-zinc-400" text-anchor="start">00:00</text>
                <text x="200" y="270" class="text-[10px] font-medium fill-zinc-400" text-anchor="middle">06:00</text>
                <text x="400" y="270" class="text-[10px] font-medium fill-zinc-400" text-anchor="middle">12:00</text>
                <text x="600" y="270" class="text-[10px] font-medium fill-zinc-400" text-anchor="middle">18:00</text>
                <text x="800" y="270" class="text-[10px] font-medium fill-zinc-400" text-anchor="end">24:00</text>

                <!-- Line paths -->
                <path d={@area_path_data} fill="url(#chartGrad)" />
                <path d={@path_data} fill="none" stroke="#10b981" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" />
              </svg>
            </div>
          <% end %>
        </div>

        <!-- Devices / Inverters status -->
        <div class="bg-white dark:bg-zinc-800 shadow rounded-lg border border-zinc-200 dark:border-zinc-700 p-6">
          <h2 class="text-lg font-medium text-zinc-900 dark:text-white mb-4">
            Device Connection Status
          </h2>
          
          <div class="grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3" id="device-status-grid">
            <%= for device <- @devices do %>
              <div class="border border-zinc-200 dark:border-zinc-700 rounded-lg p-5 flex flex-col justify-between hover:shadow-md transition" id={"device-card-#{device.id}"}>
                <div>
                  <div class="flex items-center justify-between">
                    <h3 class="text-md font-semibold text-zinc-900 dark:text-white">{device.name}</h3>
                    <span class={[
                      "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                      if(device.online, do: "bg-emerald-100 text-emerald-800 dark:bg-emerald-900/30 dark:text-emerald-400", else: "bg-zinc-100 text-zinc-800 dark:bg-zinc-800 dark:text-zinc-400")
                    ]}>
                      {if device.online, do: "online", else: "offline"}
                    </span>
                  </div>
                  <div class="mt-2 space-y-1 text-sm text-zinc-550 dark:text-zinc-400">
                    <p><span class="font-medium text-zinc-700 dark:text-zinc-300">Firmware:</span> {device.kind |> Atom.to_string() |> String.upcase()}</p>
                    <p><span class="font-medium text-zinc-700 dark:text-zinc-300">Base Topic:</span> {device.base_topic}</p>
                    <p><span class="font-medium text-zinc-700 dark:text-zinc-300">Last seen:</span> {if device.last_seen_at, do: Calendar.strftime(device.last_seen_at, "%Y-%m-%d %H:%M:%S UTC"), else: "never"}</p>
                  </div>
                </div>
                <div class="mt-4 pt-4 border-t border-zinc-100 dark:border-zinc-700/60 flex items-center justify-between text-xs text-zinc-400">
                  <span>MQTT Username: {device.mqtt_username}</span>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
