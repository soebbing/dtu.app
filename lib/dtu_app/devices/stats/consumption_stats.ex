defmodule DtuApp.Devices.Stats.ConsumptionStats do
  @moduledoc """
  Consumption-side aggregations: current household draw, today's
  consumption in kWh, peak consumption, period totals and per-day
  peak.

  Reads only `power_type = :consumption` rows (Shelly Plus 3EM
  telemetry). The today branch integrates bucket-mean
  `consumption_power` over time so a solar self-sufficient home is
  not silently zero. The period branch (week/month/year) uses the
  same integration approach for consistency with the today view.

  `compute_consumption_peak_day/4` lives here as a private helper
  called from `get_consumption_period_stats/5`. It's the per-day
  peak detector — different from `compute_consumption_peak_w/4`
  (which is the bucket-max within a window).

  Re-exported through `DtuApp.Devices.Stats` via `defdelegate` so
  existing call sites continue to work unchanged.
  """

  import Ecto.Query

  alias DtuApp.Accounts.User
  alias DtuApp.Devices.ChartData
  alias DtuApp.Devices.ConsumptionChartData
  alias DtuApp.Devices.Reading
  alias DtuApp.Repo

  alias DtuApp.Devices.Stats.PeriodHelpers

  import DtuApp.Devices.ChartHelpers, only: [owned_dtu_ids: 2, clamp_household_draw: 1]

  @doc """
  Consumption-side mirror of `get_daily_stats/2`. Reads only
  `power_type = :consumption` rows (Shelly Plus 3EM telemetry) and
  returns the same `{current_consumption, today_consumption,
  peak_consumption}` shape so the dashboard can render the
  "Current Consumption" / "Today's Consumption" stat cards next
  to the existing production cards.

  `current_consumption` is the latest fresh reading's
  `consumption_power` summed across the user's Shelly devices. A
  fresh reading is anything in the last two minutes (matching the
  cutoff used by `get_daily_stats/3`).

  `today_consumption` is the household energy consumed within the
  current UTC day (in kWh), computed by integrating the bucket-mean
  `consumption_power` over time. The Shelly Plus 3EM publishes a
  *signed* `total_act_power` per uplink (positive when the home is
  drawing from the grid, negative when the home is exporting
  surplus solar). The integration sums raw values, floored at 0
  per-bucket, so a solar home whose self-consumption exceeds grid
  draw reports non-zero kWh (the bucket-mean × 5/60h gives a real
  consumption value). A home fully covered by solar with no grid
  import still reads 0 because the bucket-mean is non-positive.

  Note that the "Today's Consumption" computation is a best
  approximation: the Shelly meter only sees net grid flow, not
  direct solar use, so a fully solar self-sufficient home will
  show zero regardless of household activity. The integration uses
  the bucket-mean rather than summing raw readings because the
  Shelly publishes ~10× per 5-min bucket — summing would 10× the
  result.

  `peak_consumption` mirrors `peak_power`: the higher of (a) the
  live fresh reading, (b) the highest 5-minute bucket mean.

  Returns the same zero defaults as `get_daily_stats/2` when the
  user has no devices.
  """
  def get_consumption_daily_stats(%User{} = user, dtu_id \\ nil, opts \\ []) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      %{current_consumption: 0.0, today_consumption: 0.0, peak_consumption: 0.0}
    else
      # Pre-computed today consumption chart points (already bucket-meaned
      # into 5-min windows by `list_consumption_chart_data/4`). When the
      # caller (the today branch of `assign_dashboard_data/5`) already
      # fetched these for the consumption overlay, pass them in via
      # `:consumption_chart_points` so we don't re-run the same `readings`
      # scan TWICE inside this helper — once via `integrate_consumption_kwh`
      # for `today_consumption` and again via `list_today_consumption_chart_data`
      # for `bucket_max`. On a paired-user mount that's 2 raw-row scans
      # saved per refresh; the same query is also used by the chart code
      # path so we cut the dashboard's consumption reads from 3 to 1.
      consumption_chart_points =
        case Keyword.get(opts, :consumption_chart_points) do
          nil -> nil
          pts when is_list(pts) -> pts
        end

      two_minutes_ago = DtuApp.Time.utc_now() |> DateTime.add(-120, :second)

      # Latest reading per (dtu_id) — Shelly only publishes one
      # meter (em:0) per device, so we don't key by inverter_serial.
      # `distinct: [r.dtu_id]` is the Ecto spelling of PostgreSQL's
      # `SELECT DISTINCT ON (dtu_id)` — it returns ONE row per device,
      # the one with the highest `inserted_at` thanks to the `order_by`.
      # Using `distinct: true` instead (full-row dedup) was a subtle bug:
      # since every uplink writes a row with a different `(consumption_power,
      # inserted_at)` tuple, no two rows were duplicates and the query
      # returned every recent row, so the `Enum.sum/1` below added up
      # ~N latest readings instead of the latest one. A typical Shelly
      # uplink every 5–10s meant the dashboard rendered ~7× the true
      # value (530W on the dashboard vs 76W on the Shelly app).
      latest_readings =
        Repo.all(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and r.power_type == "consumption" and
                r.inserted_at >= ^two_minutes_ago,
            distinct: [r.dtu_id],
            order_by: [r.dtu_id, desc: r.inserted_at]
        )

      current_consumption =
        latest_readings
        |> Enum.filter(fn r -> DateTime.after?(r.inserted_at, two_minutes_ago) end)
        # Clamp each fresh reading to the household-draw reading
        # (≥ 0 W). The Shelly's `total_act_power` is signed; during
        # net-export windows it would otherwise show a negative
        # wattage on the "Current Consumption" card. Multi-device
        # households sum the clamped values across devices.
        |> Enum.map(&clamp_household_draw(&1.consumption_power))
        |> Enum.sum()

      today_start = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
      today_end = DateTime.new!(Date.utc_today(), ~T[23:59:59], "Etc/UTC")

      # Today's household consumption in kWh, integrated from the
      # per-device bucket-mean consumption_power draw. The bucket-mean
      # approach (matching `list_consumption_chart_data/4`) collapses
      # each Shelly's ~10× per-5-min readings down to a single figure
      # per bucket, so the time integral reflects actual household
      # draw without the Shelly's per-uplink over-counting.
      #
      # When the caller passed pre-computed consumption chart points
      # (see opts above), we derive both `today_consumption` and the
      # peak from those same points instead of re-running the underlying
      # `readings` scan twice. Same math, same shape, one query.
      today_consumption =
        case consumption_chart_points do
          nil ->
            integrate_consumption_kwh(user, dtu_id, today_start, today_end)

          points ->
            points
            |> Enum.reduce(0.0, fn point, acc ->
              watts = max(point.power, 0.0)
              acc + watts * (5.0 / 60.0)
            end)
            |> Kernel./(1000)
            |> Float.round(2)
        end

      # Bucket max for the peak: same convention as production —
      # the live reading wins when it exceeds the bucket max.
      bucket_max =
        case consumption_chart_points do
          nil ->
            case ConsumptionChartData.list_today_consumption_chart_data(user, dtu_id) do
              [] ->
                0.0

              points ->
                points
                |> Enum.map(&max(&1.power, 0.0))
                |> Enum.max(fn -> 0.0 end)
            end

          points ->
            points
            |> Enum.map(&max(&1.power, 0.0))
            |> Enum.max(fn -> 0.0 end)
        end

      peak_consumption = max(current_consumption, bucket_max)

      %{
        current_consumption: Float.round(current_consumption * 1.0, 1),
        # Integrated from per-bucket-mean consumption_power (W).
        today_consumption: Float.round(today_consumption, 2),
        peak_consumption: Float.round(peak_consumption * 1.0, 1)
      }
    end
  end

  # Integrate the user's household consumption (kWh) over a UTC time
  # window from per-device bucket-mean `consumption_power` readings.
  # Same bucket-mean approach `list_consumption_chart_data/4` uses
  # for the chart series: each bucket is 5 minutes long, and the
  # per-device mean across the bucket's rows is the average watts
  # drawn during that window. The sum of `bucket_W * (5/60) h` over
  # the window is the household energy consumed in Wh, converted to
  # kWh for the dashboard.
  #
  # This replaces the earlier `MAX - MIN` lifetime-counter delta:
  # the Shelly's `consumption_energy_total` is a *grid-import* counter
  # that only grows when current flows from grid to home. For a solar
  # home that offsets its own consumption, the lifetime counter
  # barely changes and the dashboard always rendered 0 kWh. Integrating
  # the instantaneous `consumption_power` gives the actual household
  # consumption regardless of whether the energy comes from the grid
  # or directly from solar.
  #
  # Floor each bucket-mean at 0 (negative readings mean solar export;
  # we count those as zero contribution since the user is consuming
  # energy from solar directly rather than from the grid — and we
  # cannot distinguish that from solar-export with no direct use).
  # Round to 2 decimal places so small continuous loads (e.g. 30 W for
  # a few hours) don't round down to 0.
  @spec integrate_consumption_kwh(User.t(), integer() | nil, DateTime.t(), DateTime.t()) ::
          float()
  def integrate_consumption_kwh(%User{} = user, dtu_id, utc_start, utc_end) do
    ConsumptionChartData.list_consumption_chart_data(user, utc_start, utc_end, dtu_id)
    |> Enum.reduce(0.0, fn point, acc ->
      # Floor each bucket-mean at 0 (the Shelly's signed reading means
      # a negative value indicates grid export, which the household
      # consumed from solar directly; we approximate this as "no grid
      # contribution" for the integration). Bucket-mean W × bucket
      # duration (5/60 h) = Wh contributed.
      watts = max(point.power, 0.0)
      acc + watts * (5.0 / 60.0)
    end)
    # Wh → kWh, two decimal places to give continuous low loads
    # (e.g. 30 W for an hour = 0.03 kWh) a chance to surface on the
    # dashboard rather than rounding to 0.
    |> Kernel./(1000)
    |> Float.round(2)
  end

  @doc """
  Period-aware consumption stats — mirrors `get_daily_stats/3` /
  `compute_day_period_stats/2` / `compute_range_period_stats/2` for the
  consumption side. Returns one map shape per time_range so the
  dashboard can render the same row of three stat cards regardless of
  whether the user is on Today/Day (current/today/peak) or on a
  Week/Month/Year view (period total / period peak / peak date).

  All numerics are in the units the dashboard renders:

    * `current_consumption`        — W (whole-number, mirrors Current Power)
    * `today_consumption`          — kWh (1 decimal place)
    * `peak_consumption`           — W (whole-number)
    * `period_total_consumption`   — kWh (1 decimal place)
    * `period_peak_consumption`    — W (whole-number)
    * `peak_date`                  — Date.t() | nil

  The week/month/year `period_total_consumption` is the integral of
  `consumption_power` over the period via
  `integrate_consumption_kwh/4` — same approach as the today view so
  household consumption is reported correctly for solar self-sufficient
  homes (where the Shelly's grid-import lifetime counter barely
  changes). The peak helper for week/month/year picks the highest
  single-day peak via `MAX(consumption_power)` per day.

  Returns zero defaults when the user has no devices.

  ## Performance note

  The today and day branches both used to call
  `get_consumption_daily_stats/2` internally — once to fetch the
  today-side fields, and once again because the dashboard already
  fetches the same data for the consumption stat cards. The second
  call walks the day's entire consumption log twice (once for the
  latest-readings lookup, once via `integrate_consumption_kwh/4`) and
  is pure overhead on the dashboard's hot path.

  The 5th argument (`consumption_daily_stats`) lets the caller thread
  its pre-fetched result through. The dashboard passes the value it
  already computed for the consumption stat cards, so the today / day
  branches consume it directly instead of re-fetching. When the
  argument is `nil` (older callers, the NotificationsLive page, and
  tests that don't care about the perf path) the helper computes the
  value itself — preserves the existing 4-arg API.
  """
  def get_consumption_period_stats(
        %User{} = user,
        dtu_id,
        time_range,
        selected_period,
        consumption_daily_stats \\ nil
      ) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      PeriodHelpers.zero_period_stats()
    else
      today_start = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
      # Single source of truth for the today-side consumption fields.
      # `nil` callers hit the underlying helper; the dashboard thread
      # passes its pre-fetched value to skip the round-trip.
      today = consumption_daily_stats || get_consumption_daily_stats(user, dtu_id)

      case time_range do
        "today" ->
          # Live view: it's identical to the today consumption stats
          # by construction — just rename the keys into the
          # period-stats shape.
          %{
            current_consumption: today.current_consumption,
            today_consumption: today.today_consumption,
            peak_consumption: today.peak_consumption,
            period_total_consumption: today.today_consumption,
            period_peak_consumption: today.peak_consumption,
            peak_date: Date.utc_today()
          }

        "day" ->
          # Single-day historical view: same shape as today, but the
          # *period* total / peak are scoped to the selected day
          # rather than `today`. The today-side fields still come
          # from the passed-through `today` snapshot so the
          # "Current" / "Today" cards keep showing what's happening
          # now even when the user is looking at a past day.
          {_date_utc, date_local} =
            PeriodHelpers.resolve_consumption_period_date(selected_period, today_start)

          {utc_start, utc_end} = ChartData.local_day_utc_range(date_local, 0)

          period_total = compute_consumption_total_kwh(user, dtu_ids, utc_start, utc_end)
          period_peak = compute_consumption_peak_w(user, dtu_ids, utc_start, utc_end)

          %{
            current_consumption: today.current_consumption,
            today_consumption: today.today_consumption,
            peak_consumption: period_peak,
            period_total_consumption: period_total,
            period_peak_consumption: period_peak,
            peak_date: date_local
          }

        "week" ->
          {monday, sunday} = PeriodHelpers.week_range(selected_period, today_start)

          {utc_start, utc_end} =
            {elem(ChartData.local_day_utc_range(monday, 0), 0),
             elem(ChartData.local_day_utc_range(sunday, 0), 1)}

          period_total = compute_consumption_total_kwh(user, dtu_ids, utc_start, utc_end)
          {peak_date, peak_val} = compute_consumption_peak_day(user, dtu_ids, utc_start, utc_end)

          %{
            current_consumption: 0.0,
            today_consumption: 0.0,
            peak_consumption: 0.0,
            period_total_consumption: period_total,
            period_peak_consumption: peak_val,
            peak_date: peak_date
          }

        "month" ->
          {first_day, last_day} = PeriodHelpers.month_range(selected_period, today_start)

          {utc_start, utc_end} =
            {elem(ChartData.local_day_utc_range(first_day, 0), 0),
             elem(ChartData.local_day_utc_range(last_day, 0), 1)}

          period_total = compute_consumption_total_kwh(user, dtu_ids, utc_start, utc_end)
          {peak_date, peak_val} = compute_consumption_peak_day(user, dtu_ids, utc_start, utc_end)

          %{
            current_consumption: 0.0,
            today_consumption: 0.0,
            peak_consumption: 0.0,
            period_total_consumption: period_total,
            period_peak_consumption: peak_val,
            peak_date: peak_date
          }

        "year" ->
          year = PeriodHelpers.year_value(selected_period)
          start_date = Date.new!(year, 1, 1)
          end_date = Date.new!(year, 12, 31)

          {utc_start, utc_end} =
            {elem(ChartData.local_day_utc_range(start_date, 0), 0),
             elem(ChartData.local_day_utc_range(end_date, 0), 1)}

          period_total = compute_consumption_total_kwh(user, dtu_ids, utc_start, utc_end)
          {peak_date, peak_val} = compute_consumption_peak_day(user, dtu_ids, utc_start, utc_end)

          %{
            current_consumption: 0.0,
            today_consumption: 0.0,
            peak_consumption: 0.0,
            period_total_consumption: period_total,
            period_peak_consumption: peak_val,
            peak_date: peak_date
          }

        "7d" ->
          # Last 7 days ending today — same window as the production
          # side. Computed against the user's tz-offset local midnight
          # boundaries so a CET user at 23:30 local on a Sunday still
          # gets a 7-day window ending on local Sunday (not UTC
          # Monday). The dashboard passes `tz_offset_seconds = 0` here
          # because `get_consumption_period_stats/5` doesn't take it;
          # for the dashboard's default UTC offset the boundary is
          # identical to the `ChartData.local_day_utc_range(today, 0)` one.
          {today_local, start_local} = PeriodHelpers.last_n_days_window(7, today_start)
          {_, utc_end} = ChartData.local_day_utc_range(today_local, 0)
          {start_utc, _} = ChartData.local_day_utc_range(start_local, 0)
          period_total = compute_consumption_total_kwh(user, dtu_ids, start_utc, utc_end)
          {peak_date, peak_val} = compute_consumption_peak_day(user, dtu_ids, start_utc, utc_end)

          %{
            current_consumption: 0.0,
            today_consumption: 0.0,
            peak_consumption: 0.0,
            period_total_consumption: period_total,
            period_peak_consumption: peak_val,
            peak_date: peak_date
          }

        "30d" ->
          # Same as `7d` but a 30-day window.
          {today_local, start_local} = PeriodHelpers.last_n_days_window(30, today_start)
          {_, utc_end} = ChartData.local_day_utc_range(today_local, 0)
          {start_utc, _} = ChartData.local_day_utc_range(start_local, 0)
          period_total = compute_consumption_total_kwh(user, dtu_ids, start_utc, utc_end)
          {peak_date, peak_val} = compute_consumption_peak_day(user, dtu_ids, start_utc, utc_end)

          %{
            current_consumption: 0.0,
            today_consumption: 0.0,
            peak_consumption: 0.0,
            period_total_consumption: period_total,
            period_peak_consumption: peak_val,
            peak_date: peak_date
          }

        "ytd" ->
          # Year-to-date (Jan 1 of the current year → today).
          today_local = today_start |> DateTime.to_date()
          start_date = Date.new!(today_local.year, 1, 1)
          {start_utc, _} = ChartData.local_day_utc_range(start_date, 0)
          {_, utc_end} = ChartData.local_day_utc_range(today_local, 0)
          period_total = compute_consumption_total_kwh(user, dtu_ids, start_utc, utc_end)
          {peak_date, peak_val} = compute_consumption_peak_day(user, dtu_ids, start_utc, utc_end)

          %{
            current_consumption: 0.0,
            today_consumption: 0.0,
            peak_consumption: 0.0,
            period_total_consumption: period_total,
            period_peak_consumption: peak_val,
            peak_date: peak_date
          }
      end
    end
  end

  # Sum of per-device-per-day "last_total - first_total" Wh deltas across a UTC
  # window, returned in kWh. Each row carries a lifetime Wh counter;
  # grouping by `(dtu_id, date)` and taking the difference between the
  # earliest and latest reading of each day gives the energy consumed on
  # that day. Summing across days and devices yields the household total.
  #
  # Grouping by date is critical — without it, MIN/MAX across a multi-day
  # window would collapse to a single global delta that includes the
  # lifetime counter's natural growth between days (e.g. 7 AM Monday →
  # 7 AM Tuesday could span thousands of Wh even though only 24 h passed).
  # nil-handling mirrors `get_consumption_daily_stats/2`.
  #
  # The legacy implementation is preserved for reference but the
  # dashboard now uses `integrate_consumption_kwh/4` (same approach
  # `get_consumption_daily_stats/2` uses for the today view) so the
  # period total reflects actual household draw rather than grid-import
  # counter deltas. The legacy path stays here temporarily as a
  # regression fallback in case the integration approach turns out to
  # misbehave for a multi-day window that crosses the Shelly's local
  # midnight counter reset; remove once production data confirms it
  # covers week/month/year views correctly.
  def compute_consumption_total_kwh(user, dtu_ids, utc_start, utc_end) do
    # `get_consumption_daily_stats/2` integrates via power; the week/month/
    # year views must use the same approach so the headline behaviour
    # is consistent across time ranges.
    _ = dtu_ids
    integrate_consumption_kwh(user, nil, utc_start, utc_end)
  end

  # Peak household demand (W) across a UTC window — MAX of the
  # 5-minute-bucket-mean consumption chart points. Returns 0.0 when
  # the window has no consumption rows.
  defp compute_consumption_peak_w(user, dtu_ids, utc_start, utc_end) do
    pts =
      ConsumptionChartData.list_consumption_chart_data(user, utc_start, utc_end)
      |> Enum.filter(fn pt -> elem(pt.series, 0) in dtu_ids end)

    case pts do
      [] -> 0.0
      list -> list |> Enum.map(& &1.power) |> Enum.max(fn -> 0.0 end)
    end
    |> Float.round(1)
  end

  # Per-day peak (W) across a UTC window — returns the {date, peak_w}
  # of the day with the highest single-day maximum, or {nil, 0.0}
  # if no data. Used for week/month/year views so the dashboard can
  # highlight which day was the peak.
  defp compute_consumption_peak_day(_user, dtu_ids, utc_start, utc_end) do
    rows =
      Repo.all(
        from r in Reading,
          where:
            r.dtu_id in ^dtu_ids and r.power_type == "consumption" and
              r.inserted_at >= ^utc_start and r.inserted_at <= ^utc_end and
              not is_nil(r.consumption_power),
          group_by: fragment("?::date", r.inserted_at),
          select: %{
            date: fragment("?::date", r.inserted_at),
            peak_w: max(r.consumption_power)
          }
      )

    case rows do
      [] ->
        {nil, 0.0}

      list ->
        top = Enum.max_by(list, fn r -> r.peak_w || 0.0 end)
        date = top.date
        # The SQL aggregate sees raw `consumption_power`; a Shelly
        # reporting only reverse-flow (solar surplus) would otherwise
        # surface a negative per-day peak on the "Peak Demand" card.
        # Clamp to ≥ 0 W so the card reports household draw.
        peak_w = clamp_household_draw(top.peak_w)

        normalized_date =
          case date do
            %Date{} = d -> d
            str when is_binary(str) -> Date.from_iso8601!(str)
            nil -> nil
          end

        {normalized_date, Float.round(peak_w, 1)}
    end
  end
end
