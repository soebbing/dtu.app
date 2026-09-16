defmodule DtuApp.Notifications.SunDown.Payload do
  @moduledoc """
  Pure payload-building + formatting extracted from
  `DtuApp.Notifications.SunDown`. Owns the function that turns
  a `%User{}` + a `%Date{}` into the map shape
  `assets/js/notifications.js`'s `formatPayload` consumes, plus
  the gettext formatting helpers (`body_for/2`, `compare/3`,
  `format_kwh/1`, `format_w/1`) that build the body string.

  Mirrors the `DtuApp.Devices/Stats` sub-folder pattern
  (production_stats / consumption_stats / period_helpers).
  Re-exported through `DtuApp.Notifications.SunDown` via
  `defdelegate` so the notifier's call sites and the existing
  test surface stay unchanged.
  """

  use Gettext, backend: DtuAppWeb.Gettext

  alias DtuApp.Accounts.User
  alias DtuApp.Devices

  @doc """
  Build the `sun_down` notification payload for `user`, `local_date`
  (the user's local calendar day), and `tz_offset_seconds` (the
  user's `User.tz_offset_seconds`).

  Translates the local date to the inclusive UTC range
  `[00:00 local, 23:59:59 local]` via
  `DtuApp.Devices.ChartData.local_day_utc_range/2` and queries
  `DtuApp.Devices.get_daily_stats_for_local_day/4`. The previous
  2-arity used `Date.utc_today()`-style semantics and queried the
  UTC midnight-to-midnight window — that misalignment is what
  caused CEST users to receive "no end-of-day summary" rows on
  days when their local morning production (UTC 22:00–23:59 of the
  previous calendar day) fell outside the queried range. The
  local-date variant closes the gap for non-UTC users while
  keeping the same return shape.

  Returns a map shaped for `assets/js/notifications.js`'s
  `formatPayload` (see the `sun_down` branch at line ~212 of that
  file). `today_yield` is converted from Wh to kWh (the readings
  schema stores Wh; the JS formatter expects kWh). `peak_power` is
  already W.

  Returns `nil` when the user has no devices (no point firing a
  summary that reads "0.0 kWh today" — the user has nothing to
  summarise). Caller is expected to no-op on `nil`.
  """
  @spec build_payload(User.t(), Date.t(), integer()) :: map() | nil
  def build_payload(%User{} = user, %Date{} = local_date, tz_offset_seconds)
      when is_integer(tz_offset_seconds) do
    today = Devices.get_daily_stats_for_local_day(user, nil, local_date, tz_offset_seconds)

    # A user with no devices / no readings at all returns
    # `current_power: 0.0` and `per_series: []`. Skip the notification
    # — the user has nothing to summarise, so the OS banner would
    # just read "Today: 0.0 kWh, peak 0.0 W." (annoying and useless).
    if today.current_power == 0.0 and today.per_series == [] do
      nil
    else
      yesterday =
        Devices.get_daily_stats_for_local_day(
          user,
          nil,
          Date.add(local_date, -1),
          tz_offset_seconds
        )

      %{
        event: "sun_down",
        title: gettext("Sun's down — daily summary"),
        body: body_for(today, yesterday),
        tag: "sun_down:#{Date.to_iso8601(local_date)}",
        date: Date.to_iso8601(local_date),
        # `today_yield` is already converted Wh → kWh inside
        # `Devices.get_daily_stats_for_local_day/4` (the readings
        # table stores Wh; the function divides by 1000 before
        # returning). The JS hook expects kWh, so we pass it through
        # unchanged.
        today_yield_kwh: today.today_yield,
        peak_power_w: today.peak_power,
        today_yield_yesterday_kwh: yesterday.today_yield,
        peak_power_yesterday_w: yesterday.peak_power
      }
    end
  end

  @doc """
  Format the body string for the `sun_down` notification.
  Composes today's kWh + peak W with the day-over-day diff
  string. Pure — takes two daily-stats maps and returns the
  rendered body.
  """
  def body_for(today, yesterday) do
    yield_diff = compare(today.today_yield, yesterday.today_yield, "kWh")
    peak_diff = compare(today.peak_power, yesterday.peak_power, "W")

    gettext(
      "Today: %{today_kwh} kWh%{yield_diff}, peak %{peak_w} W%{peak_diff}.",
      today_kwh: format_kwh(today.today_yield),
      yield_diff: yield_diff,
      peak_w: format_w(today.peak_power),
      peak_diff: peak_diff
    )
  end

  defp compare(today, yesterday, unit) when is_number(today) and is_number(yesterday) do
    cond do
      today == yesterday ->
        gettext(" (same as yesterday)")

      true ->
        diff = today - yesterday
        sign = if diff > 0, do: "+", else: ""

        if unit == "kWh" do
          gettext(" (%{sign}%{diff} kWh vs yesterday)", sign: sign, diff: format_kwh(diff))
        else
          gettext(" (%{sign}%{diff} W vs yesterday)", sign: sign, diff: format_w(diff))
        end
    end
  end

  defp compare(_, _, _), do: ""

  # `today_yield` is already in kWh (see `build_payload/2`); pass
  # it through to the formatter. Power fields are already W.
  defp format_kwh(kwh) when is_number(kwh), do: :erlang.float_to_binary(kwh, decimals: 1)
  defp format_kwh(_), do: "—"

  defp format_w(w) when is_number(w), do: :erlang.float_to_binary(w, decimals: 1)
  defp format_w(_), do: "—"
end
