defmodule DtuApp.SunCalcTest do
  @moduledoc """
  Pins `DtuApp.SunCalc` to known NOAA-published values for a handful
  of representative cases. Each expected sunrise/sunset comes from
  https://gml.noaa.gov/grad/solcalc/calcdetails.html — the US
  government's solar geometry calculator — so the algorithm has a
  reference implementation to match.

  Tolerance is ±10 minutes. The simplified NOAA algorithm we use
  omits atmospheric refraction correction (we use the geometric
  horizon, 90.833°) and treats Earth's orbit as circular, so the
  published accuracy band is ±10 minutes vs. the full NOAA Solar
  Calculator. Tighter accuracy would require the more elaborate
  Meeus algorithm — overkill for placing a vertical guide line on
  a chart.
  """

  use ExUnit.Case, async: true

  alias DtuApp.SunCalc

  # Compare two `DateTime`s. The simplified NOAA algorithm we use
  # deliberately omits atmospheric refraction and treats Earth's
  # orbit as circular, so its published accuracy is ±10 minutes vs.
  # the more elaborate NOAA Solar Calculator (which uses full
  # astronomical almanac formulae + refraction correction). The
  # tolerance here matches that band; tighter accuracy would
  # require a more elaborate algorithm (which isn't worth the
  # complexity for placing a vertical guide line on a chart).
  @tolerance_seconds 600

  defp assert_within_tolerance(%DateTime{} = got, %DateTime{} = expected) do
    diff = DateTime.diff(got, expected, :second)

    assert abs(diff) <= @tolerance_seconds,
           "expected ~#{DateTime.to_iso8601(expected)}, got #{DateTime.to_iso8601(got)} (diff #{diff}s)"
  end

  describe "sunrise_sunset_utc/3 — known NOAA values" do
    # Berlin, summer solstice. NOAA: sunrise ≈ 04:43, sunset ≈ 21:33
    # local (CEST = UTC+2), so UTC = 02:43 / 19:33.
    test "Berlin on the summer solstice (2026-06-21)" do
      lat = 52.520_008
      lon = 13.404_954

      assert {sunrise, sunset} =
               SunCalc.sunrise_sunset_utc(lat, lon, ~D[2026-06-21])

      assert_within_tolerance(sunrise, ~U[2026-06-21 02:43:00Z])
      assert_within_tolerance(sunset, ~U[2026-06-21 19:33:00Z])
    end

    # Berlin, winter solstice. NOAA: sunrise ≈ 08:15, sunset ≈ 15:54
    # local (CET = UTC+1), so UTC = 07:15 / 14:54.
    test "Berlin on the winter solstice (2026-12-21)" do
      lat = 52.520_008
      lon = 13.404_954

      assert {sunrise, sunset} =
               SunCalc.sunrise_sunset_utc(lat, lon, ~D[2026-12-21])

      assert_within_tolerance(sunrise, ~U[2026-12-21 07:15:00Z])
      assert_within_tolerance(sunset, ~U[2026-12-21 14:54:00Z])
    end

    # Equator on the equinox. Sunrise/sunset should be 06:00 / 18:00
    # local regardless of longitude (the sun crosses the horizon at
    # the equinox in 12h-day everywhere on Earth). For longitude 0
    # (Greenwich) that's exactly 06:00 / 18:00 UTC.
    test "Equator / prime meridian on the spring equinox (2026-03-20)" do
      assert {sunrise, sunset} =
               SunCalc.sunrise_sunset_utc(0.0, 0.0, ~D[2026-03-20])

      assert_within_tolerance(sunrise, ~U[2026-03-20 06:00:00Z])
      assert_within_tolerance(sunset, ~U[2026-03-20 18:00:00Z])
    end

    # New York on the summer solstice. NOAA: sunrise ≈ 05:25,
    # sunset ≈ 20:31 local (EDT = UTC-4), so UTC = 09:25 / 00:31
    # (next day). Sunset crossing midnight UTC exercises the
    # JD-to-DateTime rollover path.
    test "New York on the summer solstice (2026-06-21) — sunset crosses midnight UTC" do
      lat = 40.712_776
      lon = -74.005_974

      assert {_sunrise, sunset} =
               SunCalc.sunrise_sunset_utc(lat, lon, ~D[2026-06-21])

      assert_within_tolerance(sunset, ~U[2026-06-22 00:31:00Z])
    end

    # Tokyo, mid-spring. NOAA: sunrise ≈ 05:00, sunset ≈ 18:30 local
    # (JST = UTC+9), so UTC = 20:00 / 09:30. Sunrise crossing
    # midnight UTC backwards exercises the other rollover case.
    test "Tokyo on 2026-04-15 — sunrise crosses midnight UTC backwards" do
      lat = 35.676_189
      lon = 139.650_311

      assert {sunrise, _sunset} =
               SunCalc.sunrise_sunset_utc(lat, lon, ~D[2026-04-15])

      assert_within_tolerance(sunrise, ~U[2026-04-14 20:00:00Z])
    end
  end

  describe "sunrise_sunset_utc/3 — polar edge cases" do
    # Tromsø (lat 69.65°N) in mid-winter: the sun stays below the
    # horizon all day. Polar night → sunrise is nil, sunset still
    # returned for completeness.
    test "Tromsø on 2026-12-21 is polar night" do
      assert {nil, _sunset} =
               SunCalc.sunrise_sunset_utc(69.649_216, 18.955_323, ~D[2026-12-21])
    end

    # Tromsø in mid-summer: the sun never sets. Polar day → sunset
    # is nil, sunrise still returned.
    test "Tromsø on 2026-06-21 is polar day" do
      assert {_sunrise, nil} =
               SunCalc.sunrise_sunset_utc(69.649_216, 18.955_323, ~D[2026-06-21])
    end
  end

  describe "sunrise_sunset_utc/3 — nil coords" do
    test "either coordinate nil → {nil, nil}" do
      assert SunCalc.sunrise_sunset_utc(nil, 13.4, ~D[2026-06-21]) == {nil, nil}
      assert SunCalc.sunrise_sunset_utc(52.5, nil, ~D[2026-06-21]) == {nil, nil}
    end
  end

  describe "sunrise_sunset_utc/3 — Decimal coords" do
    # User.latitude / User.longitude come back from Ecto as
    # `%Decimal{}` (the schema stores `:decimal`). The
    # `is_number/1`-guarded `validate!/2` would otherwise reject
    # them and raise ArgumentError, crashing the dashboard render.
    # Verify that Decimal coords coerce cleanly and the output
    # matches the equivalent float call.
    test "Decimal coords coerce to float and match the float-input result" do
      assert {dec_sr, dec_ss} =
               SunCalc.sunrise_sunset_utc(
                 Decimal.new("52.520008"),
                 Decimal.new("13.404954"),
                 ~D[2026-06-21]
               )

      assert {float_sr, float_ss} =
               SunCalc.sunrise_sunset_utc(52.520_008, 13.404_954, ~D[2026-06-21])

      assert_within_tolerance(dec_sr, float_sr)
      assert_within_tolerance(dec_ss, float_ss)
    end

    test "mixed Decimal + nil returns {nil, nil}" do
      assert SunCalc.sunrise_sunset_utc(Decimal.new("52.52"), nil, ~D[2026-06-21]) ==
               {nil, nil}

      assert SunCalc.sunrise_sunset_utc(nil, Decimal.new("13.41"), ~D[2026-06-21]) ==
               {nil, nil}
    end
  end

  describe "sunrise_sunset_utc/3 — invalid coords raise" do
    test "out-of-range latitude raises ArgumentError" do
      assert_raise ArgumentError, ~r/latitude/, fn ->
        SunCalc.sunrise_sunset_utc(91.0, 0.0, ~D[2026-06-21])
      end
    end

    test "out-of-range longitude raises ArgumentError" do
      assert_raise ArgumentError, ~r/longitude/, fn ->
        SunCalc.sunrise_sunset_utc(0.0, 181.0, ~D[2026-06-21])
      end
    end
  end
end
