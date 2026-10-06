defmodule DtuApp.Devices.ChartHelpers do
  @moduledoc """
  Small pure helpers used across the `Devices` context's chart and stats
  modules.

  Three concerns, each one a single function:

    * `clamp_household_draw/1` — the household-draw (Shelly consumption)
      numbers come off the wire as negative when the home is exporting.
      The dashboard only ever wants a non-negative draw; this clamps
      negatives to 0.0 and returns the input as a float otherwise.
    * `chart_power_for_mppt/1` — the production chart's per-MPPT Y value.
      Inverters report `ac_power` on the AC aggregate row (mppt_index 0)
      and `dc_power` on per-string rows (mppt_index ≥ 1). The chart plots
      one line per *inverter* (the AC aggregate), so mppt 0 picks `ac_power`
      and any other mppt falls back to `dc_power`. Rows with no power
      field (AhoyDTU yield-only flushes before the AC reading lands)
      contribute 0.0 instead of crashing the chart.
    * `bucket_max_from_chart_points/1` — the max *combined* power across
      a chart-point bucket list (sum across series at each bucket, max
      over buckets). Used by `Stats.get_daily_stats/4` to size the Y
      axis on daily-yield views and to compute the headline `peak_power`
      for multi-inverter fleets.
    * `peak_bucket_from_chart_points/1` — `{power, time}` of the
      max-sum bucket from `bucket_max_from_chart_points/1`'s input.
      Used by `Stats.ProductionStats.compute_peak_watts_in_period/4`
      for the 1D / 7D / 30D / YTD stat-card peak tile — needs the time
      alongside the power to label the peak on the dashboard.

  Plus the per-user DTU-ownership helpers:

    * `owned_dtu_ids/2` — returns the list of DTU IDs owned by `user`.
      When called with `nil` (the typical "all my devices" query), reads
      through `UserDtuIdsCache` to avoid the per-call `SELECT id FROM dtus
      WHERE user_id = $1` that the dashboard mounts ~22 times.
      `DashboardLive.refresh_devices/2` invalidates the cache after every
      device write so a freshly-created or removed DTU is visible in the
      next call.
    * `owned?/2` — the per-DTU single-row check that backs
      `owned_dtu_ids/2`'s `dtu_id` clause.

  All functions live here so each `Devices.<SubModule>` that needs them
  can `alias DtuApp.Devices.ChartHelpers` without dragging the rest of
  the Devices context into its compile graph.
  """

  import Ecto.Query

  alias DtuApp.Accounts.User
  alias DtuApp.Devices.Dtu
  alias DtuApp.Devices.UserDtuIdsCache
  alias DtuApp.Repo

  @spec clamp_household_draw(number() | nil) :: float()
  def clamp_household_draw(nil), do: 0.0
  def clamp_household_draw(value) when is_number(value) and value < 0.0, do: 0.0
  def clamp_household_draw(value) when is_number(value), do: value * 1.0

  @spec chart_power_for_mppt(map()) :: float()
  def chart_power_for_mppt(%{mppt_index: 0, ac_power: ac}) when not is_nil(ac), do: ac
  def chart_power_for_mppt(%{mppt_index: _, dc_power: dc}) when not is_nil(dc), do: dc
  def chart_power_for_mppt(_), do: 0.0

  @spec bucket_max_from_chart_points([map()]) :: float()
  def bucket_max_from_chart_points([]), do: 0.0

  def bucket_max_from_chart_points(points) do
    case peak_bucket_from_chart_points(points) do
      {power, _time} -> power
      nil -> 0.0
    end
  end

  @doc """
  Returns `{power, time}` of the chart-point bucket whose series'
  combined power is highest across all buckets in `points`, or `nil`
  when no AC-aggregate (`mppt_index = 0`) series are present.

  Sums across series within the same bucket so multi-inverter fleets
  see the *combined* peak (two inverters each producing 600 W at 10:00
  return 1_200 W, not 600 W). Single-inverter behaviour is unchanged:
  sum-of-one series equals max-of-one series. Per-MPPT rows
  (`mppt_index >= 1`) are filtered out — the dashboard only ever
  plots the AC aggregate as `peak_power`, and including per-MPPT
  rows here would double-count inverters that publish both an AC
  aggregate row and per-string sub-totals.

  Time precision matches whatever the caller passed in (NaiveDateTime
  from the `readings_5m` aggregate, `%DateTime{}` from raw rows, etc).
  """
  @spec peak_bucket_from_chart_points([map()]) ::
          {float(), DateTime.t() | NaiveDateTime.t()} | nil
  def peak_bucket_from_chart_points(points) do
    points
    |> Enum.filter(fn pt -> elem(pt.series, 2) == 0 end)
    |> Enum.group_by(fn pt -> pt.time end)
    |> Enum.map(fn {time, bucket_pts} ->
      power = bucket_pts |> Enum.map(fn pt -> pt.power || 0.0 end) |> Enum.sum()
      {power, time}
    end)
    |> Enum.max_by(fn {power, _time} -> power end, fn -> nil end)
  end

  @spec owned_dtu_ids(User.t(), integer() | nil) :: [integer()]
  # Resolve the user's DTU ids for a query, scoped to either all of the user's
  # devices or one specific (owned) device. Returns [] if the device isn't owned.
  #
  # The `dtu_id = nil` branch is read-through cached for 30 s — a single
  # dashboard mount calls this ~22 times (once per chart/stats helper
  # that scopes its `WHERE dtu_id IN ^dtu_ids` clause), and the
  # profile harness shows 18.39 s of cumulative DB time on the
  # underlying `SELECT id FROM dtus WHERE user_id = $1`. See
  # `DtuApp.Devices.UserDtuIdsCache` for the rationale and the
  # invalidation hook (`DashboardLive.refresh_devices/2` calls
  # `UserDtuIdsCache.invalidate/1` after every device write so a
  # freshly-created or removed device is reflected in the next
  # `owned_dtu_ids/2` call without waiting out the TTL).
  def owned_dtu_ids(%User{} = user, nil) do
    UserDtuIdsCache.get(user.id, fn ->
      Repo.all(from d in Dtu, where: d.user_id == ^user.id, select: d.id)
    end)
  end

  def owned_dtu_ids(%User{} = user, dtu_id) do
    if owned?(user, dtu_id), do: [dtu_id], else: []
  end

  @spec owned?(User.t(), integer()) :: boolean()
  def owned?(%User{} = user, dtu_id) do
    Repo.exists?(from d in Dtu, where: d.user_id == ^user.id and d.id == ^dtu_id)
  end
end
