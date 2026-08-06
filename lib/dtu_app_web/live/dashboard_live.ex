defmodule DtuAppWeb.DashboardLive do
  use DtuAppWeb, :live_view

  alias DtuApp.Devices
  alias DtuApp.MqttBroker.Telemetry
  alias DtuApp.MqttBroker.Broker

  @timezone_topic "dtu:timezone"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Telemetry.subscribe()
      Telemetry.subscribe_status()
      Broker.subscribe_presence()
      # Listen for the client-side timezone push (via PubSub from
      # `.ChartTooltip` or from tests).
      Phoenix.PubSub.subscribe(DtuApp.PubSub, @timezone_topic)
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
      # Default to UTC (offset 0). The client-side `.SetTimezone`
      # colocated hook pushes the real offset once the WebSocket is
      # connected, and `handle_info({:set_timezone, ...})` updates this
      # assign + re-renders.
      |> assign(:user_tz_offset_seconds, 0)
      |> assign_selectable_periods(user, nil)
      |> assign_dashboard_data(user, nil, "today", nil)

    {:ok, socket}
  end

  # `phx-push` path: the JS hook's `this.pushEvent("set_timezone", ...)`
  # arrives here and is forwarded to `handle_info({:set_timezone, ...})`
  # (grouped with the other `handle_info/2` clauses further down). Tests
  # use `Phoenix.PubSub.broadcast/2` directly, hitting the same handler.
  @impl true
  def handle_event("set_timezone", %{"offset_seconds" => raw}, socket)
      when is_binary(raw) do
    handle_info({:set_timezone, String.to_integer(raw)}, socket)
  end

  def handle_event("set_timezone", _payload, socket), do: {:noreply, socket}

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
    current = socket.assigns.selected_period || local_today(socket.assigns.user_tz_offset_seconds)

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

  # Network status event handler from the NetworkStatus hook
  @impl true
  def handle_event("network_status_changed", payload, socket) do
    # Handle network status changes
    # You can update UI elements, show notifications, or adjust data fetching
    socket =
      socket
      |> assign(:network_online, payload["online"])
      |> assign(:network_connection_type, payload["connection_type"])
      |> assign(:network_last_update, payload["timestamp"])

    {:noreply, socket}
  end

  @impl true
  def handle_info({:reading, _client_id, _reading}, socket) do
    user = socket.assigns.current_scope.user
    selected_id = socket.assigns.selected_dtu_id

    socket = assign_selectable_periods(socket, user, selected_id)

    # Every reading also touches the DTU's `last_seen_at` (see
    # `DtuApp.MqttBroker.Telemetry`), so re-read the device list here
    # to refresh the derived online badge — without this refresh the
    # badge would only update on a CONNECT / DISCONNECT, which means
    # a DTU that wakes up but stays MQTT-connected wouldn't flip from
    # offline to online until the next reconnect.
    socket =
      assign(socket, :devices, Devices.list_devices(user))
      |> maybe_reassign_dashboard_data(user, selected_id)

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

  # Every MQTT uplink (and every CONNECT / DISCONNECT) broadcasts a
  # `:dtu_seen` on `dtu:status` after touching `last_seen_at`. Re-read
  # the device list so the badge flips on the next render. The
  # historical-view path is left alone — only the live view's stats
  # chart is refreshed on every reading.
  @impl true
  def handle_info({:dtu_seen, _device_id}, socket) do
    user = socket.assigns.current_scope.user
    {:noreply, assign(socket, :devices, Devices.list_devices(user))}
  end

  # Timezone push from the `.ChartTooltip` colocated JS hook (or a test
  # via `Phoenix.PubSub.broadcast/2`). Invalid payloads are silently
  # ignored so a malformed client payload can't crash the dashboard.
  @impl true
  def handle_info({:set_timezone, offset_seconds}, socket)
      when is_integer(offset_seconds) do
    {:noreply,
     socket
     |> assign(:user_tz_offset_seconds, offset_seconds)
     |> assign_dashboard_data(
       socket.assigns.current_scope.user,
       socket.assigns.selected_dtu_id,
       socket.assigns.time_range,
       socket.assigns.selected_period
     )}
  end

  def handle_info({:set_timezone, _other}, socket), do: {:noreply, socket}

  # Catch-all for other messages
  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Helper to construct SVG line chart coordinates and range.
  # `local_date` is the user-facing date in the browser's timezone
  # (already converted from `selected_period` or `local_today/1`).
  # `tz_offset_seconds` shifts bucket times and labels so they read in
  # local time.
  defp assign_line_chart_data(socket, user, local_date, tz_offset_seconds, dtu_id) do
    {utc_start, utc_end} = Devices.local_day_utc_range(local_date, tz_offset_seconds)
    all_chart_points = Devices.list_day_chart_data(user, utc_start, utc_end, dtu_id)

    # The dashboard exposes one line per *inverter* (its AC aggregate,
    # mppt_index = 0). Per-MPPT DC rows are intentionally collapsed so
    # the chart stays readable when a fleet mixes single- and multi-
    # MPPT inverters; users can drill into a specific DTU on the
    # /devices page if they need MPPT-level detail.
    chart_points = Enum.filter(all_chart_points, fn pt -> pt.series |> elem(2) == 0 end)

    max_power =
      chart_points
      |> Enum.map(& &1.power)
      |> Enum.max(fn -> 100.0 end)
      |> max(100.0)
      |> Float.ceil()

    # Fleet Total is the sum of every series at each bucket, which is
    # larger than any individual series power when more than one
    # inverter/MPPT is producing. The y-axis must cover the Total line
    # peak or it renders off-screen.
    total_max_power =
      chart_points
      |> Enum.group_by(& &1.time)
      |> Enum.map(fn {_time, pts} -> Enum.sum(Enum.map(pts, & &1.power)) end)
      |> Enum.max(fn -> 0.0 end)

    # Scale max power to next multiple of 100, taking the larger of
    # the per-series peak and the Total peak so the headline curve
    # stays inside the chart area.
    y_max =
      [max_power, total_max_power]
      |> Enum.max()
      |> Float.ceil()
      |> Kernel./(100)
      |> Float.ceil()
      |> Kernel.*(100)
      |> max(100.0)

    # Chart dimensions: width 800, height 250 (with 20px top padding).
    # X range is dynamic: zoomed to data when present, full day (00:00–
    # 24:00) when empty. See `chart_time_range/2` below.
    {x_min_seconds, x_max_seconds} = chart_time_range(chart_points, tz_offset_seconds)
    x_span = x_max_seconds - x_min_seconds

    # Group points by series (one line per (inverter, MPPT) pair) and
    # translate each point into SVG coordinates within the dynamic X range.
    # We also capture the LOCAL bucket time (seconds-of-day, after applying
    # the user's timezone offset) per point so the ChartTooltip hook can
    # look up values by cursor time in the user's frame of reference
    # without round-tripping through the UTC values.
    series_points =
      chart_points
      |> Enum.group_by(& &1.series)
      |> Enum.map(fn {series, pts} ->
        coords =
          pts
          |> Enum.map(fn %{time: time, power: power} ->
            utc_seconds = time.hour * 3600 + time.minute * 60 + time.second
            local_seconds = utc_seconds + tz_offset_seconds
            local_seconds = rem(local_seconds + 86_400 * 4, 86_400)
            x = (local_seconds - x_min_seconds) / x_span * 800.0
            y = 250.0 - power / y_max * 230.0
            {Float.round(x, 1), Float.round(y, 1), local_seconds}
          end)
          |> Enum.sort_by(&elem(&1, 0))

        {series, coords}
      end)
      |> Enum.sort_by(fn {{dtu_id, serial, mppt_index, _name}, _pts} ->
        {dtu_id, serial, mppt_index}
      end)

    # Build path data per series, plus an area fill for the first
    # series (the AC aggregate, mppt_index = 0) for the existing
    # "tinted under the curve" look.
    series_paths =
      Enum.map(series_points, fn {series, coords} ->
        path =
          case coords do
            [] ->
              ""

            [{first_x, first_y, _first_t} | rest] ->
              "M #{first_x} #{first_y} " <>
                (rest |> Enum.map_join(" ", fn {x, y, _t} -> "L #{x} #{y}" end))
          end

        {series, path}
      end)
      |> Map.new()

    # Color palette per series. Each series is now one line per
    # inverter (mppt_index = 0 only), so we just need the per-inverter
    # base hue. The shade is fixed at 400 because there's no second
    # MPPT line to differentiate against anymore — using a single
    # bright shade keeps each inverter's line clearly visible against
    # the tinted area fill.
    inverter_color = inverte_order_to_color(series_points)

    series_palette =
      Enum.map(series_points, fn {series, _pts} ->
        dtu_id = elem(series, 0)
        serial = elem(series, 1)
        base = Map.get(inverter_color, {dtu_id, serial})
        {series, {base, "400"}}
      end)
      |> Map.new()

    # Friendly names for the legend. Prefer the user-set `inverter_name`,
    # fall back to the serial. Per-MPPT rows are collapsed into the
    # inverter's AC line (see the `Enum.filter` further up), so the
    # legend labels are simply the inverter's friendly name — no
    # `MPPT N` suffix needed.
    series_legend =
      Enum.map(series_points, fn {series, _pts} ->
        {dtu_id, serial, mppt_index, name} = series
        friendly = name || serial
        {{dtu_id, serial, mppt_index, name}, friendly}
      end)
      |> Map.new()

    # No tinted area under the curves. The decorative fill that used to
    # sit under the first inverter's line was misleading: in single-
    # inverter fleets the only inverter's line *is* the total, so users
    # reasonably read the tinted region as "Total" — but it wasn't.
    # The chart's lines, legend, and tooltip already convey all the
    # information; the fill was just visual noise.

    x_labels = chart_x_labels(x_min_seconds, x_max_seconds)

    # Time series per series for the tooltip hook. Encoded as JSON
    # strings (data-points="...") so the JS hook can look up the value
    # at the cursor's time without parsing the SVG path's `d=` string.
    # Each series entry is a list of {time, power} pairs in seconds /
    # watts, sorted by time. We use the bucket time captured alongside
    # each point in `series_points` (third tuple element) so we don't
    # lose precision reverse-mapping through the rounded X coord.
    series_points_data =
      Enum.map(series_points, fn {series, coords} ->
        {series,
         Enum.map(coords, fn {_x, y, seconds} ->
           %{time: seconds, power: power_at_from_coord(y, y_max)}
         end)}
      end)
      |> Map.new()

    # Fleet-wide "Total" line: sum of every series' power at each
    # bucket. This is the headline curve a customer wants to see — it
    # answers "how much am I producing right now?" without having to
    # mentally add up per-inverter lines. Computed server-side from
    # `chart_points` (one entry per inverter per bucket) so the total
    # is exact, not interpolated.
    #
    # The Total is suppressed when there's only one inverter in scope
    # — in that case the per-inverter line *is* the total and adding
    # it again would be a redundant curve.
    distinct_inverters =
      chart_points
      |> Enum.map(fn pt -> {elem(pt.series, 0), elem(pt.series, 1)} end)
      |> Enum.uniq()

    show_total? = length(distinct_inverters) > 1

    {total_path, total_coords} =
      if show_total? do
        chart_points
        |> Enum.group_by(& &1.time)
        |> Enum.map(fn {time, pts} ->
          utc_seconds = time.hour * 3600 + time.minute * 60 + time.second
          local_seconds = rem(utc_seconds + tz_offset_seconds + 86_400 * 4, 86_400)
          x = (local_seconds - x_min_seconds) / x_span * 800.0
          total_power = pts |> Enum.map(& &1.power) |> Enum.sum()
          y = 250.0 - total_power / y_max * 230.0
          {Float.round(x, 1), Float.round(y, 1), local_seconds, total_power}
        end)
        |> Enum.sort_by(&elem(&1, 0))
        |> then(fn pts ->
          path =
            case pts do
              [] ->
                ""

              [{fx, fy, _, _} | rest] ->
                "M #{fx} #{fy} " <>
                  Enum.map_join(rest, " ", fn {x, y, _, _} -> "L #{x} #{y}" end)
            end

          coords = Enum.map(pts, fn {x, y, t, _} -> {x, y, t} end)
          {path, coords}
        end)
      else
        {"", []}
      end

    # Total-time -> power data for the tooltip, in the same shape as
    # `series_points_data` so the ChartTooltip hook can iterate over
    # both uniformly.
    total_points_data =
      Enum.map(total_coords, fn {_x, y, seconds} ->
        %{time: seconds, power: round((250.0 - y) / 230.0 * y_max)}
      end)

    socket
    |> assign(:chart_points, chart_points)
    |> assign(:y_max, y_max)
    |> assign(:series_paths, series_paths)
    |> assign(:series_palette, series_palette)
    |> assign(:series_legend, series_legend)
    |> assign(:path_data, Map.get(series_paths, hd_or_first_key(series_paths), ""))
    |> assign(:x_labels, x_labels)
    |> assign(:x_min_seconds, x_min_seconds)
    |> assign(:x_max_seconds, x_max_seconds)
    |> assign(:series_points_data, series_points_data)
    |> assign(:total_path, total_path)
    |> assign(:total_points_data, total_points_data)
    |> assign(:total_palette, {"emerald", "900"})
  end

  # Reverse the data-point Y coord back to watts so the tooltip shows
  # real values, not SVG units. (The X coord is no longer round-tripped
  # through float math — `series_points_data` carries the bucket time
  # directly so we don't lose seconds of precision.)
  defp power_at_from_coord(y, y_max), do: round((250.0 - y) / 230.0 * y_max)

  # Compute the chart's X-axis time range (in LOCAL seconds-of-day,
  # so the labels read in the user's timezone).
  #
  #   * Empty `chart_points`         → full day (00:00–24:00)
  #   * Non-empty `chart_points`      → from the floor-of-the-hour of the
  #                                     first data point to the next full
  #                                     hour after the last data point
  #
  # Bucket boundaries are multiples of 5 minutes (UTC). Their hour-of-day
  # in the user's zone is `rem(bucket_utc_hour + tz_offset_hours, 24)`,
  # so we shift first/last before computing the range. `end_hour`
  # adds a 1-hour buffer so the line doesn't end at the chart's right
  # edge.
  @spec chart_time_range([%{required(:time) => DateTime.t()}], integer()) ::
          {non_neg_integer(), pos_integer()}
  defp chart_time_range([], _tz_offset_seconds), do: {0, 86_400}

  defp chart_time_range(points, tz_offset_seconds) do
    first_local = shift_local(Enum.min_by(points, & &1.time).time, tz_offset_seconds)
    last_local = shift_local(Enum.max_by(points, & &1.time).time, tz_offset_seconds)

    start_hour = first_local.hour
    end_hour = min(last_local.hour + 1, 24)

    # Ensure at least a 1-hour window so single-bucket data (e.g. one
    # point at 12:00) still draws as a 1-hour segment instead of a
    # single-pixel spike.
    end_hour = max(end_hour, min(start_hour + 1, 24))

    {start_hour * 3600, end_hour * 3600}
  end

  # Convert a UTC DateTime to a (possibly-wrapped) LOCAL seconds-of-day.
  # Used by the chart's range computation, the X-axis label generator,
  # and the ChartTooltip data embedding. Returns a `%Time{}` struct
  # because we only need hour/minute/second — and we want the wrap
  # to happen naturally (23 + 2h offset in CET = 01 next day).
  @spec shift_local(DateTime.t(), integer()) :: %Time{}
  defp shift_local(%DateTime{} = dt, tz_offset_seconds) do
    shifted = DateTime.add(dt, tz_offset_seconds, :second)
    # DateTime.add can return a datetime on the previous or next day;
    # we only care about the time-of-day component.
    %Time{
      hour: shifted.hour,
      minute: shifted.minute,
      second: shifted.second,
      microsecond: {0, 0}
    }
  end

  # Generate X-axis label positions for the chart. Returns a list of
  # `{x, label}` tuples where `x` is the SVG x-coordinate (0–800) and
  # `label` is the LOCAL time-of-day string (e.g. "07:00"). Labels
  # always include the chart's start and end hours; intermediate hours
  # are spaced at 1, 2, 3, or 6 hours depending on the total span so
  # the label density stays roughly constant regardless of zoom.
  @spec chart_x_labels(non_neg_integer(), pos_integer()) :: [{float(), String.t()}]
  defp chart_x_labels(x_min_seconds, x_max_seconds) do
    start_hour = div(x_min_seconds, 3600)
    end_hour = div(x_max_seconds, 3600)
    total_hours = end_hour - start_hour

    step =
      cond do
        total_hours <= 2 -> 1
        total_hours <= 6 -> 2
        total_hours <= 12 -> 3
        true -> 6
      end

    span = x_max_seconds - x_min_seconds

    for hour <- start_hour..end_hour,
        hour == start_hour or hour == end_hour or rem(hour - start_hour, step) == 0 do
      seconds = hour * 3600
      x = (seconds - x_min_seconds) / span * 800.0
      {Float.round(x, 1), format_hour_label(hour)}
    end
  end

  # Format a local hour-of-day (0–24) as "HH:00". The ChartTooltip
  # also uses this for its tooltip body.
  defp format_hour_label(0), do: "00:00"
  defp format_hour_label(24), do: "24:00"
  defp format_hour_label(hour) when hour < 10, do: "0#{hour}:00"
  defp format_hour_label(hour), do: "#{hour}:00"

  # Today's date in the user's local timezone. `Date.utc_today()`
  # would give us "today in London"; for a Berlin user looking at the
  # dashboard at 23:30 UTC (= 00:30 Berlin next day) we want the
  # Berlin date so the chart shows the day they're actually in.
  @spec local_today(integer()) :: Date.t()
  defp local_today(tz_offset_seconds) do
    # Use the database clock so "today in the user's timezone" matches
    # the day the readings table's `inserted_at` was bucketed under.
    # See `DtuApp.Time`.
    DtuApp.Time.utc_now()
    |> DateTime.add(tz_offset_seconds, :second)
    |> DateTime.to_date()
  end

  # Convert a local date (as the user sees it on the dashboard) to the
  # inclusive UTC day range `[start_utc, end_utc]` that the DB query
  # needs to fetch readings for that local day.
  @spec utc_day_range_for_local_date(Date.t(), integer()) ::
          {DateTime.t(), DateTime.t()}
  def utc_day_range_for_local_date(%Date{} = local_date, tz_offset_seconds) do
    {:ok, start_local} = DateTime.new(local_date, ~T[00:00:00])
    {:ok, end_local} = DateTime.new(local_date, ~T[23:59:59])

    {DateTime.add(start_local, -tz_offset_seconds, :second),
     DateTime.add(end_local, -tz_offset_seconds, :second)}
  end

  # Empty `series_paths` map is OK; we just need a default for the
  # `path_data` assign so the template always has a string.
  defp hd_or_first_key(map) when map_size(map) == 0, do: nil
  defp hd_or_first_key(map), do: map |> Enum.at(0) |> elem(0)

  # Deterministic palette: assign each (dtu_id, inverter_serial) pair a
  # base hue from a fixed set, in the order they first appear. Stable
  # across requests so the chart doesn't flicker.
  @palette ~w(emerald amber sky violet rose fuchsia cyan lime orange teal)

  defp inverte_order_to_color(series_points) do
    series_points
    |> Enum.map(fn {series, _} -> {elem(series, 0), elem(series, 1)} end)
    |> Enum.uniq()
    |> Enum.with_index()
    |> Map.new(fn {{dtu_id, serial}, idx} ->
      {{dtu_id, serial}, Enum.at(@palette, rem(idx, length(@palette)))}
    end)
  end

  # Map a (base, shade) Tailwind palette pair to a hex color string.
  # The ChartTooltip JS hook renders the tooltip's color swatches as
  # inline `style="background-color: …"` (we can't reach CSS custom
  # properties or theme tokens from a colocated hook without shipping
  # the Tailwind output as JSON), so we resolve to a concrete hex.
  # Values are the Tailwind v3 default emerald/amber/sky/violet/rose/
  # fuchsia/cyan/lime/orange/teal palette at the requested shade.
  @tailwind_colors %{
    {"emerald", "400"} => "#34d399",
    {"emerald", "600"} => "#059669",
    {"emerald", "800"} => "#065f46",
    {"emerald", "900"} => "#064e3b",
    {"amber", "400"} => "#fbbf24",
    {"amber", "600"} => "#d97706",
    {"amber", "800"} => "#92400e",
    {"amber", "900"} => "#78350f",
    {"sky", "400"} => "#38bdf8",
    {"sky", "600"} => "#0284c7",
    {"sky", "800"} => "#075985",
    {"sky", "900"} => "#0c4a6e",
    {"violet", "400"} => "#a78bfa",
    {"violet", "600"} => "#7c3aed",
    {"violet", "800"} => "#5b21b6",
    {"violet", "900"} => "#4c1d95",
    {"rose", "400"} => "#fb7185",
    {"rose", "600"} => "#e11d48",
    {"rose", "800"} => "#9f1239",
    {"rose", "900"} => "#881337",
    {"fuchsia", "400"} => "#e879f9",
    {"fuchsia", "600"} => "#c026d3",
    {"fuchsia", "800"} => "#86198f",
    {"fuchsia", "900"} => "#701a75",
    {"cyan", "400"} => "#22d3ee",
    {"cyan", "600"} => "#0891b2",
    {"cyan", "800"} => "#155e75",
    {"cyan", "900"} => "#164e63",
    {"lime", "400"} => "#a3e635",
    {"lime", "600"} => "#65a30d",
    {"lime", "800"} => "#3f6212",
    {"lime", "900"} => "#365314",
    {"orange", "400"} => "#fb923c",
    {"orange", "600"} => "#ea580c",
    {"orange", "800"} => "#9a3412",
    {"orange", "900"} => "#7c2d12",
    {"teal", "400"} => "#2dd4bf",
    {"teal", "600"} => "#0d9488",
    {"teal", "800"} => "#115e59",
    {"teal", "900"} => "#134e4a"
  }
  defp tooltip_to_hex(base, shade), do: Map.fetch!(@tailwind_colors, {base, shade})

  # MPPT-specific shades were used when the chart plotted per-MPPT
  # lines (`mppt_index = 0` was the AC aggregate, 1+ were per-string
  # DC). Now that the dashboard exposes one line per inverter (the
  # `Enum.filter` in `assign_line_chart_data/5` collapses all MPPTs
  # into the inverter's AC row), there's nothing to shade-vary — see
  # `series_palette` for the fixed `"400"` shade.

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
          value: Float.round(item.value / 1.0, 1)
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

  # Apply `assign_dashboard_data/5` only on the live view — historical
  # views (day / week / month / year) are static and don't refresh on
  # every reading. Kept as a helper so the reading handler above can
  # stay readable.
  defp maybe_reassign_dashboard_data(socket, user, selected_id) do
    if socket.assigns.live do
      assign_dashboard_data(socket, user, selected_id, socket.assigns.time_range, nil)
    else
      socket
    end
  end

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

  # Human-readable "X ago" label for a past `DateTime`. Falls back to an
  # absolute YYYY-MM-DD HH:MM string for points in time more than a week
  # back, since minute/hour counts get unwieldy beyond that. Clamps future
  # timestamps to "just now" rather than rendering negative values.
  defp relative_time_label(%DateTime{} = dt, now \\ DtuApp.Time.utc_now()) do
    diff = DateTime.diff(now, dt, :second) |> max(0)

    cond do
      diff < 60 ->
        gettext("just now")

      diff < 3_600 ->
        gettext("%{n} minutes ago", n: div(diff, 60))

      diff < 86_400 ->
        gettext("%{n} hours ago", n: div(diff, 3_600))

      diff < 604_800 ->
        gettext("%{n} days ago", n: div(diff, 86_400))

      true ->
        Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
    end
  end

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
    tz_offset_seconds = socket.assigns.user_tz_offset_seconds

    case time_range do
      "today" ->
        stats = Devices.get_daily_stats(user, dtu_id)

        socket
        |> assign(:stats, stats)
        |> assign(:chart_type, :line)
        |> assign_line_chart_data(user, local_today(tz_offset_seconds), tz_offset_seconds, dtu_id)

      "day" ->
        date =
          case selected_period do
            %Date{} = d ->
              d

            _ ->
              selectable = socket.assigns.selectable_dates
              List.first(selectable) || local_today(tz_offset_seconds)
          end

        # Convert the user-facing local date to the UTC range that
        # contains the readings for that local day.
        {utc_start, utc_end} = Devices.local_day_utc_range(date, tz_offset_seconds)

        points = Devices.list_day_chart_data(user, utc_start, utc_end, dtu_id)
        yields = Devices.list_range_yield_data(user, utc_start, utc_end, dtu_id)
        stats = Devices.compute_day_period_stats(yields, points)

        socket
        |> assign(:selected_period, date)
        |> assign(:stats, stats)
        |> assign(:chart_type, :line)
        |> assign_line_chart_data(user, date, tz_offset_seconds, dtu_id)

      "week" ->
        monday =
          case selected_period do
            %Date{} = d ->
              d

            _ ->
              selectable = socket.assigns.selectable_dates
              latest_date = List.first(selectable) || local_today(tz_offset_seconds)
              Date.add(latest_date, -(Date.day_of_week(latest_date) - 1))
          end

        sunday = Date.add(monday, 6)
        {monday_utc, _} = Devices.local_day_utc_range(monday, tz_offset_seconds)
        {sunday_utc, _} = Devices.local_day_utc_range(sunday, tz_offset_seconds)
        yields = Devices.list_range_yield_data(user, monday_utc, sunday_utc, dtu_id)
        stats = Devices.compute_range_period_stats(yields, 7)

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
              latest_date = List.first(selectable) || local_today(tz_offset_seconds)
              Date.new!(latest_date.year, latest_date.month, 1)
          end

        last_day = Date.end_of_month(first_day)
        {first_utc, _} = Devices.local_day_utc_range(first_day, tz_offset_seconds)
        {last_utc, _} = Devices.local_day_utc_range(last_day, tz_offset_seconds)
        yields = Devices.list_range_yield_data(user, first_utc, last_utc, dtu_id)
        total_days = Date.diff(last_day, first_day) + 1
        stats = Devices.compute_range_period_stats(yields, total_days)

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
              latest_date = List.first(selectable) || local_today(tz_offset_seconds)
              latest_date.year
          end

        start_date = Date.new!(year, 1, 1)
        end_date = Date.new!(year, 12, 31)
        {start_utc, _} = Devices.local_day_utc_range(start_date, tz_offset_seconds)
        {end_utc, _} = Devices.local_day_utc_range(end_date, tz_offset_seconds)
        yields = Devices.list_range_yield_data(user, start_utc, end_utc, dtu_id)
        stats = Devices.compute_range_period_stats(yields, 12)

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
          <%= if @devices == [] do %>
            <%!-- Promoted in the burger menu once a device exists. The
                 dashboard's main "Manage Devices" CTA only renders in
                 the onboarding state, so it doesn't compete with the
                 device cards below or the burger menu's link. --%>
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
          <% end %>
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
            <!-- "Today" button + historical stepper share the same row so
                 the toolbar reads as one toolbar instead of two stacked
                 controls. The wrapping <div> uses `flex flex-wrap
                 items-center gap-4` so the two clusters stay side by
                 side on desktop and wrap below each other on narrow
                 viewports. -->
            <div class="flex flex-wrap items-center gap-4">
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
                <div
                  class="relative w-full overflow-hidden"
                  id="solar-chart-container"
                  phx-hook=".ChartTooltip"
                >
                  <!-- Chart SVG -->
                  <svg
                    viewBox="0 0 800 280"
                    class="w-full h-auto overflow-visible"
                    id="solar-chart-svg"
                    data-x-min-seconds={@x_min_seconds}
                    data-x-max-seconds={@x_max_seconds}
                  >
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

                    <!-- X-Axis Labels (Time slots). Dynamically positioned to
                         fit the chart's X-axis range — full day (00:00–
                         24:00) when no data, or zoomed to data when
                         present (see `chart_time_range/1`). -->
                    <%= for {{x, label}, edge} <- Enum.with_index(@x_labels) do %>
                      <% anchor =
                        cond do
                          edge == 0 -> "start"
                          edge == length(@x_labels) - 1 -> "end"
                          true -> "middle"
                        end %>
                      <text
                        x={x}
                        y="270"
                        class="text-[10px] font-medium fill-zinc-400"
                        text-anchor={anchor}
                      >
                        {label}
                      </text>
                    <% end %>

                    <!-- Vertical guide line drawn at the cursor's X
                         position. Hidden by default; the ChartTooltip
                         hook shows it on hover/touch. -->
                    <line
                      x1="0"
                      y1="20"
                      x2="0"
                      y2="250"
                      stroke="#a1a1aa"
                      class="dark:stroke-zinc-500"
                      stroke-width="1"
                      stroke-dasharray="2,2"
                      pointer-events="none"
                      style="display:none"
                      id="chart-guide-line"
                    />

                    <!-- Floating tooltip overlay rendered by the
                         ChartTooltip hook. Hidden by default; positioned
                         via the foreignObject's x/y attributes as the
                         cursor moves. `pointer-events: none` so it
                         never blocks hover on the chart. -->
                    <foreignObject
                      x="0"
                      y="0"
                      width="200"
                      height="160"
                      pointer-events="none"
                      style="display:none;overflow:visible"
                      id="chart-tooltip"
                    >
                      <div
                        xmlns="http://www.w3.org/1999/xhtml"
                        class="rounded-md border border-zinc-200 bg-white/95 px-2.5 py-1.5 shadow-md backdrop-blur dark:border-zinc-700 dark:bg-zinc-900/95"
                      >
                        <div
                          id="chart-tooltip-body"
                          class="font-mono text-xs text-zinc-700 dark:text-zinc-200"
                        >
                        </div>
                      </div>
                    </foreignObject>

                    <!-- One SVG path per inverter. Each path carries its
                         (time, power) data points as a JSON data attribute
                         so the ChartTooltip hook can look up the cursor-
                         time value without parsing the SVG `d=` string.
                         The Total line is rendered last so it sits on top
                         of every per-inverter path — it's the headline
                         curve. -->
                    <%= for {series, path} <- @series_paths do %>
                      <% {base, shade} = Map.get(@series_palette, series) %>
                      <% stroke_hex = tooltip_to_hex(base, shade) %>
                      <% series_json =
                        Jason.encode!(%{
                          dtu_id: elem(series, 0),
                          serial: elem(series, 1),
                          mppt_index: elem(series, 2),
                          name: elem(series, 3)
                        }) %>
                      <% points_json = Jason.encode!(Map.get(@series_points_data, series, [])) %>
                      <% legend_key =
                        "series:#{elem(series, 0)}:#{elem(series, 1)}:#{elem(series, 2)}" %>
                      <path
                        d={path}
                        fill="none"
                        stroke={stroke_hex}
                        stroke-width="2.5"
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        data-series={series_json}
                        data-points={points_json}
                        data-stroke={stroke_hex}
                        data-legend-key={legend_key}
                      />
                    <% end %>
                    <%= if @total_path != "" do %>
                      <% total_json =
                        Jason.encode!(%{
                          is_total: true,
                          name: gettext("Total"),
                          serial: "",
                          mppt_index: -1
                        }) %>
                      <% total_points_json = Jason.encode!(@total_points_data) %>
                      <% {tbase, tshade} = @total_palette %>
                      <% total_stroke_hex = tooltip_to_hex(tbase, tshade) %>
                      <path
                        d={@total_path}
                        fill="none"
                        stroke={total_stroke_hex}
                        stroke-width="3"
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        data-series={total_json}
                        data-points={total_points_json}
                        data-stroke={total_stroke_hex}
                        data-legend-key="total"
                      />
                    <% end %>
                  </svg>

                  <%!-- Legend: Total line first (the headline), then one entry
                       per (inverter, MPPT) series in the same order as the
                       paths above. Each entry is a real <button> so it's
                       keyboard- and screen-reader-accessible; the
                       ChartTooltip hook toggles the matching path's hidden
                       class on click. --%>
                  <%= if map_size(@series_legend) > 0 or @total_path != "" do %>
                    <div
                      class="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1.5 text-xs"
                      id="chart-legend"
                    >
                      <%= if @total_path != "" do %>
                        <% {tbase, tshade} = @total_palette %>
                        <button
                          type="button"
                          class="legend-toggle inline-flex items-center gap-1.5 cursor-pointer rounded px-1 py-0.5 hover:bg-zinc-100 dark:hover:bg-zinc-700/50"
                          data-legend-key="total"
                          aria-pressed="true"
                        >
                          <span
                            class={"legend-swatch inline-block h-2.5 w-2.5 rounded-sm bg-#{tbase}-#{tshade}"}
                            aria-hidden="true"
                          />
                          <span class="text-zinc-700 dark:text-zinc-300">
                            {gettext("Total")}
                          </span>
                        </button>
                      <% end %>
                      <%= for {series, label} <- @series_legend do %>
                        <% {base, shade} = Map.get(@series_palette, series) %>
                        <% legend_key =
                          "series:#{elem(series, 0)}:#{elem(series, 1)}:#{elem(series, 2)}" %>
                        <button
                          type="button"
                          class="legend-toggle inline-flex items-center gap-1.5 cursor-pointer rounded px-1 py-0.5 hover:bg-zinc-100 dark:hover:bg-zinc-700/50"
                          data-legend-key={legend_key}
                          aria-pressed="true"
                        >
                          <span
                            class={"legend-swatch inline-block h-2.5 w-2.5 rounded-sm bg-#{base}-#{shade}"}
                            aria-hidden="true"
                          />
                          <span class="text-zinc-700 dark:text-zinc-300">{label}</span>
                        </button>
                      <% end %>
                    </div>
                  <% end %>
                </div>

                <%!-- Colocated JS hook: shows a vertical guide line + a
                     tooltip with the time and per-series power at the
                     cursor's position. The tooltip body is rendered
                     directly into the DOM (no LiveView round-trip) so
                     it stays smooth on hover. Series data is read
                     from the SVG's `data-series` / `data-points`
                     attributes; the time range from `data-x-min-seconds`
                     / `data-x-max-seconds`. --%>
                <script :type={Phoenix.LiveView.ColocatedHook} name=".ChartTooltip">
                  export default {
                    mounted() {
                      // The chart X-axis labels and the bucket times
                      // embedded in `data-points` are pre-shifted to
                      // LOCAL time on the server (`assign_line_chart_data/5`
                      // applies `tz_offset_seconds`). The chart range, the
                      // tooltip body and the cursor math all use those
                      // local values directly — no client-side timezone
                      // conversion is needed here.
                      this.svg = this.el.querySelector("#solar-chart-svg");
                      this.guide = this.svg.querySelector("#chart-guide-line");
                      this.tooltip = this.svg.querySelector("#chart-tooltip");
                      this.body = this.svg.querySelector("#chart-tooltip-body");
                      this.legend = this.el.querySelector("#chart-legend");

                      this.xMin = parseFloat(this.svg.dataset.xMinSeconds);
                      this.xMax = parseFloat(this.svg.dataset.xMaxSeconds);

                      // Track which series the user has hidden via the
                      // legend so the tooltip can skip them on the next
                      // hover. Keys survive LiveView re-renders because
                      // they're derived from the server template, not
                      // from DOM node identity.
                      this.hiddenKeys = new Set();

                      this.series = Array.from(
                        this.svg.querySelectorAll("path[data-series][data-points]")
                      ).map((p) => ({
                        meta: JSON.parse(p.dataset.series),
                        points: JSON.parse(p.dataset.points),
                        color: p.dataset.stroke,
                        key: p.dataset.legendKey || null
                      }));

                      // Push the browser's UTC offset (in seconds,
                      // positive east of UTC) so the LiveView can
                      // re-render labels / chart range with the right
                      // timezone. The very first render uses the default
                      // offset of 0 (UTC) until this fires — see the
                      // `set_timezone` handler in DashboardLive.
                      const offsetMinutes = new Date().getTimezoneOffset();
                      const offsetSeconds = -offsetMinutes * 60;
                      this.pushEvent("set_timezone", {
                        offset_seconds: String(offsetSeconds)
                      });

                      // Legend click -> toggle the matching path's
                      // `display:none`. No LiveView round-trip needed;
                      // the next hover rebuilds the tooltip rows from
                      // `this.series` and skips anything in
                      // `this.hiddenKeys`.
                      this.legendClick = (e) => {
                        const btn = e.target.closest("button.legend-toggle");
                        if (!btn) return;
                        const key = btn.dataset.legendKey;
                        if (!key) return;
                        // Re-query the SVG path on every click rather than
                        // caching it in `pathsByKey`. LiveView re-renders
                        // swap the path elements out for fresh ones, so a
                        // cached reference would point at a detached node
                        // that no longer affects what's on screen.
                        const path = this.svg.querySelector(
                          `path[data-legend-key="${CSS.escape(key)}"]`
                        );
                        if (!path) return;
                        const nowHidden = !this.hiddenKeys.has(key);
                        if (nowHidden) {
                          this.hiddenKeys.add(key);
                          path.style.display = "none";
                          btn.setAttribute("aria-pressed", "false");
                          btn.classList.add("opacity-40");
                        } else {
                          this.hiddenKeys.delete(key);
                          path.style.display = "";
                          btn.setAttribute("aria-pressed", "true");
                          btn.classList.remove("opacity-40");
                        }
                      };
                      // Listen on the hook container (`#solar-chart-container`)
                      // rather than `#chart-legend` so the handler survives
                      // LiveView re-renders that swap the legend strip out
                      // for a fresh one — events from the new buttons still
                      // bubble up to the container, and we re-query the
                      // matching path on every click so we still operate on
                      // the live DOM node.
                      this.el.addEventListener("click", this.legendClick);

                      this.handlers = {
                        mousemove: (e) => this.move(e),
                        mouseleave: () => this.hide(),
                        touchstart: (e) => this.move(e),
                        touchmove: (e) => this.move(e),
                        touchend: () => this.hide(),
                        touchcancel: () => this.hide(),
                        resize: () => this.refRect()
                      };

                      for (const [event, handler] of Object.entries(this.handlers)) {
                        if (event === "resize") {
                          window.addEventListener(event, handler);
                        } else {
                          this.svg.addEventListener(event, handler, { passive: true });
                        }
                      }
                    },

                    destroyed() {
                      for (const [event, handler] of Object.entries(this.handlers)) {
                        if (event === "resize") {
                          window.removeEventListener(event, handler);
                        } else {
                          this.svg.removeEventListener(event, handler);
                        }
                      }
                      if (this.legendClick) {
                        this.el.removeEventListener("click", this.legendClick);
                      }
                    },

                    refRect() {
                      this.rect = this.svg.getBoundingClientRect();
                    },

                    move(e) {
                      e.preventDefault();
                      const touch = e.touches && e.touches[0];
                      const clientX = touch ? touch.clientX : e.clientX;
                      this.refRect();
                      const x = clientX - this.rect.left;
                      if (x < 0 || x > this.rect.width) {
                        this.hide();
                        return;
                      }

                      const span = this.xMax - this.xMin;
                      const time = span > 0
                        ? this.xMin + (x / this.rect.width) * span
                        : this.xMin;

                      this.guide.setAttribute("x1", String(x));
                      this.guide.setAttribute("x2", String(x));
                      this.guide.style.display = "";

                      // Drop rows whose legend entry was toggled off
                      // before computing nearest-bucket lookup.
                      const rows = this.series
                        .filter((s) => s.points.length > 0)
                        .filter((s) => !this.hiddenKeys.has(s.key))
                        .map((s) => {
                          const nearest = this.nearest(s.points, time);
                          return { ...s, value: nearest ? nearest.power : null };
                        })
                        // Total line always sits at the top of the
                        // tooltip so the headline value is the first
                        // thing the reader sees; otherwise preserve
                        // server render order.
                        .sort((a, b) => {
                          if (a.meta.is_total) return -1;
                          if (b.meta.is_total) return 1;
                          return 0;
                        });

                      this.body.innerHTML = this.renderRows(time, rows);

                      // Position the tooltip just to the right of the
                      // cursor (4 px gap so it hugs the guide line
                      // without overlapping the data point); flip to
                      // the left when near the right edge.
                      const tooltipWidth = 200;
                      const tooltipX =
                        x > this.rect.width - tooltipWidth - 20
                          ? Math.max(0, x - tooltipWidth - 10)
                          : Math.min(this.rect.width - tooltipWidth, x + 4);
                      this.tooltip.setAttribute("x", String(tooltipX));
                      this.tooltip.style.display = "";
                    },

                    hide() {
                      if (this.guide) this.guide.style.display = "none";
                      if (this.tooltip) this.tooltip.style.display = "none";
                    },

                    nearest(points, time) {
                      // `points` is sorted ascending by time; binary search
                      // for the closest entry to the cursor's time.
                      let lo = 0;
                      let hi = points.length - 1;
                      while (lo < hi) {
                        const mid = (lo + hi) >> 1;
                        if (points[mid].time < time) lo = mid + 1;
                        else hi = mid;
                      }
                      const a = points[lo - 1];
                      const b = points[lo];
                      if (!a) return b;
                      if (!b) return a;
                      return Math.abs(a.time - time) < Math.abs(b.time - time) ? a : b;
                    },

                    seriesLabel(meta) {
                      // Per-MPPT lines were collapsed into the
                      // inverter's AC row on the server (see the
                      // `Enum.filter` in `assign_line_chart_data/5`),
                      // so the tooltip only ever sees the Total
                      // pseudo-series or one row per inverter. No
                      // `MPPT N` / `(AC)` suffix is needed.
                      if (meta.is_total) return meta.name || "Total";
                      return meta.name || meta.serial || "";
                    },

                    renderRows(time, rows) {
                      const hh = String(Math.floor(time / 3600)).padStart(2, "0");
                      const mm = String(Math.floor((time % 3600) / 60)).padStart(2, "0");
                      const header =
                        '<div class="font-semibold mb-1 tabular-nums">' +
                        hh + ":" + mm +
                        "</div>";
                      const body = rows
                        .map((r) => {
                          const val = r.value == null ? "—" : Math.round(r.value) + " W";
                          const swatch =
                            '<span class="inline-block h-2 w-2 rounded-sm mr-1.5" ' +
                            'style="background-color:' + r.color + '"></span>';
                          const rowClass = r.meta.is_total
                            ? "flex items-center justify-between gap-3 font-semibold"
                            : "flex items-center justify-between gap-3";
                          return (
                            '<div class="' + rowClass + '">' +
                            '<span class="truncate">' + swatch + this.escape(this.seriesLabel(r.meta)) + "</span>" +
                            '<span class="tabular-nums font-medium">' + val + "</span>" +
                            "</div>"
                          );
                        })
                        .join("");
                      return header + body;
                    },

                    escape(s) {
                      return String(s).replace(/[&<>"']/g, (c) => ({
                        "&": "&amp;",
                        "<": "&lt;",
                        ">": "&gt;",
                        '"': "&quot;",
                        "'": "&#39;"
                      })[c]);
                    }
                  }
                </script>
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
                  <svg
                    viewBox="0 0 800 250"
                    class="w-full h-auto overflow-visible"
                    id="solar-chart-svg"
                  >
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
                    <text x="5" y="32" class="text-[10px] font-medium fill-zinc-400">
                      {@y_max} kWh
                    </text>
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
                <% online? = DtuApp.Devices.Dtu.online?(device) %>
                <div
                  class="border border-zinc-200 dark:border-zinc-700 rounded-lg p-5 flex flex-col justify-between hover:shadow-md transition"
                  id={"device-card-#{device.id}"}
                >
                  <div>
                    <div class="flex items-center justify-between">
                      <h3 class="text-md font-semibold text-zinc-900 dark:text-white">
                        {device.name}
                      </h3>
                      <span class={[
                        "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                        if(online?,
                          do:
                            "bg-emerald-100 text-emerald-800 dark:bg-emerald-900/30 dark:text-emerald-400",
                          else: "bg-zinc-100 text-zinc-800 dark:bg-zinc-800 dark:text-zinc-400"
                        )
                      ]}>
                        {if online?, do: gettext("online"), else: gettext("offline")}
                      </span>
                    </div>
                    <div class="mt-2 space-y-1 text-sm text-zinc-550 dark:text-zinc-400">
                      <p>
                        <span class="font-medium text-zinc-700 dark:text-zinc-300">{gettext(
                          "Last seen:"
                        )}</span>
                        <span title={
                          case device.last_seen_at do
                            nil -> nil
                            dt -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
                          end
                        }>{case device.last_seen_at do
                          nil -> gettext("never")
                          dt -> relative_time_label(dt)
                        end}</span>
                      </p>
                    </div>
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
