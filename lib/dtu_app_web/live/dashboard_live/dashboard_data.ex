defmodule DtuAppWeb.DashboardLive.DashboardData do
  @moduledoc """
  Top-level dashboard data orchestration.

  One main function plus two thin wrappers that gate it:

    * `assign_dashboard_data/5` — the master "rebuild the dashboard
      assigns" function. Runs every visible-branch computation
      (today / 7d / 30d / ytd / day / week / month / year) and
      threads the result through `LineChartData.assign_line_chart_data/6`
      or `LineChartData.assign_bar_chart_data/2` for the chart
      overlays.
    * `maybe_reassign_dashboard_data/3` — guard around
      `assign_dashboard_data/5` for the live-view reading handler;
      historical views (day/week/month/year) don't refresh on
      readings, so this is a no-op when `@live` is `false`.
    * `reapply_current_view/3` — re-runs `assign_dashboard_data/5`
      for the active view (live `today` or historical) after a
      DTU switch.

  All three take a `Phoenix.LiveView.Socket` and return one with
  the dashboard's primary assigns set (`@stats`, `@consumption_stats`,
  `@net_flow_stats`, `@savings`, `@chart_type`, `@selected_period`,
  etc.). The chart-specific assigns (`@series_paths`, `@y_max`,
  `@path_data`, etc.) flow out through the `LineChartData` call.

  ## Why this is its own module

  `assign_dashboard_data/5` is the central pivot for every dashboard
  re-render. Mount, every PubSub `:reading`, every range/granularity
  /date change, every DTU switch, every timezone change — all funnel
  through here. Keeping it isolated from `DashboardLive`'s render
  template + event handlers gives the read-the-dashboard-data story
  a single entry point and keeps the LV file focused on HTTP /
  WebSocket glue. The two wrapper helpers live here too because
  they exist solely to gate this one function.

  ## Performance considerations

  The today branch reads pre-computed stats + chart points; the
  historical branches scan the hypertable directly. The today
  branch is read-through cached for 15 s by `TodayDataCache` (keyed
  on `{user_id, tz_offset_seconds, dtu_id}`); the reading-broadcast
  handler invalidates the entry on every reading, so steady-state
  refreshes re-fetch on each broadcast but cache hits in bursty
  windows avoid duplicate DB scans.
  """

  alias DtuApp.Devices
  alias DtuAppWeb.DashboardLive.LineChartData
  alias DtuAppWeb.DashboardLive.TimeHelpers
  alias DtuAppWeb.DashboardLive.TodayDataCache

  def maybe_reassign_dashboard_data(socket, user, selected_id) do
    if socket.assigns.live do
      assign_dashboard_data(socket, user, selected_id, socket.assigns.time_range, nil)
    else
      socket
    end
  end

  # Re-run the dashboard for whichever view is active after a DTU switch.
  def reapply_current_view(socket, user, dtu_id) do
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

  def assign_dashboard_data(socket, user, dtu_id, time_range, selected_period) do
    # Cloud-cover / current-condition assigns are managed by
    # `kickoff_weather_fetch/6` via the fingerprint gate — the
    # previous unconditional `assign_weather_placeholders(socket)`
    # here wiped them on every PubSub `:reading` broadcast and
    # produced a one-render flicker between reset and the async
    # refetch completing. Steady-state broadcasts now leave the
    # snapshot untouched; only a true input change (coords, date,
    # visible X range, tz) triggers a fresh fetch.
    #
    # Bar-chart branches (week / month / year) don't call
    # `kickoff_weather_fetch/6`, but the chart SVG is gated on
    # `@chart_type == :line` (line 3113), so the band never
    # renders there. `current_cloud_cover` / `current_cloud_cover_pct`
    # flow into the stat-card row independently and a snapshot
    # carried over from a prior line-chart view stays correct.

    tz_offset_seconds = socket.assigns.user_tz_offset_seconds
    # Energy rate for the "Saved" card. `cents_per_kwh` is set in
    # `mount/3` from `user.cents_per_kwh`; if the user hasn't set a
    # rate yet this is `nil` and `Devices.compute_savings/2`
    # short-circuits to `nil`, so the card is hidden by the
    # template (`<%= if @savings %>`).
    cents = socket.assigns.cents_per_kwh

    # Pre-fetch today's consumption + net-flow bucket-mean points
    # ONCE and share them across:
    #   * `get_consumption_daily_stats/3` (consumption stat cards),
    #   * `get_net_flow_stats/3` (net-flow stat cards),
    #   * `assign_line_chart_data/6` (chart overlays).
    # Without this dedup, a paired-user mount ran
    # `list_consumption_chart_data/4` three times and
    # `list_net_chart_data/4` twice on the same data, each as a
    # separate `readings` row scan. The stats helpers and the chart
    # share the same 5-minute bucket means, so deriving both from a
    # single fetch is a safe optimisation that keeps every consumer's
    # number identical.
    #
    # Perf #4 layer 1: the today-window chart data is read-through
    # cached for 15 s by `TodayDataCache`. The cache key is
    # `{user_id, opts}` where `opts` carries `tz_offset_seconds` and
    # `dtu_id` (a tz change or DTU switch automatically produces a new
    # key, so no extra invalidation is needed). The reading-broadcast
    # handler calls `invalidate/1` to drop the entry; the next
    # `assign_dashboard_data/5` re-fetches.
    %{consumption: consumption_chart_points, net: net_chart_points} =
      TodayDataCache.fetch(
        user.id,
        [tz_offset_seconds: tz_offset_seconds, dtu_id: dtu_id],
        fn ->
          net_today_start = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
          net_today_end = DateTime.new!(Date.utc_today(), ~T[23:59:59], "Etc/UTC")

          %{
            consumption: Devices.list_today_consumption_chart_data(user, dtu_id),
            net: Devices.list_net_chart_data(user, net_today_start, net_today_end, dtu_id)
          }
        end
      )

    # Consumption stats from a paired Shelly Plus 3EM (Gen3+) energy
    # meter: current household draw (W), today's consumed energy
    # (kWh), and peak demand. Computed once per dashboard refresh and
    # shared across all branches since consumption is independent of
    # the production time_range/granularity.
    consumption_stats =
      Devices.get_consumption_daily_stats(
        user,
        dtu_id,
        consumption_chart_points: consumption_chart_points
      )

    # Period-aware consumption stats — same shape as `@stats` for the
    # production side: today/day views get current/today/peak, week/
    # month/year views get period total / period peak / peak date.
    # Drives the dedicated "Power consumption" stat-card row that
    # mirrors the production row when a Shelly is paired.
    #
    # We pass the already-fetched `consumption_stats` through so the
    # today / day branches don't re-fetch the same data. The
    # `get_consumption_period_stats/4` helper used to call
    # `get_consumption_daily_stats/2` again, doubling the per-day
    # consumption scan on every dashboard mount / reading refresh
    # (the dashboard pre-fetches the value just above for the
    # consumption stat cards). The 5th argument is `nil` by default
    # for older callers — see `DtuApp.Devices.get_consumption_period_stats/5`.
    consumption_period_stats =
      Devices.get_consumption_period_stats(
        user,
        dtu_id,
        time_range,
        selected_period,
        consumption_stats
      )

    # Net flow (production minus consumption) — the headline value
    # for a solar dashboard ("am I net-exporting or net-importing?").
    # Only meaningful when both an inverter AND a Shelly are paired;
    # otherwise the helper returns all-zeros and the dashboard's
    # `net_flow_active` guard hides the row.
    net_flow_stats =
      Devices.get_net_flow_stats(
        user,
        dtu_id,
        net_chart_points: net_chart_points
      )

    case time_range do
      "today" ->
        # The today branch needs 4 heavy queries on top of the
        # consumption + net chart points already cached above:
        #   * `list_day_chart_data_for_dashboard/4` (Repo.all + 5m agg)
        #   * `get_daily_stats/4` (4× DISTINCT ON Repo.all)
        #   * `compute_self_consumption_pct/5` (2× Repo.all)
        #   * `list_yesterday_chart_data_for_dashboard/4` (called from
        #     `assign_line_chart_data/6` on the live view)
        # On a paired-user mount that's ~8 more round-trips per
        # refresh — multiplied by a 2–6 Hz PubSub `:reading` stream
        # (Shelly 30s + OpenDTU 5–10s), the connection pool
        # (`POOL_SIZE=10` per `config/runtime.exs:39`) drains and the
        # 8th call's `DBConnection.checkout_timeout` (15 s) fires.
        #
        # A second `TodayDataCache.fetch/3` call with a different
        # cache key (`branch: :today`) covers the today-specific work
        # in a single closure. On cache hit, the dashboard re-render
        # runs **zero** DB queries for the today branch.
        today_local = TimeHelpers.local_today(tz_offset_seconds)

        {today_utc_start, today_utc_end} =
          Devices.local_day_utc_range(today_local, tz_offset_seconds)

        today_specific =
          TodayDataCache.fetch(
            user.id,
            [branch: :today, tz_offset_seconds: tz_offset_seconds, dtu_id: dtu_id],
            fn ->
              # Cache miss — run the four heavy queries that drive
              # the today branch. The closure captures `user` /
              # `dtu_id` / `today_utc_start` / `today_utc_end` from
              # the call site.
              today_chart_points =
                Devices.list_day_chart_data_for_dashboard(
                  user,
                  today_utc_start,
                  today_utc_end,
                  dtu_id
                )

              raw_daily_stats =
                Devices.get_daily_stats(user, dtu_id, Date.utc_today(), today_chart_points)

              today_self_consumption_pct =
                Devices.compute_self_consumption_pct(
                  user,
                  dtu_id,
                  today_utc_start,
                  today_utc_end
                )

              yesterday_chart_points =
                user
                |> Devices.list_yesterday_chart_data_for_dashboard(
                  today_utc_start,
                  today_utc_end,
                  dtu_id
                )
                |> Enum.filter(fn pt ->
                  {_, serial, mppt_index, _name} = pt.series
                  mppt_index == 0 and serial not in ["_fleet", "em:0"]
                end)
                |> Enum.map(fn pt -> %{pt | power: pt.power || 0.0} end)

              %{
                today_chart_points: today_chart_points,
                daily_stats: raw_daily_stats,
                self_consumption_pct: today_self_consumption_pct,
                yesterday_chart_points: yesterday_chart_points
              }
            end
          )

        # The destructured keys come from the closure's return map.
        # The post-processing (`:total_yield` overwrite,
        # `Map.put :self_consumption_pct`) stays at the call site so
        # the cached value is the cheapest raw form.
        %{
          today_chart_points: today_chart_points,
          daily_stats: raw_daily_stats,
          self_consumption_pct: today_self_consumption_pct,
          yesterday_chart_points: yesterday_chart_points
        } = today_specific

        stats = raw_daily_stats

        # The 5-up stat-card row's "Yield" tile reads `@stats.total_yield`
        # uniformly across all 8 time_range branches. For the day / week
        # / month / year / 7d / 30d / ytd branches, `compute_day_period_stats/2`
        # and `compute_range_period_stats/2` already return
        # `:total_yield` as the period's kWh sum. But `get_daily_stats/4`
        # uses `:total_yield` for the **lifetime** cumulative yield
        # (firmware `yield_total`) and `:today_yield` for the day's
        # sum-of-latest-`yield_day`. Overwrite `:total_yield` here so
        # the 1D view matches the period semantics the other branches
        # use — otherwise the Yield card on 1D would show the lifetime
        # number instead of today's kWh.
        #
        # `self_consumption_pct` is computed by the same closure and
        # applied here. The cache stores the raw `get_daily_stats/4`
        # map (without these Map.puts) so the same cached value can
        # serve both today and any future caller that needs the
        # unmodified shape.
        stats =
          stats
          |> Map.put(:total_yield, stats.today_yield)
          |> Map.put(:self_consumption_pct, today_self_consumption_pct)

        socket
        |> Phoenix.Component.assign(:stats, stats)
        |> Phoenix.Component.assign(:consumption_stats, consumption_stats)
        |> Phoenix.Component.assign(:consumption_period_stats, consumption_period_stats)
        |> Phoenix.Component.assign(:net_flow_stats, net_flow_stats)
        |> Phoenix.Component.assign(:savings, Devices.compute_savings(stats.today_yield, cents))
        |> Phoenix.Component.assign(:chart_type, :line)
        |> LineChartData.assign_line_chart_data(
          user,
          today_local,
          tz_offset_seconds,
          dtu_id,
          chart_points: today_chart_points,
          consumption_chart_points: consumption_chart_points,
          net_chart_points: net_chart_points,
          yesterday_chart_points: yesterday_chart_points
        )

      "day" ->
        date =
          case selected_period do
            %Date{} = d ->
              d

            _ ->
              selectable = socket.assigns.selectable_dates
              List.first(selectable) || TimeHelpers.local_today(tz_offset_seconds)
          end

        # Convert the user-facing local date to the UTC range that
        # contains the readings for that local day.
        {utc_start, utc_end} = Devices.local_day_utc_range(date, tz_offset_seconds)

        # Perf #16: wrap the 4-query historical-day work
        # (`list_day_chart_data` + `list_range_yield_data` +
        # `compute_self_consumption_pct`) in a single
        # `TodayDataCache.fetch/3` call. Mirrors the today branch —
        # a 15 s TTL covers the PubSub `:reading` broadcast flood
        # (2–6 Hz on a paired user), so a user who's navigated to
        # "last Tuesday" and is sitting on that view doesn't pay
        # 4 round-trips per reading.
        #
        # Cache key includes the user's tz_offset (different tz →
        # different utc window), dtu_id (per-device view vs
        # fleet), and the picked `date` (clicking through the
        # calendar invalidates by changing the key).
        day_specific =
          TodayDataCache.fetch(
            user.id,
            [branch: :day, tz_offset_seconds: tz_offset_seconds, dtu_id: dtu_id, date: date],
            fn ->
              %{
                points: Devices.list_day_chart_data(user, utc_start, utc_end, dtu_id),
                yields: Devices.list_range_yield_data(user, utc_start, utc_end, dtu_id),
                self_consumption_pct:
                  Devices.compute_self_consumption_pct(user, dtu_id, utc_start, utc_end)
              }
            end
          )

        %{points: points, yields: yields, self_consumption_pct: day_self_consumption_pct} =
          day_specific

        stats = Devices.compute_day_period_stats(yields, points)

        stats_with_self_consumption =
          Map.put(stats, :self_consumption_pct, day_self_consumption_pct)

        socket
        |> Phoenix.Component.assign(:selected_period, date)
        |> Phoenix.Component.assign(:stats, stats_with_self_consumption)
        |> Phoenix.Component.assign(:consumption_stats, consumption_stats)
        |> Phoenix.Component.assign(:consumption_period_stats, consumption_period_stats)
        |> Phoenix.Component.assign(:net_flow_stats, net_flow_stats)
        |> Phoenix.Component.assign(:savings, Devices.compute_savings(stats.total_yield, cents))
        |> Phoenix.Component.assign(:chart_type, :line)
        |> LineChartData.assign_line_chart_data(user, date, tz_offset_seconds, dtu_id)

      "week" ->
        monday =
          case selected_period do
            %Date{} = d ->
              d

            _ ->
              selectable = socket.assigns.selectable_dates
              latest_date = List.first(selectable) || TimeHelpers.local_today(tz_offset_seconds)
              Date.add(latest_date, -(Date.day_of_week(latest_date) - 1))
          end

        sunday = Date.add(monday, 6)

        {monday_utc, sunday_utc_end} =
          {elem(Devices.local_day_utc_range(monday, tz_offset_seconds), 0),
           elem(Devices.local_day_utc_range(sunday, tz_offset_seconds), 1)}

        # Perf #16: wrap the 3-query week-branch work
        # (`list_range_yield_data` + `compute_peak_watts_in_period` +
        # `compute_self_consumption_pct`) in a single
        # `TodayDataCache.fetch/3` call. Same 15 s TTL + same
        # PubSub-flood rationale as the `day` branch above.
        # Cache key includes `monday` so clicking between adjacent
        # weeks invalidates by changing the key (no separate
        # invalidate needed).
        week_specific =
          TodayDataCache.fetch(
            user.id,
            [branch: :week, tz_offset_seconds: tz_offset_seconds, dtu_id: dtu_id, monday: monday],
            fn ->
              {peak_w, peak_time} =
                Devices.compute_peak_watts_in_period(user, dtu_id, monday_utc, sunday_utc_end)

              %{
                yields: Devices.list_range_yield_data(user, monday_utc, sunday_utc_end, dtu_id),
                peak_w: peak_w,
                peak_time: peak_time,
                self_consumption_pct:
                  Devices.compute_self_consumption_pct(user, dtu_id, monday_utc, sunday_utc_end)
              }
            end
          )

        %{
          yields: yields,
          peak_w: week_peak_w,
          peak_time: week_peak_time,
          self_consumption_pct: week_self_consumption_pct
        } = week_specific

        stats = Devices.compute_range_period_stats(yields, 7)

        stats =
          stats
          |> Map.put(:peak_power, week_peak_w)
          |> Map.put(:peak_time, week_peak_time)
          |> Map.put(:self_consumption_pct, week_self_consumption_pct)

        yield_map = Map.new(yields)

        bar_data =
          for day_offset <- 0..6 do
            d = Date.add(monday, day_offset)
            label = Calendar.strftime(d, "%a")
            value = Map.get(yield_map, d, 0.0)
            %{label: label, value: value}
          end

        socket
        |> Phoenix.Component.assign(:selected_period, monday)
        |> Phoenix.Component.assign(:stats, stats)
        |> Phoenix.Component.assign(:consumption_stats, consumption_stats)
        |> Phoenix.Component.assign(:consumption_period_stats, consumption_period_stats)
        |> Phoenix.Component.assign(:net_flow_stats, net_flow_stats)
        |> Phoenix.Component.assign(:savings, Devices.compute_savings(stats.total_yield, cents))
        |> Phoenix.Component.assign(:chart_type, :bar)
        |> LineChartData.assign_bar_chart_data(bar_data)

      "month" ->
        first_day =
          case selected_period do
            %Date{} = d ->
              d

            _ ->
              selectable = socket.assigns.selectable_dates
              latest_date = List.first(selectable) || TimeHelpers.local_today(tz_offset_seconds)
              Date.new!(latest_date.year, latest_date.month, 1)
          end

        last_day = Date.end_of_month(first_day)

        {first_utc, last_utc_end} =
          {elem(Devices.local_day_utc_range(first_day, tz_offset_seconds), 0),
           elem(Devices.local_day_utc_range(last_day, tz_offset_seconds), 1)}

        total_days = Date.diff(last_day, first_day) + 1

        # Perf #16: wrap the 3-query month-branch work in a single
        # `TodayDataCache.fetch/3` call. Same shape as the `week`
        # branch above. Cache key includes `first_day` so clicking
        # between months invalidates by changing the key.
        month_specific =
          TodayDataCache.fetch(
            user.id,
            [
              branch: :month,
              tz_offset_seconds: tz_offset_seconds,
              dtu_id: dtu_id,
              first_day: first_day
            ],
            fn ->
              {peak_w, peak_time} =
                Devices.compute_peak_watts_in_period(user, dtu_id, first_utc, last_utc_end)

              %{
                yields: Devices.list_range_yield_data(user, first_utc, last_utc_end, dtu_id),
                peak_w: peak_w,
                peak_time: peak_time,
                self_consumption_pct:
                  Devices.compute_self_consumption_pct(user, dtu_id, first_utc, last_utc_end)
              }
            end
          )

        %{
          yields: yields,
          peak_w: month_peak_w,
          peak_time: month_peak_time,
          self_consumption_pct: month_self_consumption_pct
        } = month_specific

        stats = Devices.compute_range_period_stats(yields, total_days)

        stats =
          stats
          |> Map.put(:peak_power, month_peak_w)
          |> Map.put(:peak_time, month_peak_time)
          |> Map.put(:self_consumption_pct, month_self_consumption_pct)

        yield_map = Map.new(yields)

        bar_data =
          for day_offset <- 0..(total_days - 1) do
            d = Date.add(first_day, day_offset)
            label = to_string(d.day)
            value = Map.get(yield_map, d, 0.0)
            %{label: label, value: value}
          end

        socket
        |> Phoenix.Component.assign(:selected_period, first_day)
        |> Phoenix.Component.assign(:stats, stats)
        |> Phoenix.Component.assign(:consumption_stats, consumption_stats)
        |> Phoenix.Component.assign(:consumption_period_stats, consumption_period_stats)
        |> Phoenix.Component.assign(:net_flow_stats, net_flow_stats)
        |> Phoenix.Component.assign(:savings, Devices.compute_savings(stats.total_yield, cents))
        |> Phoenix.Component.assign(:chart_type, :bar)
        |> LineChartData.assign_bar_chart_data(bar_data)

      "year" ->
        year =
          case selected_period do
            %Date{} = d ->
              d.year

            y when is_integer(y) ->
              y

            _ ->
              selectable = socket.assigns.selectable_dates
              latest_date = List.first(selectable) || TimeHelpers.local_today(tz_offset_seconds)
              latest_date.year
          end

        start_date = Date.new!(year, 1, 1)
        end_date = Date.new!(year, 12, 31)

        {start_utc, end_utc_end} =
          {elem(Devices.local_day_utc_range(start_date, tz_offset_seconds), 0),
           elem(Devices.local_day_utc_range(end_date, tz_offset_seconds), 1)}

        # Perf #16: wrap the 3-query year-branch work in a single
        # `TodayDataCache.fetch/3` call. Cache key includes the
        # integer `year` so the year-stepper selector naturally
        # invalidates by changing the key.
        year_specific =
          TodayDataCache.fetch(
            user.id,
            [branch: :year, tz_offset_seconds: tz_offset_seconds, dtu_id: dtu_id, year: year],
            fn ->
              {peak_w, peak_time} =
                Devices.compute_peak_watts_in_period(user, dtu_id, start_utc, end_utc_end)

              %{
                yields: Devices.list_range_yield_data(user, start_utc, end_utc_end, dtu_id),
                peak_w: peak_w,
                peak_time: peak_time,
                self_consumption_pct:
                  Devices.compute_self_consumption_pct(user, dtu_id, start_utc, end_utc_end)
              }
            end
          )

        %{
          yields: yields,
          peak_w: year_peak_w,
          peak_time: year_peak_time,
          self_consumption_pct: year_self_consumption_pct
        } = year_specific

        stats = Devices.compute_range_period_stats(yields, 12)

        stats =
          stats
          |> Map.put(:peak_power, year_peak_w)
          |> Map.put(:peak_time, year_peak_time)
          |> Map.put(:self_consumption_pct, year_self_consumption_pct)

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
        |> Phoenix.Component.assign(:selected_period, Date.new!(year, 1, 1))
        |> Phoenix.Component.assign(:stats, stats)
        |> Phoenix.Component.assign(:consumption_stats, consumption_stats)
        |> Phoenix.Component.assign(:consumption_period_stats, consumption_period_stats)
        |> Phoenix.Component.assign(:net_flow_stats, net_flow_stats)
        |> Phoenix.Component.assign(:savings, Devices.compute_savings(stats.total_yield, cents))
        |> Phoenix.Component.assign(:chart_type, :bar)
        |> LineChartData.assign_bar_chart_data(bar_data)

      "7d" ->
        # Last 7 days ending today, daily yields → bar chart. Anchored on
        # the user's tz offset so a CET user at 01:00 local on Monday sees
        # the window start at the previous Tuesday's local midnight
        # (matching the dashboard's other local-day boundaries).
        today_local = TimeHelpers.local_today(tz_offset_seconds)

        {seven_day_utc_start, seven_day_utc_end} =
          Devices.local_day_utc_range(today_local, tz_offset_seconds)

        seven_day_window_start = DateTime.add(seven_day_utc_start, -6 * 86_400, :second)

        # Perf #16: wrap the 3-query 7d-branch work in a single
        # `TodayDataCache.fetch/3` call. Rolling window anchored on
        # `today_local` — the cache key therefore changes daily at
        # local midnight (no explicit invalidate needed; the old
        # entry simply ages out via the 15 s TTL or sits under an
        # orphan key until the next `:today` / `:day` overwrite
        # happens to collide). The 15 s TTL is fine because no new
        # readings for past dates can change the window's content
        # (the rolling tail re-evaluates on the next cache miss
        # after local midnight).
        seven_day_specific =
          TodayDataCache.fetch(
            user.id,
            [branch: :"7d", tz_offset_seconds: tz_offset_seconds, dtu_id: dtu_id],
            fn ->
              {peak_w, peak_time} =
                Devices.compute_peak_watts_in_period(
                  user,
                  dtu_id,
                  seven_day_window_start,
                  seven_day_utc_end
                )

              %{
                yields: Devices.list_last_n_days_yield_data(user, 7, tz_offset_seconds, dtu_id),
                peak_w: peak_w,
                peak_time: peak_time,
                self_consumption_pct:
                  Devices.compute_self_consumption_pct(
                    user,
                    dtu_id,
                    seven_day_window_start,
                    seven_day_utc_end
                  )
              }
            end
          )

        %{
          yields: yields,
          peak_w: seven_day_peak_w,
          peak_time: seven_day_peak_time,
          self_consumption_pct: seven_day_self_consumption_pct
        } = seven_day_specific

        stats = Devices.compute_range_period_stats(yields, 7)

        stats =
          stats
          |> Map.put(:peak_power, seven_day_peak_w)
          |> Map.put(:peak_time, seven_day_peak_time)
          |> Map.put(:self_consumption_pct, seven_day_self_consumption_pct)

        yield_map = Map.new(yields)

        bar_data =
          for day_offset <- -6..0 do
            d = Date.add(today_local, day_offset)
            label = Calendar.strftime(d, "%a")
            value = Map.get(yield_map, d, 0.0)
            %{label: label, value: value}
          end

        socket
        |> Phoenix.Component.assign(:stats, stats)
        |> Phoenix.Component.assign(:consumption_stats, consumption_stats)
        |> Phoenix.Component.assign(:consumption_period_stats, consumption_period_stats)
        |> Phoenix.Component.assign(:net_flow_stats, net_flow_stats)
        |> Phoenix.Component.assign(:savings, Devices.compute_savings(stats.total_yield, cents))
        |> Phoenix.Component.assign(:chart_type, :bar)
        |> LineChartData.assign_bar_chart_data(bar_data)

      "30d" ->
        # Last 30 days ending today, daily yields → bar chart. Same
        # boundary handling as `7d` above; just a wider window.
        today_local = TimeHelpers.local_today(tz_offset_seconds)

        {thirty_day_utc_start, thirty_day_utc_end} =
          Devices.local_day_utc_range(today_local, tz_offset_seconds)

        thirty_day_window_start = DateTime.add(thirty_day_utc_start, -29 * 86_400, :second)

        # Perf #16: wrap the 3-query 30d-branch work in a single
        # `TodayDataCache.fetch/3` call. Same rolling-window shape
        # as the `7d` branch above.
        thirty_day_specific =
          TodayDataCache.fetch(
            user.id,
            [branch: :"30d", tz_offset_seconds: tz_offset_seconds, dtu_id: dtu_id],
            fn ->
              {peak_w, peak_time} =
                Devices.compute_peak_watts_in_period(
                  user,
                  dtu_id,
                  thirty_day_window_start,
                  thirty_day_utc_end
                )

              %{
                yields: Devices.list_last_n_days_yield_data(user, 30, tz_offset_seconds, dtu_id),
                peak_w: peak_w,
                peak_time: peak_time,
                self_consumption_pct:
                  Devices.compute_self_consumption_pct(
                    user,
                    dtu_id,
                    thirty_day_window_start,
                    thirty_day_utc_end
                  )
              }
            end
          )

        %{
          yields: yields,
          peak_w: thirty_day_peak_w,
          peak_time: thirty_day_peak_time,
          self_consumption_pct: thirty_day_self_consumption_pct
        } = thirty_day_specific

        stats = Devices.compute_range_period_stats(yields, 30)

        stats =
          stats
          |> Map.put(:peak_power, thirty_day_peak_w)
          |> Map.put(:peak_time, thirty_day_peak_time)
          |> Map.put(:self_consumption_pct, thirty_day_self_consumption_pct)

        yield_map = Map.new(yields)

        bar_data =
          for day_offset <- -29..0 do
            d = Date.add(today_local, day_offset)
            # %-d → no zero-pad; with 30 bars the wider "%b %-d" format
            # keeps each label readable on a tight x-axis.
            label = Calendar.strftime(d, "%b %-d")
            value = Map.get(yield_map, d, 0.0)
            %{label: label, value: value}
          end

        socket
        |> Phoenix.Component.assign(:stats, stats)
        |> Phoenix.Component.assign(:consumption_stats, consumption_stats)
        |> Phoenix.Component.assign(:consumption_period_stats, consumption_period_stats)
        |> Phoenix.Component.assign(:net_flow_stats, net_flow_stats)
        |> Phoenix.Component.assign(:savings, Devices.compute_savings(stats.total_yield, cents))
        |> Phoenix.Component.assign(:chart_type, :bar)
        |> LineChartData.assign_bar_chart_data(bar_data)

      "ytd" ->
        # Year-to-date (Jan 1 of current year → today), monthly yields →
        # bar chart. Same shape as the existing `year` branch above but
        # window starts on Jan 1 (not Jan 1 of an arbitrary year), so the
        # bars stop at the current month rather than going all the way to
        # December.
        today = Date.utc_today()
        ytd_start_date = Date.new!(today.year, 1, 1)
        months_in_window = today.month

        {ytd_utc_start, ytd_utc_end} =
          Devices.local_day_utc_range(ytd_start_date, tz_offset_seconds)

        # Perf #16: wrap the 3-query ytd-branch work in a single
        # `TodayDataCache.fetch/3` call. Rolling window anchored on
        # the current calendar year — the cache key therefore changes
        # at local midnight on Jan 1 (no explicit invalidate needed).
        ytd_specific =
          TodayDataCache.fetch(
            user.id,
            [branch: :ytd, tz_offset_seconds: tz_offset_seconds, dtu_id: dtu_id],
            fn ->
              {peak_w, peak_time} =
                Devices.compute_peak_watts_in_period(user, dtu_id, ytd_utc_start, ytd_utc_end)

              %{
                monthly_yields: Devices.list_ytd_yield_data(user, dtu_id),
                peak_w: peak_w,
                peak_time: peak_time,
                self_consumption_pct:
                  Devices.compute_self_consumption_pct(user, dtu_id, ytd_utc_start, ytd_utc_end)
              }
            end
          )

        %{
          monthly_yields: monthly_yields,
          peak_w: ytd_peak_w,
          peak_time: ytd_peak_time,
          self_consumption_pct: ytd_self_consumption_pct
        } = ytd_specific

        # `Devices.list_ytd_yield_data/2` returns
        # `[{{year, month}, kwh}]` — the range-period stats helper
        # expects `[{Date.t(), float()}]` so we widen the tuple back
        # into a first-of-month `Date`. Multi-year installs (rare:
        # one full January's worth of cross-year data is the only
        # case where the same `{year, month}` would collide) collapse
        # cleanly because we group by `month` only below for the bars.
        stats =
          Devices.compute_range_period_stats(
            Enum.map(monthly_yields, fn {{year, month}, kwh} ->
              {Date.new!(year, month, 1), kwh}
            end),
            months_in_window
          )

        # Peak watts + self-consumption across Jan 1 → today (the
        # YTD window). Uses the user's tz offset so the boundaries
        # line up with the bar chart's first bar (January).

        stats =
          stats
          |> Map.put(:peak_power, ytd_peak_w)
          |> Map.put(:peak_time, ytd_peak_time)
          |> Map.put(:self_consumption_pct, ytd_self_consumption_pct)

        bar_data =
          for month <- 1..months_in_window do
            first_day = Date.new!(today.year, month, 1)
            label = Calendar.strftime(first_day, "%b")

            value =
              monthly_yields
              |> Enum.filter(fn {{_y, m}, _} -> m == month end)
              |> Enum.map(fn {_, kwh} -> kwh end)
              |> Enum.sum()

            %{label: label, value: value}
          end

        socket
        |> Phoenix.Component.assign(:stats, stats)
        |> Phoenix.Component.assign(:consumption_stats, consumption_stats)
        |> Phoenix.Component.assign(:consumption_period_stats, consumption_period_stats)
        |> Phoenix.Component.assign(:net_flow_stats, net_flow_stats)
        |> Phoenix.Component.assign(:savings, Devices.compute_savings(stats.total_yield, cents))
        |> Phoenix.Component.assign(:chart_type, :bar)
        |> LineChartData.assign_bar_chart_data(bar_data)
    end
  end
end
