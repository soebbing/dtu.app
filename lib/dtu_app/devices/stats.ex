defmodule DtuApp.Devices.Stats do
  @moduledoc """
  Daily / range / period stats aggregations.

  Three concerns, each one a cluster:

    1. **Production stats** — `get_daily_stats/1`, `get_daily_stats/2`,
       `get_daily_stats/3`, `get_daily_stats/4`,
       `compute_peak_watts_in_period/4`,
       `compute_self_consumption_pct/4` (and the private
       `integrate_export_kwh/4` helper). The dashboard's day-totals,
       peak-power, and "self-consumption" cards come from here.
       Live in `DtuApp.Devices.Stats.ProductionStats`.
    2. **Consumption stats** — `get_consumption_daily_stats/3`,
       `get_consumption_period_stats/5`,
       `integrate_consumption_kwh/4`,
       `compute_consumption_total_kwh/4` (and the private
       `compute_consumption_peak_w/4`, `compute_consumption_peak_day/4`
       helpers). Live in `DtuApp.Devices.Stats.ConsumptionStats`.
    3. **Period/range helpers** — `resolve_consumption_period_date/2`,
       `week_range/2`, `month_range/2`, `year_value/1`,
       `last_n_days_window/2`, `zero_period_stats/0`. Live in
       `DtuApp.Devices.Stats.PeriodHelpers`.

  Net-flow stats live in `DtuApp.Devices.ConsumptionChartData`
  (`get_net_flow_stats/3`), not here.

  All queries prefer the `readings_daily` continuous aggregate over
  raw `readings` rows; see the `@readings_daily` referenced in the
  sibling modules' bodies for the column list.

  Re-exported through `DtuApp.Devices` via `defdelegate` so existing
  call sites continue to work unchanged. This module is a thin
  `defdelegate` shell — every public function here forwards to the
  appropriate sibling module. The default-arg wrappers are reified to
  all arities here because `defdelegate` does not preserve default
  values at the forward boundary.
  """

  # Production stats — every default-arg wrapper is reified.
  defdelegate get_daily_stats(user), to: __MODULE__.ProductionStats
  defdelegate get_daily_stats(user, dtu_id), to: __MODULE__.ProductionStats
  defdelegate get_daily_stats(user, dtu_id, date), to: __MODULE__.ProductionStats
  defdelegate get_daily_stats(user, dtu_id, date, chart_points), to: __MODULE__.ProductionStats
  defdelegate get_daily_stats_for_local_day(user, dtu_id, local_date, tz_offset_seconds),
    to: __MODULE__.ProductionStats

  defdelegate compute_peak_watts_in_period(user, dtu_id, utc_start, utc_end),
    to: __MODULE__.ProductionStats

  defdelegate compute_self_consumption_pct(user, dtu_id, utc_start, utc_end),
    to: __MODULE__.ProductionStats

  # Consumption stats — every default-arg wrapper is reified.
  defdelegate get_consumption_daily_stats(user), to: __MODULE__.ConsumptionStats
  defdelegate get_consumption_daily_stats(user, dtu_id), to: __MODULE__.ConsumptionStats
  defdelegate get_consumption_daily_stats(user, dtu_id, opts), to: __MODULE__.ConsumptionStats

  defdelegate get_consumption_period_stats(user, dtu_id, time_range, selected_period),
    to: __MODULE__.ConsumptionStats

  defdelegate get_consumption_period_stats(user, dtu_id, time_range, selected_period, cds),
    to: __MODULE__.ConsumptionStats

  defdelegate integrate_consumption_kwh(user, dtu_id, utc_start, utc_end),
    to: __MODULE__.ConsumptionStats

  defdelegate compute_consumption_total_kwh(user, dtu_ids, utc_start, utc_end),
    to: __MODULE__.ConsumptionStats
end
