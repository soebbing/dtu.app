defmodule DtuApp.Notifications.SunDown.Detection do
  @moduledoc """
  Pure fleet-power + sunset-gate analysis extracted from
  `DtuApp.Notifications.SunDown` so the notifier doesn't have
  to carry ~60 lines of arithmetic that only ever inspect a
  state map. Every function here is either stateless (struct
  accessors) or takes a fully-formed state map and a clock
  instant — none read the GenServer's state.

  Split mirrors the `DtuApp.Devices/Stats` sub-folder pattern
  (production_stats / consumption_stats / period_helpers).
  Re-exported through `DtuApp.Notifications.SunDown` via
  `defdelegate` so the notifier's call sites and the existing
  test surface stay unchanged.
  """

  # `@fleet_reading_stale_seconds` is owned by the notifier (it
  # governs the GenServer's arming window). The detection helpers
  # reach back to the attribute so a future tuning lives in one
  # place — the notifier module.
  @fleet_reading_stale_seconds 300

  @doc """
  Extract the DTU id from a parsed reading map.

  Tolerates `nil` (synthetic test fixtures broadcast
  `%{dtu_id: nil}` for disconnect paths).
  """
  def reading_dtu_id(%{dtu_id: id}) when is_integer(id), do: id
  def reading_dtu_id(%{dtu_id: id}) when not is_nil(id), do: id
  def reading_dtu_id(_), do: nil

  @doc """
  Extract the AC-aggregate power from a parsed reading.

  `mppt_index == 0` is the AC aggregate row; per-MPPT rows
  carry `dc_power`, not `ac_power`, and the in-page arming
  path ignores them — `reading_ac_power/1` returns `:ignore`
  for any other shape so the caller can filter via
  `Enum.reject(... &(&1 == :ignore))`.
  """
  def reading_ac_power(%{mppt_index: 0, ac_power: w}) when is_number(w), do: w * 1.0
  def reading_ac_power(%{mppt_index: 0, ac_power: nil}), do: 0.0
  def reading_ac_power(%{ac_power: _}), do: :ignore
  def reading_ac_power(_), do: :ignore

  @doc """
  Sum of `power_w` across devices whose last reading is fresher
  than `@fleet_reading_stale_seconds`. See the notifier's
  moduledoc for the full rationale ("Why 'active' fleet sum?").
  """
  def active_fleet_w(devices, now) do
    devices
    |> Map.values()
    |> Enum.filter(fn %{last_reading_at: last} ->
      DateTime.diff(now, last, :second) < @fleet_reading_stale_seconds
    end)
    |> Enum.map(& &1.power_w)
    |> Enum.sum()
  end

  @doc """
  True iff every device the user owns is stale. A user with no
  devices returns `true` (vacuous truth). Used by `maybe_arm_timer/2`
  to handle the "all devices went silent at the same time" case.
  """
  def all_devices_silent?(%{devices: devices}, now) do
    devices == [] or
      Enum.all?(devices, fn {_id, %{last_reading_at: last}} ->
        DateTime.diff(now, last, :second) >= @fleet_reading_stale_seconds
      end)
  end

  @doc """
  Sunset gate: returns `true` iff the user's fleet should be
  considered idle AND the current instant is past today's
  sunset for the user's geographic position. A daily summary
  fired at noon (under cloud cover) is the wrong signal —
  that's `YieldAnomaly`'s job.

  Fallback contract: when the user has no coordinates
  (`latitude` / `longitude` nil) `past_sunset?/2` returns
  `true`, matching the legacy behaviour. Polar edge cases
  (`{sunrise, nil}` polar day, `{nil, sunset}` polar night)
  return `false` — no sunset known for the location today,
  so the gate conservatively blocks the fire rather than guess.
  """
  def past_sunset?(user_id, %DateTime{} = now) do
    case safe_get_user(user_id) do
      nil ->
        # User vanished mid-flight (deletion race) — treat as past
        # sunset so the summary still fires; this matches the
        # original un-gated behaviour for users that briefly don't
        # exist.
        true

      %DtuApp.Accounts.User{latitude: nil} ->
        true

      %DtuApp.Accounts.User{longitude: nil} ->
        true

      %DtuApp.Accounts.User{latitude: lat, longitude: lon}
      when not is_nil(lat) and not is_nil(lon) ->
        date = DateTime.to_date(now)

        case DtuApp.SunCalc.sunrise_sunset_utc(lat, lon, date) do
          {_, %DateTime{} = sunset} -> DateTime.compare(now, sunset) in [:gt, :eq]
          # Polar day (`{_, nil}`), polar night (`{nil, _}`) and
          # unknown shapes: no sunset known for this location/date,
          # so conservatively block the fire rather than guess.
          _ -> false
        end

      _ ->
        true
    end
  end

  @doc """
  Test override for "now" — mirrors `:yield_anomaly_now` in
  `YieldAnomaly`. Lets the suite drive the sunset-gate check
  at a fixed instant without mocking `Time.utc_now/0`. Falls
  back to the wall-clock time in production.
  """
  def read_now do
    case Application.get_env(:dtu_app, :sun_down_now, :__unset__) do
      :__unset__ -> DtuApp.Time.utc_now()
      %DateTime{} = configured -> configured
    end
  end

  # Same `:repo, :rescue` defensive pattern as the notifier's
  # `safe_get_user/1` — the gate runs on the rare idle-transition
  # path (only charged when `fleet_w == 0.0` AND `zero_since == nil`,
  # not on every reactive `:reading` broadcast), so we still want
  # the call to be best-effort rather than crash the producer if
  # the DB briefly hiccups.
  defp safe_get_user(user_id) do
    try do
      DtuApp.Repo.get(DtuApp.Accounts.User, user_id)
    rescue
      _ -> nil
    end
  end
end
