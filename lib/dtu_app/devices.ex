defmodule DtuApp.Devices do
  @moduledoc """
  The Devices context.

  Every function is scoped to an owning `DtuApp.Accounts.User`, so a user can
  only ever touch their own devices. Create/update/delete refresh the MQTT
  credential cache (see `DtuApp.MqttBroker.Credentials`) so the broker sees new
  credentials without a restart.

  Readings are stored in a TimescaleDB hypertable (`readings`) with continuous
  aggregates (`readings_5m`, `readings_hourly`, `readings_daily`). Chart and
  summary queries prefer the aggregates to avoid scanning raw rows.
  """

  # A chart point is one 5-minute bucket worth of data for one
  # (inverter, mppt) pair. `inverter_name` is the optional display
  # label the user can set; the chart falls back to the serial when
  # it's nil. Shared between `DtuApp.Devices.ChartData` and the
  # Stats cluster — see those modules' @moduledoc for use sites.
  @type series_key ::
          {dtu_id :: pos_integer(), inverter_serial :: String.t(),
           mppt_index :: non_neg_integer(), inverter_name :: String.t() | nil}

  @type chart_point :: %{time: DateTime.t(), series: series_key(), power: float()}

  # Chart helpers (`clamp_household_draw/1`, `chart_power_for_mppt/1`,
  # `bucket_max_from_chart_points/1`, `owned_dtu_ids/2`, `owned?/2`) live in
  # `DtuApp.Devices.ChartHelpers` \u2014 see that module's @moduledoc for the
  # rationale and the per-function docs. Re-exported here via
  # `defdelegate` so the existing `Devices.foo(...)` call sites continue
  # to work unchanged.

  defdelegate clamp_household_draw(value), to: __MODULE__.ChartHelpers
  defdelegate chart_power_for_mppt(point), to: __MODULE__.ChartHelpers
  defdelegate bucket_max_from_chart_points(points), to: __MODULE__.ChartHelpers
  defdelegate owned_dtu_ids(user, dtu_id), to: __MODULE__.ChartHelpers
  defdelegate owned?(user, dtu_id), to: __MODULE__.ChartHelpers

  # CRUD + MQTT credential-cache hooks live in DtuApp.Devices.Credentials so
  # that the device-write / cache-refresh call graph is obvious without
  # paging through 3,000 lines of stats and chart code. Re-exported via
  # defdelegate so existing `Devices.list_devices/1`-style call sites
  # continue to work unchanged.
  defdelegate list_devices(user), to: __MODULE__.Credentials
  defdelegate get_device!(user, id), to: __MODULE__.Credentials
  defdelegate get_device(user, id), to: __MODULE__.Credentials
  defdelegate get_device_by_username(username), to: __MODULE__.Credentials
  defdelegate create_device(user, attrs), to: __MODULE__.Credentials
  defdelegate update_device(dtu, attrs), to: __MODULE__.Credentials
  defdelegate delete_device(dtu), to: __MODULE__.Credentials
  defdelegate change_device(user), to: __MODULE__.Credentials
  defdelegate change_device(user, dtu), to: __MODULE__.Credentials
  defdelegate change_device(user, dtu, attrs), to: __MODULE__.Credentials

  # Telemetry reading ingestion (`create_reading/1`,
  # `create_reading_and_touch_power_at/1`, `update_inverter_name/3`,
  # `patch_latest_reading_status/3`) lives in
  # `DtuApp.Devices.Readings`. Re-exported here so existing
  # `Devices.create_reading/1`-style call sites continue to work
  # unchanged. The guarded implementations (`is_integer/1`,
  # `is_binary/1`) still enforce their preconditions inside the
  # target module; `defdelegate` does not preserve guards at the
  # forward boundary.
  defdelegate create_reading(attrs), to: __MODULE__.Readings
  defdelegate create_reading_and_touch_power_at(attrs), to: __MODULE__.Readings
  defdelegate update_inverter_name(dtu_id, inverter_serial, name), to: __MODULE__.Readings
  defdelegate patch_latest_reading_status(dtu_id, inverter_serial, flags), to: __MODULE__.Readings

  # DTU error-history tracking (`record_dtu_error/2`,
  # `update_dtu_error/2`, `clear_stale_dtu_error/1`,
  # `count_distinct_dtu_errors/2`, `list_dtu_error_groups/2`,
  # plus the per-table tunables `dtu_error_history_cap/0`,
  # `dtu_error_recency_seconds/0`, `dtu_error_recency_cutoff/0`)
  # lives in `DtuApp.Devices.DtuErrors`. Re-exported here so
  # existing call sites continue to work unchanged. The default-arg
  # wrappers on `count_distinct_dtu_errors/2` and
  # `list_dtu_error_groups/2` keep their default values inside the
  # target module; `defdelegate` does not preserve default values
  # at the forward boundary, so we expose both arities here.
  defdelegate dtu_error_history_cap(), to: __MODULE__.DtuErrors
  defdelegate dtu_error_recency_seconds(), to: __MODULE__.DtuErrors
  defdelegate dtu_error_recency_cutoff(), to: __MODULE__.DtuErrors
  defdelegate record_dtu_error(dtu_id, message), to: __MODULE__.DtuErrors
  defdelegate update_dtu_error(dtu_id, message), to: __MODULE__.DtuErrors
  defdelegate clear_stale_dtu_error(dtu_id), to: __MODULE__.DtuErrors
  defdelegate count_distinct_dtu_errors(dtu_id), to: __MODULE__.DtuErrors
  defdelegate count_distinct_dtu_errors(dtu_id, cutoff), to: __MODULE__.DtuErrors
  defdelegate list_dtu_error_groups(dtu_id), to: __MODULE__.DtuErrors
  defdelegate list_dtu_error_groups(dtu_id, cutoff), to: __MODULE__.DtuErrors

  # Export-side reading queries (`list_recent_readings/3`,
  # `export_page_size/0`, `stream_readings_for_export/4`) live in
  # `DtuApp.Devices.ReadingExports`. Re-exported here so existing
  # call sites continue to work unchanged. The default-arg wrapper
  # on `list_recent_readings/3` is reified into both arities here
  # because `defdelegate` does not preserve default values at the
  # forward boundary.
  defdelegate list_recent_readings(user, dtu_id), to: __MODULE__.ReadingExports
  defdelegate list_recent_readings(user, dtu_id, limit), to: __MODULE__.ReadingExports
  defdelegate export_page_size(), to: __MODULE__.ReadingExports

  defdelegate stream_readings_for_export(user, dtu_id, utc_start, utc_end),
    to: __MODULE__.ReadingExports

  # Day-boundary chart data queries (`list_day_readings_for_chart/4`,
  # `local_day_utc_range/2`, `list_day_chart_data/4`,
  # `list_day_chart_data_for_dashboard/4`,
  # `list_yesterday_chart_data_for_dashboard/4`) live in
  # `DtuApp.Devices.ChartData`. Re-exported here so existing call
  # sites continue to work unchanged. The default-arg wrappers are
  # reified to both arities here because `defdelegate` does not
  # preserve default values at the forward boundary.
  defdelegate list_day_readings_for_chart(user, utc_start, utc_end),
    to: __MODULE__.ChartData

  defdelegate list_day_readings_for_chart(user, utc_start, utc_end, dtu_id),
    to: __MODULE__.ChartData

  defdelegate local_day_utc_range(local_date, tz_offset_seconds), to: __MODULE__.ChartData
  defdelegate list_day_chart_data(user, utc_start, utc_end), to: __MODULE__.ChartData
  defdelegate list_day_chart_data(user, utc_start, utc_end, dtu_id), to: __MODULE__.ChartData

  defdelegate list_day_chart_data_for_dashboard(user, utc_start, utc_end),
    to: __MODULE__.ChartData

  defdelegate list_day_chart_data_for_dashboard(user, utc_start, utc_end, dtu_id),
    to: __MODULE__.ChartData

  defdelegate list_yesterday_chart_data_for_dashboard(user, utc_start, utc_end),
    to: __MODULE__.ChartData

  defdelegate list_yesterday_chart_data_for_dashboard(user, utc_start, utc_end, dtu_id),
    to: __MODULE__.ChartData

  # Today-window and net/consumption chart queries
  # (`list_today_readings_for_chart/2`, `list_today_chart_data/2`,
  # `list_today_consumption_chart_data/2`,
  # `list_consumption_chart_data/4`, `list_net_chart_data/4`,
  # `get_net_flow_stats/3`) live in
  # `DtuApp.Devices.ConsumptionChartData`. Re-exported here so
  # existing call sites continue to work unchanged. The default-arg
  # wrappers are reified to both arities here because `defdelegate`
  # does not preserve default values at the forward boundary.
  defdelegate list_today_readings_for_chart(user), to: __MODULE__.ConsumptionChartData
  defdelegate list_today_readings_for_chart(user, dtu_id), to: __MODULE__.ConsumptionChartData
  defdelegate list_today_chart_data(user), to: __MODULE__.ConsumptionChartData
  defdelegate list_today_chart_data(user, dtu_id), to: __MODULE__.ConsumptionChartData
  defdelegate list_today_consumption_chart_data(user), to: __MODULE__.ConsumptionChartData
  defdelegate list_today_consumption_chart_data(user, dtu_id), to: __MODULE__.ConsumptionChartData

  defdelegate list_consumption_chart_data(user, utc_start, utc_end),
    to: __MODULE__.ConsumptionChartData

  defdelegate list_consumption_chart_data(user, utc_start, utc_end, dtu_id),
    to: __MODULE__.ConsumptionChartData

  defdelegate list_net_chart_data(user, utc_start, utc_end), to: __MODULE__.ConsumptionChartData

  defdelegate list_net_chart_data(user, utc_start, utc_end, dtu_id),
    to: __MODULE__.ConsumptionChartData

  defdelegate get_net_flow_stats(user), to: __MODULE__.ConsumptionChartData
  defdelegate get_net_flow_stats(user, dtu_id), to: __MODULE__.ConsumptionChartData
  defdelegate get_net_flow_stats(user, dtu_id, opts), to: __MODULE__.ConsumptionChartData

  # Stats aggregations — production (`get_daily_stats/1..4`,
  # `compute_peak_watts_in_period/4`, `compute_self_consumption_pct/4`),
  # consumption (`get_consumption_daily_stats/1..3`,
  # `integrate_consumption_kwh/4`, `get_consumption_period_stats/4`,
  # `get_consumption_period_stats/5`,
  # `compute_consumption_total_kwh/4`) — live in
  # `DtuApp.Devices.Stats`. Re-exported here so existing call sites
  # continue to work unchanged. The default-arg wrappers are reified
  # to all arities here because `defdelegate` does not preserve
  # default values at the forward boundary.
  defdelegate get_daily_stats(user), to: __MODULE__.Stats
  defdelegate get_daily_stats(user, dtu_id), to: __MODULE__.Stats
  defdelegate get_daily_stats(user, dtu_id, date), to: __MODULE__.Stats
  defdelegate get_daily_stats(user, dtu_id, date, chart_points), to: __MODULE__.Stats

  defdelegate get_daily_stats_for_local_day(user, dtu_id, local_date, tz_offset_seconds),
    to: __MODULE__.Stats

  defdelegate get_consumption_daily_stats(user), to: __MODULE__.Stats
  defdelegate get_consumption_daily_stats(user, dtu_id), to: __MODULE__.Stats
  defdelegate get_consumption_daily_stats(user, dtu_id, opts), to: __MODULE__.Stats

  defdelegate integrate_consumption_kwh(user, dtu_id, utc_start, utc_end),
    to: __MODULE__.Stats

  defdelegate get_consumption_period_stats(user, dtu_id, time_range, selected_period),
    to: __MODULE__.Stats

  defdelegate get_consumption_period_stats(user, dtu_id, time_range, selected_period, cds),
    to: __MODULE__.Stats

  defdelegate compute_consumption_total_kwh(user, dtu_ids, utc_start, utc_end),
    to: __MODULE__.Stats

  defdelegate compute_peak_watts_in_period(user, dtu_id, utc_start, utc_end), to: __MODULE__.Stats
  defdelegate compute_self_consumption_pct(user, dtu_id, utc_start, utc_end), to: __MODULE__.Stats

  # Selectable dates + range yield aggregations
  # (`list_selectable_dates/1`, `list_selectable_dates/2`,
  # `list_range_yield_data/3`, `list_range_yield_data/4`,
  # `list_last_n_days_yield_data/4`, `list_ytd_yield_data/1`,
  # `list_ytd_yield_data/2`) live in
  # `DtuApp.Devices.SelectableDates`. Re-exported here so existing
  # call sites continue to work unchanged.
  defdelegate list_selectable_dates(user), to: __MODULE__.SelectableDates
  defdelegate list_selectable_dates(user, dtu_id), to: __MODULE__.SelectableDates

  defdelegate list_range_yield_data(user, utc_start, utc_end),
    to: __MODULE__.SelectableDates

  defdelegate list_range_yield_data(user, utc_start, utc_end, dtu_id),
    to: __MODULE__.SelectableDates

  defdelegate list_last_n_days_yield_data(user, n, tz_offset_seconds),
    to: __MODULE__.SelectableDates

  defdelegate list_last_n_days_yield_data(user, n, tz_offset_seconds, dtu_id),
    to: __MODULE__.SelectableDates

  defdelegate list_ytd_yield_data(user), to: __MODULE__.SelectableDates
  defdelegate list_ytd_yield_data(user, dtu_id), to: __MODULE__.SelectableDates

  # Pure-data period-stats computations
  # (`compute_day_period_stats/2`, `compute_range_period_stats/2`)
  # live in `DtuApp.Devices.PeriodStats`. Re-exported here so
  # existing call sites continue to work unchanged.
  defdelegate compute_day_period_stats(yields, points), to: __MODULE__.PeriodStats
  defdelegate compute_range_period_stats(yields, divisor), to: __MODULE__.PeriodStats

  # Number / savings / locale formatting (`compute_savings/2`,
  # `format_savings/1`, `format_savings/2`, `format_number/1..3`)
  # lives in `DtuApp.Devices.Formatting`. Re-exported here so
  # existing call sites continue to work unchanged.
  defdelegate compute_savings(kwh, cents), to: __MODULE__.Formatting
  defdelegate format_savings(cents), to: __MODULE__.Formatting
  defdelegate format_savings(cents, locale), to: __MODULE__.Formatting
  defdelegate format_number(value), to: __MODULE__.Formatting
  defdelegate format_number(value, decimals), to: __MODULE__.Formatting
  defdelegate format_number(value, decimals, locale), to: __MODULE__.Formatting
end
