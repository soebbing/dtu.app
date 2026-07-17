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
      |> assign(:selected_dtu_id, nil)
      # `live` is true for the auto-refreshing Today view.
      # `granularity` drives the historical stepper (day/week/month/year).
      |> assign(:live, true)
      |> assign(:granularity, "day")
      |> assign(:time_range, "today")
      |> assign(:selected_period, nil)
      |> assign_selectable_periods(user, nil)
      |> assign_dashboard_data(user, nil, "today", nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("select_dtu", %{"id" => id_str}, socket) do
    selected_id = if id_str == "total", do: nil, else: String.to_integer(id_str)
    user = socket.assigns.current_scope.user

    socket = assign_selectable_periods(socket, user, selected_id)

    socket =
      socket
      |> assign(:selected_dtu_id, selected_id)
      |> reapply_current_view(user, selected_id)

    {:noreply, socket}
  end

  # The Today quick-range: switch to the live, auto-refreshing view.
  @impl true
  def handle_event("select_quick_range", %{"range" => "today"}, socket) do
    user = socket.assigns.current_scope.user
    dtu_id = socket.assigns.selected_dtu_id

    {:noreply,
     socket
     |> assign(:live, true)
     |> assign(:time_range, "today")
     |> assign(:selected_period, nil)
     |> assign_dashboard_data(user, dtu_id, "today", nil)}
  end

  # Granularity dropdown in the historical stepper (day/week/month/year).
  @impl true
  def handle_event("set_granularity", %{"granularity" => granularity}, socket) do
    user = socket.assigns.current_scope.user
    dtu_id = socket.assigns.selected_dtu_id

    # Start the new granularity on the most recent period with data (or today).
    selectable = selectable_periods_for(socket.assigns, granularity)
    period = first_period(selectable, granularity)

    {:noreply,
     socket
     |> assign(:live, false)
     |> assign(:granularity, granularity)
     |> assign(:time_range, granularity)
     |> assign_dashboard_data(user, dtu_id, granularity, period)}
  end

  # Stepper: move one granularity step backward/forward.
  @impl true
  def handle_event("navigate_period", %{"dir" => dir}, socket) do
    user = socket.assigns.current_scope.user
    dtu_id = socket.assigns.selected_dtu_id
    granularity = socket.assigns.granularity
    current = socket.assigns.selected_period || Date.utc_today()

    period = shift_period(current, granularity, dir)

    {:noreply,
     socket
     |> assign(:live, false)
     |> assign(:time_range, granularity)
     |> assign_dashboard_data(user, dtu_id, granularity, period)}
  end

  # Calendar: native <input type=date> picks the anchor date for the granularity.
  @impl true
  def handle_event("set_date", %{"date" => date_str}, socket) do
    user = socket.assigns.current_scope.user
    dtu_id = socket.assigns.selected_dtu_id
    granularity = socket.assigns.granularity

    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        period = anchor_period(date, granularity)

        {:noreply,
         socket
         |> assign(:live, false)
         |> assign(:time_range, granularity)
         |> assign_dashboard_data(user, dtu_id, granularity, period)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:reading, _client_id, _reading}, socket) do
    user = socket.assigns.current_scope.user
    selected_id = socket.assigns.selected_dtu_id

    socket = assign_selectable_periods(socket, user, selected_id)

    # Only live views refresh on every reading; historical views are static.
    socket =
      if socket.assigns.live do
        assign_dashboard_data(socket, user, selected_id, socket.assigns.time_range, nil)
      else
        socket
      end

    {:noreply, socket}
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

  # Helper to construct SVG line chart coordinates and range
  defp assign_line_chart_data(socket, user, date, dtu_id) do
    chart_points = Devices.list_day_chart_data(user, date, dtu_id)

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
        x = seconds / 86400.0 * 800.0
        # leave 20px padding at top
        y = 250.0 - power / y_max * 230.0
        {Float.round(x, 1), Float.round(y, 1)}
      end)

    path_data =
      case points do
        [] ->
          ""

        [{first_x, first_y} | rest] ->
          "M #{first_x} #{first_y} " <>
            (rest |> Enum.map_join(" ", fn {x, y} -> "L #{x} #{y}" end))
      end

    area_path_data =
      case points do
        [] ->
          ""

        [{first_x, first_y} | rest] ->
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

  # Helper to construct SVG bar chart coordinates and range
  defp assign_bar_chart_data(socket, bar_data) do
    max_val =
      bar_data
      |> Enum.map(& &1.value)
      |> Enum.max(fn -> 1.0 end)
      |> max(1.0)

    y_max =
      cond do
        max_val <= 5.0 -> 5.0
        max_val <= 10.0 -> 10.0
        true -> Float.ceil(max_val)
      end

    count = length(bar_data)
    col_width = 800.0 / count
    bar_width = col_width * 0.65

    bars =
      bar_data
      |> Enum.with_index()
      |> Enum.map(fn {item, idx} ->
        height = item.value / y_max * 200.0
        x = idx * col_width + (col_width - bar_width) / 2.0
        y = 220.0 - height

        %{
          x: Float.round(x / 1.0, 1),
          y: Float.round(y / 1.0, 1),
          w: Float.round(bar_width / 1.0, 1),
          h: Float.round(max(height, 1.0) / 1.0, 1),
          label: item.label,
          value: Float.round(item.value / 1.0, 3)
        }
      end)

    socket
    |> assign(:y_max, y_max)
    |> assign(:bars, bars)
  end

  defp assign_selectable_periods(socket, user, dtu_id) do
    dates = Devices.list_selectable_dates(user, dtu_id)

    socket
    |> assign(:selectable_dates, dates)
    |> assign(:selectable_days, build_selectable_days(dates))
    |> assign(:selectable_weeks, build_selectable_weeks(dates))
    |> assign(:selectable_months, build_selectable_months(dates))
    |> assign(:selectable_years, build_selectable_years(dates))
  end

  # --- Time-picker helpers ----------------------------------------------------

  # Re-run the dashboard for whichever view is active after a DTU switch.
  defp reapply_current_view(socket, user, dtu_id) do
    if socket.assigns.live do
      assign_dashboard_data(socket, user, dtu_id, socket.assigns.time_range, nil)
    else
      assign_dashboard_data(
        socket,
        user,
        dtu_id,
        socket.assigns.granularity,
        socket.assigns.selected_period
      )
    end
  end

  # Map a granularity to the prebuilt selectable-period list from assigns.
  defp selectable_periods_for(assigns, "day"), do: assigns.selectable_days
  defp selectable_periods_for(assigns, "week"), do: assigns.selectable_weeks
  defp selectable_periods_for(assigns, "month"), do: assigns.selectable_months
  defp selectable_periods_for(assigns, "year"), do: assigns.selectable_years
  defp selectable_periods_for(_assigns, _), do: []

  # First selectable period for a granularity (most recent with data), else today.
  defp first_period([], "year"), do: Date.utc_today().year
  defp first_period([], _), do: Date.utc_today()
  defp first_period([{_label, value} | _], "year"), do: String.to_integer(value)
  defp first_period([{_label, value} | _], _), do: Date.from_iso8601!(value)

  # Shift a period by one granularity step. "prev"/"next" move backward/forward.
  defp shift_period(%Date{} = date, "day", dir),
    do: Date.add(date, if(dir == "next", do: 1, else: -1))

  defp shift_period(%Date{} = date, "week", dir),
    do: Date.add(date, if(dir == "next", do: 7, else: -7))

  defp shift_period(%Date{} = date, "month", dir) do
    months = if(dir == "next", do: 1, else: -1)
    add_months(date, months)
  end

  defp shift_period(%Date{} = date, "year", dir),
    do: Date.add(date, if(dir == "next", do: 365, else: -365))

  defp shift_period(year, "year", dir) when is_integer(year),
    do: year + if(dir == "next", do: 1, else: -1)

  defp shift_period(period, _granularity, _dir), do: period

  defp add_months(date, months) do
    total = date.year * 12 + (date.month - 1) + months
    year = div(total, 12)
    month = rem(total, 12) + 1
    last_day = Date.new!(year, month, 1) |> Date.end_of_month() |> Map.get(:day)
    Date.new!(year, month, min(date.day, last_day))
  end

  # Normalize an arbitrary picked date to the start of the current granularity
  # (week→Monday, month/year→first day).
  defp anchor_period(date, "week"),
    do: Date.add(date, -(Date.day_of_week(date) - 1))

  defp anchor_period(date, "month"), do: Date.new!(date.year, date.month, 1)
  defp anchor_period(date, "year"), do: Date.new!(date.year, 1, 1)
  defp anchor_period(date, _), do: date

  # Human-readable label for the stepper's current position.
  defp stepper_label(%Date{} = date, "day"), do: Calendar.strftime(date, "%a %b %-d, %Y")

  defp stepper_label(%Date{} = date, "week"),
    do: gettext("Week of %{date}", date: Calendar.strftime(date, "%b %-d, %Y"))

  defp stepper_label(%Date{} = date, "month"), do: Calendar.strftime(date, "%B %Y")
  defp stepper_label(%Date{} = date, "year"), do: to_string(date.year)
  defp stepper_label(year, _), do: to_string(year)

  # Value for the native date input (yyyy-mm-dd).
  defp date_input_value(%Date{} = date), do: Date.to_iso8601(date)

  defp date_input_value(year) when is_integer(year),
    do: Date.new!(year, 1, 1) |> Date.to_iso8601()

  defp date_input_value(_), do: Date.utc_today() |> Date.to_iso8601()

  # Earliest date with data, for the calendar's `min` bound (yyyy-mm-dd, or nil).
  defp date_min_bound([]), do: nil
  defp date_min_bound(dates), do: dates |> Enum.min(Date) |> Date.to_iso8601()

  # Latest date with data, for the calendar's `max` bound.
  defp date_max_bound([]), do: nil
  defp date_max_bound(dates), do: dates |> Enum.max(Date) |> Date.to_iso8601()

  # True when the current historical granularity has no data to show.
  defp historical_empty?("day", days, _, _, _), do: days == []
  defp historical_empty?("week", _, weeks, _, _), do: weeks == []
  defp historical_empty?("month", _, _, months, _), do: months == []
  defp historical_empty?("year", _, _, _, years), do: years == []
  defp historical_empty?(_, _, _, _, _), do: false

  defp quick_range_btn(assigns) do
    ~H"""
    <button
      phx-click="select_quick_range"
      phx-value-range={@range}
      id={@id}
      class={[
        "px-3.5 py-1.5 text-xs font-semibold rounded-lg transition-all duration-250",
        @active &&
          "bg-emerald-500 text-zinc-950 shadow-md shadow-emerald-500/10",
        !@active &&
          "text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100 hover:bg-zinc-250/50 dark:hover:bg-zinc-700/50"
      ]}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp build_selectable_days(dates) do
    dates
    |> Enum.map(fn date ->
      label = Calendar.strftime(date, "%Y-%m-%d")
      {label, Date.to_string(date)}
    end)
  end

  defp build_selectable_weeks(dates) do
    dates
    |> Enum.group_by(fn d ->
      :calendar.iso_week_number({d.year, d.month, d.day})
    end)
    |> Enum.map(fn {{year, week}, week_dates} ->
      representative_date = hd(week_dates)
      monday = Date.add(representative_date, -(Date.day_of_week(representative_date) - 1))

      label =
        gettext("Year %{year}, Week %{week} (starting %{monday})",
          year: year,
          week: week,
          monday: monday
        )

      {label, Date.to_string(monday)}
    end)
    |> Enum.sort_by(fn {_, val} -> val end, :desc)
  end

  defp build_selectable_months(dates) do
    dates
    |> Enum.map(fn d -> {d.year, d.month} end)
    |> Enum.uniq()
    |> Enum.map(fn {year, month} ->
      first_day = Date.new!(year, month, 1)
      translated_month = Gettext.gettext(DtuAppWeb.Gettext, Calendar.strftime(first_day, "%B"))
      label = "#{translated_month} #{first_day.year}"
      {label, Date.to_string(first_day)}
    end)
    |> Enum.sort_by(fn {_, val} -> val end, :desc)
  end

  defp build_selectable_years(dates) do
    dates
    |> Enum.map(& &1.year)
    |> Enum.uniq()
    |> Enum.map(fn year ->
      {to_string(year), to_string(year)}
    end)
    |> Enum.sort(:desc)
  end

  defp assign_dashboard_data(socket, user, dtu_id, time_range, selected_period) do
    case time_range do
      "today" ->
        stats = Devices.get_daily_stats(user, dtu_id)

        socket
        |> assign(:stats, stats)
        |> assign(:chart_type, :line)
        |> assign_line_chart_data(user, Date.utc_today(), dtu_id)

      "day" ->
        date =
          case selected_period do
            %Date{} = d ->
              d

            _ ->
              selectable = socket.assigns.selectable_dates
              List.first(selectable) || Date.utc_today()
          end

        points = Devices.list_day_chart_data(user, date, dtu_id)
        yields = Devices.list_range_yield_data(user, date, date, dtu_id)

        total_yield =
          case yields do
            [{^date, y}] -> y
            _ -> 0.0
          end

        peak_power =
          case points do
            [] -> 0.0
            pts -> pts |> Enum.map(fn {_, p} -> p end) |> Enum.max(fn -> 0.0 end)
          end

        avg_power =
          case points do
            [] -> 0.0
            pts -> Enum.sum(pts |> Enum.map(fn {_, p} -> p end)) / length(pts)
          end

        stats = %{
          total_yield: Float.round(total_yield * 1.0, 3),
          peak_power: Float.round(peak_power * 1.0, 1),
          avg_power: Float.round(avg_power * 1.0, 1)
        }

        socket
        |> assign(:selected_period, date)
        |> assign(:stats, stats)
        |> assign(:chart_type, :line)
        |> assign_line_chart_data(user, date, dtu_id)

      "week" ->
        monday =
          case selected_period do
            %Date{} = d ->
              d

            _ ->
              selectable = socket.assigns.selectable_dates
              latest_date = List.first(selectable) || Date.utc_today()
              Date.add(latest_date, -(Date.day_of_week(latest_date) - 1))
          end

        sunday = Date.add(monday, 6)
        yields = Devices.list_range_yield_data(user, monday, sunday, dtu_id)
        total_yield = yields |> Enum.map(fn {_, y} -> y end) |> Enum.sum()
        avg_yield = total_yield / 7.0

        {peak_date, peak_val} =
          case yields do
            [] -> {nil, 0.0}
            list -> list |> Enum.max_by(fn {_, y} -> y end, fn -> {nil, 0.0} end)
          end

        stats = %{
          total_yield: Float.round(total_yield * 1.0, 3),
          avg_yield: Float.round(avg_yield * 1.0, 3),
          peak_date: peak_date,
          peak_val: Float.round(peak_val * 1.0, 3)
        }

        yield_map = Map.new(yields)

        bar_data =
          for day_offset <- 0..6 do
            d = Date.add(monday, day_offset)
            label = Calendar.strftime(d, "%a")
            value = Map.get(yield_map, d, 0.0)
            %{label: label, value: value}
          end

        socket
        |> assign(:selected_period, monday)
        |> assign(:stats, stats)
        |> assign(:chart_type, :bar)
        |> assign_bar_chart_data(bar_data)

      "month" ->
        first_day =
          case selected_period do
            %Date{} = d ->
              d

            _ ->
              selectable = socket.assigns.selectable_dates
              latest_date = List.first(selectable) || Date.utc_today()
              Date.new!(latest_date.year, latest_date.month, 1)
          end

        last_day = Date.end_of_month(first_day)
        yields = Devices.list_range_yield_data(user, first_day, last_day, dtu_id)
        total_yield = yields |> Enum.map(fn {_, y} -> y end) |> Enum.sum()
        total_days = Date.diff(last_day, first_day) + 1
        avg_yield = total_yield / total_days

        {peak_date, peak_val} =
          case yields do
            [] -> {nil, 0.0}
            list -> list |> Enum.max_by(fn {_, y} -> y end, fn -> {nil, 0.0} end)
          end

        stats = %{
          total_yield: Float.round(total_yield * 1.0, 3),
          avg_yield: Float.round(avg_yield * 1.0, 3),
          peak_date: peak_date,
          peak_val: Float.round(peak_val * 1.0, 3)
        }

        yield_map = Map.new(yields)

        bar_data =
          for day_offset <- 0..(total_days - 1) do
            d = Date.add(first_day, day_offset)
            label = to_string(d.day)
            value = Map.get(yield_map, d, 0.0)
            %{label: label, value: value}
          end

        socket
        |> assign(:selected_period, first_day)
        |> assign(:stats, stats)
        |> assign(:chart_type, :bar)
        |> assign_bar_chart_data(bar_data)

      "year" ->
        year =
          case selected_period do
            %Date{} = d ->
              d.year

            y when is_integer(y) ->
              y

            _ ->
              selectable = socket.assigns.selectable_dates
              latest_date = List.first(selectable) || Date.utc_today()
              latest_date.year
          end

        start_date = Date.new!(year, 1, 1)
        end_date = Date.new!(year, 12, 31)
        yields = Devices.list_range_yield_data(user, start_date, end_date, dtu_id)
        total_yield = yields |> Enum.map(fn {_, y} -> y end) |> Enum.sum()
        avg_yield = total_yield / 12.0

        {peak_date, peak_val} =
          case yields do
            [] -> {nil, 0.0}
            list -> list |> Enum.max_by(fn {_, y} -> y end, fn -> {nil, 0.0} end)
          end

        stats = %{
          total_yield: Float.round(total_yield * 1.0, 3),
          avg_yield: Float.round(avg_yield * 1.0, 3),
          peak_date: peak_date,
          peak_val: Float.round(peak_val * 1.0, 3)
        }

        yield_map = Map.new(yields)

        bar_data =
          for month <- 1..12 do
            month_yield =
              yield_map
              |> Enum.filter(fn {date, _} -> date.month == month end)
              |> Enum.map(fn {_, y} -> y end)
              |> Enum.sum()

            first_day_of_month = Date.new!(year, month, 1)
            label = Calendar.strftime(first_day_of_month, "%b")
            %{label: label, value: month_yield}
          end

        socket
        |> assign(:selected_period, Date.new!(year, 1, 1))
        |> assign(:stats, stats)
        |> assign(:chart_type, :bar)
        |> assign_bar_chart_data(bar_data)
    end
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
              {gettext("PV Power Dashboard")}
            </h1>
            <p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
              {gettext("Real-time and historic generation stats for your solar converter system.")}
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
              {gettext("Manage Devices")}
            </.link>
          </div>
        </div>

        <%= if @devices == [] do %>
          <!-- Onboarding: no DTUs yet. The whole stats/chart grid is meaningless
               without a device, so guide the user to create their first one. -->
          <div
            class="rounded-2xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-8 text-center"
            id="onboarding-empty"
          >
            <div class="mx-auto w-fit p-3 rounded-xl bg-emerald-50 dark:bg-emerald-950/30 text-emerald-600 dark:text-emerald-400">
              <.icon name="hero-bolt" class="h-8 w-8" />
            </div>
            <h2 class="mt-4 text-xl font-bold tracking-tight text-zinc-900 dark:text-white">
              {gettext("Welcome! Let's connect your first DTU")}
            </h2>
            <p class="mt-2 text-sm text-zinc-500 dark:text-zinc-400 max-w-md mx-auto">
              {gettext(
                "A DTU (Data Transfer Unit) reads your solar inverter and publishes live telemetry here over MQTT. Add yours to start seeing real-time generation — works with OpenDTU and AhoyDTU firmware."
              )}
            </p>
            <div class="mt-6">
              <.link
                navigate={~p"/devices/new"}
                id="btn-add-first-dtu"
                class="inline-flex items-center gap-1.5 rounded-lg bg-emerald-500 hover:bg-emerald-400 px-5 py-2.5 text-sm font-semibold text-zinc-950 shadow-sm transition"
              >
                <.icon name="hero-plus-mini" class="size-4" />
                {gettext("Add your first DTU")}
              </.link>
            </div>
          </div>
        <% else %>

        <!-- Toolbar: Switcher & Time Ranges -->
        <div class="flex flex-col gap-4">
          <!-- DTU Switcher -->
          <%= if length(@devices) > 1 do %>
            <div
              class="flex flex-wrap items-center gap-2 border border-zinc-200 dark:border-zinc-700 bg-zinc-50/80 dark:bg-zinc-800/40 p-1.5 rounded-xl max-w-max"
              id="dtu-switcher"
            >
              <button
                phx-click="select_dtu"
                phx-value-id="total"
                id="btn-select-total"
                class={[
                  "px-3.5 py-1.5 text-xs font-semibold rounded-lg transition-all duration-250",
                  is_nil(@selected_dtu_id) &&
                    "bg-emerald-500 text-zinc-950 shadow-md shadow-emerald-500/10",
                  !is_nil(@selected_dtu_id) &&
                    "text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100 hover:bg-zinc-250/50 dark:hover:bg-zinc-700/50"
                ]}
              >
                {gettext("Total (All DTUs)")}
              </button>
              <%= for device <- @devices do %>
                <button
                  phx-click="select_dtu"
                  phx-value-id={device.id}
                  id={"btn-select-dtu-#{device.id}"}
                  class={[
                    "px-3.5 py-1.5 text-xs font-semibold rounded-lg transition-all duration-250",
                    @selected_dtu_id == device.id &&
                      "bg-emerald-500 text-zinc-950 shadow-md shadow-emerald-500/10",
                    @selected_dtu_id != device.id &&
                      "text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100 hover:bg-zinc-250/50 dark:hover:bg-zinc-700/50"
                  ]}
                >
                  {device.name}
                </button>
              <% end %>
            </div>
          <% end %>

          <!-- Time Range Tab Selector -->
          <!-- Quick ranges: live, auto-refreshing views -->
          <div
            class="flex flex-wrap items-center gap-2 border border-zinc-200 dark:border-zinc-700 bg-zinc-50/80 dark:bg-zinc-800/40 p-1.5 rounded-xl max-w-max"
            id="quick-range-switcher"
          >
            <.quick_range_btn id="btn-range-today" range="today" active={@live}>
              {gettext("Today")}
            </.quick_range_btn>
          </div>

          <!-- Historical stepper: ‹ [Granularity ▾] [Date ▾] › -->
          <div
            class="flex flex-wrap items-center gap-1.5 border border-zinc-200 dark:border-zinc-700 bg-zinc-50/80 dark:bg-zinc-800/40 p-1.5 rounded-xl"
            id="history-picker"
          >
            <button
              phx-click="navigate_period"
              phx-value-dir="prev"
              id="btn-history-prev"
              aria-label={gettext("Previous period")}
              class="px-2.5 py-1.5 text-sm font-semibold rounded-lg text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100 hover:bg-zinc-250/50 dark:hover:bg-zinc-700/50 transition"
            >
              <.icon name="hero-chevron-left" class="size-4" />
            </button>

            <form phx-change="set_granularity" id="form-granularity" class="inline-block">
              <select
                name="granularity"
                id="select-granularity"
                class="bg-white dark:bg-zinc-800 text-zinc-900 dark:text-white border border-zinc-300 dark:border-zinc-700 rounded-lg text-sm px-2.5 py-1.5 focus:ring-emerald-500 focus:border-emerald-500"
              >
                <%= for {label, value} <- [
                      {gettext("Day"), "day"},
                      {gettext("Week"), "week"},
                      {gettext("Month"), "month"},
                      {gettext("Year"), "year"}
                    ] do %>
                  <option value={value} selected={value == @granularity}>
                    {label}
                  </option>
                <% end %>
              </select>
            </form>

            <!-- Date label: clicking reveals the native calendar -->
            <label
              class="relative inline-flex items-center rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-800 px-2.5 py-1.5 text-sm font-semibold text-zinc-700 dark:text-zinc-200 cursor-pointer hover:bg-zinc-50 dark:hover:bg-zinc-700 transition"
              title={gettext("Choose date")}
            >
              <span id="history-label">{stepper_label(@selected_period, @granularity)}</span>
              <.icon name="hero-calendar-days-mini" class="ml-1.5 size-4 text-zinc-400" />
              <input
                type="date"
                phx-change="set_date"
                id="history-date-input"
                value={date_input_value(@selected_period)}
                min={date_min_bound(@selectable_dates)}
                max={date_max_bound(@selectable_dates)}
                class="absolute inset-0 opacity-0 cursor-pointer"
              />
            </label>

            <button
              phx-click="navigate_period"
              phx-value-dir="next"
              id="btn-history-next"
              aria-label={gettext("Next period")}
              class="px-2.5 py-1.5 text-sm font-semibold rounded-lg text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100 hover:bg-zinc-250/50 dark:hover:bg-zinc-700/50 transition"
            >
              <.icon name="hero-chevron-right" class="size-4" />
            </button>

            <%= if @live == false and historical_empty?(@granularity, @selectable_days, @selectable_weeks, @selectable_months, @selectable_years) do %>
              <span class="ml-2 text-sm text-zinc-450 dark:text-zinc-500 italic">
                {gettext("No historical data for this period.")}
              </span>
            <% end %>
          </div>
        </div>

        <!-- Stats Grid -->
        <div class="grid grid-cols-1 gap-5 sm:grid-cols-3">
          <%= if @live do %>
            <!-- Current Power (Today only) -->
            <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
              <div class="px-4 py-5 sm:p-6">
                <div class="flex items-center">
                  <div class="p-3 rounded-md bg-emerald-50 dark:bg-emerald-950/30 text-emerald-600 dark:text-emerald-400">
                    <.icon name="hero-bolt" class="h-6 w-6" />
                  </div>
                  <div class="ml-5 w-0 flex-1">
                    <dl>
                      <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                        {gettext("Current Generation")}
                      </dt>
                      <dd class="flex items-baseline space-x-2">
                        <div
                          class="text-3xl font-semibold text-zinc-900 dark:text-white"
                          id="stat-current-power"
                        >
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
          <% else %>
            <!-- Total Yield (Historical views) -->
            <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
              <div class="px-4 py-5 sm:p-6">
                <div class="flex items-center">
                  <div class="p-3 rounded-md bg-emerald-50 dark:bg-emerald-950/30 text-emerald-600 dark:text-emerald-400">
                    <.icon name="hero-bolt" class="h-6 w-6" />
                  </div>
                  <div class="ml-5 w-0 flex-1">
                    <dl>
                      <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                        {gettext("Total Yield")}
                      </dt>
                      <dd class="flex items-baseline">
                        <div
                          class="text-3xl font-semibold text-zinc-900 dark:text-white"
                          id="stat-total-yield"
                        >
                          {@stats.total_yield} kWh
                        </div>
                      </dd>
                    </dl>
                  </div>
                </div>
              </div>
            </div>
          <% end %>

          <!-- Middle Card: Today Yield (Today) vs Avg Power (Day) vs Daily Avg Yield (Week/Month/Year) -->
          <%= cond do %>
            <% @live -> %>
              <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
                <div class="px-4 py-5 sm:p-6">
                  <div class="flex items-center">
                    <div class="p-3 rounded-md bg-amber-50 dark:bg-amber-950/30 text-amber-600 dark:text-amber-400">
                      <.icon name="hero-sun" class="h-6 w-6" />
                    </div>
                    <div class="ml-5 w-0 flex-1">
                      <dl>
                        <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                          {gettext("Today's Total Yield")}
                        </dt>
                        <dd class="flex items-baseline">
                          <div
                            class="text-3xl font-semibold text-zinc-900 dark:text-white"
                            id="stat-today-yield"
                          >
                            {@stats.today_yield} kWh
                          </div>
                        </dd>
                      </dl>
                    </div>
                  </div>
                </div>
              </div>
            <% @time_range == "day" -> %>
              <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
                <div class="px-4 py-5 sm:p-6">
                  <div class="flex items-center">
                    <div class="p-3 rounded-md bg-amber-50 dark:bg-amber-950/30 text-amber-600 dark:text-amber-400">
                      <.icon name="hero-bolt" class="h-6 w-6" />
                    </div>
                    <div class="ml-5 w-0 flex-1">
                      <dl>
                        <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                          {gettext("Average Power")}
                        </dt>
                        <dd class="flex items-baseline">
                          <div
                            class="text-3xl font-semibold text-zinc-900 dark:text-white"
                            id="stat-avg-power"
                          >
                            {@stats.avg_power} W
                          </div>
                        </dd>
                      </dl>
                    </div>
                  </div>
                </div>
              </div>
            <% true -> %>
              <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
                <div class="px-4 py-5 sm:p-6">
                  <div class="flex items-center">
                    <div class="p-3 rounded-md bg-amber-50 dark:bg-amber-950/30 text-amber-600 dark:text-amber-400">
                      <.icon name="hero-calculator" class="h-6 w-6" />
                    </div>
                    <div class="ml-5 w-0 flex-1">
                      <dl>
                        <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                          {gettext("Daily Average Yield")}
                        </dt>
                        <dd class="flex items-baseline">
                          <div
                            class="text-3xl font-semibold text-zinc-900 dark:text-white"
                            id="stat-avg-yield"
                          >
                            {@stats.avg_yield} kWh
                          </div>
                        </dd>
                      </dl>
                    </div>
                  </div>
                </div>
              </div>
          <% end %>

          <!-- Right Card: Peak Power (Today/Day) vs Peak Yield Day (Week/Month/Year) -->
          <%= cond do %>
            <% @live or @time_range == "day" -> %>
              <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
                <div class="px-4 py-5 sm:p-6">
                  <div class="flex items-center">
                    <div class="p-3 rounded-md bg-blue-50 dark:bg-blue-950/30 text-blue-600 dark:text-blue-400">
                      <.icon name="hero-chart-bar" class="h-6 w-6" />
                    </div>
                    <div class="ml-5 w-0 flex-1">
                      <dl>
                        <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                          {gettext("Peak Power")}
                        </dt>
                        <dd class="flex items-baseline">
                          <div
                            class="text-3xl font-semibold text-zinc-900 dark:text-white"
                            id="stat-peak-power"
                          >
                            {@stats.peak_power} W
                          </div>
                        </dd>
                      </dl>
                    </div>
                  </div>
                </div>
              </div>
            <% true -> %>
              <div class="bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg border border-zinc-200 dark:border-zinc-700">
                <div class="px-4 py-5 sm:p-6">
                  <div class="flex items-center">
                    <div class="p-3 rounded-md bg-blue-50 dark:bg-blue-950/30 text-blue-600 dark:text-blue-400">
                      <.icon name="hero-fire" class="h-6 w-6" />
                    </div>
                    <div class="ml-5 w-0 flex-1">
                      <dl>
                        <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400 truncate">
                          {gettext("Peak Yield Day")}
                        </dt>
                        <dd class="flex flex-col">
                          <div
                            class="text-2xl font-semibold text-zinc-900 dark:text-white"
                            id="stat-peak-yield"
                          >
                            {@stats.peak_val} kWh
                          </div>
                          <%= if @stats.peak_date do %>
                            <div
                              class="text-xs text-zinc-400 dark:text-zinc-500 mt-0.5"
                              id="stat-peak-yield-date"
                            >
                              {gettext("on %{date}", date: @stats.peak_date)}
                            </div>
                          <% end %>
                        </dd>
                      </dl>
                    </div>
                  </div>
                </div>
              </div>
          <% end %>
        </div>

        <!-- Chart Panel -->
        <div class="bg-white dark:bg-zinc-800 shadow rounded-lg border border-zinc-200 dark:border-zinc-700 p-6">
          <h2 class="text-lg font-medium text-zinc-900 dark:text-white mb-4" id="chart-title">
            <%= cond do %>
              <% @live -> %>
                {gettext("Today's Production Curve (Watts)")}
              <% @time_range == "day" -> %>
                {gettext("Production Curve for %{period} (Watts)", period: @selected_period)}
              <% @time_range == "week" -> %>
                {gettext("Daily Yields for Week starting %{period} (kWh)", period: @selected_period)}
              <% @time_range == "month" -> %>
                {gettext("Daily Yields for month of %{month_year} (kWh)",
                  month_year:
                    "#{Gettext.gettext(DtuAppWeb.Gettext, Calendar.strftime(@selected_period, "%B"))} #{@selected_period.year}"
                )}
              <% @time_range == "year" -> %>
                {gettext("Monthly Yields for %{year} (kWh)", year: @selected_period.year)}
            <% end %>
          </h2>

          <%= if @chart_type == :line do %>
            <%= if @path_data == "" do %>
              <div
                class="flex flex-col items-center justify-center h-64 border-2 border-dashed border-zinc-300 dark:border-zinc-700 rounded-lg"
                id="empty-chart"
              >
                <.icon name="hero-presentation-chart-line" class="h-12 w-12 text-zinc-400 mb-2" />
                <p class="text-sm text-zinc-500 dark:text-zinc-400">
                  {gettext("No power readings logged for this day.")}
                </p>
              </div>
            <% else %>
              <div class="relative w-full overflow-hidden" id="solar-chart-container">
                <!-- Chart SVG -->
                <svg viewBox="0 0 800 280" class="w-full h-auto overflow-visible" id="solar-chart-svg">
                  <defs>
                    <linearGradient id="chartGrad" x1="0" y1="0" x2="0" y2="1">
                      <stop offset="0%" stop-color="#10b981" stop-opacity="0.25" />
                      <stop offset="100%" stop-color="#10b981" stop-opacity="0.00" />
                    </linearGradient>
                  </defs>

                  <!-- Grid Lines -->
                  <line
                    x1="0"
                    y1="20"
                    x2="800"
                    y2="20"
                    stroke="#f4f4f5"
                    class="dark:stroke-zinc-700"
                    stroke-width="1"
                  />
                  <line
                    x1="0"
                    y1="77.5"
                    x2="800"
                    y2="77.5"
                    stroke="#f4f4f5"
                    class="dark:stroke-zinc-700"
                    stroke-width="1"
                  />
                  <line
                    x1="0"
                    y1="135"
                    x2="800"
                    y2="135"
                    stroke="#f4f4f5"
                    class="dark:stroke-zinc-700"
                    stroke-width="1"
                    stroke-dasharray="4"
                  />
                  <line
                    x1="0"
                    y1="192.5"
                    x2="800"
                    y2="192.5"
                    stroke="#f4f4f5"
                    class="dark:stroke-zinc-700"
                    stroke-width="1"
                  />
                  <line
                    x1="0"
                    y1="250"
                    x2="800"
                    y2="250"
                    stroke="#e4e4e7"
                    class="dark:stroke-zinc-600"
                    stroke-width="1.5"
                  />

                  <!-- Y-Axis Labels -->
                  <text x="5" y="32" class="text-[10px] font-medium fill-zinc-400">{@y_max} W</text>
                  <text x="5" y="147" class="text-[10px] font-medium fill-zinc-400">
                    {div(round(@y_max), 2)} W
                  </text>
                  <text x="5" y="245" class="text-[10px] font-medium fill-zinc-400">0 W</text>

                  <!-- X-Axis Labels (Time slots) -->
                  <text
                    x="0"
                    y="270"
                    class="text-[10px] font-medium fill-zinc-400"
                    text-anchor="start"
                  >
                    00:00
                  </text>
                  <text
                    x="200"
                    y="270"
                    class="text-[10px] font-medium fill-zinc-400"
                    text-anchor="middle"
                  >
                    06:00
                  </text>
                  <text
                    x="400"
                    y="270"
                    class="text-[10px] font-medium fill-zinc-400"
                    text-anchor="middle"
                  >
                    12:00
                  </text>
                  <text
                    x="600"
                    y="270"
                    class="text-[10px] font-medium fill-zinc-400"
                    text-anchor="middle"
                  >
                    18:00
                  </text>
                  <text
                    x="800"
                    y="270"
                    class="text-[10px] font-medium fill-zinc-400"
                    text-anchor="end"
                  >
                    24:00
                  </text>

                  <!-- Line paths -->
                  <path d={@area_path_data} fill="url(#chartGrad)" />
                  <path
                    d={@path_data}
                    fill="none"
                    stroke="#10b981"
                    stroke-width="2.5"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                  />
                </svg>
              </div>
            <% end %>
          <% else %>
            <!-- Bar Chart -->
            <%= if Enum.all?(@bars, &(&1.value == 0.0)) do %>
              <div
                class="flex flex-col items-center justify-center h-64 border-2 border-dashed border-zinc-300 dark:border-zinc-700 rounded-lg"
                id="empty-chart"
              >
                <.icon name="hero-presentation-chart-bar" class="h-12 w-12 text-zinc-400 mb-2" />
                <p class="text-sm text-zinc-500 dark:text-zinc-400">
                  {gettext("No yield records logged for this period.")}
                </p>
              </div>
            <% else %>
              <div class="relative w-full overflow-hidden" id="solar-chart-container">
                <svg viewBox="0 0 800 250" class="w-full h-auto overflow-visible" id="solar-chart-svg">
                  <defs>
                    <linearGradient id="barGrad" x1="0" y1="0" x2="0" y2="1">
                      <stop offset="0%" stop-color="#10b981" stop-opacity="0.85" />
                      <stop offset="100%" stop-color="#047857" stop-opacity="0.95" />
                    </linearGradient>
                  </defs>

                  <!-- Grid Lines -->
                  <line
                    x1="0"
                    y1="20"
                    x2="800"
                    y2="20"
                    stroke="#f4f4f5"
                    class="dark:stroke-zinc-700"
                    stroke-width="1"
                  />
                  <line
                    x1="0"
                    y1="120"
                    x2="800"
                    y2="120"
                    stroke="#f4f4f5"
                    class="dark:stroke-zinc-700"
                    stroke-width="1"
                    stroke-dasharray="4"
                  />
                  <line
                    x1="0"
                    y1="220"
                    x2="800"
                    y2="220"
                    stroke="#e4e4e7"
                    class="dark:stroke-zinc-600"
                    stroke-width="1.5"
                  />

                  <!-- Y-Axis Labels -->
                  <text x="5" y="32" class="text-[10px] font-medium fill-zinc-400">{@y_max} kWh</text>
                  <text x="5" y="128" class="text-[10px] font-medium fill-zinc-400">
                    {Float.round(@y_max / 2, 2)} kWh
                  </text>
                  <text x="5" y="215" class="text-[10px] font-medium fill-zinc-400">0 kWh</text>

                  <!-- Draw Bars -->
                  <%= for bar <- @bars do %>
                    <g class="group">
                      <rect
                        x={bar.x}
                        y={bar.y}
                        width={bar.w}
                        height={bar.h}
                        fill="url(#barGrad)"
                        rx="4"
                        class="transition-all duration-200 hover:fill-emerald-400 cursor-pointer"
                      />
                      <!-- Hover tooltip showing value -->
                      <text
                        x={bar.x + bar.w / 2}
                        y={max(bar.y - 6.0, 15.0)}
                        text-anchor="middle"
                        class="text-[9px] font-bold fill-zinc-800 dark:fill-white opacity-0 group-hover:opacity-100 transition-opacity duration-150 pointer-events-none"
                      >
                        {bar.value}
                      </text>
                      <!-- X label -->
                      <text
                        x={bar.x + bar.w / 2}
                        y="238"
                        text-anchor="middle"
                        class="text-[9px] font-semibold fill-zinc-550 dark:fill-zinc-400"
                      >
                        {bar.label}
                      </text>
                    </g>
                  <% end %>
                </svg>
              </div>
            <% end %>
          <% end %>
        </div>

        <!-- Devices / Inverters status -->
        <div class="bg-white dark:bg-zinc-800 shadow rounded-lg border border-zinc-200 dark:border-zinc-700 p-6">
          <h2 class="text-lg font-medium text-zinc-900 dark:text-white mb-4">
            {gettext("Device Connection Status")}
          </h2>

          <div class="grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3" id="device-status-grid">
            <%= for device <- @devices do %>
              <div
                class="border border-zinc-200 dark:border-zinc-700 rounded-lg p-5 flex flex-col justify-between hover:shadow-md transition"
                id={"device-card-#{device.id}"}
              >
                <div>
                  <div class="flex items-center justify-between">
                    <h3 class="text-md font-semibold text-zinc-900 dark:text-white">{device.name}</h3>
                    <span class={[
                      "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                      if(device.online,
                        do:
                          "bg-emerald-100 text-emerald-800 dark:bg-emerald-900/30 dark:text-emerald-400",
                        else: "bg-zinc-100 text-zinc-800 dark:bg-zinc-800 dark:text-zinc-400"
                      )
                    ]}>
                      {if device.online, do: gettext("online"), else: gettext("offline")}
                    </span>
                  </div>
                  <div class="mt-2 space-y-1 text-sm text-zinc-550 dark:text-zinc-400">
                    <p>
                      <span class="font-medium text-zinc-700 dark:text-zinc-300">{gettext("Firmware:")}</span> {device.kind
                      |> Atom.to_string()
                      |> String.upcase()}
                    </p>
                    <p>
                      <span class="font-medium text-zinc-700 dark:text-zinc-300">{gettext(
                        "Base Topic:"
                      )}</span> {device.base_topic}
                    </p>
                    <p>
                      <span class="font-medium text-zinc-700 dark:text-zinc-300">{gettext(
                        "Last seen:"
                      )}</span> {if device.last_seen_at,
                        do: Calendar.strftime(device.last_seen_at, "%Y-%m-%d %H:%M:%S UTC"),
                        else: gettext("never")}
                    </p>
                  </div>
                </div>
                <div class="mt-4 pt-4 border-t border-zinc-100 dark:border-zinc-700/60 flex items-center justify-between text-xs text-zinc-400">
                  <span>{gettext("MQTT Username:")} {device.mqtt_username}</span>
                </div>
              </div>
            <% end %>
          </div>
        </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
