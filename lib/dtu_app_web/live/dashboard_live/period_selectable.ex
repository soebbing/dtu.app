defmodule DtuAppWeb.DashboardLive.PeriodSelectable do
  @moduledoc """
  Selectable-period builders + stepper UI helpers for the dashboard
  LiveView's "Custom" preset toolbar.

  Every function here is pure — same inputs → same outputs, no
  LiveView state, no DB calls — so the module can be unit-tested
  in isolation. The `assign_selectable_periods/3` helper
  delegates the DB read to `DtuApp.Devices.list_selectable_dates/2`
  (it owns the assign-pipeline; the builders take whatever dates
  the caller already fetched).

  Sister module: `DtuAppWeb.DashboardLive.TimeHelpers` owns the
  date/time math (`local_today/1`, `format_peak_time/2`, …).

  Functions called from the dashboard's HEEx template
  (`historical_empty?/5`, `date_input_value/1`, `date_min_bound/1`,
  `date_max_bound/1`) are public so the LiveView can `import` them
  and call them as bare names in the template.
  """

  use Gettext, backend: DtuAppWeb.Gettext

  alias DtuApp.Devices

  @doc """
  Refresh the dashboard's selectable-period assigns from the DB.

  Reads `selectable_dates` for `(user, dtu_id)` via
  `DtuApp.Devices.list_selectable_dates/2`, then buckets them into
  per-granularity lists (`selectable_days/weeks/months/years`).
  Returns the socket unchanged-but-assigned.

  Called on every mount + every DTU switch — the stepper widget
  reads these assigns to know what calendar bounds + dropdown
  options to show.
  """
  @spec assign_selectable_periods(Phoenix.LiveView.Socket.t(), any(), integer() | nil) ::
          Phoenix.LiveView.Socket.t()
  def assign_selectable_periods(socket, user, dtu_id) do
    dates = Devices.list_selectable_dates(user, dtu_id)

    socket
    |> Phoenix.Component.assign(:selectable_dates, dates)
    |> Phoenix.Component.assign(:selectable_days, build_selectable_days(dates))
    |> Phoenix.Component.assign(:selectable_weeks, build_selectable_weeks(dates))
    |> Phoenix.Component.assign(:selectable_months, build_selectable_months(dates))
    |> Phoenix.Component.assign(:selectable_years, build_selectable_years(dates))
  end

  # --- Selectable-period builders --------------------------------------------

  @doc """
  Per-day list of `{label, iso_date}` for the day-granularity stepper.
  Sorted by date (most recent last — the stepper iterates in order).
  """
  @spec build_selectable_days([Date.t()]) :: [{String.t(), String.t()}]
  def build_selectable_days(dates) do
    dates
    |> Enum.map(fn date ->
      label = Calendar.strftime(date, "%Y-%m-%d")
      {label, Date.to_string(date)}
    end)
  end

  @doc """
  Per-week list of `{label, iso_monday}` for the week-granularity
  stepper. Each ISO week is represented by its Monday (the
  ISO-week-1 representative date) and labelled via gettext. Sorted
  newest-week first.
  """
  @spec build_selectable_weeks([Date.t()]) :: [{String.t(), String.t()}]
  def build_selectable_weeks(dates) do
    dates
    |> Enum.group_by(fn d ->
      :calendar.iso_week_number({d.year, d.month, d.day})
    end)
    |> Enum.map(fn {{year, week}, week_dates} ->
      representative_date = hd(week_dates)
      monday = Date.add(representative_date, -(Date.day_of_week(representative_date) - 1))

      label =
        gettext(
          "Year %{year}, Week %{week} (starting %{monday})",
          year: year,
          week: week,
          monday: monday
        )

      {label, Date.to_string(monday)}
    end)
    |> Enum.sort_by(fn {_, val} -> val end, :desc)
  end

  @doc """
  Per-month list of `{translated_month_label, iso_first_of_month}`
  for the month-granularity stepper. The month name goes through
  `Gettext.gettext/2` so it follows the user's locale. Sorted
  newest-month first.
  """
  @spec build_selectable_months([Date.t()]) :: [{String.t(), String.t()}]
  def build_selectable_months(dates) do
    dates
    |> Enum.map(fn d -> {d.year, d.month} end)
    |> Enum.uniq()
    |> Enum.map(fn {year, month} ->
      first_day = Date.new!(year, month, 1)
      translated_month = Gettext.gettext(DtuAppWeb.Gettext, Calendar.strftime(first_day, "%B"))
      label = "#{translated_month} #{first_day.year}"
      {label, Date.to_string(first_day)}
    end)
    |> Enum.sort_by(fn {_, val} -> val end, :desc)
  end

  @doc """
  Per-year list of `{year_string, year_string}` for the year-
  granularity stepper. Sorted newest-year first.
  """
  @spec build_selectable_years([Date.t()]) :: [{String.t(), String.t()}]
  def build_selectable_years(dates) do
    dates
    |> Enum.map(& &1.year)
    |> Enum.uniq()
    |> Enum.map(fn year ->
      {to_string(year), to_string(year)}
    end)
    |> Enum.sort(:desc)
  end

  # --- Calendar input + empty-state helpers ----------------------------------
  #
  # These are imported into the dashboard LiveView and called as
  # bare names from the HEEx template — keep them public for that.

  @doc """
  Value for the native date input (`yyyy-mm-dd`). Accepts either a
  `Date` (day/week/month granularity) or an integer year (year
  granularity); anything else falls back to today's ISO date so
  the calendar widget always has a valid string.
  """
  @spec date_input_value(Date.t() | integer() | any()) :: String.t()
  def date_input_value(%Date{} = date), do: Date.to_iso8601(date)

  def date_input_value(year) when is_integer(year),
    do: Date.new!(year, 1, 1) |> Date.to_iso8601()

  def date_input_value(_), do: Date.utc_today() |> Date.to_iso8601()

  @doc """
  Earliest date with data, for the calendar widget's `min` bound
  (`yyyy-mm-dd`). Returns nil when the user has no data so the
  calendar renders unbounded below.
  """
  @spec date_min_bound([Date.t()]) :: String.t() | nil
  def date_min_bound([]), do: nil
  def date_min_bound(dates), do: dates |> Enum.min(Date) |> Date.to_iso8601()

  @doc """
  Latest date with data, for the calendar widget's `max` bound
  (`yyyy-mm-dd`). Returns nil when the user has no data.
  """
  @spec date_max_bound([Date.t()]) :: String.t() | nil
  def date_max_bound([]), do: nil
  def date_max_bound(dates), do: dates |> Enum.max(Date) |> Date.to_iso8601()

  @doc """
  True when the active historical granularity has no data to show.
  Drives the "No historical data for this period." sub-caption
  that appears next to the stepper. The five-arg signature
  mirrors the dashboard's `selectable_days / weeks / months /
  years` assigns so the template can pass them in order without
  re-bucketing.

  Unknown granularities return `false` — the dashboard's live /
  today view isn't "empty" in the same sense, and showing the
  caption there would be wrong.
  """
  @spec historical_empty?(
          String.t(),
          [any()],
          [any()],
          [any()],
          [any()]
        ) :: boolean()
  def historical_empty?("day", days, _, _, _), do: days == []
  def historical_empty?("week", _, weeks, _, _), do: weeks == []
  def historical_empty?("month", _, _, months, _), do: months == []
  def historical_empty?("year", _, _, _, years), do: years == []
  def historical_empty?(_, _, _, _, _), do: false
end
