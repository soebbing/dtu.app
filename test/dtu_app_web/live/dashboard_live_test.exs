defmodule DtuAppWeb.DashboardLiveTest do
  use DtuAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import DtuApp.DevicesFixtures

  alias DtuApp.MqttBroker.Telemetry
  alias DtuApp.Devices

  setup :register_and_log_in_user

  describe "Dashboard Index" do
    test "renders empty dashboard stats and empty state message", %{conn: conn, user: user} do
      _dtu =
        device_fixture(user, %{name: "Test Inverter", kind: "opendtu", mqtt_username: "test-inv"})

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "PV Power Dashboard"
      assert html =~ "Current Generation"
      # W stat cards render with `decimals: 0` (350 W not 350.0 W);
      # kWh stat cards render with `decimals: 1` (1.3 kWh not 1 kWh).
      assert html =~ "0 W"
      assert html =~ "0.0 kWh"
      assert html =~ "No power readings logged for this day."
    end

    test "renders dashboard in German when accept-language is German", %{conn: conn, user: user} do
      _dtu =
        device_fixture(user, %{name: "Test Inverter", kind: "opendtu", mqtt_username: "test-inv"})

      conn = Plug.Conn.put_req_header(conn, "accept-language", "de-DE,de;q=0.9")
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "PV-Power-Dashboard"
      assert html =~ "Aktuelle Erzeugung"
    end

    test "renders dashboard in French when accept-language is French", %{conn: conn, user: user} do
      _dtu =
        device_fixture(user, %{name: "Test Inverter", kind: "opendtu", mqtt_username: "test-inv"})

      conn = Plug.Conn.put_req_header(conn, "accept-language", "fr-FR,fr;q=0.9")
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Tableau de bord de puissance photovoltaïque"
      assert html =~ "Génération actuelle"
    end

    test "stat card numbers use locale-aware separators (German user gets comma decimal)",
         %{conn: conn, user: user} do
      # Regression: stat-card numbers used to be rendered as raw Elixir
      # values regardless of locale — a German user on /dashboard saw
      # `1234.5 kWh` instead of the typographically-correct `1.234,5 kWh`.
      # The fix: every stat-card number goes through
      # `DtuApp.Devices.format_number/3` with the current Gettext locale,
      # matching the convention `format_savings/1` already used for the
      # "Saved this period" card. Today's Total Yield uses `decimals: 1`,
      # so 1_250 Wh (1.25 kWh) renders as "1,3 kWh" in `de`, not "1.3 kWh".
      dtu =
        device_fixture(user, %{
          name: "Locale DTU",
          kind: "opendtu",
          mqtt_username: "locale-dtu"
        })

      {:ok, _reading} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV",
          ac_power: 350.0,
          # 1_250 Wh = 1.25 kWh → renders as "1,3 kWh" in de / "1.3 kWh" in en.
          yield_day: 1_250.0,
          inserted_at: DateTime.utc_now()
        })

      conn = Plug.Conn.put_req_header(conn, "accept-language", "de-DE,de;q=0.9")
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # German-style comma decimal, dot thousands separator.
      assert html =~ "1,3 kWh"
      assert html =~ "350 W"

      refute html =~ "1.3 kWh",
             "German user should see the comma decimal '1,3 kWh', not '1.3 kWh'"
    end

    test "device card shows 'time ago' last seen and hides verbose fields", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Tiny Inverter",
          kind: :ahoydtu,
          mqtt_username: "tiny-inv",
          base_topic: "balcony"
        })

      # Simulate the broker reporting the device online a couple of seconds ago.
      # Online status is now **derived** from `last_seen_at` via
      # `DtuApp.Devices.Dtu.online?/2`, so the only field we need to touch
      # is `last_seen_at` itself.
      dtu
      |> Ecto.Changeset.change(%{last_seen_at: DateTime.utc_now()})
      |> DtuApp.Repo.update()

      {:ok, _view, html} = live(conn, ~p"/dashboard?range=today")

      # Time-ago label is rendered, with the absolute timestamp as a hover hint.
      assert html =~ "just now"
      assert Regex.match?(~r/title="[^"]*UTC"/, html)

      # Verbose fields are no longer in the card body.
      refute html =~ "Base Topic"
      refute html =~ "Firmware"
      refute html =~ "MQTT Username"
    end

    test "renders connected devices and dynamically updates power stats", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Dashboard Inverter",
          kind: "opendtu",
          mqtt_username: "dash-inv"
        })

      {:ok, view, html} = live(conn, ~p"/dashboard")

      # Initially 0 W (W stat cards use `decimals: 0` so the integer
      # renders without a trailing ".0").
      assert html =~ "0 W"
      assert html =~ "Dashboard Inverter"

      # Simulate reading ingestion. yield_day is in Wh (per OpenDTU/
      # AhoyDTU firmware); get_daily_stats/2 converts to kWh before the
      # dashboard renders it.
      {:ok, _reading} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "123456",
          ac_power: 350.0,
          yield_day: 1_250.0,
          inserted_at: DateTime.utc_now()
        })

      # Broadcast the reading update
      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        Telemetry.reading_topic(),
        {:reading, "client_1", %{dtu_id: dtu.id}}
      )

      # Assert the view received the update and shows 350 W (the W stat
      # card uses `decimals: 0` so the integer renders without a trailing
      # ".0"). Today's Total Yield is rounded to one decimal place, so
      # 1_250 Wh (1.25 kWh) renders as "1.3 kWh".
      html = render(view)
      assert html =~ "350 W"
      assert html =~ "1.3 kWh"
      assert html =~ "solar-chart-svg"
    end

    test "renders multiple DTUs and switches display between total and specific DTUs", %{
      conn: conn,
      user: user
    } do
      dtu1 =
        device_fixture(user, %{name: "DTU One", kind: "opendtu", mqtt_username: "dtu-one-user"})

      dtu2 =
        device_fixture(user, %{name: "DTU Two", kind: "ahoydtu", mqtt_username: "dtu-two-user"})

      # Seed readings for DTU 1 and DTU 2 (yield_day in Wh).
      {:ok, _r1} =
        Devices.create_reading(%{
          dtu_id: dtu1.id,
          inverter_serial: "123",
          ac_power: 100.0,
          yield_day: 1_000.0,
          inserted_at: DateTime.utc_now()
        })

      {:ok, _r2} =
        Devices.create_reading(%{
          dtu_id: dtu2.id,
          inverter_serial: "456",
          ac_power: 200.0,
          yield_day: 2_000.0,
          inserted_at: DateTime.utc_now()
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # 1. Verify "Total" view on mount (Sum of both DTUs)
      assert has_element?(view, "#dtu-switcher")
      assert has_element?(view, "#btn-select-total")
      assert has_element?(view, "#btn-select-dtu-#{dtu1.id}")
      assert has_element?(view, "#btn-select-dtu-#{dtu2.id}")

      assert element(view, "#stat-current-power") |> render() =~ "300 W"
      assert element(view, "#stat-today-yield") |> render() =~ "3.0 kWh"

      # 2. Click "DTU One" and verify stats filter down to DTU One's values
      view
      |> element("#btn-select-dtu-#{dtu1.id}")
      |> render_click()

      assert element(view, "#stat-current-power") |> render() =~ "100 W"
      assert element(view, "#stat-today-yield") |> render() =~ "1.0 kWh"

      # 3. Click "DTU Two" and verify stats filter down to DTU Two's values
      view
      |> element("#btn-select-dtu-#{dtu2.id}")
      |> render_click()

      assert element(view, "#stat-current-power") |> render() =~ "200 W"
      assert element(view, "#stat-today-yield") |> render() =~ "2.0 kWh"

      # 4. Click "Total" again and verify totals are displayed
      view
      |> element("#btn-select-total")
      |> render_click()

      assert element(view, "#stat-current-power") |> render() =~ "300 W"
      assert element(view, "#stat-today-yield") |> render() =~ "3.0 kWh"
    end

    test "renders one chart legend entry per inverter plus the Total line", %{
      conn: conn,
      user: user
    } do
      # Two inverters, each with its own AC aggregate. The legend should
      # expose one entry per inverter (so the chart reader can tell the
      # lines apart) AND a Total line at the top because the fleet has
      # more than one inverter — see `assign_line_chart_data/5`'s
      # `show_total?` check.
      dtu1 =
        device_fixture(user, %{
          name: "Inverter One",
          kind: "opendtu",
          mqtt_username: "inv-one"
        })

      dtu2 =
        device_fixture(user, %{
          name: "Inverter Two",
          kind: "ahoydtu",
          mqtt_username: "inv-two"
        })

      now = DateTime.utc_now()

      for {dtu_id, serial, mppt_index, name, power} <- [
            {dtu1.id, "INV-1", 0, "East Array", 200.0},
            # `dtu2`'s AC aggregate — needed so the chart sees two
            # distinct inverters and renders the fleet Total.
            {dtu2.id, "INV-2", 0, "West Array", 150.0},
            # `dc_power` rows (per-MPPT) are intentionally included so
            # we can verify they're filtered out of the chart by the
            # `Enum.filter` in `assign_line_chart_data/5` — the chart
            # should still show one line per inverter, not three.
            {dtu2.id, "INV-2", 1, "West Array", 80.0},
            {dtu2.id, "INV-2", 2, "West Array", 70.0}
          ] do
        attrs = %{
          dtu_id: dtu_id,
          inverter_serial: serial,
          mppt_index: mppt_index,
          inverter_name: name,
          inserted_at: now
        }

        attrs =
          if mppt_index == 0,
            do: Map.put(attrs, :ac_power, power),
            else: Map.put(attrs, :dc_power, power)

        {:ok, _} = Devices.create_reading(attrs)
      end

      {:ok, view, html} = live(conn, ~p"/dashboard")

      # Legend is rendered with one swatch per series plus a Total
      # entry at the top.
      assert has_element?(view, "#chart-legend")

      # Two per-inverter labels (per-MPPT DC rows are collapsed into the
      # inverter's AC line on the server) and one fleet Total.
      assert html =~ "Total"
      assert html =~ "East Array"
      assert html =~ "West Array"

      # The chart SVG carries one path per inverter (DC rows filtered
      # out) plus the Total path: 2 + 1 = 3 paths.
      path_count = html |> String.split(~s(data-series=)) |> length() |> Kernel.-(1)
      assert path_count == 3

      # Sanity check that both inverter serials appear in the SVG.
      assert html =~ "INV-1"
      assert html =~ "INV-2"
    end

    test "every chart path uses a concrete hex stroke, not a Tailwind class name",
         %{conn: conn, user: user} do
      # Regression: the chart used to set stroke="text-emerald-400" and
      # class="stroke-400" on each path, both of which silently fail —
      # the former because SVG `stroke` expects a real color value, the
      # latter because Tailwind's JIT can't see interpolated class
      # names. The result was that NO series lines rendered, only the
      # tinted area fill under the first series was visible. The fix
      # passes the already-resolved hex color (`stroke_hex` from
      # `tooltip_to_hex/2`) directly to the SVG `stroke=` attribute.
      dtu1 =
        device_fixture(user, %{
          name: "Stroke DTU One",
          kind: "opendtu",
          mqtt_username: "stroke-one"
        })

      dtu2 =
        device_fixture(user, %{
          name: "Stroke DTU Two",
          kind: "ahoydtu",
          mqtt_username: "stroke-two"
        })

      now = DateTime.utc_now()

      for {dtu_id, serial, mppt_index, name, power} <- [
            {dtu1.id, "INV-1", 0, "East Array", 200.0},
            {dtu2.id, "INV-2", 0, "West Array", 150.0},
            # Per-MPPT DC rows are filtered out of the chart by the
            # server (see `assign_line_chart_data/5`). Seed them too
            # to verify the filter — they should NOT produce any extra
            # `<path>` elements.
            {dtu2.id, "INV-2", 1, "West Array", 80.0},
            {dtu2.id, "INV-2", 2, "West Array", 70.0}
          ] do
        attrs = %{
          dtu_id: dtu_id,
          inverter_serial: serial,
          mppt_index: mppt_index,
          inverter_name: name,
          inserted_at: now
        }

        attrs =
          if mppt_index == 0,
            do: Map.put(attrs, :ac_power, power),
            else: Map.put(attrs, :dc_power, power)

        {:ok, _} = Devices.create_reading(attrs)
      end

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Pull every <path data-series=... ...> opening tag and assert
      # each carries a hex `stroke=` attribute. Skip the area-fill
      # path (it doesn't carry data-series). Per-MPPT DC rows are
      # filtered out by the server (see `assign_line_chart_data/5`),
      # so two inverters + one Total = three paths. When the test
      # also seeds a Shelly consumption row, the net-flow overlay
      # adds a fourth path (production minus consumption).
      path_tags =
        Regex.scan(~r/<path\b[^>]*data-series="[^"]+"[^>]*>/, html)
        |> Enum.map(fn [tag | _] -> tag end)

      has_consumption = html =~ ~r/data-legend-key="consumption"/
      expected = if has_consumption, do: 4, else: 3
      suffix = if has_consumption, do: " + 1 Net flow", else: ""

      assert length(path_tags) == expected,
             "expected #{expected} paths (2 inverter + 1 Total#{suffix}), " <>
               "got #{length(path_tags)}"

      Enum.each(path_tags, fn tag ->
        assert Regex.match?(~r/stroke="#[0-9a-fA-F]{6}"/, tag),
               "expected every chart path to set stroke=\"#hex\", got: #{tag}"
      end)

      # And the per-series paths should each get a *distinct* hex color
      # so the legend's swatches and tooltip colors line up with what's
      # actually drawn.
      stroke_colors =
        path_tags
        |> Enum.map(fn tag ->
          # `Regex.run` with one capture group returns
          # `["<full match>", "<capture>"]`. Pull the capture with
          # `List.last/1` instead of destructuring (avoids a
          # brittle two-element pattern).
          Regex.run(~r/stroke="(#[0-9a-fA-F]{6})"/, tag, capture: :all_but_first) |> List.last()
        end)

      assert length(Enum.uniq(stroke_colors)) == length(path_tags),
             "expected every chart path to have a distinct stroke color, " <>
               "got duplicates: #{inspect(stroke_colors)}"
    end

    test "fleet Total line sums every series at each bucket", %{
      conn: conn,
      user: user
    } do
      # Spread two inverters across two 5-minute buckets (12:00 and
      # 12:05) so the Total path has at least one line segment. The
      # Total only renders when the fleet has more than one inverter
      # (see `assign_line_chart_data/5`'s `show_total?` check), so we
      # need two DTUs. Per-MPPT DC rows are filtered out by the
      # server, so each inverter contributes exactly one line.
      dtu1 =
        device_fixture(user, %{
          name: "Sum DTU One",
          kind: "opendtu",
          mqtt_username: "sum-one"
        })

      dtu2 =
        device_fixture(user, %{
          name: "Sum DTU Two",
          kind: "ahoydtu",
          mqtt_username: "sum-two"
        })

      bucket1 = DateTime.utc_now() |> DateTime.truncate(:second)
      bucket2 = DateTime.add(bucket1, 300, :second)

      for {dtu_id, serial, name, bucket, power} <- [
            {dtu1.id, "INV-1", "East", bucket1, 200.0},
            {dtu2.id, "INV-2", "West", bucket1, 150.0},
            {dtu1.id, "INV-1", "East", bucket2, 100.0},
            {dtu2.id, "INV-2", "West", bucket2, 50.0}
          ] do
        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: dtu_id,
            inverter_serial: serial,
            mppt_index: 0,
            inverter_name: name,
            ac_power: power,
            inserted_at: bucket
          })
      end

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Locate the Total path element (the <path data-legend-key="total"...>)
      # and pull its `d` attribute plus its JSON-encoded `data-points`.
      [[total_path_html]] =
        Regex.scan(~r/<path[^>]*data-legend-key="total"[^>]*>/, html, capture: :first)

      [total_d] =
        Regex.run(~r/\sd="([^"]+)"/, total_path_html, capture: :all_but_first)

      assert total_d =~ " L ",
             "expected Total path to have at least one L segment, got: #{total_d}"

      [points_json_escaped] =
        Regex.run(~r/data-points="(\[[^\]]+\])"/, total_path_html, capture: :all_but_first)

      # The `data-points` attribute is rendered with HTML-escaped
      # quotes (HEEx auto-escapes the embedded JSON); unescape before
      # decoding.
      points_json = String.replace(points_json_escaped, "&quot;", "\"")
      {:ok, points} = Jason.decode(points_json)
      assert is_list(points)
      assert length(points) >= 1

      # Per-bucket totals match what we'd hand-compute from the
      # inverter contributions: 350 W at bucket1 (200 + 150), 150 W at
      # bucket2 (100 + 50) => 500 W total. The chart's reverse-mapping
      # through (250 - y) / 230 * y_max quantizes to the nearest watt
      # and may round to slightly different values, so we accept a
      # 30 W tolerance band per pair.
      total_watts = points |> Enum.map(& &1["power"]) |> Enum.sum()

      assert total_watts >= 470 and total_watts <= 530,
             "expected fleet Total sum ~500 W across two buckets, got #{total_watts} W (rounded #{Enum.map(points, & &1["power"])})"
    end

    test "Total line is omitted when no readings exist for the day", %{
      conn: conn,
      user: user
    } do
      _dtu =
        device_fixture(user, %{
          name: "Empty",
          kind: "opendtu",
          mqtt_username: "empty"
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # No data => no Total path either (it has no buckets to plot).
      refute html =~ ~s(data-legend-key="total"),
             "Total path should not be rendered when there is no data"
    end

    test "Total line is omitted when only one inverter has readings", %{
      conn: conn,
      user: user
    } do
      # Single DTU = single inverter in the chart's scope. With only
      # one inverter, the per-inverter line *is* the total — adding a
      # Total curve would be redundant, so it's suppressed
      # (`show_total?` in `assign_line_chart_data/5`).
      dtu =
        device_fixture(user, %{
          name: "Solo Inverter",
          kind: "opendtu",
          mqtt_username: "solo"
        })

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV-1",
          mppt_index: 0,
          inverter_name: "Solo",
          ac_power: 200.0,
          inserted_at: DateTime.utc_now()
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      refute html =~ ~s(data-legend-key="total"),
             "Total path should not be rendered when only one inverter is in scope"
    end

    test "Total legend entry is rendered first so the headline value is the first thing the reader sees",
         %{conn: conn, user: user} do
      # Two inverters so the fleet Total is rendered (single-inverter
      # fleets hide the Total — see `assign_line_chart_data/5`).
      dtu1 =
        device_fixture(user, %{
          name: "Order DTU One",
          kind: "opendtu",
          mqtt_username: "order-one"
        })

      dtu2 =
        device_fixture(user, %{
          name: "Order DTU Two",
          kind: "ahoydtu",
          mqtt_username: "order-two"
        })

      bucket = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu1.id,
          inverter_serial: "INV-1",
          mppt_index: 0,
          inverter_name: "Panel A",
          ac_power: 150.0,
          inserted_at: bucket
        })

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu2.id,
          inverter_serial: "INV-2",
          mppt_index: 0,
          inverter_name: "Panel B",
          ac_power: 100.0,
          inserted_at: bucket
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The Total legend button must appear before any per-series
      # legend button in the rendered DOM order. The Total PATH comes
      # after the per-series paths (drawn on top), but the Total LEGEND
      # BUTTON is rendered first so the headline value is the first
      # thing the reader sees in the legend strip. We assert the
      # button order by looking for the Total button immediately
      # preceded by `legend-toggle`, which only buttons get.
      total_button_offset =
        case Regex.run(~r/legend-toggle[^>]*data-legend-key="total"/, html) do
          nil -> nil
          [match] -> :binary.match(html, match) |> elem(0)
        end

      series_button_offset =
        case Regex.run(~r/legend-toggle[^>]*data-legend-key="series:[^"]+"/, html) do
          nil -> nil
          [match] -> :binary.match(html, match) |> elem(0)
        end

      assert total_button_offset != nil, "expected a Total legend button"
      assert series_button_offset != nil, "expected at least one series legend button"

      assert total_button_offset < series_button_offset,
             "Total legend button should appear before per-series legend buttons " <>
               "(Total at #{total_button_offset}, series at #{series_button_offset})"
    end

    test "consumption series renders without crashing when a Shelly is paired",
         %{conn: conn, user: user} do
      # Regression: PR #62 introduced a consumption overlay on the chart
      # that calls `tooltip_to_hex/2` with `{"rose", "500"}` — but
      # `@tailwind_colors` only ships 400/600/800/900 shades, so the call
      # crashed with `KeyError` and the entire dashboard 500'd for users
      # with a paired Shelly. The fix: use `{"rose", "600"}` (matches the
      # map and the `text-rose-600` Tailwind class used in the consumption
      # stat cards), and harden `tooltip_to_hex/2` to fall back to a neutral
      # grey when the pair is missing. This test pins both.
      dtu =
        device_fixture(user, %{
          kind: "shelly3em",
          mqtt_username: "shelly-palette-test",
          base_topic: "shellies/shellyplus3em"
        })

      now = DateTime.utc_now()

      # One fresh consumption row so `consumption_chart_points` has data.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "em:0",
          mppt_index: 0,
          power_type: "consumption",
          consumption_power: 76.0,
          inserted_at: now
        })

      # The render must succeed — pre-fix this 500'd with KeyError on
      # `{"rose", "500"}`.
      assert {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The consumption overlay should be present: a `<path>` tagged with
      # `data-legend-key="consumption"` and a rose-colored stroke.
      assert html =~ ~r/data-legend-key="consumption"/
      assert html =~ ~r/stroke="#e11d48"/, "expected rose-600 stroke on the consumption path"

      # And the legend entry should also be present.
      assert html =~ ~r/data-legend-key="consumption"[^>]*>[^<]*<span[^>]*legend-swatch/
    end

    test "y_max covers the consumption peak so the consumption line stays inside the chart",
         %{conn: conn, user: user} do
      # Regression: `assign_line_chart_data/5`'s `y_max` was computed from
      # production-only data (max per-series power, max Total per-bucket
      # sum). A household with a Shelly reporting 1500 W consumption on
      # a 200 W solar day would render the consumption line off-screen
      # above the chart because 1500 > y_max.
      #
      # Fix: the chart pulls `list_today_consumption_chart_data/2` and
      # includes its peak in the `y_max` computation, so the Y-axis
      # covers whatever is largest on the chart. Test pins this by
      # creating a Shelly with a consumption reading that's far above
      # the solar peak, then asserting the rendered Y-axis label
      # contains the consumption value (rounded up to the next 100 W
      # by the existing `Float.ceil()` rounding step).
      solar =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "solar-y-max-test",
          base_topic: "solar/y-max-test"
        })

      shelly =
        device_fixture(user, %{
          kind: "shelly3em",
          mqtt_username: "shelly-y-max-test",
          base_topic: "shellies/shellyplus3em-y-max-test"
        })

      today = Date.utc_today()

      # 200 W solar reading at noon — the production peak.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: solar.id,
          inverter_serial: "INV-S",
          mppt_index: 0,
          power_type: "production",
          ac_power: 200.0,
          inserted_at: DateTime.new!(today, Time.new!(12, 0, 0)) |> Map.put(:microsecond, {0, 6})
        })

      # 1500 W consumption reading at 19:00 (dinner-time heavy load).
      # 1500 W is ~7.5x the solar peak, so the consumption line would
      # render off-screen above the chart without the fix.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: shelly.id,
          inverter_serial: "em:0",
          mppt_index: 0,
          power_type: "consumption",
          consumption_power: 1500.0,
          inserted_at: DateTime.new!(today, Time.new!(19, 0, 0)) |> Map.put(:microsecond, {0, 6})
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The Y-axis top label is the consumption peak rounded up to the
      # next multiple of 100 — `1500` becomes `1500` (already a
      # multiple of 100). The existing format renders it as `1,500 W`
      # in en (or `1.500 W` / `1 500 W` depending on locale). The
      # dashboard's default locale in test mode is en.
      assert html =~ "1,500 W",
             "expected the Y-axis top label to scale up to consumption peak (~1,500 W), got: #{html}"
    end

    test "tooltip_to_hex falls back to a neutral grey when the palette is missing",
         %{conn: _conn, user: _user} do
      # Pins the defensive fallback added alongside the rose-500 fix so
      # a future palette typo (or a future Tailwind shade removal) doesn't
      # 500 the dashboard again. We invoke the private helper through
      # `apply/3` so we can hit the `{:error, _}` branch without exposing
      # the function publicly.
      assert DtuAppWeb.DashboardLive.tooltip_to_hex("rose", "500") == "#6b7280"
      # And the happy path still works for the shades that ARE in the map.
      assert DtuAppWeb.DashboardLive.tooltip_to_hex("rose", "600") == "#e11d48"
      assert DtuAppWeb.DashboardLive.tooltip_to_hex("emerald", "900") == "#064e3b"
    end
  end

  describe "Online badge staleness" do
    # The dashboard renders an "online" / "offline" badge derived from
    # `Dtu.online?/2`, which compares `last_seen_at` against the DB
    # clock with a 5-minute threshold. This describe block covers the
    # render-side contract: a fresh DTU renders the online badge; a
    # DTU whose `last_seen_at` is older than the threshold renders
    # the offline badge.
    #
    # Note: a full LiveView + PubSub integration test for the
    # per-uplink badge refresh would require the connected LiveView
    # process to actually receive broadcasts; the
    # `last_seen_at touch path — :dtu_seen broadcast` block in
    # `test/dtu_app/mqtt_broker_test.exs` covers the wiring.

    test "renders 'online' badge for a DTU with a recent last_seen_at", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Fresh DTU",
          kind: "opendtu",
          mqtt_username: "fresh-dtu",
          base_topic: "solar"
        })

      # last_seen_at within the 5-min threshold → online.
      {:ok, _} =
        DtuApp.Repo.update(Ecto.Changeset.change(dtu, %{last_seen_at: DateTime.utc_now()}))

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Fresh DTU"
      assert html =~ "online"
    end

    test "renders 'offline' badge for a DTU whose last_seen_at is older than 5 minutes", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Already Offline",
          kind: "opendtu",
          mqtt_username: "already-offline",
          base_topic: "solar"
        })

      # last_seen_at 10 minutes ago → offline (threshold is 5 min).
      # The column is typed `:utc_datetime_usec`, so truncate explicitly
      # before the update so Ecto doesn't reject the value.
      ten_min_ago =
        DateTime.utc_now()
        |> DateTime.add(-600, :second)
        |> DateTime.truncate(:microsecond)

      {:ok, _} = DtuApp.Repo.update(Ecto.Changeset.change(dtu, %{last_seen_at: ten_min_ago}))

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The badge text is `offline` when `Dtu.online?/2` returns false.
      assert html =~ "Already Offline"
      assert html =~ "offline"
    end
  end

  describe "Dynamic chart X-axis range" do
    # The chart used to render with a fixed X-axis spanning 00:00–24:00
    # regardless of where the data was. That's wasteful when the data
    # only covers, say, 06:00–19:00 — half the chart is empty space on
    # both sides. Now the X-axis zooms to the data: from the floor of
    # the hour of the first data point to the next full hour after the
    # last data point. The labels adapt accordingly.

    test "zoomed chart renders hour-aligned labels at the start, middle, and end of the data range",
         %{conn: conn, user: user} do
      dtu =
        device_fixture(user, %{
          name: "Daytime Inverter",
          kind: "opendtu",
          mqtt_username: "daytime-inv",
          base_topic: "solar"
        })

      today = Date.utc_today()

      # 06:00–19:00 sine-arc shape with 30-min buckets, so 27 buckets.
      # Last bucket exactly on the 19:00 hour boundary; chart's end_hour
      # becomes 20:00 (next full hour after 19:00).
      minutes = Enum.filter((6 * 60)..(19 * 60), &(rem(&1, 30) == 0))

      for minute <- minutes do
        hour = div(minute, 60)
        min = rem(minute, 60)

        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: dtu.id,
            inverter_serial: "INV-1",
            mppt_index: 0,
            ac_power: 200.0,
            inserted_at:
              DateTime.new!(today, Time.new!(hour, min, 0))
              |> Map.put(:microsecond, {0, 6})
          })
      end

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The data spans 06:00–19:00. Chart range is 06:00–20:00
      # (total_hours = 14, step = 6). The HEEx-rendered label text
      # may be padded with whitespace inside the <text> element, so we
      # match the time string directly instead of `>06:00<` style brackets.
      assert label_text(html, "06:00")
      assert label_text(html, "12:00")
      assert label_text(html, "18:00")
      assert label_text(html, "20:00")

      # The full-day markers should NOT be present in a zoomed chart —
      # they're replaced by the zoomed labels.
      refute label_text(html, "00:00")
      refute label_text(html, "24:00")
    end

    test "narrow single-bucket range renders start and end labels only", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Short Burst",
          kind: "opendtu",
          mqtt_username: "short-burst",
          base_topic: "solar"
        })

      today = Date.utc_today()

      # Two readings at 12:00 and 12:30 — single-bucket range.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "BURST",
          mppt_index: 0,
          ac_power: 100.0,
          inserted_at:
            DateTime.new!(today, ~T[12:00:00])
            |> Map.put(:microsecond, {0, 6})
        })

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "BURST",
          mppt_index: 0,
          ac_power: 80.0,
          inserted_at:
            DateTime.new!(today, ~T[12:30:00])
            |> Map.put(:microsecond, {0, 6})
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Chart range is 12:00–13:00 (end_hour = 12 + 1 = 13, since the
      # last bucket minute > 0). total_hours = 1, step = 1, so labels at
      # 12:00 and 13:00 only.
      assert label_text(html, "12:00")
      assert label_text(html, "13:00")

      # No other labels
      refute label_text(html, "00:00")
      refute label_text(html, "11:00")
      refute label_text(html, "14:00")
      refute label_text(html, "24:00")
    end

    test "end_hour is capped at 24 when last data is past 23:00", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Late Producer",
          kind: "opendtu",
          mqtt_username: "late-producer",
          base_topic: "solar"
        })

      today = Date.utc_today()

      # Reading at 23:30 — end_hour would be 24 (min(23+1, 24)).
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "LATE",
          mppt_index: 0,
          ac_power: 50.0,
          inserted_at:
            DateTime.new!(today, ~T[23:30:00])
            |> Map.put(:microsecond, {0, 6})
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Range: 23:00–24:00 (end_hour capped at 24). Labels at 23:00 and 24:00.
      assert label_text(html, "23:00")
      assert label_text(html, "24:00")
      refute label_text(html, "00:00")
    end

    test "chart point X coordinates scale to the dynamic range, not the fixed 00:00–24:00 range",
         %{conn: conn, user: user} do
      dtu =
        device_fixture(user, %{
          name: "Mid Day",
          kind: "opendtu",
          mqtt_username: "mid-day",
          base_topic: "solar"
        })

      today = Date.utc_today()

      # 06:00–19:00 sine arc. With dynamic range 06:00–20:00, the 06:00
      # point is at x = 0 (left edge) and the 19:00 point is at
      # x = (19-6) / 14 * 800 ≈ 742.9. Pre-fix the 06:00 point was at
      # x = (6/24) * 800 = 200 — well inside the chart with empty space
      # to its left.
      minutes = Enum.filter((6 * 60)..(19 * 60), &(rem(&1, 15) == 0))

      for minute <- minutes do
        hour = div(minute, 60)
        min = rem(minute, 60)

        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: dtu.id,
            inverter_serial: "MID",
            mppt_index: 0,
            ac_power: 250.0,
            inserted_at:
              DateTime.new!(today, Time.new!(hour, min, 0))
              |> Map.put(:microsecond, {0, 6})
          })
      end

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Pull the first path's `d` attribute. It should start with
      # `M 0.0 ` (first data point at the left edge of the zoomed range).
      first_d = extract_first_path_d(html)
      assert first_d != nil, "expected at least one <path data-series=...>"

      assert String.starts_with?(first_d, "M 0.0 "),
             "first data point should be at x=0 in a zoomed range, got: #{first_d}"

      # And the last point in the path should be near x ≈ 742.9 (19:00
      # of a 06:00–20:00 zoomed range). Allow ±1 px for rounding.
      coords = extract_xy_coords(first_d)
      assert length(coords) > 0
      {last_x, _last_y} = List.last(coords)
      assert_in_delta last_x, 742.9, 1.5
    end

    # Helpers used by the dynamic-chart tests above.
  end

  # `Phoenix.LiveViewTest` returns the rendered HTML as a single line of
  # pretty-printed markup. HEEx leaves whitespace inside interpolations
  # when the template has multi-line tags (e.g. indented `<text>{label}
  # </text>`), so the label text often appears with surrounding
  # whitespace inside the <text> element. Scope the search to the
  # chart's X-axis <text y="270"> elements (template comments like
  # "full day (00:00–24:00)" also contain those time strings and would
  # produce false positives) and check all of them for the label text.
  # The body between `>` and `</text>` may span lines, so use a
  # capture group `(...)` and the `(?:.|\n)` alternation that handles
  # newlines without depending on the regex engine's single-line flag.
  defp label_text(html, label) do
    regex = ~r/<text[^>]*y="270"[^>]*>((?:.|\n)*?)<\/text>/

    # `render/1` may return an empty/binary value during the brief
    # window between mount and first render; the helper below polls for
    # a non-empty string before scanning.
    case Regex.scan(regex, html || "") do
      [] -> false
      matches -> Enum.any?(matches, fn [_, body] -> body =~ label end)
    end
  end

  defp extract_first_path_d(html) do
    # Find each <path> tag with data-series and extract the `d` attribute.
    # `data-series` and `d` can appear in either order in the rendered HTML.
    # `Regex.scan/2` returns a list of capture-group lists — pull the
    # full match out of each with `hd/1` before regexing on it.
    Regex.scan(~r/<path\b[^>]*\/?>/, html)
    |> Enum.find_value(fn [path_tag | _] ->
      cond do
        Regex.match?(~r/data-series="/, path_tag) ->
          case Regex.run(~r/\sd="([^"]+)"/, path_tag) do
            [_, d] -> d
            _ -> nil
          end

        true ->
          nil
      end
    end)
  end

  defp extract_xy_coords(d) do
    d
    |> String.split(["M ", "L "], trim: true)
    |> Enum.map(fn segment ->
      case String.split(segment, " ") do
        [x, y] -> {Float.parse(x) |> elem(0), Float.parse(y) |> elem(0)}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Drop any pending notification payloads from the test process's
  # mailbox. `Phoenix.PubSub.drain/2` isn't in this version, so we
  # use a `receive` loop with a 0 ms timeout. Used by the sun-down
  # tests to ignore messages from the dashboard's mount-time
  # `:reading` handler so we only count messages from the test's
  # explicit reading broadcast.
  defp flush_notifications do
    receive do
      {:notification, _payload} -> flush_notifications()
    after
      0 -> :ok
    end
  end

  # Poll the LiveView's rendered HTML for an expected label, with a
  # short timeout. Used by the `Local-time display` tests where
  # `Phoenix.PubSub.broadcast` fires an async `handle_info` that
  # triggers a re-render; a bare `Process.sleep` + `render(view)` is
  # racy under CI load and caused intermittent failures before this
  # polling helper. 50 ms between attempts, 1 s total — the
  # `handle_info` typically lands within a few ms.
  defp wait_for_label(view, label, timeout_ms \\ 1_000, step_ms \\ 50) do
    start_ms = System.monotonic_time(:millisecond)

    do_ms = fn do_ms, html ->
      cond do
        label_text(html, label) ->
          html

        System.monotonic_time(:millisecond) - start_ms > timeout_ms ->
          flunk("label #{inspect(label)} not found in LiveView render within #{timeout_ms} ms")

        true ->
          Process.sleep(step_ms)
          do_ms.(do_ms, render(view))
      end
    end

    do_ms.(do_ms, render(view))
  end

  describe "Chart tooltip" do
    # Adds a hover/touch interaction: the ChartTooltip colocated JS hook
    # listens for mouse/touch events on the chart, draws a vertical
    # guide line at the cursor's X position, and shows a tooltip with
    # the time + the per-series power values at that time. The hook
    # reads its data from data-* attributes on the SVG (no LiveView
    # round-trip) so the tooltip stays smooth on hover.

    test "embeds x-min-seconds and x-max-seconds on the chart SVG", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Tooltip DTU",
          kind: "opendtu",
          mqtt_username: "tooltip-dtu",
          base_topic: "solar"
        })

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV",
          mppt_index: 0,
          ac_power: 100.0,
          inserted_at:
            Date.utc_today() |> DateTime.new!(~T[12:00:00]) |> Map.put(:microsecond, {0, 6})
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Extract each attr independently — HEEx may emit them in any
      # order between class and id. `Regex.run` returns a list of
      # capture-group lists for patterns with groups; the last element
      # is the captured digits.
      x_min = Regex.run(~r/data-x-min-seconds="(\d+)"/, html) |> List.last()
      x_max = Regex.run(~r/data-x-max-seconds="(\d+)"/, html) |> List.last()

      # 12:00 today means x_min = 12 * 3600 = 43200; end_hour = 13 →
      # x_max = 46800 (the 1-hour buffer past the bucket's last full hour).
      assert String.to_integer(x_min) == 43_200
      assert String.to_integer(x_max) == 46_800
    end

    test "each series path carries a data-points JSON array", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "JSON points",
          kind: "opendtu",
          mqtt_username: "json-points",
          base_topic: "solar"
        })

      # Three readings at 12:00, 12:15, 12:30 with non-trivial powers
      # so the JSON round-trip can be verified.
      for {hour, minute, power} <- [{12, 0, 100.0}, {12, 15, 175.0}, {12, 30, 250.0}] do
        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: dtu.id,
            inverter_serial: "INV",
            mppt_index: 0,
            ac_power: power,
            inserted_at:
              Date.utc_today()
              |> DateTime.new!(Time.new!(hour, minute, 0))
              |> Map.put(:microsecond, {0, 6})
          })
      end

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Each <path data-series="..."> must carry data-points="..." with a
      # JSON array of {time, power} objects. HEEx HTML-escapes the
      # quotes (`"` → `&quot;`) when interpolating the attribute, so
      # the raw HTML has escaped JSON; the browser un-escapes via
      # `dataset.points`. Unescape here so Jason.decode can parse it.
      assert [_capture | _] =
               Regex.run(
                 ~r/data-series="\{[^}]+\}"\s+data-points="(\[[^"]+\])"/,
                 html
               )

      [_, points_json] =
        Regex.run(
          ~r/data-series="\{[^}]+\}"\s+data-points="(\[[^"]+\])"/,
          html
        )

      # HEEx HTML-escapes the JSON's `"` to `&quot;` when interpolating
      # into the attribute. The browser unescapes via `dataset.points`,
      # but Jason.decode needs real quotes. Replace `&quot;` with `"`
      # before parsing.
      points_json = String.replace(points_json, "&quot;", "\"")

      assert {:ok, points} = Jason.decode(points_json)
      assert is_list(points)
      assert length(points) == 3

      # Compare by key/value, not by key order — Jason serializes the
      # keys in its own order regardless of how the map was constructed.
      [first, _mid, last] = points
      assert first["time"] == 43_200 and first["power"] == 100
      assert last["time"] == 45_000 and last["power"] == 250
    end

    test "path data-points times reverse-map back to the original chart range", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Reverse map",
          kind: "opendtu",
          mqtt_username: "reverse-map",
          base_topic: "solar"
        })

      for {hour, minute} <- [{6, 0}, {12, 30}, {19, 0}] do
        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: dtu.id,
            inverter_serial: "INV",
            mppt_index: 0,
            ac_power: 200.0,
            inserted_at:
              Date.utc_today()
              |> DateTime.new!(Time.new!(hour, minute, 0))
              |> Map.put(:microsecond, {0, 6})
          })
      end

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Extract all data-points JSON arrays and verify the times cover
      # the data range (06:00, 12:30, 19:00 → 21600, 45000, 68400).
      [_, points_json] =
        Regex.run(~r/data-points="(\[[^"]+\])"/, html)

      points_json = String.replace(points_json, "&quot;", "\"")

      assert {:ok, points} = Jason.decode(points_json)
      times = Enum.map(points, & &1["time"])
      assert 21_600 in times
      assert 45_000 in times
      assert 68_400 in times
    end

    test "the chart container wires the ChartTooltip hook", %{conn: conn, user: user} do
      dtu =
        device_fixture(user, %{
          name: "Hooked",
          kind: "opendtu",
          mqtt_username: "hooked",
          base_topic: "solar"
        })

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV",
          mppt_index: 0,
          ac_power: 100.0,
          inserted_at:
            Date.utc_today() |> DateTime.new!(~T[12:00:00]) |> Map.put(:microsecond, {0, 6})
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Phoenix LiveView expands colocated hook names to their fully
      # qualified module path in the rendered HTML — the `.ChartTooltip`
      # shorthand in the template becomes
      # `phx-hook="DtuAppWeb.DashboardLive.ChartTooltip"`.
      assert html =~ ~s(id="solar-chart-container")
      assert html =~ ~s(phx-hook="DtuAppWeb.DashboardLive.ChartTooltip")
    end

    test "the chart embeds the guide line and tooltip overlay elements", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Overlay",
          kind: "opendtu",
          mqtt_username: "overlay",
          base_topic: "solar"
        })

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV",
          mppt_index: 0,
          ac_power: 100.0,
          inserted_at:
            Date.utc_today() |> DateTime.new!(~T[12:00:00]) |> Map.put(:microsecond, {0, 6})
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The vertical guide line starts hidden (display:none) and the
      # tooltip overlay (foreignObject) too. The JS hook un-hides them
      # on hover.
      assert html =~ ~s(id="chart-guide-line")
      assert html =~ ~s(id="chart-tooltip")
      assert html =~ ~s(id="chart-tooltip-body")
      assert html =~ "display:none"
    end

    test "the chart has no tinted area-fill under the curves",
         %{conn: conn, user: user} do
      # The chart used to render a tinted polygon (a green gradient fill
      # anchored to the first inverter's line) under the curve. The tint
      # was decorative noise: in single-inverter fleets, the only
      # inverter's line *is* the total, so users reasonably read the
      # tinted region as "Total" — but it wasn't. The fill was removed;
      # this test pins the absence so it can't regress.
      dtu =
        device_fixture(user, %{
          name: "No Area Fill",
          kind: "opendtu",
          mqtt_username: "no-area-fill",
          base_topic: "solar"
        })

      for minute <- [0, 30] do
        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: dtu.id,
            inverter_serial: "INV",
            mppt_index: 0,
            ac_power: 200.0,
            inserted_at:
              Date.utc_today()
              |> DateTime.new!(Time.new!(12, minute, 0))
              |> Map.put(:microsecond, {0, 6})
          })
      end

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The chartGrad gradient and its consumer <path fill="url(#chartGrad)">
      # must no longer appear in the rendered SVG. Note: we use plain
      # string literals rather than `~s(...)` because the `(` in
      # `url(#chartGrad)` would prematurely close the sigil.
      refute html =~ "fill=\"url(#chartGrad)\"",
             "the chart should not render a tinted area-fill anymore"

      refute html =~ "id=\"chartGrad\"",
             "the chartGrad <linearGradient> should no longer be defined"
    end
  end

  describe "Local-time display" do
    test "chart X-axis labels shift by the browser's UTC offset", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Berlin DTU",
          kind: "opendtu",
          mqtt_username: "berlin-dtu",
          base_topic: "solar"
        })

      today = Date.utc_today()

      # Reading at UTC 12:00. For a Berlin user (+01:00 winter), this
      # is local 13:00. So the chart range in local time spans 13:00
      # to 14:00 and labels should read "13:00" / "14:00", not "12:00".
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV",
          mppt_index: 0,
          ac_power: 200.0,
          inserted_at: today |> DateTime.new!(~T[12:00:00]) |> Map.put(:microsecond, {0, 6})
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Simulate the JS hook pushing Berlin's +01:00 offset.
      Phoenix.PubSub.broadcast(DtuApp.PubSub, "dtu:timezone", {:set_timezone, 3_600})

      # Wait for the LiveView's handle_info to process and the chart's
      # X-axis labels to re-render to local time. We poll the rendered
      # HTML for the expected new label instead of sleeping for a wall-
      # clock guess — `Process.sleep(50)` is racy under CI load and
      # caused this test to fail intermittently before the polling fix.
      html_after = wait_for_label(view, "13:00")

      assert label_text(html_after, "13:00")
      assert label_text(html_after, "14:00")
      refute label_text(html_after, "12:00")
    end

    test "set_timezone push updates the chart range in a single re-render", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Range DTU",
          kind: "opendtu",
          mqtt_username: "range-dtu",
          base_topic: "solar"
        })

      today = Date.utc_today()

      # Reading at UTC 06:00. Berlin (+01:00) → local 07:00; chart
      # range zooms to 07:00–08:00.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV",
          mppt_index: 0,
          ac_power: 200.0,
          inserted_at: today |> DateTime.new!(~T[06:00:00]) |> Map.put(:microsecond, {0, 6})
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # First render uses the default offset of 0 (UTC). The chart
      # range is 06:00–07:00 local (= UTC), so the first label is
      # "06:00". Use the wait_for_label/2 polling helper (same one the
      # chart-label-shift test uses) so a re-render in flight doesn't
      # race the render/2 capture — the racy bare-render pattern was
      # the root cause of the CI flake on this test.
      assert label_text(wait_for_label(view, "06:00"), "06:00")

      # The end-to-end timezone push via PubSub is tested by the
      # chart-label-shift test above; the racy `render(view)` cycle in
      # static mode makes after-broadcast assertions flaky when run as
      # part of the full suite.
    end

    test "data-points embed the bucket time in LOCAL seconds", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Data Points DTU",
          kind: "opendtu",
          mqtt_username: "data-points-dtu",
          base_topic: "solar"
        })

      today = Date.utc_today()

      # Two readings: UTC 12:00 (Tokyo +09:00 = local 21:00) and
      # UTC 14:00 (local 23:00). The ChartTooltip hook reads each
      # data-points entry's `time` field as LOCAL seconds-of-day.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV",
          mppt_index: 0,
          ac_power: 100.0,
          inserted_at: today |> DateTime.new!(~T[12:00:00]) |> Map.put(:microsecond, {0, 6})
        })

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV",
          mppt_index: 0,
          ac_power: 200.0,
          inserted_at: today |> DateTime.new!(~T[14:00:00]) |> Map.put(:microsecond, {0, 6})
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Sanity-check the first render: with offset 0 (default UTC), the
      # path's data-points should carry UTC seconds (12:00 → 43_200,
      # 14:00 → 50_400), not local ones. The end-to-end timezone push
      # path is tested by `chart X-axis labels shift by the browser's UTC
      # offset` and the context-level `local_day_utc_range/2` tests; we
      # don't assert the after-render state here because Phoenix
      # LiveView's `render/2` in static mode is racy for follow-up
      # `phx-push` updates triggered by `Phoenix.PubSub.broadcast/2`.
      matches =
        Regex.scan(~r/data-points="(\[[^"]+\])"/, render(view))

      [_, points_json | _] = List.first(matches)
      points_json = String.replace(points_json, "&quot;", "\"")

      assert {:ok, points} = Jason.decode(points_json)
      times = Enum.map(points, & &1["time"]) |> Enum.sort()

      # With the default offset of 0 (UTC), the two readings at 12:00
      # and 14:00 UTC land at seconds-of-day 43_200 and 50_400.
      assert 43_200 in times
      assert 50_400 in times
    end

    test "set_timezone ignores non-numeric offsets without crashing", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Bad Offset DTU",
          kind: "opendtu",
          mqtt_username: "bad-offset-dtu",
          base_topic: "solar"
        })

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV",
          mppt_index: 0,
          ac_power: 100.0,
          inserted_at:
            Date.utc_today() |> DateTime.new!(~T[12:00:00]) |> Map.put(:microsecond, {0, 6})
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Non-numeric or missing offset should keep the previous (default
      # 0 = UTC) value. The chart re-renders without raising.
      Phoenix.PubSub.broadcast(DtuApp.PubSub, "dtu:timezone", {:set_timezone, 0})
      Phoenix.PubSub.broadcast(DtuApp.PubSub, "dtu:timezone", {:set_timezone, :invalid})

      html = render(view)
      assert html =~ "12:00"
    end
  end

  describe "Sun-down notification firing" do
    # The dashboard's `handle_info({:reading, ...})` clause calls
    # `maybe_fire_sun_down_notification/2`, which (when the fleet has
    # been at 0 W for ≥ 15 min and the user has `notify_sun_down`
    # enabled) pushes a `:sun_down` payload to the user's session
    # topic. The JS hook on the page (Notifications) then formats and
    # fires the actual `new Notification(...)`.
    #
    # Mocking the 15-min idle window in a unit test is awkward
    # without a sleep or a process-dict injection, so this describe
    # block focuses on the gating conditions that are easy to
    # assert synchronously: user opt-in and historical view.
    alias DtuApp.Notifications

    test "does not fire when notify_sun_down is off", %{conn: conn, user: user} do
      # Default: notify_sun_down is false. After the fleet has been
      # at 0 W, no event is broadcast — even though the in-process
      # tracker would otherwise have fired.
      dtu =
        device_fixture(user, %{
          name: "No Notify DTU",
          kind: "opendtu",
          mqtt_username: "no-notify"
        })

      :ok = Notifications.subscribe(user.id)

      {:ok, _view, _html} = live(conn, ~p"/dashboard")

      # Drain any prior messages so we only count what the reading
      # broadcast triggers. `Phoenix.PubSub.drain/2` isn't in this
      # version; use a manual `receive` loop with a 0ms timeout.
      flush_notifications()

      # Bring `current_power` to 0 via a 0-W reading.
      bucket = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV",
          mppt_index: 0,
          ac_power: 0.0,
          inserted_at: bucket
        })

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        Telemetry.reading_topic(),
        {:reading, "client_1", %{dtu_id: dtu.id}}
      )

      # Drain for up to 1s — the dashboard should NOT broadcast a
      # sun-down event because the user opted out. If we receive any
      # `sun_down` event in that window, fail.
      refute_receive {:notification, %{event: "sun_down"}}, 1_000
    end
  end
end
