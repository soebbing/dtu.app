defmodule DtuApp.Devices.Stats.ProductionStats do
  @moduledoc """
  Production-side aggregations: current AC power, today's yield,
  lifetime yield, peak power & time, per-inverter breakdown,
  self-consumption percentage.

  Read paths prefer the `readings_daily` continuous aggregate where
  possible and the live `readings` tail where it isn't. The two big
  functions are `get_daily_stats/4` (today's headline stats for the
  dashboard's stat cards) and `compute_peak_watts_in_period/4`
  (the highest 5-min-bucket-mean wattage within an arbitrary UTC
  window, used by day / week / month / year views).

  `compute_self_consumption_pct/4` reads both production-side
  (yield_day) and consumption-side (signed consumption_power)
  metering; the consumption-side integration is private to this
  module as `integrate_export_kwh/4`.

  The returned struct carries a `has_readings: boolean` field —
  true iff at least one row exists in `readings` for any of the
  user's `dtu_ids` within `[today_start, today_end]` (any
  `mppt_index`). This is the canonical "did the user publish any
  reading today?" signal that downstream predicates (notably
  `Notifications.SunDown.Payload.build_payload/3`) consume; it
  intentionally does NOT filter on `mppt_index = 0` because some
  firmware (AhoyDTU's per-MPPT-only config) never synthesises the
  AC aggregate row, and the older `per_series == []`-based
  predicate would otherwise fire a misleading "Your devices haven't
  reported any readings today" history row for those fleets.

  Re-exported through `DtuApp.Devices.Stats` via `defdelegate` so
  existing call sites continue to work unchanged.
  """

  import Ecto.Query

  alias DtuApp.Accounts.User
  alias DtuApp.Devices.ChartData
  alias DtuApp.Devices.Reading
  alias DtuApp.Repo

  import DtuApp.Devices.ChartHelpers,
    only: [owned_dtu_ids: 2, bucket_max_from_chart_points: 1]

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

  @doc """
  Variant of `get_daily_stats/3` that treats `local_date` as the
  USER'S local calendar date and translates it to the inclusive
  UTC range `[00:00 local, 23:59:59 local]` via
  `ChartData.local_day_utc_range/2`. Used by the SunDown notifier
  (so a CEST user's "today" maps to UTC [Sep 14 22:00, Sep 15
  21:59]) and the dashboard stat card (same reasoning — see
  `DtuAppWeb.SharedDashboardLive`).

  Without this variant, callers that pass a UTC date end up with
  a midnight-to-midnight-UTC window that misses the early-morning
  hours of a positive-UTC-offset user's local day (or, for
  negative-UTC-offset users, the late-evening hours of their local
  day). The existing `get_daily_stats/3` keeps the UTC-date
  semantics for callers that genuinely want that window (e.g.
  the share/heatmap pages that key off UTC calendar days).

  `current_power` and `peak_power` are still computed against the
  present instant — they only make sense for the live day — but
  `today_yield` and `total_yield` reflect the local day so we can
  compare day-over-day in the user's timezone.
  """
  def get_daily_stats_for_local_day(
        %User{} = user,
        dtu_id,
        %Date{} = local_date,
        tz_offset_seconds
      )
      when is_integer(tz_offset_seconds) do
    {utc_start, utc_end} = ChartData.local_day_utc_range(local_date, tz_offset_seconds)
    impl_get_daily_stats_for_range(user, dtu_id, utc_start, utc_end, [])
  end

  defp impl_get_daily_stats(%User{} = user, dtu_id, %Date{} = date, pre_fetched_chart_points)
       when is_list(pre_fetched_chart_points) do
    # The 3-arity UTC-date path: build the [00:00 UTC, 23:59:59 UTC]
    # window from the date and forward to the range-based impl.
    # The local-date variant (`get_daily_stats_for_local_day/4`)
    # computes its own UTC range via
    # `ChartData.local_day_utc_range/2` so the two paths share the
    # same SELECT/WHERE clauses below.
    utc_start = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    utc_end = DateTime.new!(date, ~T[23:59:59], "Etc/UTC")
    impl_get_daily_stats_for_range(user, dtu_id, utc_start, utc_end, pre_fetched_chart_points)
  end

  defp impl_get_daily_stats_for_range(
         %User{} = user,
         dtu_id,
         utc_start,
         utc_end,
         pre_fetched_chart_points
       )
       when is_list(pre_fetched_chart_points) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      %{
        current_power: 0.0,
        today_yield: 0.0,
        total_yield: 0.0,
        peak_power: 0.0,
        peak_time: nil,
        per_series: [],
        # Has ANY reading been written for this user inside today's
        # window? `false` is the correct answer when the user owns
        # no devices — there's no row that could match. The
        # predicate in `Notifications.SunDown.Payload.build_payload/3`
        # short-circuits to `nil` when this is `false`, which is
        # what suppresses the "no readings today" history row for
        # users with no devices. (See
        # `silent drop when build_payload/2 returns nil` in
        # `sun_down_notifier_test.exs`.)
        has_readings: false
      }
    else
      # "Recent" reads against `readings.inserted_at`, which is written
      # via `DtuApp.Time.utc_now_usec/0`. Use the same DB clock for the
      # cutoff so a drifted app clock doesn't artificially age out fresh
      # rows (or vice versa).
      two_minutes_ago = DtuApp.Time.utc_now() |> DateTime.add(-120, :second)

      # `utc_start` / `utc_end` are passed in by the caller — the
      # UTC-date variant (`impl_get_daily_stats/4`) builds a
      # midnight-to-midnight-UTC window from `date`, the local-date
      # variant (`get_daily_stats_for_local_day/4`) builds a
      # local-midnight-to-local-midnight window via
      # `ChartData.local_day_utc_range/2`. Either way, these are the
      # bounds the DISTINCT ON + chart-points queries use below.
      today_start = utc_start
      today_end = utc_end

      # `has_readings` is the canonical "did this user publish any
      # reading inside today's window?" signal — consumed by
      # `Notifications.SunDown.Payload.build_payload/3`'s predicate
      # so the producer doesn't write a misleading
      # "Your devices haven't reported any readings today"
      # history row for fleets whose firmware only emits per-MPPT
      # rows (`mppt_index >= 1`) and never the synthesised AC
      # aggregate row (`mppt_index = 0`). Unlike `per_series` —
      # which is built off `ac_latest_per_inverter`'s DISTINCT ON
      # with an `mppt_index = 0` filter — this check is
      # mppt_index-agnostic and `inverter_serial`-agnostic (a
      # legacy `_fleet` row still counts as a reading; that path
      # has its own data-shape consequences but a silent-drop is
      # strictly worse than a noisy day-zero entry).
      #
      # The query is bounded on both `dtu_id` (via the `in ^dtu_ids`
      # list, which the planner turns into an index seek per id)
      # AND on `inserted_at` (via the day's `[today_start,
      # today_end]` window, which keeps the scan inside a single
      # hypertable chunk). Postgres' native `EXISTS` short-circuits
      # on the first match — the planner never walks the whole
      # chunk even if the user has thousands of readings today.
      has_readings =
        Repo.exists?(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and
                r.inserted_at >= ^today_start and r.inserted_at <= ^today_end
        )

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
          end),

        # Mppt_index-agnostic "any readings today?" flag. See the
        # `has_readings` query above for the rationale (per-MPPT
        # fleets with no synthesised AC aggregate row would
        # otherwise trip the `per_series == []` predicate in
        # `Notifications.SunDown.Payload.build_payload/3`).
        has_readings: has_readings
      }
    end
  end

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
end
