defmodule DtuAppWeb.DashboardHistoricalTest do
  use DtuAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import DtuApp.DevicesFixtures

  alias DtuApp.Devices

  setup :register_and_log_in_user

  describe "Historical Dashboard" do
    test "renders empty states when no data is available", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Click Historical Day
      html = view |> element("#btn-range-day") |> render_click()
      assert html =~ "No historical days available"

      # Click Historical Week
      html = view |> element("#btn-range-week") |> render_click()
      assert html =~ "No historical weeks available"

      # Click Historical Month
      html = view |> element("#btn-range-month") |> render_click()
      assert html =~ "No historical months available"

      # Click Historical Year
      html = view |> element("#btn-range-year") |> render_click()
      assert html =~ "No historical years available"
    end

    test "renders selectable dropdown options when data is present", %{conn: conn, user: user} do
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

      # Select Historical Day range
      view |> element("#btn-range-day") |> render_click()

      # Select dropdown should contain the option for the seeded day
      assert has_element?(view, "#select-day")
      assert render(view) =~ date_str

      # Select Historical Week range
      view |> element("#btn-range-week") |> render_click()
      assert has_element?(view, "#select-week")

      # Select Historical Month range
      view |> element("#btn-range-month") |> render_click()
      assert has_element?(view, "#select-month")

      # Select Historical Year range
      view |> element("#btn-range-year") |> render_click()
      assert has_element?(view, "#select-year")
    end

    test "filters data when specific period is chosen", %{conn: conn, user: user} do
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

      # Go to historical day
      view |> element("#btn-range-day") |> render_click()

      # Change dropdown to select d1
      html = view |> element("#form-select-day") |> render_change(%{period: d1_str})
      # Should show 1.0 kWh yield and peak 100 W
      assert html =~ "1.0 kWh"
      assert html =~ "100.0 W"

      # Change dropdown to select d2
      html = view |> element("#form-select-day") |> render_change(%{period: d2_str})
      # Should show 5.0 kWh yield and peak 500 W
      assert html =~ "5.0 kWh"
      assert html =~ "500.0 W"
    end
  end
end
