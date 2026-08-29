defmodule DtuAppWeb.DashboardLive.ChartHelpers do
  @moduledoc """
  Pure math helpers for the dashboard's SVG line chart.

  Extracted from `DtuAppWeb.DashboardLive` so the chart code can be
  reasoned about — and tested — in isolation, and so the dashboard
  module stops growing past 4500 lines. Every function here is pure:
  same inputs → same outputs, no DB / PubSub / socket state.

  Helpers that are also rendered into the chart's HTML end up in
  here even though they're a one-liner (e.g. `format_hour_label/1`)
  — co-locating them with the rest of the chart math keeps the
  dashboard's render layer free of magic constants.

  Sister module: `DtuAppWeb.DashboardLive.ChartPalette` owns the
  colour constants + per-series palette assignment.
  """

  # 24 hours in seconds. Used for the local-time-of-day wrap-around in
  # `shift_local/2` and `now_marker_x/4`.
  @seconds_per_day 86_400

  # Chart canvas width in pixels. Matches the `viewBox` width on the
  # dashboard's SVG. Centralised here so a future template change can
  # update it once instead of hunting through every coordinate calc.
  @chart_width 800.0

  # Top padding inside the chart SVG (in pixels). Used for the Y-axis
  # scale (`pixels_per_watt_positive`) so the 0 W line never sits
  # flush against the SVG top edge.
  @chart_top_padding 20.0

  @doc """
  Convert a UTC `DateTime` to a `%Time{}` in the user's local timezone.

  Returns just the time-of-day component (hour/minute/second); the
  date component is discarded because callers want the wrap to happen
  naturally (23 + 2h offset in CET = 01 next day).
  """
  @spec shift_local(DateTime.t(), integer()) :: %Time{}
  def shift_local(%DateTime{} = dt, tz_offset_seconds) do
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

  @doc """
  Compute the chart's X-axis time range (in LOCAL seconds-of-day,
  so the labels read in the user's timezone).

    * Empty `chart_points`         → full day (00:00–24:00)
    * Non-empty `chart_points`      → from the floor-of-the-hour of the
                                      first data point to the next full
                                      hour after the last data point

  Bucket boundaries are multiples of 5 minutes (UTC). Their hour-of-day
  in the user's zone is `rem(bucket_utc_hour + tz_offset_hours, 24)`,
  so we shift first/last before computing the range. `end_hour`
  adds a 1-hour buffer so the line doesn't end at the chart's right
  edge.
  """
  @spec chart_time_range([%{required(:time) => DateTime.t()}], integer()) ::
          {non_neg_integer(), pos_integer()}
  def chart_time_range([], _tz_offset_seconds), do: {0, @seconds_per_day}

  def chart_time_range(points, tz_offset_seconds) do
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

  @doc """
  Generate X-axis label positions for the chart. Returns a list of
  `{x, label}` tuples where `x` is the SVG x-coordinate (0–800) and
  `label` is the LOCAL time-of-day string (e.g. "07:00"). Labels
  always include the chart's start and end hours; intermediate hours
  are spaced at 1 or 2 hours depending on the total span. The step
  is capped at 2 hours regardless of zoom — a 24-hour view shows a
  tick every 2 hours (00:00, 02:00, …, 24:00), a ≤2h zoom shows
  every hour. The previous ladder (1/2/3/6) traded tick density for
  label clutter at long spans; the user's explicit ask was a max
  2-hour interval.
  """
  @spec chart_x_labels(non_neg_integer(), pos_integer()) :: [{float(), String.t()}]
  def chart_x_labels(x_min_seconds, x_max_seconds) do
    start_hour = div(x_min_seconds, 3600)
    end_hour = div(x_max_seconds, 3600)
    total_hours = end_hour - start_hour

    step =
      cond do
        total_hours <= 2 -> 1
        true -> 2
      end

    span = x_max_seconds - x_min_seconds

    for hour <- start_hour..end_hour,
        hour == start_hour or hour == end_hour or rem(hour - start_hour, step) == 0 do
      seconds = hour * 3600
      x = (seconds - x_min_seconds) / span * @chart_width
      {Float.round(x, 1), format_hour_label(hour)}
    end
  end

  @doc """
  Format a local hour-of-day (0–24) as "HH:00". The ChartTooltip
  also uses this for its tooltip body.
  """
  @spec format_hour_label(integer()) :: String.t()
  def format_hour_label(0), do: "00:00"
  def format_hour_label(24), do: "24:00"
  def format_hour_label(hour) when hour < 10, do: "0#{hour}:00"
  def format_hour_label(hour), do: "#{hour}:00"

  @doc """
  Generate the Y-axis gridline + label positions for the chart.
  Returns a list of `{watts, y_pixel}` tuples, ascending. The
  gridline step is 500 W (the user's explicit ask: "at least every
  500 W"). The set always includes the chart's edge ticks (`y_min`
  and `y_max`) plus every 500 W step in between, regardless of
  whether `y_min` is zero or below.

  Examples:
    * y_min = 0,   y_max = 400 → [0, 400]  (400 isn't a 500 step;
      the next aligned tick above 0 is 500, but that's above y_max,
      so it's dropped — only the edges remain). In practice y_max
      is rounded up to a multiple of 100, so this is the common
      "small peak" case.
    * y_min = 0,   y_max = 500 → [0, 500]
    * y_min = 0,   y_max = 2500 → [0, 500, 1000, 1500, 2000, 2500]
    * y_min = -500, y_max = 2500 → [-500, 0, 500, 1000, …, 2500]
    * y_min = -100, y_max = 2500 → [-100, 0, 500, …, 2500] — the
      -100 edge tick is preserved even though it's not on the 500 W
      grid (the bottom edge of the chart must always be labelled).

  The function returns raw watts + pixel positions; the SVG template
  iterates the list and renders each tick with a dashed stroke for
  the `watts == 0` case.
  """
  @spec chart_y_gridlines(float(), float(), float(), float(), float()) :: [{float(), float()}]
  def chart_y_gridlines(y_min, y_max, zero_y, chart_bottom_y, lower_height) do
    step = 500.0

    # First interior tick above y_min aligned to the 500 W grid, then
    # the edge ticks (y_min and y_max) added back in. We add the
    # edges separately so a non-500-multiple edge (y_min = -100, say)
    # still gets a label even though it's off the grid.
    interior_first = Float.ceil(y_min / step) * step

    interior_last = Float.floor(y_max / step) * step

    interior = tick_range(interior_first, interior_last, step)

    # Dedupe edges if they happen to coincide with an interior tick
    # (e.g. y_min = 0, y_max = 500 → interior = [0, 500], edges are
    # the same set — no dups needed).
    edges = Enum.uniq([y_min, y_max, 0.0])

    ticks =
      (interior ++ edges)
      |> Enum.uniq()
      |> Enum.sort()

    pixels_per_watt_positive = (zero_y - @chart_top_padding) / y_max
    pixels_per_watt_negative = (chart_bottom_y - zero_y) / max(lower_height, 1.0)

    for tick <- ticks do
      y_pixel =
        if tick >= 0.0 do
          zero_y - tick * pixels_per_watt_positive
        else
          chart_bottom_y - abs(tick) * pixels_per_watt_negative
        end

      {tick, Float.round(y_pixel, 1)}
    end
  end

  @doc """
  Inclusive ascending range from `first` to `last` in `step`
  increments. Uses arithmetic to avoid Float drift on long runs.
  """
  @spec tick_range(float(), float(), float()) :: [float()]
  def tick_range(first, last, step) do
    if first > last do
      []
    else
      count = trunc((last - first) / step) + 1
      Enum.map(0..(count - 1), &(first + &1 * step))
    end
  end

  @doc """
  Reverse the per-series / total / consumption Y coord back to watts
  against the unified Y-axis. When the chart extends below zero
  (`y_min < 0`), the zero line sits at `zero_y` instead of the
  default y=135, so the reverse mapping must use the upper-half
  scale (`zero_y - 20` pixels over `y_max` W) — the same factor
  the forward mapping uses.
  """
  @spec power_at_from_unified_y(float(), float(), float()) :: integer()
  def power_at_from_unified_y(y, zero_y, y_max),
    do: round((zero_y - y) / max(zero_y - @chart_top_padding, 1.0) * y_max)

  @doc """
  Pixel X position for a "now" indicator line on the 1D live chart.

  Shifts `now` into the user's local time-of-day, then maps the
  resulting seconds-of-day onto the chart's `[x_min_seconds,
  x_max_seconds]` X range using the same `(seconds - x_min) / span *
  width` formula the chart's X labels use.

  Returns `nil` when the current local time falls outside the chart's
  X range — a historical view, or a day with no data near `now` —
  so the template renders no line. The 1D live view always extends
  across the user's full local day (00:00–24:00 when there's no
  data, or zoomed to data when there is), so `nil` is rare in
  practice but the guard keeps the line from drawing at 4am on a
  chart whose X range is 06:00–22:00.

  `now` defaults to `DtuApp.Time.utc_now/0` so production callers
  don't have to thread it through; tests inject a fixed `DateTime`
  to pin the marker position without waiting on wall-clock time.
  """
  @spec now_marker_x(integer(), integer(), integer(), DateTime.t()) :: float() | nil
  def now_marker_x(
        x_min_seconds,
        x_max_seconds,
        tz_offset_seconds,
        now \\ DtuApp.Time.utc_now()
      )

  def now_marker_x(x_min_seconds, x_max_seconds, tz_offset_seconds, %DateTime{} = now) do
    utc_seconds = now.hour * 3600 + now.minute * 60 + now.second

    # Same wrap-around pattern the per-series path code uses: a
    # positive tz_offset_seconds can push past midnight, so we
    # mod into [0, 86_400) before comparing against the X range.
    local_seconds =
      (utc_seconds + tz_offset_seconds + @seconds_per_day * 4)
      |> rem(@seconds_per_day)

    span = x_max_seconds - x_min_seconds

    if local_seconds < x_min_seconds or local_seconds > x_max_seconds do
      nil
    else
      x = (local_seconds - x_min_seconds) / span * @chart_width
      Float.round(x, 1)
    end
  end
end
