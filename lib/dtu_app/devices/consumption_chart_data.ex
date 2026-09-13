defmodule DtuApp.Devices.ConsumptionChartData do
  @moduledoc """
  Today-window and net/consumption chart data queries.

  Two distinct shapes:

    1. **Today-window raw + bucketed** —
       `list_today_readings_for_chart/2`,
       `list_today_chart_data/2`,
       `list_today_consumption_chart_data/2`. The "today" view on
       the dashboard mounts these to render the live tail (uses
       `DtuApp.Devices.ChartData.local_day_utc_range/2` to anchor
       the UTC window).
    2. **Range net/consumption queries** —
       `list_consumption_chart_data/4`, `list_net_chart_data/4`,
       `get_net_flow_stats/3`. These join inverter AC production
       against Shelly consumption / grid import-export to compute
       the net flow bucketed series. `lift_naive!/1` is the
       Postgres-returned-timestamp helper.

  Day-boundary (non-"today") queries live in
  `DtuApp.Devices.ChartData`. Stats aggregations live in
  `DtuApp.Devices.Stats`. This module is the "today" / net-flow
  bridge between those two.

  Re-exported through `DtuApp.Devices` via `defdelegate` so existing
  call sites continue to work unchanged.
  """

  import Ecto.Query

  alias DtuApp.Accounts.User
  alias DtuApp.Devices.ChartData
  alias DtuApp.Devices.Reading
  alias DtuApp.Repo

  import DtuApp.Devices.ChartHelpers,
    only: [owned_dtu_ids: 2, chart_power_for_mppt: 1, clamp_household_draw: 1]

  @doc "Fetch today's readings for the user's DTUs (raw rows)."
  def list_today_readings_for_chart(%User{} = user, dtu_id \\ nil) do
    today_utc = Date.utc_today()
    {utc_start, _} = ChartData.local_day_utc_range(today_utc, 0)
    ChartData.list_day_readings_for_chart(user, utc_start, ~U[9999-12-31 23:59:59Z], dtu_id)
  end

  @doc "Fetch today's power readings as 5-minute buckets for charts."
  def list_today_chart_data(%User{} = user, dtu_id \\ nil) do
    today_utc = Date.utc_today()
    {utc_start, _} = ChartData.local_day_utc_range(today_utc, 0)
    ChartData.list_day_chart_data(user, utc_start, ~U[9999-12-31 23:59:59Z], dtu_id)
  end

  @doc """
  Same shape as `list_today_chart_data/2`, but only for
  `power_type = :consumption` rows — i.e. the household's drawn power
  published by a paired Shelly Plus 3EM (Gen3+) energy meter. Each
  Shelly device is a single series (one meter), so the buckets
  collapse to one point per 5-minute window per device.
  """
  def list_today_consumption_chart_data(%User{} = user, dtu_id \\ nil) do
    today_utc = Date.utc_today()
    {utc_start, _} = ChartData.local_day_utc_range(today_utc, 0)

    list_consumption_chart_data(user, utc_start, ~U[9999-12-31 23:59:59Z], dtu_id)
  end

  def list_consumption_chart_data(%User{} = user, utc_start, utc_end, dtu_id \\ nil)
      when is_struct(utc_start, DateTime) and is_struct(utc_end, DateTime) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      []
    else
      readings =
        Repo.all(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and r.power_type == "consumption" and
                r.inserted_at >= ^utc_start and r.inserted_at <= ^utc_end,
            select: %{
              inserted_at: r.inserted_at,
              consumption_power: r.consumption_power,
              dtu_id: r.dtu_id
            }
        )

      if readings == [] do
        []
      else
        readings
        |> Enum.group_by(fn r -> div(DateTime.to_unix(r.inserted_at), 300) end)
        |> Enum.flat_map(fn {bucket, bucket_readings} ->
          time = DateTime.from_unix!(bucket * 300)

          # One chart series per (dtu_id) — a Shelly device is a single
          # physical meter even if it publishes per-phase fields; we sum
          # across phases upstream and store a single `total_act_power`
          # in `consumption_power`. So the bucket mean is the
          # household's average drawn watts in that window, per device.
          bucket_readings
          |> Enum.group_by(fn r -> r.dtu_id end)
          |> Enum.map(fn {dtu_id, series_readings} ->
            # `clamp_household_draw/1` filters the Shelly's signed
            # `total_act_power` to ≥ 0 W so the consumption overlay
            # never dips below the X-axis when the home is net-
            # exporting. The net-flow arithmetic still subtracts the
            # clamped value (see `list_net_chart_data/4`), keeping
            # "net export" bounded above by total solar production.
            powers =
              Enum.map(series_readings, fn r -> clamp_household_draw(r.consumption_power) end)

            power = Enum.sum(powers) / length(series_readings)

            %{time: time, series: {dtu_id, "em:0", 0, nil}, power: power}
          end)
        end)
        |> Enum.sort_by(& &1.time)
      end
    end
  end

  @doc """
  Net flow chart series — production minus consumption, bucketed into
  the same 5-minute windows used by `list_day_chart_data/4` and
  `list_consumption_chart_data/4`. Net flow is the most actionable
  single number on a solar dashboard: positive means the home is
  exporting (selling to the grid), negative means importing (buying).

  Both sides must be present for a meaningful series — without a Shelly,
  the household draw is unknown and the dashboard falls back to the
  pure-production view. Without an inverter, there's nothing to net
  against. The dashboard hides the net-flow chart and stat cards
  unless both kinds are present (`@net_flow_active`).

  The series is built by:
    1. Fetching all readings (production + consumption) in the UTC
       window — one SQL query, no per-power-type round-trip.
    2. Grouping by 5-minute bucket.
    3. Within each bucket, computing the **bucket mean** per device on
       each side: the AC aggregate row (`mppt_index = 0`) is the
       inverter's true AC output (per-MPPT DC rows are excluded — they
       duplicate the AC output and would double-count the inverter),
       and each Shelly device contributes its `consumption_power` mean
       across all uplinks in the bucket. The per-device means are then
       summed across devices so a 2-MPPT Hoymiles (1 row per bucket)
       and a Shelly (~10 rows per bucket) both contribute a single
       house-wide figure to the net.
    4. Returning `%{time, power}` per bucket, where `power` is
       `production - consumption`. A positive value means export;
       negative means import.

  ## Why per-device mean instead of sum?

  Summing every raw row in the bucket produces wildly wrong numbers:

    * **Production** — a multi-MPPT Hoymiles publishes the AC total
      on `realtime/data` *and* per-string DC on `[serial]/[1-N]/power`.
      Summing all rows double- or triples the inverter's actual AC
      output.
    * **Consumption** — a Shelly Plus 3EM publishes ~10× per 5-min
      window (every 30s). Summing every reading reports 10× the true
      household draw (e.g. `76 W` on the Shelly app rendered as
      `760 W` on the dashboard — exactly the "factor of 10" users
      reported).

  Averaging per device collapses each side to a single number in the
  same units (W) before the subtraction, mirroring what
  `list_day_chart_data/4` and `list_consumption_chart_data/4` already
  do for their chart buckets.

  Returns `[]` when the user has no devices or no readings in the
  window — the dashboard hides the net-flow row.
  """
  @spec list_net_chart_data(User.t(), DateTime.t(), DateTime.t(), integer() | nil) :: [
          %{time: DateTime.t(), power: float()}
        ]
  def list_net_chart_data(%User{} = user, utc_start, utc_end, dtu_id \\ nil)
      when is_struct(utc_start, DateTime) and is_struct(utc_end, DateTime) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      []
    else
      # Single SQL query that pushes the production/consumption split
      # into the database via `FILTER` aggregates on the raw
      # `readings` rows. The result is one row per
      # `(bucket, dtu_id, inverter_serial)` that has any data on either
      # side — typically a few hundred rows for a day's worth of data,
      # versus the ~30k raw rows the BEAM-driven path used to fetch.
      #
      # The `FILTER` clauses mirror the BEAM-side guards the previous
      # implementation used:
      #
      #   * `power_type = 'production' AND mppt_index = 0` selects the
      #     AC aggregate row only — per-MPPT DC rows duplicate the AC
      #     total and would 2×/3× the inverter's actual output if
      #     included.
      #   * `power_type = 'consumption'` selects the Shelly's
      #     instantaneous draw. `GREATEST(consumption_power, 0)` clamps
      #     to ≥ 0 W so net-export windows where the Shelly publishes
      #     negative `total_act_power` don't inflate the net figure
      #     past the inverter's actual output.
      #
      # `time_bucket('5 minutes', inserted_at)` is the same bucketing
      # the `readings_5m` continuous aggregate uses, so the bucket
      # boundaries line up with the production chart's buckets.
      # `AVG(...)` collapses each Shelly's ~10× per-5-min readings
      # (and a multi-MPPT Hoymiles's per-minute per-string rows) to
      # a single figure per (bucket, device) — the same per-device
      # average the pre-rewrite code computed in BEAM.
      bucketed =
        Repo.all(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and
                r.inserted_at >= ^utc_start and r.inserted_at <= ^utc_end,
            group_by: [
              fragment("time_bucket(INTERVAL '5 minutes', ?)", r.inserted_at),
              r.dtu_id,
              r.inverter_serial
            ],
            select: %{
              bucket: fragment("time_bucket(INTERVAL '5 minutes', ?)", r.inserted_at),
              dtu_id: r.dtu_id,
              inverter_serial: r.inverter_serial,
              production_w:
                fragment(
                  "avg(?) FILTER (WHERE ? = 'production' AND ? = 0)",
                  r.ac_power,
                  r.power_type,
                  r.mppt_index
                ),
              consumption_w:
                fragment(
                  "avg(GREATEST(?, 0)) FILTER (WHERE ? = 'consumption')",
                  r.consumption_power,
                  r.power_type
                ),
              # `count(*) FILTER (WHERE power_type='consumption')` lets the
              # drop-bucket guard below distinguish "bucket had at least
              # one consumption row" from "no consumption row at all".
              # The clamped mean can be 0 W (a net-export window where
              # every Shelly reading was negative) while the bucket still
              # contains real data — keeping it preserves the
              # production − 0 = export signal. Without this flag, the
              # guard would drop those buckets and lose the export curve
              # for net-exporting homes. Adds one extra `count(*)` per
              # bucket to the work the planner already does alongside
              # the two `avg`s.
              consumption_presence:
                fragment(
                  "count(*) FILTER (WHERE ? = 'consumption')",
                  r.power_type
                )
            }
        )

      if bucketed == [] do
        []
      else
        bucketed
        |> Enum.group_by(fn row -> row.bucket end)
        |> Enum.flat_map(fn {bucket, bucket_rows} ->
          # `production_w` is NULL for rows that only have consumption
          # rows in the bucket (and vice versa) — `|| 0.0` collapses
          # both to a numeric zero so the SUM below doesn't drop NULL
          # and skip the bucket.
          production_w =
            bucket_rows
            |> Enum.map(fn r -> r.production_w || 0.0 end)
            |> Enum.sum()

          consumption_w =
            bucket_rows
            |> Enum.map(fn r -> r.consumption_w || 0.0 end)
            |> Enum.sum()

          # Drop buckets where no Shelly uplink landed at all —
          # without this guard, the net-flow curve would equal the
          # production line (`production - 0 = production`) and just be
          # a duplicate of the Total. A bucket where the clamped
          # consumption is 0 but the bucket had at least one
          # consumption row (net-export window where every Shelly reading
          # was negative) is *kept* — `production - 0 = production` is
          # exactly the export signal the chart should plot. Matches
          # the pre-rewrite BEAM guard
          # (`Enum.any?(&(&1.power_type == "consumption"))`).
          has_consumption_row =
            Enum.any?(bucket_rows, fn row ->
              (row.consumption_presence || 0) > 0
            end)

          if consumption_w > 0.0 or has_consumption_row do
            [%{time: lift_naive!(bucket), power: production_w - consumption_w}]
          else
            []
          end
        end)
        |> Enum.sort_by(& &1.time)
      end
    end
  end

  # `time_bucket` returns a `timestamp without time zone` so Postgres
  # decodes it as `NaiveDateTime`. The dashboard's chart pipeline
  # (`shift_local/2`, `chart_time_range/2`, the bucket-mean math)
  # expects `%DateTime{}` — see the matching `case` in
  # `list_day_chart_data_for_dashboard/4` for the same coercion.
  defp lift_naive!(%NaiveDateTime{} = naive),
    do: DateTime.from_naive!(naive, "Etc/UTC")

  defp lift_naive!(%DateTime{} = dt), do: dt

  @doc """
  Net flow stat snapshot — mirrors `get_daily_stats/3` /
  `get_consumption_daily_stats/2` for the difference between the two.

  Returns:
    * `current_net_flow`   — W, fresh (last 2 min). Positive = exporting,
      negative = importing. `production - consumption` summed across
      the user's devices, computed from the latest reading per
      `(dtu_id, power_type)` pair (so a Shelly publishing every 30s
      isn't summed 10× like the bucket paths used to — see
      `list_net_chart_data/4` for the matching per-bucket fix).
    * `today_net_export`   — kWh, total energy exported today (the sum
      of positive net-flow buckets, in kWh).
    * `today_net_import`   — kWh, total energy imported today (the sum
      of negative net-flow buckets, in absolute kWh).
    * `peak_export` / `peak_import` — W, largest single-bucket export /
      import in the day, used for the dashboard's headline.

  Returns zero defaults when the user has no devices or no readings.
  """
  @spec get_net_flow_stats(User.t(), integer() | nil) :: %{
          current_net_flow: float(),
          today_net_export: float(),
          today_net_import: float(),
          peak_export: float(),
          peak_import: float()
        }
  def get_net_flow_stats(%User{} = user, dtu_id \\ nil, opts \\ []) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      %{
        current_net_flow: 0.0,
        today_net_export: 0.0,
        today_net_import: 0.0,
        peak_export: 0.0,
        peak_import: 0.0
      }
    else
      # Pre-computed today net-flow chart points (already bucket-meaned
      # into 5-min windows by `list_net_chart_data/4`). When the
      # caller (the today branch of `assign_dashboard_data/5`) already
      # fetched these for the net-flow chart overlay, pass them in via
      # `:net_chart_points` so we don't re-run the same `readings` scan
      # (production + consumption) here. On a paired-user mount that's
      # 1 raw-row scan saved per refresh.
      net_chart_points =
        case Keyword.get(opts, :net_chart_points) do
          nil -> nil
          pts when is_list(pts) -> pts
        end

      today_start = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
      today_end = DateTime.new!(Date.utc_today(), ~T[23:59:59], "Etc/UTC")
      two_minutes_ago = DtuApp.Time.utc_now() |> DateTime.add(-120, :second)

      points =
        case net_chart_points do
          nil -> list_net_chart_data(user, today_start, today_end, dtu_id)
          pts -> pts
        end

      if points == [] do
        %{
          current_net_flow: 0.0,
          today_net_export: 0.0,
          today_net_import: 0.0,
          peak_export: 0.0,
          peak_import: 0.0
        }
      else
        # Convert the bucket-mean power (W) into energy (Wh) by
        # multiplying by the bucket duration (5 min = 1/12 h).
        bucket_h = 5.0 / 60.0
        net_per_bucket = Enum.map(points, fn p -> p.power * bucket_h end)

        # Exports are positive bucket-hours; imports are negative.
        # We sum the absolute values on each side to express
        # `today_net_export` and `today_net_import` in Wh, then convert
        # to kWh at the end.
        exported_wh =
          net_per_bucket
          |> Enum.filter(&(&1 > 0.0))
          |> Enum.sum()

        imported_wh =
          net_per_bucket
          |> Enum.filter(&(&1 < 0.0))
          |> Enum.map(&abs/1)
          |> Enum.sum()

        # Peak export = largest single positive bucket; peak import =
        # largest single negative bucket (as a positive W).
        peak_export = Enum.max(Enum.map(points, & &1.power), fn -> 0.0 end)
        peak_import = Enum.max(Enum.map(points, fn p -> abs(p.power) end), fn -> 0.0 end)

        # Live net flow: take the freshest reading's `production_power -
        # consumption_power` rather than relying on the bucket mean
        # (which lags a few minutes when the bucket hasn't filled).
        latest_readings =
          Repo.all(
            from r in Reading,
              where: r.dtu_id in ^dtu_ids and r.inserted_at >= ^two_minutes_ago,
              distinct: [r.dtu_id, r.power_type],
              order_by: [r.dtu_id, r.power_type, desc: r.inserted_at]
          )

        # `distinct: [r.dtu_id, r.power_type]` gives one row per
        # (dtu_id, power_type) — production and consumption latest.
        # The `inserted_at >= ^two_minutes_ago` bound turns the
        # otherwise-unbounded DISTINCT ON into a single-chunk range
        # scan via the `(dtu_id, power_type, inserted_at)` access
        # path. It is semantically equivalent to the original query:
        # the reduce loop below discards any row older than
        # `two_minutes_ago` via `DateTime.after?(r.inserted_at,
        # two_minutes_ago)`, so a DTU whose latest reading is older
        # than the bound contributes 0 W either way. Without this
        # bound, a multi-year install's `readings` hypertable walks
        # every compressed chunk on every dashboard mount —
        # observed 13.1 s for a user with ~3.7 M readings (see
        # perf-telemetry 2026-09-12).
        {production_now, consumption_now} =
          Enum.reduce(latest_readings, {0.0, 0.0}, fn r, {p, c} ->
            fresh? = DateTime.after?(r.inserted_at, two_minutes_ago)

            cond do
              not fresh? -> {p, c}
              r.power_type == "production" -> {p + chart_power_for_mppt(r), c}
              # Clamp the Shelly's signed `total_act_power` to the
              # household-draw reading the dashboard reports as
              # "Current Consumption" (always ≥ 0 W). Without the
              # clamp, a sunny midday with low draw would render the
              # "Net export" figure as `production - (-|draw|) =
              # production + |draw|`, exceeding the inverter's
              # actual output.
              r.power_type == "consumption" -> {p, c + clamp_household_draw(r.consumption_power)}
              true -> {p, c}
            end
          end)

        current_net_flow = production_now - consumption_now

        %{
          current_net_flow: Float.round(current_net_flow * 1.0, 1),
          today_net_export: Float.round(exported_wh / 1000, 2),
          today_net_import: Float.round(imported_wh / 1000, 2),
          peak_export: Float.round(peak_export * 1.0, 1),
          peak_import: Float.round(peak_import * 1.0, 1)
        }
      end
    end
  end

end
