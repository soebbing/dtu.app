defmodule DtuApp.Devices.Stats.PeriodHelpers do
  @moduledoc """
  Pure date-range helpers used by the consumption-side period
  stats. Each function takes either `nil` (today / this week / this
  month / this year) or a `%Date{}` and returns the matching
  `{first, last}` pair.

  These are pure: no DB calls, no clock reads. The single non-pure
  input is `Date.utc_today/0` for the `nil` branches — callers that
  want to test specific dates should pass an explicit `%Date{}` and
  they'll never hit the clock. The helpers are intentionally
  format-free: they return `%Date{}` pairs (or, for `year_value/1`,
  integers), which the chart code then projects to a UTC window via
  `DtuApp.Devices.ChartData.local_day_utc_range/2`.

  These helpers are not `defdelegate`d back through
  `DtuApp.Devices.Stats` — they're internal to the stats
  sub-folder and only the `ConsumptionStats` sibling calls them.
  """

  # Build the (today, start) date pair for the trailing-N-days presets.
  # `today_start` is `DateTime.new!(Date.utc_today(), ~T[00:00:00],
  # "Etc/UTC")` — the helper the rest of the function passes around;
  # we only need its date component.
  def last_n_days_window(n, today_start) do
    today_local = DateTime.to_date(today_start)
    {today_local, Date.add(today_local, -(n - 1))}
  end

  @doc """
  The "no devices" zero map returned by
  `DtuApp.Devices.Stats.ConsumptionStats.get_consumption_period_stats/5`
  when the user owns no DTUs.
  """
  def zero_period_stats do
    %{
      current_consumption: 0.0,
      today_consumption: 0.0,
      peak_consumption: 0.0,
      period_total_consumption: 0.0,
      period_peak_consumption: 0.0,
      peak_date: nil
    }
  end

  # Resolve the local Date for a consumption-period stats query. The
  # dashboard passes `selected_period` which can be `nil` (today) or
  # a `%Date{}` for historical views.
  def resolve_consumption_period_date(nil, today_utc_start) do
    {today_utc_start, Date.utc_today()}
  end

  def resolve_consumption_period_date(%Date{} = d, _today_utc_start), do: {d, d}

  def resolve_consumption_period_date(_other, today_utc_start),
    do: {today_utc_start, Date.utc_today()}

  # Mon..Sun range for the week view, anchored on the most recent
  # week with data (or this week if `selected_period` is `nil`).
  def week_range(nil, today_utc_start) do
    week_range(
      Date.utc_today() |> Date.add(-(Date.day_of_week(Date.utc_today()) - 1)),
      today_utc_start
    )
  end

  def week_range(%Date{} = d, _today_utc_start) do
    monday = Date.add(d, -(Date.day_of_week(d) - 1))
    sunday = Date.add(monday, 6)
    {monday, sunday}
  end

  # First..last day of the month, anchored on the month of the
  # provided Date (or this month if `nil`).
  def month_range(nil, _today_utc_start) do
    today = Date.utc_today()
    first = Date.new!(today.year, today.month, 1)
    {first, Date.end_of_month(first)}
  end

  def month_range(%Date{} = d, _today_utc_start) do
    first = Date.new!(d.year, d.month, 1)
    {first, Date.end_of_month(first)}
  end

  # Integer year for the year view, anchored on the year of the
  # provided Date (or this year if `nil`).
  def year_value(nil), do: Date.utc_today().year
  def year_value(%Date{} = d), do: d.year
  def year_value(y) when is_integer(y), do: y
end
