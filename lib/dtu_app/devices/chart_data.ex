defmodule DtuApp.Devices.ChartData do
  @moduledoc """
  Day-boundary chart data queries.

  Reads for the "today" view (the live / 30-min tail) live in
  `DtuApp.Devices.ConsumptionChartData`. Range reads (e.g. a
  user-selected local-day window) live here.

  Two distinct shapes live in this module:

    1. **Raw-reading lookups** (`list_day_readings_for_chart/4`) —
       the per-inverter rows the dashboard uses to bucket per-MPPT
       series.
    2. **Bucketed chart points** (`list_day_chart_data/4`,
       `list_day_chart_data_for_dashboard/4`,
       `list_yesterday_chart_data_for_dashboard/4`) — the
       5-minute-bucketed `[{time, series, power}]` shape that the
       SVG chart renders. The `live_tail_bucketed_chart_points/3`
       helper backs the "recent" tail on the today view.

  Re-exported through `DtuApp.Devices` via `defdelegate` so existing
  call sites continue to work unchanged.
  """

  import Ecto.Query

  alias DtuApp.Accounts.User
  alias DtuApp.Devices.Reading
  alias DtuApp.Repo

  import DtuApp.Devices.ChartHelpers, only: [owned_dtu_ids: 2, chart_power_for_mppt: 1]

  @doc """
  Fetch all readings for the user's DTUs whose `inserted_at` falls within
  the inclusive UTC range `[utc_start, utc_end]`. Use `local_day_utc_range/2`
  to translate a user-facing local date into a UTC range before calling.
  """
  def list_day_readings_for_chart(%User{} = user, utc_start, utc_end, dtu_id \\ nil)
      when is_struct(utc_start, DateTime) and is_struct(utc_end, DateTime) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      []
    else
      Repo.all(
        from r in Reading,
          # Filter to production-side rows so a paired Shelly Plus
          # 3EM (which writes rows with `inverter_serial: "em:0"`
          # and `power_type: "consumption"`) never contributes to
          # the production chart's input stream. Without this,
          # `chart_power_for_mppt/1`'s nil-fallback returns 0.0 W
          # for every Shelly row, producing a synthetic flat-zero
          # line labelled "em:0" in the legend (see the matching
          # filter in `live_tail_bucketed_chart_points/3` and the
          # defensive filter in
          # `DtuAppWeb.DashboardLive.assign_line_chart_data/5`).
          where:
            r.dtu_id in ^dtu_ids and
              r.inserted_at >= ^utc_start and r.inserted_at <= ^utc_end and
              r.power_type == "production",
          order_by: [asc: r.inserted_at],
          select: %{
            inserted_at: r.inserted_at,
            ac_power: r.ac_power,
            # Per-MPPT rows store their power in `dc_power` (the firmware
            # only emits per-channel DC scalars). The chart aggregation
            # below picks the right one per row via `chart_power_for_mppt/1`.
            dc_power: r.dc_power,
            dtu_id: r.dtu_id,
            inverter_serial: r.inverter_serial,
            mppt_index: r.mppt_index,
            inverter_name: r.inverter_name
          }
      )
    end
  end

  @doc """
  Translate a user-facing local date into the inclusive UTC range
  `[00:00 local, 23:59:59 local]` — what the readings table actually
  queries against. Pass `tz_offset_seconds` from
  `socket.assigns.user_tz_offset_seconds`.

  Examples (winter, no DST):

      iex> local_day_utc_range(~D[2026-07-31], 3600)
      {~U[2026-07-30 23:00:00Z], ~U[2026-07-31 22:59:59Z]}

      iex> local_day_utc_range(~D[2026-07-31], 0)
      {~U[2026-07-31 00:00:00Z], ~U[2026-07-31 23:59:59Z]}
  """
  @spec local_day_utc_range(Date.t(), integer()) :: {DateTime.t(), DateTime.t()}
  def local_day_utc_range(%Date{} = local_date, tz_offset_seconds) do
    {:ok, start_local} = DateTime.new(local_date, ~T[00:00:00])
    {:ok, end_local} = DateTime.new(local_date, ~T[23:59:59])

    {DateTime.add(start_local, -tz_offset_seconds, :second),
     DateTime.add(end_local, -tz_offset_seconds, :second)}
  end

  # A chart series identifies one line on the live/day chart: one
  # (inverter, mppt) pair. `inverter_name` is the optional display label
  # the user can set; the chart falls back to the serial when it's nil.
  #
  # Canonical definitions live in `DtuApp.Devices` so the Stats
  # cluster's `@spec`s resolve against the same source of truth;
  # re-exported here as type aliases.
  @type series_key :: DtuApp.Devices.series_key()
  @type chart_point :: DtuApp.Devices.chart_point()

  @doc """
  Fetch a day's worth of readings for the user's DTUs and bucket them
  per (dtu_id, inverter_serial, mppt_index) into 5-minute averages, so
  the chart can render one line per (inverter, MPPT) instead of a
  single total.

  Each `power` point picks `ac_power` for the AC-aggregate row
  (`mppt_index = 0` — the AhoyDTU ch0 / OpenDTU total) and `dc_power`
  for the per-MPPT rows (`mppt_index >= 1` — individual DC strings).
  Per-MPPT rows never carry `ac_power` (the firmware only emits
  per-channel DC on `[serial]/[1-4]/...` topics), so collapsing them
  to `ac_power || 0.0` would draw every per-MPPT line flat at the
  X-axis even when those strings are producing.

  This implementation walks the raw `readings` hypertable and buckets
  in the BEAM, which is fine for a few hundred rows but scales poorly
  once a DTU starts emitting a row every 10–30s for a full day
  (≈20 000+ raw rows per device). The dashboard's hot path uses
  `list_day_chart_data_for_dashboard/4` (aggregate-backed) instead;
  this helper stays for callers that need a row-accurate view (e.g.
  `compute_day_period_stats/2` against a single historical day where
  the per-MPPT detail matters).
  """
  def list_day_chart_data(%User{} = user, utc_start, utc_end, dtu_id \\ nil)
      when is_struct(utc_start, DateTime) and is_struct(utc_end, DateTime) do
    readings = list_day_readings_for_chart(user, utc_start, utc_end, dtu_id)

    if readings == [] do
      []
    else
      readings
      |> Enum.group_by(fn r -> div(DateTime.to_unix(r.inserted_at), 300) end)
      |> Enum.flat_map(fn {bucket, bucket_readings} ->
        time = DateTime.from_unix!(bucket * 300)

        bucket_readings
        |> Enum.group_by(fn r -> {r.dtu_id, r.inverter_serial, r.mppt_index, r.inverter_name} end)
        |> Enum.map(fn {series, series_readings} ->
          powers = Enum.map(series_readings, &chart_power_for_mppt/1)
          power = Enum.sum(powers) / length(series_readings)

          %{time: time, series: series, power: power}
        end)
      end)
      |> Enum.sort_by(& &1.time)
    end
  end

  # Live / historical day chart, aggregate-backed. Replaces the per-row
  # scan that `list_day_chart_data/4` did for the dashboard's hot path.
  # See the `Devices` moduledoc for the broader rationale.
  @doc """
  Same shape as `list_day_chart_data/4`, but reads the per-bucket
  average from the `readings_5m` continuous aggregate for everything
  older than the aggregate's `end_offset` (5 min — matches the
  policy: `add_continuous_aggregate_policy('readings_5m', end_offset =>
  INTERVAL '5 minutes')`). The most recent 5 minutes of the day
  aren't materialised yet, so we union with the raw `readings` table
  for that tail.

  Returns a flat list of `%{time, series, power}` map points — the
  exact contract `list_day_chart_data/4` returns — so the dashboard
  can swap the implementation without touching the chart code.

  ## Why this matters

  Without the aggregate, `list_day_chart_data/4` would walk every raw
  `readings` row in the day for every dashboard mount and every
  reading-triggered refresh. A typical AhoyDTU install publishes
  ~4 300 AC rows + ~10–20 000 per-MPPT rows per day per DTU; a fleet
  of two inverters plus a Shelly produces 20–30 thousand rows / day,
  most in the current (uncompressed) hypertable chunk. The 5-minute
  aggregate holds one row per `(bucket, dtu_id, inverter_serial,
  mppt_index)` — at 288 buckets/day that's ≤ 1 200 rows per device
  per day, an order-of-magnitude fewer rows than the raw table.

  The 5-minute live tail (`utc_tail_start = now - 5 min`) is read
  from the raw table because the aggregate lags by `end_offset`. The
  tail's bucket means are computed in the BEAM (the same way
  `list_day_chart_data/4` does for the full day) — the small row
  count there makes the BEAM bucketing a non-issue.

  Returns `[]` when the user has no devices or no readings in the
  window.
  """
  @spec list_day_chart_data_for_dashboard(User.t(), DateTime.t(), DateTime.t(), integer() | nil) ::
          [
            chart_point()
          ]
  def list_day_chart_data_for_dashboard(
        %User{} = user,
        utc_start,
        utc_end,
        dtu_id \\ nil
      )
      when is_struct(utc_start, DateTime) and is_struct(utc_end, DateTime) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      []
    else
      now_usec = DtuApp.Time.utc_now_usec()

      # The continuous aggregate has a 5-minute `end_offset`, so the
      # newest closed bucket is `now - 5min`. Anything more recent than
      # that lands in the raw-table "live tail".
      utc_tail_start =
        now_usec |> DateTime.add(-300, :second) |> DateTime.truncate(:microsecond)

      # Materialised buckets: `bucket < utc_tail_start` (closed-only).
      # `readings_5m.bucket` is the aggregate's time column.
      #
      # `avg_ac_power` is NULL on per-MPPT rows (`mppt_index >= 1`,
      # where the firmware only publishes `dc_power`) — but the
      # dashboard filters those out (`Enum.filter` in
      # `assign_line_chart_data/5`), so this NULL never reaches the
      # chart.
      aggregate_points =
        Repo.all(
          from a in "readings_5m",
            where:
              a.dtu_id in ^dtu_ids and a.bucket < ^utc_tail_start and
                a.bucket >= ^utc_start and a.bucket <= ^utc_end,
            select: %{
              # `readings_5m.bucket` is the aggregate's time column
              # (TimescaleDB's `time_bucket(...)` result). The chart
              # pipeline expects `:time` everywhere — the live tail
              # (`live_tail_bucketed_chart_points/3`) and the
              # raw-row fallback (`list_day_chart_data/4`) both use
              # `:time` for the same field. Selecting the column as
              # `:time` here keeps the consumer contract uniform and
              # lets the `case pt.time` argument coercion below
              # (NaiveDateTime → DateTime) handle the aggregate rows
              # in the same pass as the live tail.
              time: a.bucket,
              dtu_id: a.dtu_id,
              inverter_serial: a.inverter_serial,
              mppt_index: a.mppt_index,
              inverter_name: a.inverter_name,
              power: a.avg_ac_power
            }
        )
        # The aggregate SELECT returns a wide-table shape (`dtu_id`,
        # `inverter_serial`, `mppt_index`, `inverter_name` as separate
        # fields) — that's what TimescaleDB's continuous aggregate view
        # exposes. The chart pipeline (`DashboardLive.assign_line_chart_data/5`,
        # `get_daily_stats/3`'s `bucket_max`, the `chart_power_for_mppt/1` per-MPPT
        # filter) consumes the `chart_point()` contract, where `:series`
        # is a 4-tuple `{dtu_id, inverter_serial, mppt_index, inverter_name}`
        # — not four fields. Without this reshape, every consumer that does
        # `elem(pt.series, N)` raises `KeyError: key :series not found`.
        # The live tail (`live_tail_bucketed_chart_points/3`) and the
        # raw-row fallback (`list_day_chart_data/4`) already produce the
        # 4-tuple shape; only the aggregate path needs the reshape.
        |> Enum.map(fn pt ->
          %{
            time: pt.time,
            series: {pt.dtu_id, pt.inverter_serial, pt.mppt_index, pt.inverter_name},
            power: pt.power
          }
        end)

      # Live tail — raw rows, bucketed via `time_bucket` in SQL so the
      # shape matches the aggregate exactly. The 5-minute tail is
      # small (≤ 5 min × 30 uplinks/min × N devices) so the bucketing
      # is cheap, and skipping it would make the chart's "most
      # recent bucket" lag up to 5 min behind reality.
      live_tail_chart_points = live_tail_bucketed_chart_points(utc_tail_start, dtu_ids, utc_end)

      # Fallback: a brand-new or never-refreshed `readings_5m`
      # aggregate is empty (`WITH NO DATA` from the migration + no
      # policy run since the first uplink). The first dashboard
      # mount for a fresh install — or a test DB with no materialised
      # buckets — would render an empty chart even though raw rows
      # exist for the period. The fallback fires whenever the
      # aggregate is empty, **regardless of the live tail** — the
      # live tail only covers the last 5 minutes, so a cold
      # aggregate plus day-old readings would otherwise drop
      # everything but the last 5 minutes of data. The fallback
      # path (`list_day_chart_data/4`) walks the raw rows for the
      # full day and produces the same chart the pre-aggregate code
      # did, so a cold aggregate doesn't blank the chart or lose
      # out-of-tail readings. Once the aggregate fills in (after
      # the first 5-min policy run), this branch won't fire and the
      # hot path serves the optimised read.
      result =
        if aggregate_points == [] do
          list_day_chart_data(user, utc_start, utc_end, dtu_id)
        else
          aggregate_points ++ live_tail_chart_points
        end

      result
      |> Enum.map(fn pt ->
        # `readings_5m.bucket` and the SQL `time_bucket(...)` result
        # are `timestamp without time zone` columns. Without a schema
        # cast (the aggregate has no Ecto schema), Postgrex decodes
        # them as `NaiveDateTime`, but the rest of the dashboard
        # (`shift_local/2`, `chart_time_range/2`, the bucket-mean
        # arithmetic) expects `%DateTime{}`. Lift the value back into
        # a UTC `DateTime` here so the contract matches
        # `list_day_chart_data/4`. The raw-row fallback already
        # returns `%DateTime{}` from `list_day_chart_data/4`, so the
        # `case` keeps the function's contract uniform across both
        # branches.
        case pt.time do
          %DateTime{} -> pt
          %NaiveDateTime{} -> %{pt | time: DateTime.from_naive!(pt.time, "Etc/UTC")}
        end
      end)
      |> Enum.sort_by(& &1.time)
    end
  end

  # Live-today ghost chart: yesterday's closed-bucket chart points for
  # the user's DTU scope. Backs the dashboard's "yesterday ghost line"
  # overlay behind today's curve.
  #
  # Returns the same `%{time, series, power}` shape as
  # `list_day_chart_data_for_dashboard/4`. Yesterday is fully closed
  # (no live tail needed — there's no 5-min raw tail for a day that's
  # already past midnight), so this reads from `readings_5m` only.
  # Falls back to `list_day_chart_data/4` against the same window when
  # the aggregate is empty (cold installs, fresh test DBs).
  @doc """
  Returns yesterday's per-bucket chart points for the same scope
  (`dtu_id`) and time window as `list_day_chart_data_for_dashboard/4`,
  shifted by -1 day. Used by the dashboard's 1D live view to render
  a translucent ghost line behind today's curve.

  The window is computed by subtracting 1 day from the supplied
  `utc_start` / `utc_end`, so callers can reuse their today's-window
  DateTimes without re-deriving them. `dtu_id` filters the same way
  it does in the today function (nil = fleet-wide).

  Returns `[]` when the user has no devices or no readings in the
  yesterday window.
  """
  @spec list_yesterday_chart_data_for_dashboard(
          User.t(),
          DateTime.t(),
          DateTime.t(),
          integer() | nil
        ) :: [chart_point()]
  def list_yesterday_chart_data_for_dashboard(
        %User{} = user,
        utc_start,
        utc_end,
        dtu_id \\ nil
      )
      when is_struct(utc_start, DateTime) and is_struct(utc_end, DateTime) do
    # Shift the window back by one day so callers can reuse the same
    # DateTimes they pass to `list_day_chart_data_for_dashboard/4`.
    yesterday_start = DateTime.add(utc_start, -86_400, :second)
    yesterday_end = DateTime.add(utc_end, -86_400, :second)

    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      []
    else
      # Yesterday is past — every bucket is closed. No live tail to
      # union with; the aggregate alone covers the full window.
      # We still apply the same defensive contract as the today path:
      # the cold-aggregate fallback keeps a fresh test DB / brand-new
      # install from rendering an empty ghost when raw rows exist.
      aggregate_points =
        Repo.all(
          from a in "readings_5m",
            where:
              a.dtu_id in ^dtu_ids and
                a.bucket >= ^yesterday_start and a.bucket <= ^yesterday_end,
            select: %{
              time: a.bucket,
              dtu_id: a.dtu_id,
              inverter_serial: a.inverter_serial,
              mppt_index: a.mppt_index,
              inverter_name: a.inverter_name,
              power: a.avg_ac_power
            }
        )
        |> Enum.map(fn pt ->
          %{
            time: pt.time,
            series: {pt.dtu_id, pt.inverter_serial, pt.mppt_index, pt.inverter_name},
            power: pt.power
          }
        end)
        |> Enum.map(fn pt ->
          case pt.time do
            %DateTime{} -> pt
            %NaiveDateTime{} -> %{pt | time: DateTime.from_naive!(pt.time, "Etc/UTC")}
          end
        end)

      if aggregate_points == [] do
        list_day_chart_data(user, yesterday_start, yesterday_end, dtu_id)
      else
        aggregate_points
      end
    end
  end

  # Returns the chart's bucket-mean shape for raw rows whose
  # `inserted_at >= utc_tail_start`. Aggregated by
  # `(bucket, dtu_id, inverter_serial, mppt_index)` via `time_bucket`
  # so the output rows match the `readings_5m` schema 1:1. Returns
  # the same `%{time, series, power}` map shape as
  # `list_day_chart_data/4`.
  defp live_tail_bucketed_chart_points(utc_tail_start, dtu_ids, utc_end) do
    # `time_bucket('5 minutes', ...)` has the same boundary semantics
    # as `readings_5m`'s bucket column, so concatenating with the
    # aggregate rows produces a single ordered stream.
    tail_rows =
      Repo.all(
        from r in Reading,
          where:
            r.dtu_id in ^dtu_ids and
              r.inserted_at >= ^utc_tail_start and r.inserted_at <= ^utc_end and
              r.power_type == "production",
          group_by: [
            fragment("time_bucket(INTERVAL '5 minutes', ?)", r.inserted_at),
            r.dtu_id,
            r.inverter_serial,
            r.mppt_index,
            r.inverter_name
          ],
          select: %{
            bucket: fragment("time_bucket(INTERVAL '5 minutes', ?)", r.inserted_at),
            dtu_id: r.dtu_id,
            inverter_serial: r.inverter_serial,
            mppt_index: r.mppt_index,
            inverter_name: r.inverter_name,
            ac_power: fragment("avg(?)", r.ac_power),
            dc_power: fragment("avg(?)", r.dc_power)
          }
      )

    Enum.map(tail_rows, fn row ->
      series = {row.dtu_id, row.inverter_serial, row.mppt_index, row.inverter_name}

      %{
        time: row.bucket,
        series: series,
        # Per `list_day_chart_data/4`: pick `ac_power` for AC-aggregate
        # rows (`mppt_index = 0`) and `dc_power` for per-MPPT rows.
        # The aggregate's NULLs for per-MPPT rows are dropped by the
        # dashboard's filter, so we don't have to guard against them
        # here.
        power:
          chart_power_for_mppt(%{
            mppt_index: row.mppt_index,
            ac_power: row.ac_power,
            dc_power: row.dc_power
          })
      }
    end)
  end

end
