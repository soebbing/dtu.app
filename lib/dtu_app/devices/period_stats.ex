defmodule DtuApp.Devices.PeriodStats do
  @moduledoc """
  Pure-data period-stats computations.

  Two helpers, both side-effect-free and DB-free:

    * `compute_day_period_stats/2` — roll up the day's
      `[{date, yield_kwh}]` rows and the bucketed `chart_point`
      list into the stat-card shape (`total_yield`,
      `peak_power`, `peak_time`, etc.). The day-view reads this
      straight on the dashboard render path.
    * `compute_range_period_stats/2` — same shape over an
      arbitrary range, but with `avg_yield` instead of `peak`
      since the range may span a year.

  Re-exported through `DtuApp.Devices` via `defdelegate` so
  existing call sites continue to work unchanged.
  """

  @type chart_point :: DtuApp.Devices.chart_point()

  @doc """
  Roll up the day-view "stat cards" from a day's yields and chart points.

  Used by `DashboardLive` for the per-day granularity. The day shape is
  `{total_yield, peak_power, avg_power}` (no `peak_date` — the day view's
  peak is the highest sampled power, which is intrinsically tied to the
  day itself).

  Both inputs are already user-scoped (yields come from
  `list_range_yield_data/4`, points from `list_day_chart_data/4`), so this
  function is pure data-shaping with no DB access.
  """
  @spec compute_day_period_stats([{Date.t(), float()}], [chart_point()]) :: %{
          total_yield: float(),
          peak_power: float(),
          peak_time: DateTime.t() | nil,
          avg_power: float()
        }
  def compute_day_period_stats(yields, points) do
    total_yield =
      case yields do
        [{_date, y}] -> y
        _ -> 0.0
      end

    # Peak power + peak time come from the same 5-min bucket scan.
    # The `peak_time` is the bucket's `time` field (UTC). The
    # dashboard formats it as HH:MM in the user's local timezone.
    # `peak_time == nil` when the window has no chart points — the
    # stats card then renders a `—` placeholder instead of `00:00`.
    {peak_power, peak_time} =
      case points do
        [] ->
          {0.0, nil}

        pts ->
          top =
            Enum.max_by(pts, fn pt ->
              case pt.power do
                nil -> 0.0
                p -> p
              end
            end)

          {top.power || 0.0, top.time}
      end

    avg_power =
      case points do
        [] -> 0.0
        pts -> Enum.sum(pts |> Enum.map(& &1.power)) / length(pts)
      end

    %{
      total_yield: Float.round(total_yield * 1.0, 1),
      peak_power: Float.round(peak_power * 1.0, 1),
      peak_time: peak_time,
      avg_power: Float.round(avg_power * 1.0, 1)
    }
  end

  @doc """
  Roll up the week/month/year "stat cards" from a range's daily yields.

  Returns `{total_yield, avg_yield, peak_date, peak_val}` — `avg_yield`
  is the average per day across the period (`total_yield / divisor`),
  `peak_date`/`peak_val` are the single highest-yield day. `divisor` is
  the number of days the period spans (7 for a week, days-in-month for a
  month, 12 for a year) — the caller computes it from the calendar, not
  from the data, so a partial period (e.g. the first week of operation)
  still averages over the calendar's full span.

  `yields` comes from `list_range_yield_data/4` (already user-scoped).
  """
  @spec compute_range_period_stats([{Date.t(), float()}], pos_integer()) :: %{
          total_yield: float(),
          avg_yield: float(),
          peak_date: Date.t() | nil,
          peak_val: float()
        }
  def compute_range_period_stats(yields, divisor) when is_integer(divisor) and divisor > 0 do
    total_yield = yields |> Enum.map(fn {_, y} -> y end) |> Enum.sum()
    avg_yield = total_yield / (divisor * 1.0)

    {peak_date, peak_val} =
      case yields do
        [] -> {nil, 0.0}
        list -> list |> Enum.max_by(fn {_, y} -> y end, fn -> {nil, 0.0} end)
      end

    %{
      total_yield: Float.round(total_yield * 1.0, 1),
      avg_yield: Float.round(avg_yield * 1.0, 1),
      peak_date: peak_date,
      peak_val: Float.round(peak_val * 1.0, 1)
    }
  end

end
