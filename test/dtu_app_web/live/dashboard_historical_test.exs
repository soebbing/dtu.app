defmodule DtuAppWeb.DashboardHistoricalTest do
  use DtuAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import DtuApp.DevicesFixtures

  alias DtuApp.Devices

  setup :register_and_log_in_user

  describe "Historical Dashboard" do
    test "shows an empty-state hint when the selected granularity has no data", %{
      conn: conn,
      user: user
    } do
      _dtu =
        device_fixture(user, %{
          name: "Historical Inverter",
          kind: "opendtu",
          mqtt_username: "hist-inv"
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # The dashboard boots in live mode; switch granularity to enter history.
      view |> element("#form-granularity") |> render_change(%{granularity: "day"})
      assert render(view) =~ "No historical data for this period."

      view |> element("#form-granularity") |> render_change(%{granularity: "week"})
      assert render(view) =~ "No historical data for this period."

      view |> element("#form-granularity") |> render_change(%{granularity: "month"})
      assert render(view) =~ "No historical data for this period."

      view |> element("#form-granularity") |> render_change(%{granularity: "year"})
      assert render(view) =~ "No historical data for this period."
    end

    test "renders the seeded day in the stepper when data is present", %{conn: conn, user: user} do
      dtu =
        device_fixture(user, %{
          name: "Historical Inverter",
          kind: "opendtu",
          mqtt_username: "hist-inv"
        })

      # Seed historic data on a known past day (2 days ago), independent of today.
      date = Date.add(Date.utc_today(), -2)
      date_str = Date.to_iso8601(date)
      dt = DateTime.new!(date, ~T[12:00:00], "Etc/UTC")

      {:ok, _reading} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "123456",
          ac_power: 450.0,
          yield_day: 3.5,
          inserted_at: dt
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Switch to Day granularity — the stepper should land on the seeded day.
      view |> element("#form-granularity") |> render_change(%{granularity: "day"})
      assert has_element?(view, "#history-picker")
      assert render(view) =~ date_str

      # The calendar is bounded to the data range: the seeded day is both the
      # earliest and latest date with data, so min and max both equal it.
      html = render(view)
      assert html =~ ~s(min="#{date_str}")
      assert html =~ ~s(max="#{date_str}")

      # The other granularities also render without error.
      view |> element("#form-granularity") |> render_change(%{granularity: "week"})
      assert has_element?(view, "#history-picker")

      view |> element("#form-granularity") |> render_change(%{granularity: "month"})
      assert has_element?(view, "#history-picker")

      view |> element("#form-granularity") |> render_change(%{granularity: "year"})
      assert has_element?(view, "#history-picker")
    end

    test "stepper + date picker filter data to the chosen day", %{conn: conn, user: user} do
      dtu =
        device_fixture(user, %{
          name: "Historical Inverter",
          kind: "opendtu",
          mqtt_username: "hist-inv"
        })

      # Seed two different past days (relative to today so the test is stable).
      d1 = Date.add(Date.utc_today(), -3)
      d2 = Date.add(Date.utc_today(), -2)
      d1_str = Date.to_iso8601(d1)
      d2_str = Date.to_iso8601(d2)

      {:ok, _r1} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "123",
          ac_power: 100.0,
          yield_day: 1.0,
          inserted_at: DateTime.new!(d1, ~T[12:00:00], "Etc/UTC")
        })

      {:ok, _r2} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "123",
          ac_power: 500.0,
          yield_day: 5.0,
          inserted_at: DateTime.new!(d2, ~T[12:00:00], "Etc/UTC")
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Enter Day granularity, then pick d1 via the calendar input.
      view |> element("#form-granularity") |> render_change(%{granularity: "day"})

      html = view |> element("#history-date-input") |> render_change(%{date: d1_str})
      assert html =~ "1.0 kWh"
      assert html =~ "100.0 W"

      # Pick d2 via the calendar input.
      html = view |> element("#history-date-input") |> render_change(%{date: d2_str})
      assert html =~ "5.0 kWh"
      assert html =~ "500.0 W"

      # The prev/next stepper moves one day at a time (d2 -> d1).
      html = view |> element("#btn-history-prev") |> render_click()
      assert html =~ "1.0 kWh"
    end
  end
end
