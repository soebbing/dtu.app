defmodule DtuAppWeb.DashboardLive.LineChartData do
  @moduledoc """
  Line + bar chart SVG rendering helpers for the dashboard LiveView.

  Three functions, all LiveView-coupled (take a `Phoenix.LiveView.Socket`,
  return one with the chart-data assigns set):

    * `assign_line_chart_data/6` — the production / consumption /
      net-flow line chart (today view + historical day/week/month/
      year views). Computes X/Y ranges, builds per-series SVG paths,
      picks the colour palette, and assigns everything the template
      needs.
    * `assign_bar_chart_data/2` — the daily-yields bar chart used by
      the week / month / year / 7d / 30d / ytd views. Same 800px chart
      width as the line chart, same SVG coordinate system.
    * `hd_or_first_key/1` — private helper used by the line chart to
      surface one arbitrary series' path as the `:path_data` default
      (empty map → `nil`, otherwise first key in insertion order).

  ## Coordinate system

  Both charts share an 800px-wide, 230px-tall SVG. The line chart uses
  `zero_y` (≈135, mid-height) as the Y origin so export/import can
  swing ±115 px below/above zero. The bar chart anchors bars to the
  220 baseline (with a 200 px max bar height). All Y magic numbers
  (`zero_y`, chart bottom, etc.) live as module attributes in
  `ChartHelpers` — see that module for the constants.

  ## Day vs historical ranges

  `assign_line_chart_data/6` handles every range preset (today, day,
  week, month, year). The `:live?` opt flips the yesterday-ghost
  overlay on for the 1D (today) view — historical views skip the
  ghost so the chart stays scoped to the selected period.

  ## Why these are not in ChartHelpers

  `ChartHelpers` houses the pure math (projection, Y-gridline picks,
  X-label formatting). `LineChartData` is the data orchestration:
  it pulls points from `Devices`, builds the paths, picks the
  colour palette, and assigns everything. The split lets
  `ChartHelpers` stay testable in isolation (no DB, no socket)
  while `LineChartData` stays focused on the LiveView data plumbing.
  """

  alias DtuApp.Devices
  alias DtuAppWeb.DashboardLive.ChartHelpers
  alias DtuAppWeb.DashboardLive.ChartPalette
  alias DtuAppWeb.DashboardLive.Weather

  def assign_line_chart_data(
         socket,
         user,
         local_date,
         tz_offset_seconds,
         dtu_id,
         opts \\ []
       ) do
    # `:live?` flips on the yesterday-ghost overlay. Only the 1D (today)
    # preset shows it — historical day/week/month/year views keep the
    # chart scoped to their selected period. The historical-day caller
    # still gets a clean chart without a confusing ghost line.
    live? = Keyword.get(opts, :live?, socket.assigns[:live] == true)

    {utc_start, utc_end} = Devices.local_day_utc_range(local_date, tz_offset_seconds)
    # Read from the `readings_5m` continuous aggregate (older buckets)
    # unioned with a 5-minute live tail from raw rows; collapses the
    # per-row scan that `list_day_chart_data/4` did on every refresh.
    # See `DtuApp.Devices.list_day_chart_data_for_dashboard/4`.
    #
    # The dashboard thread pre-fetches the chart points once at the
    # top of `assign_dashboard_data/5`'s `:today` branch (where
    # `get_daily_stats/4` ALSO needs `bucket_max`). Re-using that
    # result here collapses two identical day-chart queries into one
    # on the noon mount path. Older callers (anything still passing
    # 5 args, including historical day/week/month branches and tests
    # via `select_quick_range`) fall through to the old fetch path.
    all_chart_points =
      case Keyword.get(opts, :chart_points) do
        nil -> Devices.list_day_chart_data_for_dashboard(user, utc_start, utc_end, dtu_id)
        pts -> pts
      end

    # The dashboard exposes one line per *inverter* (its AC aggregate,
    # mppt_index = 0). Per-MPPT DC rows are intentionally collapsed so
    # the chart stays readable when a fleet mixes single- and multi-
    # MPPT inverters; users can drill into a specific DTU on the
    # /devices page if they need MPPT-level detail.
    #
    # `inverter_serial != "_fleet"` is the matching defensive filter
    # against any legacy fleet-total rows an older parser version
    # persisted before the parser drop (see the matching comment in
    # `Devices.get_daily_stats/3`). The new parser no longer creates
    # these rows, but installs upgrading from a previous version still
    # have historical `_fleet` rows on disk — letting them through
    # would (a) render a phantom "Total" line in the legend and (b)
    # inflate the `show_total?` count, lighting up the headline Total
    # curve on single-inverter installs. Same defensive filter lives
    # at the data layer in `get_daily_stats/3` and `Devices.list_*` for
    # the same reason.
    #
    # `inverter_serial != "em:0"` is the matching defensive filter for
    # the Shelly Plus 3EM case. The Shelly parser writes rows with
    # `inverter_serial: "em:0"`, `mppt_index: 0`, `power_type:
    # "consumption"`, and nil `ac_power`/`dc_power` — the
    # `chart_power_for_mppt/1` nil-fallback returns 0.0 W for that
    # combination, which would otherwise render a synthetic flat-zero
    # line labelled "em:0" on the production chart. The data-layer
    # filter (`r.power_type == "production"` in
    # `list_day_readings_for_chart/4` and
    # `live_tail_bucketed_chart_points/3`) is the source of truth;
    # this clause is belt-and-suspenders for any caller that reaches
    # the dashboard with a hand-rolled `chart_points` opt.
    chart_points =
      all_chart_points
      |> Enum.filter(fn pt ->
        {_, serial, mppt_index, _name} = pt.series
        mppt_index == 0 and serial not in ["_fleet", "em:0"]
      end)
      # `readings_5m.avg_ac_power` is NULL for buckets whose only rows
      # had `ac_power: nil` (e.g. an AhoyDTU yield-only buffer flush
      # before the AC reading arrived — the same root cause as the
      # `bucket_max_from_chart_points/1` fix in PR #131). The aggregate
      # path exposes that NULL as a chart-point with `power: nil`.
      # Coalesce to `0.0` here, once, so every downstream consumer
      # (`Enum.max` over powers, `Enum.sum` per bucket, the per-point
      # `y = zero_y - power * pixels_per_watt_positive` calc) sees
      # numeric values only. Without the coalesce, `Float.ceil(nil, 0)`
      # at the `max_power` step raises `FunctionClauseError` and
      # `nil * pixels_per_watt_positive` at the per-point step raises
      # `ArithmeticError` — both crash the dashboard mount with a 500.
      |> Enum.map(fn pt -> %{pt | power: pt.power || 0.0} end)

    # Pull the consumption series upfront so `y_max` below can include
    # its peak — otherwise a heavy-load evening (Shelly reporting e.g.
    # 1500 W draw on a 600 W solar day) would clip the consumption line
    # off-screen above the chart.
    #
    # The today branch of `assign_dashboard_data/5` pre-fetches these
    # points once and threads them through `:consumption_chart_points`
    # so the consumption overlay + `get_consumption_daily_stats/3` +
    # `get_consumption_period_stats/5` all share a single `readings`
    # scan instead of running three independent ones on a paired-user
    # mount.
    consumption_chart_points =
      case Keyword.get(opts, :consumption_chart_points) do
        nil -> Devices.list_today_consumption_chart_data(user, dtu_id)
        pts -> pts
      end

    # Net-flow chart points (production minus consumption, sign-flipped
    # in the path below) — fetched up front so we can size the Y-axis
    # negative bound before computing the production/consumption paths.
    # Without this we'd render export peaks below the chart's bottom
    # edge, exactly the bug this fix targets.
    #
    # The today branch of `assign_dashboard_data/5` pre-fetches these
    # points once and threads them through `:net_chart_points` so the
    # net overlay + `get_net_flow_stats/3` share a single `readings`
    # scan instead of running two.
    net_chart_points =
      case Keyword.get(opts, :net_chart_points) do
        nil ->
          {start, end_} = Devices.local_day_utc_range(local_date, tz_offset_seconds)
          Devices.list_net_chart_data(user, start, end_, dtu_id)

        pts ->
          pts
      end

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

    # Consumption peak — the highest bucket-mean household draw on
    # today/day. We compare against (max per-series production,
    # max Total production) so the Y-axis covers whatever's largest on
    # the chart. Without this, the consumption path renders off-screen
    # above the chart whenever the household draw exceeds solar peak
    # (common in winter / evenings).
    consumption_max_power =
      consumption_chart_points
      |> Enum.map(& &1.power)
      |> Enum.max(fn -> 0.0 end)

    # Scale max power to next multiple of 100, taking the larger of
    # the per-series peak, the Total peak, and the consumption peak so
    # the headline curve stays inside the chart area.
    y_max =
      [max_power, total_max_power, consumption_max_power]
      |> Enum.max()
      |> Float.ceil()
      |> Kernel./(100)
      |> Float.ceil()
      |> Kernel.*(100)
      |> max(100.0)

    # Negative Y-axis bound: the chart's lower edge should extend down
    # to the most-negative net-flow display value (i.e. -max_export),
    # rounded DOWN to the next multiple of 100 so the export peak
    # never sits flush against the chart's bottom edge. Without this
    # guard a 432 W export peak would clip to ~432 W below the zero
    # line on a chart whose lower bound is implicitly 0.
    #
    # `display_power` here is the *sign-flipped* net value (positive
    # for import, negative for export) — the same convention the path
    # uses below — so the most-negative display_power equals
    # -max_export. We only extend the axis when the user actually has
    # net data and a non-zero export peak; without that, the chart
    # stays positive-only (the previous behaviour).
    #
    # DTU-only users (no Shelly paired) have nothing to net against, so
    # the chart must NEVER extend below zero — there's no export peak to
    # show in the lower half and a negative axis would be visually
    # wrong (negative gridline labels on a production-only curve).
    # `list_net_chart_data/4` already returns [] for DTU-only users
    # (the bucket-drop guard requires a consumption row), but we clamp
    # at the chart layer too as defense-in-depth against any future
    # code path that might seed a net row without a paired Shelly.
    y_min =
      cond do
        not socket.assigns[:has_shelly?] ->
          0.0

        true ->
          case net_chart_points do
            [] ->
              0.0

            pts ->
              most_negative_display =
                pts
                |> Enum.map(fn p -> -p.power end)
                |> Enum.min(fn -> 0.0 end)

              # Round DOWN to the next lower 100. A -432 W peak → -500 W
              # (next lower multiple of 100). A -50 W peak → -100 W so
              # even small export dips stay inside the chart area.
              if most_negative_display < 0.0 do
                most_negative_display
                |> Float.floor()
                |> Kernel./(100)
                |> Float.floor()
                |> Kernel.*(100)
              else
                0.0
              end
          end
      end

    # Net path's Y mapping depends on the unified [y_min, y_max] range.
    # When y_min < 0 (paired user with export peak), the zero line
    # shifts UP proportionally to `y_max / (y_max + |y_min|)` of the
    # chart area, leaving room for the export peak in the lower half.
    # The net path is then plotted against this asymmetric two-sided
    # scale.
    #
    # When y_min == 0 (no export data), there is no positive-only
    # constraint on the lower half. DTU-only users (no Shelly paired)
    # have nothing to net against — the chart never extends below
    # zero, and pushing the zero line to the chart bottom (`zero_y =
    # chart_bottom_y`) gives the production curve the full chart
    # height. The previous mid-chart zero line (`zero_y_default =
    # 135`) wasted the lower half of the canvas for DTU-only users,
    # since no curve ever plots there.
    chart_top_y = 20.0
    chart_bottom_y = 250.0
    zero_y_default = 135.0

    {zero_y, lower_height} =
      cond do
        y_min < 0.0 ->
          total_range = y_max + abs(y_min)

          {chart_top_y + y_max / total_range * (chart_bottom_y - chart_top_y), abs(y_min)}

        socket.assigns[:has_shelly?] ->
          # Shelly-only / no-net-data case: the previous behaviour
          # (zero line at y=135) is preserved. Only paired inverters
          # + Shelly users flip the asymmetric layout on, so a Shelly-
          # only user keeps the historical layout for now.
          {zero_y_default, 0.0}

        true ->
          # DTU-only user: pin zero to the chart bottom so the
          # production curve fills the full chart height.
          {chart_bottom_y, 0.0}
      end

    # Pixel-per-watt scale factors for the unified Y-axis. Positive
    # values (production, consumption, total) use the upper-half
    # scale; the net path's negative display values use the lower-
    # half scale (only set when y_min < 0; defaults to 0 when the
    # chart stays positive-only).
    pixels_per_watt_positive = (zero_y - chart_top_y) / y_max
    pixels_per_watt_negative = (chart_bottom_y - zero_y) / max(lower_height, 1.0)

    # Chart dimensions: width 800, height 250 (with 20px top padding).
    # X range is dynamic: zoomed to data when present, full day (00:00–
    # 24:00) when empty. See `chart_time_range/2` below.
    {x_min_seconds, x_max_seconds} =
      ChartHelpers.chart_time_range(
        chart_points,
        tz_offset_seconds,
        user.latitude,
        user.longitude,
        local_date
      )

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
            # Positive watts use the upper-half pixel-per-watt scale
            # (above the zero line). When `y_min` is 0 the zero line
            # sits at y=135 by default and this collapses to the
            # original `250 - power/y_max * 230` formula.
            y = zero_y - power * pixels_per_watt_positive
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

    # Yesterday's ghost overlay — only on the 1D (live) view. The
    # ghost reuses the same X/Y scale as today's chart so it sits on
    # the same baseline visually; same per-series grouping so the
    # ghost line picks up the same inverter colour (just rendered
    # translucent + dashed in the template). Empty when there's no
    # yesterday data — e.g. a brand-new install — so the template can
    # render nothing instead of a misleading zero line.
    #
    # The today branch of `assign_dashboard_data/5` pre-fetches
    # these points via `TodayDataCache` (the closure captures the
    # work to avoid running the `readings_5m` continuous-aggregate
    # query per reading broadcast). Older callers — historical day /
    # week / month / year — pass nothing for this opt and fall
    # through to the direct fetch.
    yesterday_paths =
      if live? do
        yesterday_chart_points =
          case Keyword.get(opts, :yesterday_chart_points) do
            nil ->
              user
              |> Devices.list_yesterday_chart_data_for_dashboard(utc_start, utc_end, dtu_id)
              |> Enum.filter(fn pt ->
                pt.series |> elem(2) == 0 and pt.series |> elem(1) != "_fleet"
              end)
              |> Enum.map(fn pt -> %{pt | power: pt.power || 0.0} end)

            pts ->
              pts
          end

        yesterday_chart_points
        |> Enum.group_by(& &1.series)
        |> Enum.map(fn {series, pts} ->
          coords =
            pts
            |> Enum.map(fn %{time: time, power: power} ->
              utc_seconds = time.hour * 3600 + time.minute * 60 + time.second

              local_seconds =
                (utc_seconds + tz_offset_seconds)
                |> rem(86_400 * 4)
                |> rem(86_400)

              x = (local_seconds - x_min_seconds) / x_span * 800.0
              y = zero_y - power * pixels_per_watt_positive
              {Float.round(x, 1), Float.round(y, 1)}
            end)
            |> Enum.sort_by(&elem(&1, 0))

          path =
            case coords do
              [] ->
                ""

              [{fx, fy} | rest] ->
                "M #{fx} #{fy} " <>
                  Enum.map_join(rest, " ", fn {x, y} -> "L #{x} #{y}" end)
            end

          {series, path}
        end)
        |> Map.new()
      else
        %{}
      end

    # Color palette per series. Each series is now one line per
    # inverter (mppt_index = 0 only), so we just need the per-inverter
    # base hue. The shade is fixed at 400 because there's no second
    # MPPT line to differentiate against anymore — using a single
    # bright shade keeps each inverter's line clearly visible against
    # the tinted area fill.
    inverter_color = ChartPalette.inverte_order_to_color(series_points)

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

    x_labels = ChartHelpers.chart_x_labels(x_min_seconds, x_max_seconds)

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
           %{time: seconds, power: ChartHelpers.power_at_from_unified_y(y, zero_y, y_max)}
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
          y = zero_y - total_power * pixels_per_watt_positive
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
        %{time: seconds, power: ChartHelpers.power_at_from_unified_y(y, zero_y, y_max)}
      end)

    # Consumption overlay: household draw (W) from a paired Shelly
    # Plus 3EM, plotted alongside the production lines. The consumption
    # chart points are bound earlier in this function (just below the
    # production points) so `y_max` can include the consumption peak
    # and the consumption path stays inside the chart area. Rendered
    # as a dashed rose-colored line so it reads as a separate metric,
    # not another inverter.
    {consumption_path, consumption_coords} =
      case consumption_chart_points do
        [] ->
          {"", []}

        pts ->
          path_coords =
            pts
            |> Enum.map(fn %{time: time, power: power} ->
              utc_seconds = time.hour * 3600 + time.minute * 60 + time.second
              local_seconds = utc_seconds + tz_offset_seconds
              local_seconds = rem(local_seconds + 86_400 * 4, 86_400)
              x = (local_seconds - x_min_seconds) / x_span * 800.0
              y = zero_y - power * pixels_per_watt_positive
              {Float.round(x, 1), Float.round(y, 1), local_seconds, power}
            end)
            |> Enum.sort_by(&elem(&1, 0))

          path =
            case path_coords do
              [] ->
                ""

              [{fx, fy, _, _} | rest] ->
                "M #{fx} #{fy} " <>
                  Enum.map_join(rest, " ", fn {x, y, _, _} -> "L #{x} #{y}" end)
            end

          coords = Enum.map(path_coords, fn {x, y, t, _} -> {x, y, t} end)
          {path, coords}
      end

    consumption_points_data =
      Enum.map(consumption_coords, fn {_x, y, seconds} ->
        %{time: seconds, power: ChartHelpers.power_at_from_unified_y(y, zero_y, y_max)}
      end)

    # Net flow overlay — production minus consumption, plotted on the
    # same axes. The user-facing sign convention flips the raw
    # `production - consumption` value: power LEAVING the home
    # (export, positive raw) is shown as a NEGATIVE value on the
    # graph and power ENTERING the home (import, negative raw) is
    # shown as POSITIVE. This matches the energy-flow perspective
    # "the home is exporting negative household consumption" and is
    # also the same convention the Shelly Plus 3EM uses for its
    # `total_act_power` field.
    #
    # Implementation:
    #   * `display_power = -power` — flips the sign for both the SVG
    #     Y coordinate and the JSON embedded in `data-points`. The
    #     tooltip's hover readout therefore shows the same number the
    #     user sees on the chart (-300 W for a 300 W export).
    #   * `y = 135 - display_power / y_max * 115.0` — same Y formula
    #     the production lines use (negative display_power increases
    #     y, plotting export below the zero line at y=135).
    #
    # The full SVG height is 230 (20px top padding, 250px bottom);
    # a centered zero line at y=135 lets the curve swing ±115. The
    # zero line itself is rendered as a separate <line> below the
    # net path so users see at a glance which side of zero a point
    # is on.
    #
    # `net_chart_points` is fetched up front (just below the production
    # chart_points binding) so the Y-axis scale can include the most-
    # negative export value before the per-series paths are computed.
    # `display_power = -power` flips the raw sign so export (positive
    # raw) becomes a negative display value below the zero line; the
    # Y mapping uses the unified [y_min, y_max] scale so the export
    # peak always sits inside the chart area, never clipping below
    # the bottom edge.
    {net_path, net_coords, net_points_data} =
      case net_chart_points do
        [] ->
          {"", [], []}

        pts ->
          path_coords =
            pts
            |> Enum.map(fn %{time: time, power: power} ->
              utc_seconds = time.hour * 3600 + time.minute * 60 + time.second
              local_seconds = utc_seconds + tz_offset_seconds
              local_seconds = rem(local_seconds + 86_400 * 4, 86_400)
              x = (local_seconds - x_min_seconds) / x_span * 800.0
              # Flip the sign: export (raw positive) becomes negative
              # for display, then plot below the zero line. See the
              # block comment above for the full sign-convention
              # rationale.
              display_power = -power
              # Use the unified [y_min, y_max] Y-axis: positive
              # display values (import) plot above `zero_y` against
              # the upper-half scale; negative display values (export)
              # plot below `zero_y` against the lower-half scale. The
              # export peak therefore sits inside the chart even when
              # the export magnitude is a fraction of the production
              # peak — the original centered-115-px formula clipped
              # export values that exceeded 50% of `y_max` past the
              # chart's bottom edge.
              y =
                cond do
                  display_power >= 0 ->
                    zero_y - display_power * pixels_per_watt_positive

                  true ->
                    zero_y + abs(display_power) * pixels_per_watt_negative
                end

              {Float.round(x, 1), Float.round(y, 1), local_seconds, display_power}
            end)
            |> Enum.sort_by(&elem(&1, 0))

          path =
            case path_coords do
              [] ->
                ""

              [{fx, fy, _, _} | rest] ->
                "M #{fx} #{fy} " <>
                  Enum.map_join(rest, " ", fn {x, y, _, _} -> "L #{x} #{y}" end)
            end

          coords = Enum.map(path_coords, fn {x, y, t, _} -> {x, y, t} end)

          points_data =
            Enum.map(path_coords, fn {_x, _y, seconds, display_power} ->
              %{time: seconds, power: display_power}
            end)

          {path, coords, points_data}
      end

    socket
    |> Phoenix.Component.assign(:chart_points, chart_points)
    |> Phoenix.Component.assign(:y_max, y_max)
    |> Phoenix.Component.assign(:y_min, y_min)
    |> Phoenix.Component.assign(:zero_y, zero_y)
    |> Phoenix.Component.assign(
      :y_gridlines,
      ChartHelpers.chart_y_gridlines(y_min, y_max, zero_y, chart_bottom_y, lower_height)
    )
    |> Phoenix.Component.assign(:series_paths, series_paths)
    |> Phoenix.Component.assign(:yesterday_paths, yesterday_paths)
    |> Phoenix.Component.assign(:series_palette, series_palette)
    |> Phoenix.Component.assign(:series_legend, series_legend)
    |> Phoenix.Component.assign(:path_data, Map.get(series_paths, hd_or_first_key(series_paths), ""))
    |> Phoenix.Component.assign(:x_labels, x_labels)
    |> Phoenix.Component.assign(:x_min_seconds, x_min_seconds)
    |> Phoenix.Component.assign(:x_max_seconds, x_max_seconds)
    |> Phoenix.Component.assign(:series_points_data, series_points_data)
    |> Phoenix.Component.assign(:total_path, total_path)
    |> Phoenix.Component.assign(:total_points_data, total_points_data)
    |> Phoenix.Component.assign(:total_palette, {"emerald", "900"})
    |> Phoenix.Component.assign(:consumption_path, consumption_path)
    |> Phoenix.Component.assign(:consumption_points_data, consumption_points_data)
    |> Phoenix.Component.assign(:consumption_palette, {"rose", "600"})
    |> Phoenix.Component.assign(:net_path, net_path)
    |> Phoenix.Component.assign(:net_coords, net_coords)
    |> Phoenix.Component.assign(:net_points_data, net_points_data)
    |> Phoenix.Component.assign(:net_palette, {"indigo", "500"})
    |> Phoenix.Component.assign(
      :now_marker_x,
      if(live?,
        do: ChartHelpers.now_marker_x(x_min_seconds, x_max_seconds, tz_offset_seconds),
        else: nil
      )
    )
    # Local-time label for the now-marker pill — formatted as
    # "HH:MM" in the user's timezone so the chart shows the
    # actual current time, not the static word "now". Gated on
    # the same `live?` flag as `:now_marker_x`; historical-day
    # views get `nil` and the template falls back to "now".
    |> Phoenix.Component.assign(
      :now_marker_label,
      if(live?,
        do: ChartHelpers.now_marker_label(tz_offset_seconds),
        else: nil
      )
    )
    # Sunrise / sunset guide-line X positions. Only computed when
    # the user has a captured geographic position (the JS hook
    # pushes it on every dashboard mount via `set_location`); the
    # helper returns `{nil, nil}` for nil coords so the template
    # renders nothing. We pass the chart's local date so the
    # "today" branch shows today's sunrise/sunset and the historical-
    # day branch shows that specific day's (slightly different) pair.
    |> Phoenix.Component.assign(
      :sun_markers,
      ChartHelpers.sun_markers(
        user.latitude,
        user.longitude,
        local_date,
        x_min_seconds,
        x_max_seconds,
        tz_offset_seconds
      )
    )
    # Cloud-cover band + current weather condition + percentage used
    # to live inline here, taking the Open-Meteo HTTP round trip on
    # every render. Perf #5 moved them out of the synchronous path:
    # `kickoff_weather_fetch/6` runs the fetch async on WebSocket
    # callbacks (so the chart paints first) and inline on the HTTP
    # render path (which has no follow-up render). See
    # `kickoff_weather_fetch/6` for the full rationale.
    |> Weather.kickoff_weather_fetch(user, local_date, x_min_seconds, x_max_seconds, tz_offset_seconds)
    # Perf #5 — flip `:initial_mount?` off so subsequent
    # `assign_dashboard_data/5` re-renders (preset switches,
    # `set_location`, `set_timezone`, PubSub reading broadcasts)
    # take the async-on-WebSocket branch in
    # `kickoff_weather_fetch/6`.
    |> Phoenix.Component.assign(:initial_mount?, false)
    # Mirrored from `user.latitude` / `user.longitude` so the cloud-
    # cover card slot can branch on "user has coords" without
    # reaching into the user struct from the template. Re-derived
    # on every `assign_dashboard_data` call so it stays fresh after
    # `set_location` persists a new position.
    |> Phoenix.Component.assign(:user_has_geolocation, DtuApp.Accounts.user_has_geolocation?(user))
  end

  def hd_or_first_key(map) when map_size(map) == 0, do: nil
  def hd_or_first_key(map), do: map |> Enum.at(0) |> elem(0)


  # Helper to construct SVG bar chart coordinates and range
  def assign_bar_chart_data(socket, bar_data) do
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
    |> Phoenix.Component.assign(:y_max, y_max)
    |> Phoenix.Component.assign(:bars, bars)
  end
end
