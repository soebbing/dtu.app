defmodule DtuAppWeb.DashboardLive.TimeHelpers do
  @moduledoc """
  Pure date/time helpers used by the dashboard LiveView and its
  per-time-range stat-card renders.

  Every function here is pure — same inputs → same outputs, no
  LiveView state, no DB calls — so the module can be unit-tested
  in isolation. The LiveView's `local_today/1`, `format_peak_time/2`,
  `utc_day_range_for_local_date/2`, and the private `format_time_hhmm/1`
  used to live inline in `DtuAppWeb.DashboardLive`; this module
  extracts them so the dashboard's LiveView stays focused on its
  LiveView-specific concerns (assigns, PubSub, mount/handle_*).

  Sister module: `DtuAppWeb.DashboardLive.PeriodSelectable` owns
  the per-granularity selectable-period builders + stepper helpers.

  Note: `DtuAppWeb.SharedDashboardLive` keeps its own local
  `local_today/1` — deliberately duplicated, not exported, so the
  two views can evolve independently (see the comment in
  `SharedDashboardLive.assign_shared_data/2`).
  """

  use Gettext, backend: DtuAppWeb.Gettext

  @doc """
  "Today" in the user's local timezone.

  Uses the database clock so "today in the user's timezone" matches
  the day the readings table's `inserted_at` was bucketed under.
  See `DtuApp.Time`.

  This is the canonical `local_today` for the *main* dashboard;
  `DtuAppWeb.SharedDashboardLive` keeps its own copy (commented
  as "deliberately duplicated") because it doesn't want a
  `DtuApp.Time` dependency on the public share-link path.
  """
  @spec local_today(integer()) :: Date.t()
  def local_today(tz_offset_seconds) do
    DtuApp.Time.utc_now()
    |> DateTime.add(tz_offset_seconds, :second)
    |> DateTime.to_date()
  end

  @doc """
  Convert a local date (as the user sees it on the dashboard) to
  the inclusive UTC day range `[start_utc, end_utc]` that DB
  queries need to fetch readings for that local day.

  The bounds are 00:00:00 and 23:59:59 in the local timezone,
  shifted back to UTC by `tz_offset_seconds`. Note the end bound
  is the last *second* of the local day (23:59:59), not the first
  second of the next — readers comparing bucket counts to wall
  clocks depend on this.
  """
  @spec utc_day_range_for_local_date(Date.t(), integer()) ::
          {DateTime.t(), DateTime.t()}
  def utc_day_range_for_local_date(%Date{} = local_date, tz_offset_seconds) do
    {:ok, start_local} = DateTime.new(local_date, ~T[00:00:00])
    {:ok, end_local} = DateTime.new(local_date, ~T[23:59:59])

    {DateTime.add(start_local, -tz_offset_seconds, :second),
     DateTime.add(end_local, -tz_offset_seconds, :second)}
  end

  @doc """
  Format a UTC `DateTime` as the user's local HH:MM.

  Returns `—` (em-dash) when the time is nil — the bucket-peak
  helper returns nil for an empty window (no buckets means no
  peak time), and a "—" placeholder reads more clearly than a
  blank string. The shift uses the same `tz_offset_seconds`
  channel the chart axis labels use, so the peak-time card and
  the chart agree on what "13:42" means.
  """
  @spec format_peak_time(DateTime.t() | nil, integer()) :: String.t()
  def format_peak_time(nil, _tz_offset_seconds), do: "—"

  def format_peak_time(%DateTime{} = dt, tz_offset_seconds) do
    dt
    |> DateTime.add(tz_offset_seconds, :second)
    |> format_time_hhmm()
  end

  # "HH:MM" string for an already-local `DateTime`. We don't bother
  # with seconds — the chart's X-axis labels are hour-aligned and
  # the user reads minutes at most, so second-precision would be
  # visual noise on the peak-time card.
  @spec format_time_hhmm(DateTime.t()) :: String.t()
  def format_time_hhmm(%DateTime{} = dt) do
    :io_lib.format("~2..0B:~2..0B", [dt.hour, dt.minute])
    |> IO.iodata_to_binary()
  end

  @doc """
  Human-friendly relative-time label for the device-status card's
  "Last seen:" line.

  Returns `"just now"` / `"%{n} minutes ago"` / `"%{n} hours ago"`
  / `"%{n} days ago"` for the past week, then falls back to the
  absolute `YYYY-MM-DD HH:MM UTC` string for older timestamps
  (where minute/hour counts get unwieldy). Future timestamps
  (`diff < 0` after the read) are clamped to `"just now"` rather
  than rendering negative values.

  Was a `defp` in `DtuAppWeb.DashboardLive`; promoted to this
  module when the device-status-card render was extracted to its
  own Phoenix component (`DtuAppWeb.DeviceStatusCard`), which
  can't resolve free function references in its template.
  """
  @spec relative_time_label(DateTime.t(), DateTime.t()) :: String.t()
  def relative_time_label(%DateTime{} = dt, now \\ DtuApp.Time.utc_now()) do
    diff = DateTime.diff(now, dt, :second) |> max(0)

    cond do
      diff < 60 ->
        gettext("just now")

      diff < 3_600 ->
        gettext("%{n} minutes ago", n: div(diff, 60))

      diff < 86_400 ->
        gettext("%{n} hours ago", n: div(diff, 3_600))

      diff < 604_800 ->
        gettext("%{n} days ago", n: div(diff, 86_400))

      true ->
        Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
    end
  end
end
