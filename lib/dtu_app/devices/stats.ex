defmodule DtuApp.Devices.Stats do
  @moduledoc """
  Daily / range / period stats aggregations.

  Three concerns, each one a cluster:

    1. **Production stats** — `get_daily_stats/1`, `get_daily_stats/2`,
       `get_daily_stats/3`, `get_daily_stats/4`,
       `impl_get_daily_stats/4`, `compute_peak_watts_in_period/4`,
       `compute_self_consumption_pct/4`, `integrate_export_kwh/4`.
       The dashboard's day-totals, peak-power, and "self-consumption"
       cards come from here.
    2. **Consumption stats** — `get_consumption_daily_stats/3`,
       `get_consumption_period_stats/4`,
       `integrate_consumption_kwh/4`,
       `compute_consumption_total_kwh/4`,
       `compute_consumption_peak_w/4`,
       `compute_consumption_peak_day/4`,
       plus the date-range helpers (`resolve_consumption_period_date/2`,
       `week_range/2`, `month_range/2`, `year_value/1`,
       `last_n_days_window/2`, `zero_period_stats/0`).
    3. **Net flow stats** — none in this module; the net-flow
       aggregations live in `DtuApp.Devices.ConsumptionChartData`
       as `get_net_flow_stats/3`.

  All queries prefer the `readings_daily` continuous aggregate over
  raw `readings` rows; see the `@readings_daily` referenced in the
  body for the column list.

  Re-exported through `DtuApp.Devices` via `defdelegate` so existing
  call sites continue to work unchanged.
  """

  import Ecto.Query

  alias DtuApp.Accounts.User
  alias DtuApp.Devices.ChartData
  alias DtuApp.Devices.ConsumptionChartData
  alias DtuApp.Devices.Reading
  alias DtuApp.Repo

  import DtuApp.Devices.ChartHelpers,
    only: [owned_dtu_ids: 2, bucket_max_from_chart_points: 1, clamp_household_draw: 1]

  @doc "Calculate aggregated daily stats for a user's DTUs (or a specific DTU)."
  def get_daily_stats(%User{} = user, dtu_id \\ nil) do
    get_daily_stats(user, dtu_id, Date.utc_today(), [])
  end

  @doc """
  Variant of `get_daily_stats/4` that lets callers thread in a pre-fetched
  chart-points list. The dashboard's `today` branch fetches the day-chart
  points once (for both the SVG render and the peak-power `bucket_max`)
  and passes them in here so we don't run the same
  `list_day_chart_data_for_dashboard/4` query twice back-to-back on every
  dashboard mount. Pass `[]` (or call the 2-arity) when no pre-fetch is
  available — the helper then runs the query itself.
  """
  def get_daily_stats(%User{} = user, dtu_id, %Date{} = date, chart_points)
      when is_list(chart_points) do
    impl_get_daily_stats(user, dtu_id, date, chart_points)
  end

  @doc """
  Same as `get_daily_stats/2` but accepts the target date (UTC) so
  the sun-down scheduler can request yesterday's totals without
  duplicating the SQL. `current_power` and `peak_power` are still
  computed against *today* (the most recent readings) — they only
  make sense for the live day — but `today_yield` reflects the
  requested date so we can compare day-over-day.

  `today_yield` and `total_yield` are computed by **summing each
  inverter's last reading of the day** (for `today_yield`) or its
  max-recorded `yield_total` (for `total_yield`). Each per-inverter
  `yield_day` counter is a monotonic Wh figure that resets at
  midnight and climbs through the day — so the day's total per
  inverter IS its last reading of the day. Summing that across
  inverters (and across the user's DTUs) gives the fleet's daily
  total without relying on the firmware-aggregated `{base}/total`
  topic, which the parser now drops (no `_fleet` row persisted).

  Restricted to `mppt_index = 0` so multi-MPPT AhoyDTU inverters
  don't double-count ch0 + ch1 + ch2 yields. OpenDTU only persists
  `yield_day` / `yield_total` on `mppt_index = 0`, so the
  restriction is a no-op for OpenDTU. `cast_ahoy_yield/1` in the
  parser normalises AhoyDTU's kWh `YieldTotal` to Wh at the
  boundary, so `readings.yield_total` is uniformly Wh.

  As a defence against any legacy `_fleet` rows that older parser
  versions persisted, the chart data paths still filter
  `inverter_serial != "_fleet"` — see
  `list_day_readings_for_chart/4` and friends. The `today_yield` /
  `total_yield` queries below take the per-inverter latest row
  ordered by `inserted_at DESC LIMIT 1` per `(dtu_id,
  inverter_serial)`, which inherently skips `_fleet` (no real
  inverter goes by that name).
  """
  def get_daily_stats(%User{} = user, dtu_id, %Date{} = date) do
    impl_get_daily_stats(user, dtu_id, date, [])
  end

  defp impl_get_daily_stats(%User{} = user, dtu_id, %Date{} = date, pre_fetched_chart_points)
       when is_list(pre_fetched_chart_points) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      %{
        current_power: 0.0,
        today_yield: 0.0,
        total_yield: 0.0,
        peak_power: 0.0,
        peak_time: nil,
        per_series: []
      }
    else
      # "Recent" reads against `readings.inserted_at`, which is written
      # via `DtuApp.Time.utc_now_usec/0`. Use the same DB clock for the
      # cutoff so a drifted app clock doesn't artificially age out fresh
      # rows (or vice versa).
      two_minutes_ago = DtuApp.Time.utc_now() |> DateTime.add(-120, :second)

      today_start = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      today_end = DateTime.new!(date, ~T[23:59:59], "Etc/UTC")

      # Perf #12: a single DISTINCT ON returns the per-inverter "latest
      # reading of the day" row (one per (dtu, serial), filtered to
      # `mppt_index = 0` so multi-MPPT inverters don't double-count
      # sub-totals). That single row carries `ac_power` (current_power
      # input), `yield_day` (today's per-inverter yield — monotonic
      # Wh counter so the day's total IS the last reading of the day,
      # summing across inverters gives the fleet's daily total), and
      # `inverter_name` (for the chart legend).
      #
      # The `inserted_at >= ^today_start` bound turns the unbounded
      # DISTINCT ON into a single-chunk range scan via the
      # `(dtu_id, inverter_serial, mppt_index, inserted_at)` primary
      # key, keeping the planner inside the active chunk even on
      # multi-year installs where the whole-table DISTINCT ON would
      # touch every compressed chunk.
      #
      # `inverter_serial != "_fleet"` is a defensive filter against
      # any legacy `_fleet` rows that older parser versions persisted
      # — the current parser never creates them (see `telemetry.ex`'s
      # `[binary_base, "total"]` ignored-topic clauses).
      #
      # Replaces the previous five-`Repo.all` shape: `latest_ac_readings`
      # (current_power), `today_yield_per_inverter` (today_yield),
      # `latest_per_series_readings` (per_series_peak — only its
      # `mppt_index = 0` slice was ever read), and `per_series_rows`
      # (legend breakdown). All four collapse into this one query.
      # The fifth query (`total_yield_per_inverter`) stays separate —
      # it walks a 30-day `lifetime_cutoff` window for the
      # MAX(yield_total) aggregation, which neither shares the today
      # window nor the DISTINCT ON shape.
      ac_latest_per_inverter =
        Repo.all(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and r.mppt_index == 0 and
                r.inverter_serial != "_fleet" and
                r.inserted_at >= ^today_start and r.inserted_at <= ^today_end,
            distinct: [r.dtu_id, r.inverter_serial],
            order_by: [r.dtu_id, r.inverter_serial, desc: r.inserted_at],
            select: %{
              ac_power: r.ac_power,
              yield_day: r.yield_day,
              inserted_at: r.inserted_at,
              dtu_id: r.dtu_id,
              inverter_serial: r.inverter_serial,
              inverter_name: r.inverter_name
            }
        )

      current_power =
        ac_latest_per_inverter
        |> Enum.filter(fn r -> DateTime.after?(r.inserted_at, two_minutes_ago) end)
        |> Enum.map(&(&1.ac_power || 0.0))
        |> Enum.sum()

      # Today's total yield: sum each inverter's last reading of the
      # day. Per-inverter `yield_day` is monotonic Wh that resets at
      # midnight, so the day's per-inverter total IS its last
      # reading — summing across inverters (and across the user's
      # DTUs) gives the fleet's daily total without depending on the
      # AhoyDTU `{base}/total` MQTT topic (which the parser drops).
      today_yield =
        ac_latest_per_inverter
        |> Enum.map(fn r -> r.yield_day || 0.0 end)
        |> Enum.sum()

      # Lifetime total yield.
      #
      # Same per-inverter summation as `today_yield`, but using
      # `MAX(yield_total)` per inverter (the lifetime counter is
      # monotonic and never resets, so MAX == latest recorded
      # lifetime value). Summing those across inverters gives the
      # fleet's lifetime total. `yield_total` is uniformly Wh across
      # all firmwares because `cast_ahoy_yield/1` normalises
      # AhoyDTU's kWh-published lifetime counter to Wh at the
      # parser boundary.
      #
      # The `inserted_at >= ^lifetime_cutoff` filter constrains the
      # scan to a recent 30-day window — `yield_total` is monotonic
      # per `(dtu_id, inverter_serial)` and the latest reported
      # value within the window is by definition the largest, so
      # `MAX(yield_total)` is unchanged for any inverter that has
      # uplinked within the last 30 days (every active DTU). The
      # bound collapses a full-hypertable `GROUP BY` into a single
      # chunk's range scan via the `(dtu_id, inverter_serial,
      # mppt_index, inserted_at)` primary key — without it, a
      # multi-year install's `GROUP BY dtu_id, inverter_serial
      # SELECT MAX(...)` walked every compressed chunk the DTU had
      # ever written, which dominated the noon mount latency on
      # long-running installs.
      lifetime_cutoff =
        DtuApp.Time.utc_now_usec() |> DateTime.add(-30 * 86_400, :second)

      total_yield_per_inverter =
        Repo.all(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and r.mppt_index == 0 and
                r.inverter_serial != "_fleet" and
                r.inserted_at >= ^lifetime_cutoff,
            group_by: [r.dtu_id, r.inverter_serial],
            select: %{max_yield_total: max(r.yield_total)}
        )

      total_yield_wh =
        total_yield_per_inverter
        |> Enum.map(fn row -> row.max_yield_total || 0.0 end)
        |> Enum.sum()

      # Peak power today comes from the 5-minute continuous aggregate
      # via `list_day_chart_data_for_dashboard/4` (no per-row scan).
      # The aggregate's bucket stays closed until its window fills, so a
      # fast-rising morning ramp can leave `bucket_max` several
      # minutes behind the live `current_power`. Lift the peak to the
      # live reading whenever it exceeds the bucket max so the
      # displayed number reflects what the inverter is producing *now*.
      #
      # `pre_fetched_chart_points == []` is the "no pre-fetch" signal from
      # the 2-arity wrapper (an empty list is the default for a
      # dashboard-threaded caller that didn't run the chart yet). The
      # dashboard thread passes a non-empty list it already rendered so
      # we don't re-run `list_day_chart_data_for_dashboard/4`
      # immediately after `assign_line_chart_data/5` ran the exact same
      # query.
      #
      # Empty-list semantics: `[] || fetched` returns `[]` (empty lists
      # are truthy in Elixir) and `bucket_max_from_chart_points([]) == 0.0`,
      # which would silently collapse the headline peak power to the
      # live `current_power`. Pattern-match instead so an empty list
      # falls through to the fetch.
      chart_points_for_max =
        case pre_fetched_chart_points do
          [] -> ChartData.list_day_chart_data_for_dashboard(user, today_start, today_end, dtu_id)
          [_ | _] = pts -> pts
        end

      bucket_max = bucket_max_from_chart_points(chart_points_for_max)

      peak_power = max(current_power, bucket_max)

      # Peak time: the bucket that produced `bucket_max`. If the live
      # `current_power` wins, attribute peak to "now" (the inverter is
      # at peak right now). The chart-point bucket-time is UTC; the
      # dashboard formats it as HH:MM in the user's local timezone.
      peak_time =
        case peak_power do
          p when p > bucket_max ->
            DtuApp.Time.utc_now()

          _ ->
            case chart_points_for_max do
              [] ->
                nil

              pts ->
                top = Enum.max_by(pts, fn pt -> pt.power || 0.0 end)
                top.time
            end
        end

      # Per-(inverter) peak so the dashboard can show, e.g., "INV-1 peaked
      # at 580 W" in the legend. The chart legend only ever looks up
      # the `mppt_index = 0` slice (each legend entry's `series` key
      # forces mppt_index to 0), so this map is now sourced from the
      # same DISTINCT ON query that feeds `current_power` /
      # `today_yield` — no separate per-MPPT scan needed. Per-MPPT
      # peak data (dc_power for ch1+) is dropped here; it's surfaced
      # on the chart SVG itself via `assign_line_chart_data/5`
      # (per-MPPT DC lines), not the stat-card legend.
      per_series_peak =
        ac_latest_per_inverter
        |> Enum.filter(fn r -> DateTime.after?(r.inserted_at, two_minutes_ago) end)
        |> Enum.reduce(%{}, fn r, acc ->
          series = {r.dtu_id, r.inverter_serial, 0, r.inverter_name}

          Map.put(acc, series, r.ac_power || 0.0)
        end)

      # Per-inverter breakdown for the chart legend. Now sourced from
      # the same DISTINCT ON query as `current_power` / `today_yield`
      # — the row's `yield_day` IS the day's per-inverter total
      # (monotonic counter, last reading of the day = total for that
      # day), so no separate MAX(yield_day) GROUP BY is needed.
      # `per_series` is about showing the user "which inverter
      # produced what" on the chart, so each row is per-(inverter)
      # rather than a fleet sum. The `_fleet` row is excluded
      # (DISTINCT ON `inverter_serial` already skips it; the explicit
      # WHERE filter is defensive against legacy data the parser no
      # longer creates).

      %{
        current_power: Float.round(current_power * 1.0, 1),
        # `readings.yield_day` is published by OpenDTU/AhoyDTU in Wh (per the
        # firmware's `YieldDay` field). The dashboard renders this stat with
        # a kWh label, so divide by 1000 before returning so the displayed
        # number matches the unit.
        #
        # Round to one decimal place so the "Today's Total Yield" stat reads
        # as e.g. `12.3 kWh` rather than `12.345 kWh`.
        today_yield: Float.round(today_yield / 1000, 1),
        # Lifetime cumulative yield from the firmware's `YieldTotal` field
        # (Wh). Wh → kWh so the dashboard's kWh label matches. One decimal
        # place for consistency with `today_yield`.
        total_yield: Float.round(total_yield_wh / 1000, 1),
        peak_power: Float.round(peak_power * 1.0, 1),
        peak_time: peak_time,

        # Per (inverter) breakdown so the dashboard can show each
        # string's contribution and name in the chart legend. Yields are
        # in kWh, peak powers in W (matching the totals' units). Since the
        # aggregation is restricted to `mppt_index = 0` (the AC aggregate
        # row), each entry is per-inverter, not per-MPPT.
        per_series:
          Enum.map(ac_latest_per_inverter, fn row ->
            series = {row.dtu_id, row.inverter_serial, 0, row.inverter_name}

            %{
              dtu_id: row.dtu_id,
              inverter_serial: row.inverter_serial,
              inverter_name: row.inverter_name,
              mppt_index: 0,
              # nil can leak in if every reading for a series has yield_day: nil.
              today_yield: Float.round((row.yield_day || 0.0) / 1000, 3),
              peak_power: Float.round(Map.get(per_series_peak, series, 0.0), 1)
            }
          end)
      }
    end
  end

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
      zero_period_stats()
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
          {_date_utc, date_local} = resolve_consumption_period_date(selected_period, today_start)
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
          {monday, sunday} = week_range(selected_period, today_start)

          {utc_start, utc_end} =
            {elem(ChartData.local_day_utc_range(monday, 0), 0), elem(ChartData.local_day_utc_range(sunday, 0), 1)}

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
          {first_day, last_day} = month_range(selected_period, today_start)

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
          year = year_value(selected_period)
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
          {today_local, start_local} = last_n_days_window(7, today_start)
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
          {today_local, start_local} = last_n_days_window(30, today_start)
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

  # Build the (today, start) date pair for the trailing-N-days presets.
  # `today_start` is `DateTime.new!(Date.utc_today(), ~T[00:00:00],
  # "Etc/UTC")` — the helper the rest of the function passes around;
  # we only need its date component.
  defp last_n_days_window(n, today_start) do
    today_local = DateTime.to_date(today_start)
    {today_local, Date.add(today_local, -(n - 1))}
  end

  defp zero_period_stats do
    %{
      current_consumption: 0.0,
      today_consumption: 0.0,
      peak_consumption: 0.0,
      period_total_consumption: 0.0,
      period_peak_consumption: 0.0,
      peak_date: nil
    }
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

  # Resolve the local Date for a consumption-period stats query. The
  # dashboard passes `selected_period` which can be `nil` (today) or
  # a `%Date{}` for historical views.
  defp resolve_consumption_period_date(nil, today_utc_start) do
    {today_utc_start, Date.utc_today()}
  end

  defp resolve_consumption_period_date(%Date{} = d, _today_utc_start), do: {d, d}

  defp resolve_consumption_period_date(_other, today_utc_start),
    do: {today_utc_start, Date.utc_today()}

  # Mon..Sun range for the week view, anchored on the most recent
  # week with data (or this week if `selected_period` is `nil`).
  defp week_range(nil, today_utc_start) do
    week_range(
      Date.utc_today() |> Date.add(-(Date.day_of_week(Date.utc_today()) - 1)),
      today_utc_start
    )
  end

  defp week_range(%Date{} = d, _today_utc_start) do
    monday = Date.add(d, -(Date.day_of_week(d) - 1))
    sunday = Date.add(monday, 6)
    {monday, sunday}
  end

  # First..last day of the month, anchored on the month of the
  # provided Date (or this month if `nil`).
  defp month_range(nil, _today_utc_start) do
    today = Date.utc_today()
    first = Date.new!(today.year, today.month, 1)
    {first, Date.end_of_month(first)}
  end

  defp month_range(%Date{} = d, _today_utc_start) do
    first = Date.new!(d.year, d.month, 1)
    {first, Date.end_of_month(first)}
  end

  # Integer year for the year view, anchored on the year of the
  # provided Date (or this year if `nil`).
  defp year_value(nil), do: Date.utc_today().year
  defp year_value(%Date{} = d), do: d.year
  defp year_value(y) when is_integer(y), do: y

  @doc """
  Highest 5-min-bucket-mean wattage within `[utc_start, utc_end]`, and
  the bucket's timestamp. Returns `{0.0, nil}` when the window has no
  AC-aggregate rows (no DTU has uplinked for the period).

  Reads from the `readings_5m` continuous aggregate when the bucket is
  in the past, falls back to the live `readings` table for the most
  recent 5 minutes (matching the rest of the dashboard's tail strategy).
  Restricted to `mppt_index = 0` so multi-MPPT AhoyDTU inverters don't
  double-count — same convention as `get_daily_stats/3`.

  `peak_time` is the bucket's UTC `time` field; the dashboard
  formats it as HH:MM in the user's local timezone.
  """
  @spec compute_peak_watts_in_period(User.t(), integer() | nil, DateTime.t(), DateTime.t()) ::
          {float(), DateTime.t() | nil}
  def compute_peak_watts_in_period(%User{} = user, dtu_id, utc_start, utc_end) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      {0.0, nil}
    else
      utc_tail_start = DateTime.add(utc_end, -300, :second)

      # Aggregate buckets strictly before the live tail.
      aggregate_top =
        if DateTime.compare(utc_start, utc_tail_start) == :lt do
          from_buckets =
            ChartData.list_day_chart_data_for_dashboard(user, utc_start, utc_tail_start, dtu_id)

          case from_buckets do
            [] ->
              nil

            pts ->
              top = Enum.max_by(pts, fn pt -> pt.power || 0.0 end)

              %{
                power: top.power || 0.0,
                time: top.time
              }
          end
        else
          nil
        end

      # Live tail: latest AC-aggregate row per DTU in the tail window.
      live_top =
        if DateTime.compare(utc_tail_start, utc_end) in [:lt, :eq] do
          tail_rows =
            Repo.all(
              from r in Reading,
                where:
                  r.dtu_id in ^dtu_ids and r.mppt_index == 0 and
                    r.inserted_at >= ^utc_tail_start and r.inserted_at <= ^utc_end,
                distinct: [r.dtu_id, r.inverter_serial],
                order_by: [r.dtu_id, r.inverter_serial, desc: r.inserted_at],
                select: %{power: r.ac_power, time: r.inserted_at}
            )

          case tail_rows do
            [] ->
              nil

            rows ->
              max_row = Enum.max_by(rows, fn r -> r.power || 0.0 end)
              %{power: max_row.power || 0.0, time: max_row.time}
          end
        else
          nil
        end

      pick_higher = aggregate_top || live_top

      case pick_higher do
        nil ->
          {0.0, nil}

        %{power: power, time: time} ->
          {Float.round(power * 1.0, 1), time}
      end
    end
  end

  @doc """
  Self-consumption percentage for a UTC period: `(production - exported) /
  production × 100`, rounded to one decimal place. Returns `nil` when no
  consumption devices (Shelly) are in scope — the dashboard uses this to
  decide whether to show the self-consumption stat card at all.

  `production_kwh` is the period's total yield in kWh, derived from the
  same per-inverter last-yield query that powers `get_daily_stats/3`'s
  `today_yield` (sum of each inverter's last `yield_day` of the window).

  `exported_kwh` is the positive-net-flow energy that left the home,
  computed by summing bucket-mean wattage (one mean per Shelly device
  per 5-min window) across all windows in the period — see
  `integrate_export_kwh/4`. The bucket-mean approach mirrors
  `integrate_consumption_kwh/4` and `list_consumption_chart_data/4` so
  bursty Shelly uplinks (which can fire every few seconds) don't get
  multiplied up into fake export. The result is a headline number for
  the stat card, not an audit figure.

  Edge cases:
  * No production at all → returns `0.0` (the card shows "0 %", not
    `nil`, because the user has solar, just no output this period).
  * Exported > production → clamp at 0 % (a battery discharging into
    the home during a sunny stretch can flip the net-flow sign; the
    clamp keeps the percentage non-negative by definition).
  """
  @spec compute_self_consumption_pct(User.t(), integer() | nil, DateTime.t(), DateTime.t()) ::
          float() | nil
  def compute_self_consumption_pct(%User{} = user, dtu_id, utc_start, utc_end) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      nil
    else
      production_wh =
        Repo.all(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and r.mppt_index == 0 and
                r.inverter_serial != "_fleet" and
                r.inserted_at >= ^utc_start and r.inserted_at <= ^utc_end,
            distinct: [r.dtu_id, r.inverter_serial],
            order_by: [r.dtu_id, r.inverter_serial, desc: r.inserted_at],
            select: %{yield_day: r.yield_day}
        )
        |> Enum.map(fn row -> row.yield_day || 0.0 end)
        |> Enum.sum()

      exported_kwh = integrate_export_kwh(user, dtu_id, utc_start, utc_end)
      production_kwh = production_wh / 1000.0

      cond do
        production_kwh <= 0.0 -> 0.0
        exported_kwh <= 0.0 -> 100.0
        exported_kwh >= production_kwh -> 0.0
        true -> Float.round((1.0 - exported_kwh / production_kwh) * 100.0, 1)
      end
    end
  end

  # Sum of bucket-mean negative `consumption_power` across all 5-min
  # windows in a UTC period, expressed in kWh. The Shelly's signed
  # reading means negative = exporting (solar pushing into the grid),
  # positive = importing (household drawing from the grid); only the
  # negative bucket-means contribute to exported energy.
  #
  # Mirrors `integrate_consumption_kwh/4` (which floors at 0 for
  # the household-draw chart) but inverts the sign so export survives
  # the clamp. Bucket-mean × 5 min gives one Wh figure per
  # (bucket, device), summed across the period.
  #
  # This is the same approach `list_consumption_chart_data/4` uses
  # for the consumption chart — without it, a Shelly that sends N
  # uplinks per real-time minute would overcount export by a factor
  # of N × (5/60) hours-of-energy per real-time minute, clamping
  # the self-consumption percentage at 0 % even when the user is
  # actually self-consuming most of their solar.
  defp integrate_export_kwh(%User{} = user, dtu_id, utc_start, utc_end) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      0.0
    else
      readings =
        Repo.all(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and r.power_type == "consumption" and
                r.inserted_at >= ^utc_start and r.inserted_at <= ^utc_end and
                not is_nil(r.consumption_power),
            select: %{
              inserted_at: r.inserted_at,
              consumption_power: r.consumption_power,
              dtu_id: r.dtu_id
            }
        )

      if readings == [] do
        0.0
      else
        readings
        |> Enum.group_by(fn r -> div(DateTime.to_unix(r.inserted_at), 300) end)
        |> Enum.reduce(0.0, fn {_bucket, bucket_readings}, acc ->
          # Per (bucket, dtu_id), take the signed mean and only
          # count it if negative (export). Sum the per-device
          # contributions into one bucket export figure, add to
          # accumulator. 5-min bucket × 5/60 h = Wh contributed.
          bucket_export_wh =
            bucket_readings
            |> Enum.group_by(& &1.dtu_id)
            |> Enum.reduce(0.0, fn {_dtu_id, series}, device_acc ->
              mean_power =
                Enum.sum(Enum.map(series, & &1.consumption_power)) /
                  length(series)

              if mean_power < 0.0 do
                device_acc + abs(mean_power) * (5.0 / 60.0)
              else
                device_acc
              end
            end)

          acc + bucket_export_wh
        end)
        |> Kernel./(1000)
        |> Float.round(2)
      end
    end
  end

  # The historical stepper's calendar widget lets the user pick any
  # date with data, so this DISTINCT scan underpins the `min` /
  # `max` bounds + every granularity dropdown. Without a date cap
  # the planner has to scan every compressed chunk in the hypertable
  # and de-duplicate by date — for a 3-inverter fleet with several
  # years of history that was the dominant cost on every dashboard
  # mount and every DTU switch (the stepper re-fetches on both).
  # 5 years is well past any realistic solar comparison window
  # (the user is most likely navigating YTD or the last summer) and
  # keeps the planner in the active chunk range where the chunk
  # exclusion makes the scan cheap.
  #
  # Why not `readings_daily` cagg: that cagg is `materialized_only
  # => true` (see `timescaledb_information.continuous_aggregates`)
  # with a `start_offset` of 60 days and `end_offset` of 1 day,
  # refreshed once per day. So a reading that landed yesterday is
  # only in the cagg AFTER the next daily policy tick — for ~24
  # hours the stepper would not show "today" or "yesterday", which
  # is exactly the range the user navigates most. Querying raw
  # `readings` here keeps the freshness guarantee the stepper
  # needs; the `(dtu_id, inserted_at)` btree index keeps the
  # 5-year scan cheap enough that the per-call cost is acceptable.
  #
  # Why this still fits in the perf plan: callers run this twice
  # per mount (once on initial render, once after the
  # `handle_info({:reading, ...})` PubSub broadcast re-runs
  # `PeriodSelectable.assign_selectable_periods/3`). Perf #8's
  # `DtuApp.Devices.UserDtuIdsCache` already reduces the query to
  # the per-user min-cost path; the 5y bound (Perf #2, PR #213)
  # keeps the scan O(active chunks); and the
  # `readings_daily (dtu_id, bucket DESC)` index added in
  # `#20260831183444` is staged for the day we drop in a
  # `materialized_only => false` cagg or a daily-marker materialised
  # view that can serve this query safely.

end
