defmodule DtuApp.Devices.SelectableDates do
  @moduledoc """
  Selectable dates + range yield aggregations.

  Three concerns, all read-side:

    1. **Selectable dates list** (`list_selectable_dates/2`) —
       powers the dashboard's date picker and
       `PeriodSelectable.assign_selectable_periods/3`. Bounded to
       `@selectable_dates_max_lookback_days 5 * 365` to keep the
       `readings_daily` scan O(active chunks); see the module
       attribute's comment for the perf-trail rationale.
    2. **Range yield** (`list_range_yield_data/4`) — daily kWh
       totals over an arbitrary UTC window. The dashboard's
       "selected range" charts read from here.
    3. **Trailing windows** (`list_last_n_days_yield_data/4`,
       `list_ytd_yield_data/2`) — pre-windowed aggregations. The
       7d / 30d / YTD cards read from these.

  Re-exported through `DtuApp.Devices` via `defdelegate` so
  existing call sites continue to work unchanged.
  """

  import Ecto.Query

  alias DtuApp.Accounts.User
  alias DtuApp.Devices.ChartData
  alias DtuApp.Devices.Reading
  alias DtuApp.Devices.SelectableDatesCache
  alias DtuApp.Repo

  import DtuApp.Devices.ChartHelpers, only: [owned_dtu_ids: 2]

  @selectable_dates_max_lookback_days 5 * 365

  @doc "List selectable dates containing telemetry readings."
  def list_selectable_dates(%User{} = user, dtu_id \\ nil) do
    # The whole DB-backed body is wrapped in a per-(user_id, dtu_id)
    # TTL cache. `assign_selectable_periods/3` calls this on every
    # mount (HTTP+WS = 2×/mount) and on every DTU switch; even after
    # the readings_5m cagg move the DISTINCT scan across 5 years is
    # the single largest remaining query on the dashboard mount. The
    # cache collapses the HTTP+WS mount pair to a single round trip
    # and the per-DTU-switch storm (every toolbar change) to a single
    # round trip per `(user_id, dtu_id)` per 30 s window.
    SelectableDatesCache.get(user.id, dtu_id, fn ->
      dtu_ids = owned_dtu_ids(user, dtu_id)

      if dtu_ids == [] do
        []
      else
        lookback_cutoff =
          Date.utc_today()
          |> Date.add(-@selectable_dates_max_lookback_days)
          |> DateTime.new!(~T[00:00:00], "Etc/UTC")

        # Read distinct dates from `readings_5m` instead of the raw
        # `readings` hypertable. The raw-row path walked every
        # compressed chunk in the 5-year lookback — ~5 s on the
        # production DB, the single largest query on the dashboard
        # mount per the 2026-09-01 perf profile. The cagg stores one
        # row per (dtu_id, 5-min bucket), and the `(dtu_id, bucket
        # DESC)` index added in
        # `20260818195333_add_readings_5m_dtu_bucket_index` makes the
        # distinct-date walk an index-only range scan — typically
        # sub-second even on multi-year installs.
        #
        # The cagg's `materialized_only => false` default means the
        # view unions recent raw rows in, so freshly-arrived readings
        # show up in the result without waiting for the next policy
        # refresh.
        Repo.all(
          from a in "readings_5m",
            where: a.dtu_id in ^dtu_ids and a.bucket >= ^lookback_cutoff,
            select: fragment("(?::date)", a.bucket),
            distinct: true,
            order_by: [desc: fragment("(?::date)", a.bucket)]
        )
        |> Enum.map(fn
          %Date{} = d -> d
          str when is_binary(str) -> Date.from_iso8601!(str)
        end)
      end
    end)
  end

  @doc "Fetch daily yield totals over a date range."
  def list_range_yield_data(%User{} = user, utc_start, utc_end, dtu_id \\ nil)
      when is_struct(utc_start, DateTime) and is_struct(utc_end, DateTime) do
    dtu_ids = owned_dtu_ids(user, dtu_id)

    if dtu_ids == [] do
      []
    else
      # Sum each inverter's last `yield_day` reading of the day across
      # every inverter (and across the user's DTUs). Per-inverter
      # `yield_day` is monotonic Wh that resets at midnight, so the
      # day's per-inverter total IS its last reading of the day —
      # summing across inverters gives the fleet's daily total
      # without depending on the firmware-aggregated `{base}/total`
      # topic (which the parser now drops).
      #
      # `DISTINCT ON (date, dtu_id, inverter_serial)` ordered by
      # `inserted_at DESC` picks the latest row per inverter per day.
      # `mppt_index = 0` so multi-MPPT AhoyDTU inverters don't
      # double-count ch0 + ch1 + ch2 yields. `inverter_serial !=
      # "_fleet"` is defensive against any legacy `_fleet` rows
      # older parser versions persisted (the current parser never
      # creates them — see `telemetry.ex`'s `[binary_base, "total"]`
      # ignored-topic clauses).
      latest_per_inverter_per_day =
        Repo.all(
          from r in Reading,
            where:
              r.dtu_id in ^dtu_ids and r.mppt_index == 0 and
                r.inverter_serial != "_fleet" and
                r.inserted_at >= ^utc_start and r.inserted_at <= ^utc_end,
            distinct: [fragment("?::date", r.inserted_at), r.dtu_id, r.inverter_serial],
            order_by: [
              fragment("?::date", r.inserted_at),
              r.dtu_id,
              r.inverter_serial,
              desc: r.inserted_at
            ],
            select: %{
              date: fragment("?::date", r.inserted_at),
              dtu_id: r.dtu_id,
              inverter_serial: r.inverter_serial,
              yield_day: r.yield_day
            }
        )

      daily_yields =
        latest_per_inverter_per_day
        |> Enum.group_by(fn r ->
          case r.date do
            %Date{} = d -> d
            str when is_binary(str) -> Date.from_iso8601!(str)
          end
        end)
        |> Enum.map(fn {date, date_readings} ->
          # Sum each inverter's last reading of the day. Missing
          # `yield_day` (nil from a half-published reading) counts
          # as 0 so a partial day doesn't blow up the headline.
          {date, date_readings |> Enum.map(&(&1.yield_day || 0.0)) |> Enum.sum()}
        end)
        |> Map.new()

      all_dates =
        Map.keys(daily_yields)
        |> Enum.uniq()
        |> Enum.sort()

      # `readings.yield_day` is in Wh (see comment in `get_daily_stats/2`).
      # The historical chart and `total_yield` for the `stats` map both
      # render with a kWh label, so convert here.
      Enum.map(all_dates, fn date ->
        {date, (daily_yields[date] || 0.0) / 1000}
      end)
    end
  end

  @doc """
  Fetch the daily yield totals for the trailing `n` days (inclusive of
  today). Backed by `list_range_yield_data/4` over the `[start_of_window,
  end_of_today]` UTC range — pure call-site convenience for the dashboard's
  `7D` and `30D` presets, which would otherwise have to compute the window
  themselves.

  The window is anchored at **local midnight** `n - 1` days ago (so a `7D`
  request always returns up to 7 daily buckets, today included) and ends
  at the same local midnight + 24 h. The `tz_offset_seconds` argument is
  the user's offset (set by `DashboardLive`'s `SetTimezone` hook) so a
  user in CET calling `7D` at 01:00 local gets a window starting at the
  previous Monday 00:00 CET, not Sunday 23:00 UTC.

  Returns `[]` for users with no DTUs (matches `list_range_yield_data/4`).
  """
  @spec list_last_n_days_yield_data(User.t(), pos_integer(), integer(), integer() | nil) ::
          [{Date.t(), float()}]
  def list_last_n_days_yield_data(%User{} = user, n, tz_offset_seconds, dtu_id \\ nil)
      when is_integer(n) and n > 0 and is_integer(tz_offset_seconds) do
    today_local = devices_local_today(tz_offset_seconds)
    start_local = Date.add(today_local, -(n - 1))
    {start_utc, _} = ChartData.local_day_utc_range(start_local, tz_offset_seconds)
    {_, end_utc} = ChartData.local_day_utc_range(today_local, tz_offset_seconds)
    list_range_yield_data(user, start_utc, end_utc, dtu_id)
  end

  @doc """
  Fetch monthly yield totals for the year-to-date (Jan 1 of the current
  year through today), bucketed per month. Backed by
  `list_range_yield_data/4` over the same UTC range and then rolled up
  into `[{{year, month}, kWh}]` for the dashboard's `YTD` preset.

  The current year is computed from `Date.utc_today/0` (no timezone
  adjustment — the user's local year and the UTC year agree for every
  real-world solar installer's workday; switching on the user's tz
  here would cause a CET user's January 1 morning to land on the
  previous year's December 31 bucket).

  Returns `[]` for users with no DTUs.
  """
  @spec list_ytd_yield_data(User.t(), integer() | nil) :: [{{integer(), 1..12}, float()}]
  def list_ytd_yield_data(%User{} = user, dtu_id \\ nil) do
    today = Date.utc_today()
    start_date = Date.new!(today.year, 1, 1)
    {start_utc, _} = ChartData.local_day_utc_range(start_date, 0)
    {_, end_utc} = ChartData.local_day_utc_range(today, 0)

    list_range_yield_data(user, start_utc, end_utc, dtu_id)
    |> Enum.group_by(fn {date, _} -> {date.year, date.month} end)
    |> Enum.map(fn {{year, month}, yields} ->
      {{year, month}, yields |> Enum.map(fn {_, kwh} -> kwh end) |> Enum.sum()}
    end)
    |> Enum.sort()
  end

  # Local "today" anchored on the user's tz offset. Mirrors
  # `DtuAppWeb.DashboardLive.local_today/1` — the dashboard already
  # passes the offset in, so we just need the helper here to keep
  # `list_last_n_days_yield_data/3` self-contained (it doesn't reach
  # into a LiveView).
  defp devices_local_today(tz_offset_seconds) do
    DtuApp.Time.utc_now()
    |> DateTime.add(tz_offset_seconds, :second)
    |> DateTime.to_date()
  end
end
