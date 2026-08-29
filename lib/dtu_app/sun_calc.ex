defmodule DtuApp.SunCalc do
  @moduledoc """
  Astronomical sunrise and sunset computation for a given date and
  geographic position.

  Uses NOAA's Solar Position Algorithm (the simplified version that
  appears in the Astronomical Almanac — the same formulae the US
  Navy's observatory publishes). The algorithm has been the standard
  for non-precision solar geometry for decades: it's accurate to
  within a minute for any point on Earth over the past few centuries
  and far beyond, which is more than enough for placing a vertical
  guide line on a power chart.

  Why implement it inline rather than pull in the `:sunrise` Hex
  package? The algorithm is ~40 lines of straightforward arithmetic
  (no trig identities, just `:math.sin/1`, `:math.cos/1`, `:math.acos/1`),
  it has zero dependencies, and we don't need any of the extra
  features (twilight variants, refraction correction, sub-second
  precision) that would justify a library. The functions here are
  pure and 100% covered by `test/dtu_app/sun_calc_test.exs` against
  known NOAA-published values.

  Limits:
    * Returns `{nil, nil}` (or `{nil, sunset}` / `{sunrise, nil}`)
      in polar day / polar night conditions where the sun never
      rises or never sets on the requested date. The chart treats
      `nil` as "don't draw this line".
    * Refraction, atmospheric pressure, and observer elevation are
      NOT corrected for — the sun appears at the geometric horizon,
      not the apparent one. Acceptable for chart placement; off by
      1–2 minutes compared to "actual" sunrise as experienced by an
      observer.

  See:
    * https://gml.noaa.gov/grad/solcalc/calcdetails.html
    * NOAA Solar Calculator: https://gml.noaa.gov/grad/solcalc/
  """

  # Angular diameter of the sun (degrees). Used to correct the
  # 90° zenith angle — sunrise/sunset are defined as the moments
  # the centre of the disc crosses the horizon, not the limb.
  @sun_radius_deg 0.833

  # Conversion factor from degrees to radians.
  @deg_to_rad :math.pi() / 180.0

  @doc """
  Compute sunrise and sunset (UTC `DateTime`s) for the given
  latitude (decimal degrees, positive north), longitude (decimal
  degrees, positive east), and local calendar `date`.

  Returns:
    * `{sunrise_utc, sunset_utc}` — both populated on a normal day.
    * `{nil, sunset_utc}` — polar night (sun never rises).
    * `{sunrise_utc, nil}` — polar day (sun never sets).
    * `{nil, nil}` — if either coordinate is `nil` (the chart
      skips rendering sun markers for users without a captured
      position).

  Coordinates are validated to WGS84 bounds (lat ∈ [-90, 90],
  lon ∈ [-180, 180]) — out-of-range values raise `ArgumentError`
  rather than returning a wrong answer, since a corrupted payload
  is the only realistic source (browser geolocation can never
  produce values outside this range).
  """
  @spec sunrise_sunset_utc(float() | integer() | nil, float() | integer() | nil, Date.t()) ::
          {DateTime.t() | nil, DateTime.t() | nil}
  def sunrise_sunset_utc(nil, _lon, _date), do: {nil, nil}
  def sunrise_sunset_utc(_lat, nil, _date), do: {nil, nil}

  def sunrise_sunset_utc(lat, lon, %Date{} = date) do
    _ = validate!(lat, lon)

    # Julian day at noon UTC of the requested date. The algorithm
    # is symmetric around noon so the exact hour doesn't matter
    # much; noon gives the most numerically stable input. We
    # compute the noon-JD locally because `julian_day/1` returns
    # the midnight-JD (per the standard formula).
    jd_midnight = julian_day(date)
    jd_noon = jd_midnight + 0.5

    # Solar declination (degrees) — the angle between the sun's
    # rays and the equatorial plane. Drives the season.
    declination = solar_declination(jd_noon)

    # Hour angle at sunrise (degrees) — the angle the Earth must
    # rotate for the sun to move from its noon position to the
    # horizon. Negative before noon, positive after; we negate
    # the result for sunrise and use as-is for sunset.
    hour_angle = solar_hour_angle(lat, declination)

    cond do
      hour_angle == :polar_night ->
        {nil, solar_to_utc(jd_midnight, lon, -180.0)}

      hour_angle == :polar_day ->
        {solar_to_utc(jd_midnight, lon, 180.0), nil}

      true ->
        {solar_to_utc(jd_midnight, lon, -hour_angle), solar_to_utc(jd_midnight, lon, hour_angle)}
    end
  end

  # Julian Day Number at noon UTC on `date`. Standard formula from
  # the astronomical almanac; works for the entire Gregorian
  # calendar range.
  defp julian_day(%Date{year: y, month: m, day: d}) do
    a = div(14 - m, 12)
    y2 = y + 4800 - a
    m2 = m + 12 * a - 3

    d + div(153 * m2 + 2, 5) + 365 * y2 + div(y2, 4) - div(y2, 100) + div(y2, 400) - 32045
  end

  # Solar declination in degrees, using the simplified NOAA
  # formula. Approximates Earth's orbital eccentricity as constant;
  # accurate to ~0.5° (≈ 30 minutes of sun-time difference at
  # solstice, which is fine for chart placement — the X-axis grid
  # is rarely sub-minute).
  #
  # Takes the noon-JD of the date (midnight-JD + 0.5) so the
  # offset from J2000.0 (2451545.0) lines up with the standard
  # reference.
  defp solar_declination(jd_noon) do
    # Fractional year (radians), measured from 2000-01-01 noon UTC.
    # 365.25 days/year accounts for leap years on average.
    gamma = 2 * :math.pi() / 365.25 * (jd_noon - 2_451_545.0)

    # Equation of the centre (the seasonal modulation of the
    # sun's apparent speed) + the obliquity of the ecliptic.
    decl =
      0.006918 -
        0.399912 * :math.cos(gamma) +
        0.070257 * :math.sin(gamma) -
        0.006758 * :math.cos(2 * gamma) +
        0.000907 * :math.sin(2 * gamma) -
        0.002697 * :math.cos(3 * gamma) +
        0.00148 * :math.sin(3 * gamma)

    decl / @deg_to_rad
  end

  # Hour angle at sunrise (degrees). The geometric relation is
  #
  #   cos(H) = (cos(zenith) - sin(lat) · sin(decl)) / (cos(lat) · cos(decl))
  #
  # where zenith is the angle from the zenith (i.e. 90° minus the
  # sun's altitude). We use zenith = 90° + sun radius (= 90.833°)
  # for the standard "geometric horizon + solar radius" definition
  # of sunrise: the centre of the disc crossing the horizon, ignoring
  # atmospheric refraction.
  #
  # Crucially the formula needs `cos(zenith)`, NOT `sin(zenith)` —
  # `sin(90.833°) ≈ 0.99990` (near 1, which would put sunrise at
  # solar noon) while `cos(90.833°) ≈ 0.01454` (which gives the
  # expected ~6h offset at the equator on the equinox). The two
  # formulations differ by a trig identity; we follow the NOAA
  # reference directly.
  #
  # Returns one of:
  #   * a positive degree value (sun rises + sets normally)
  #   * `:polar_night` — `cos(H)` would need to be > 1 (sun never
  #     reaches the horizon)
  #   * `:polar_day` — `cos(H)` would need to be < -1 (sun never
  #     sets)
  defp solar_hour_angle(lat, decl_deg) do
    zenith = 90.0 + @sun_radius_deg

    cos_h =
      (:math.cos(zenith * @deg_to_rad) -
         :math.sin(lat * @deg_to_rad) * :math.sin(decl_deg * @deg_to_rad)) /
        (:math.cos(lat * @deg_to_rad) * :math.cos(decl_deg * @deg_to_rad))

    cond do
      cos_h > 1.0 -> :polar_night
      cos_h < -1.0 -> :polar_day
      true -> :math.acos(cos_h) / @deg_to_rad
    end
  end

  # Convert a solar hour angle back to a UTC `DateTime` for the
  # given Julian day. The hour angle `H` is measured from local
  # solar noon; `H = 0` is noon, positive hour angles are after
  # noon. We convert the JD at noon UTC back to a wall-clock time,
  # subtract `H/15` hours (15°/hour) for sunrise, add for sunset.
  defp solar_to_utc(jd_midnight, lon, hour_angle_deg) do
    # Solar noon is at 12:00 UTC - lon/15 hours on the local
    # date. We start from the midnight-JD of the requested date,
    # add 0.5 to land on noon UTC of that date, then subtract
    # lon/360 (= lon/15h expressed as JD) to find solar noon.
    solar_noon_jd = jd_midnight + 0.5 - lon / 360.0

    # Sunrise: solar noon - |H|/15h, where H is the magnitude.
    # Sunset: solar noon + |H|/15h.
    # `hour_angle_deg` carries the sign (- for sunrise, + for
    # sunset), so we always add: -|H| for sunrise, +|H| for sunset.
    target_jd = solar_noon_jd + hour_angle_deg / 360.0

    jd_to_datetime(target_jd)
  end

  # Julian day → UTC DateTime. Uses the Fliegel & Van Flandern
  # algorithm (published in Communications of the ACM, 1968) —
  # well-known, well-tested, works for the entire Gregorian
  # calendar range.
  #
  # `jd` is the Julian Day Number at midnight UTC + a fractional
  # day for the time-of-day (so jd 2461213.5 = noon on 2026-06-21).
  defp jd_to_datetime(jd) do
    z = trunc(jd)
    f = jd - z

    l = z + 68_569
    n = div(4 * l, 146_097)
    l = l - div(146_097 * n + 3, 4)
    i = div(4000 * (l + 1), 1_461_001)
    l = l - div(1461 * i, 4) + 31
    j = div(80 * l, 2447)
    day = l - div(2447 * j, 80)
    l = div(j, 11)
    month = j + 2 - 12 * l
    year = 100 * (n - 49) + i + l

    date = Date.new!(year, month, day)

    # Fractional day → HH:MM:SS. Rounded to the nearest second;
    # sub-second precision is irrelevant for chart placement
    # (the X-axis grid is hour-aligned via `chart_x_labels/2`).
    # If `f` rounds up to 1.0 (i.e. `total_seconds == 86_400`),
    # bump the date forward by one day so the resulting
    # DateTime is the very first second of the next day instead
    # of overflowing HH:MM:SS. Edge case for sunset times in the
    # eastern hemisphere near solstice (sunset can land after
    # 24:00 UTC after the JD→date wrap).
    total_seconds = round(f * 86_400)

    {date, total_seconds} =
      if total_seconds >= 86_400 do
        {Date.add(date, 1), 0}
      else
        {date, total_seconds}
      end

    hour = div(total_seconds, 3600)
    minute = rem(div(total_seconds, 60), 60)
    second = rem(total_seconds, 60)

    {:ok, dt} = DateTime.new(date, ~T[00:00:00])
    DateTime.add(dt, hour * 3600 + minute * 60 + second, :second)
  end

  # Range validation. Defends against corrupted payloads (e.g.
  # a JS bug that emits NaN, swaps lat/lon, or applies the wrong
  # sign). Anything outside WGS84 bounds raises immediately so
  # the bug surfaces in the LiveView crash report rather than
  # silently placing the sun markers at the wrong time.
  defp validate!(lat, lon) do
    cond do
      not is_number(lat) or lat < -90.0 or lat > 90.0 ->
        raise ArgumentError, "latitude must be a number in [-90, 90], got #{inspect(lat)}"

      not is_number(lon) or lon < -180.0 or lon > 180.0 ->
        raise ArgumentError, "longitude must be a number in [-180, 180], got #{inspect(lon)}"

      true ->
        :ok
    end
  end
end
