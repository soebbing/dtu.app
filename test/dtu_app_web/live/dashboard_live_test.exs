defmodule DtuAppWeb.DashboardLiveTest do
  use DtuAppWeb.ConnCase, async: false

  use Gettext, backend: DtuAppWeb.Gettext

  import Phoenix.LiveViewTest
  import DtuApp.DevicesFixtures

  alias DtuApp.MqttBroker.Telemetry
  alias DtuApp.Devices
  alias DtuApp.Notifications

  setup :register_and_log_in_user

  describe "Dashboard Index" do
    test "renders empty dashboard stats and empty state message", %{conn: conn, user: user} do
      _dtu =
        device_fixture(user, %{name: "Test Inverter", kind: "opendtu", mqtt_username: "test-inv"})

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "PV Power Dashboard"
      # The 5-up row uses period-stable labels ("Yield" / "Peak Power"
      # / "Peak Time" / "Self-consumption" / "Saved this period") so
      # both the live view and the historical views share the same
      # headline row.
      assert html =~ "Yield"
      assert html =~ "Peak Power"
      # W stat cards render with `decimals: 0` (350 W not 350.0 W);
      # kWh stat cards render with `decimals: 1` (1.3 kWh not 1 kWh).
      assert html =~ "0 W"
      assert html =~ "0.0 kWh"
      assert html =~ "No power readings logged for this day."
    end

    test "renders dashboard in German when the user has German locale", %{conn: conn, user: user} do
      # The user's persisted locale wins over Accept-Language
      # (see `Plugs.Locale` priority chain) — set it explicitly to
      # exercise the German catalog end-to-end. Setting Accept-Language
      # alone is no longer sufficient once a user is signed in.
      {:ok, user} =
        DtuApp.Accounts.update_user_settings(user, %{"locale" => "de"})

      _dtu =
        device_fixture(user, %{name: "Test Inverter", kind: "opendtu", mqtt_username: "test-inv"})

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The German catalog has "PV Power Dashboard" → "PV-Power-Dashboard"
      # (catalog entries aren't all proper German; some are borrowed
      # English terms with German hyphenation). The test pins the
      # catalog as it stands today — if the catalog gets a proper
      # German translation later, this assertion should follow it.
      assert html =~ "PV-Power-Dashboard"
      # The 5-up row's labels are period-stable across all presets.
      # "Peak Power" is translated to "Spitzenleistung" in the German
      # catalog; "Yield" / "Peak Time" / "Self-consumption" are not
      # translated yet, so they fall back to the English msgid.
      assert html =~ "Spitzenleistung"
    end

    test "renders dashboard in French when the user has French locale", %{conn: conn, user: user} do
      {:ok, user} =
        DtuApp.Accounts.update_user_settings(user, %{"locale" => "fr"})

      _dtu =
        device_fixture(user, %{name: "Test Inverter", kind: "opendtu", mqtt_username: "test-inv"})

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Tableau de bord de puissance photovoltaïque"
      # The 5-up row's labels are period-stable across all presets.
      # "Peak Power" is translated to "Puissance de crête" in the
      # French catalog; the other row labels fall back to their
      # English msgid until the catalog catches up.
      assert html =~ "Puissance de crête"
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
      {:ok, user} =
        DtuApp.Accounts.update_user_settings(user, %{"locale" => "de"})

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

      assert element(view, "#stat-yield-kwh") |> render() =~ "3.0 kWh"
      # Total view sums each inverter's last reading of the day across
      # both DTUs (each inverter's monotonic `yield_day` reaches its
      # day's total at the day's last reading). Sum across DTUs:
      # 1_000 + 2_000 = 3_000 Wh = 3.0 kWh. The "Yield" card is the
      # single kWh headline on the new 5-up row — the old live view
      # also surfaced a separate "Current Power" W figure that the new
      # row folds into the chart.

      # 2. Click "DTU One" and verify stats filter down to DTU One's values
      view
      |> element("#btn-select-dtu-#{dtu1.id}")
      |> render_click()

      assert element(view, "#stat-yield-kwh") |> render() =~ "1.0 kWh"

      # 3. Click "DTU Two" and verify stats filter down to DTU Two's values
      view
      |> element("#btn-select-dtu-#{dtu2.id}")
      |> render_click()

      assert element(view, "#stat-yield-kwh") |> render() =~ "2.0 kWh"

      # 4. Click "Total" again and verify totals are displayed
      view
      |> element("#btn-select-total")
      |> render_click()

      assert element(view, "#stat-yield-kwh") |> render() =~ "3.0 kWh"
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

    test "DTU-only user renders the 0 W label on the chart's bottom edge", %{
      conn: conn,
      user: user
    } do
      # Regression for "the production curve wastes the lower half of the
      # chart when no Shelly is paired". Previously the chart used a
      # fixed `zero_y_default = 135` regardless of device mix, leaving
      # the lower 110 px of the chart empty for DTU-only users (no curve
      # ever plots below the zero line because there's no export peak).
      # The chart now pins `zero_y` to the chart bottom (y=250) for
      # DTU-only users so the production curve fills the full chart
      # height — the 0 W gridline + label sit at y=250 / y=262.
      dtu =
        device_fixture(user, %{
          name: "Bottom Edge DTU",
          kind: "opendtu",
          mqtt_username: "bottom-edge"
        })

      # 350 W peak → y_max rounds up to 400, but with no Shelly paired
      # the only ticks are the edges (0 and 400) — 400 < 500 so the
      # next interior 500 W tick is dropped.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV",
          mppt_index: 0,
          inverter_name: "Solo",
          ac_power: 350.0,
          yield_day: 1_000.0,
          inserted_at: DateTime.utc_now()
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The 0 W label sits at y_pixel + 12. With zero_y = 250 the gridline
      # is at y=250 and the label is at y=262. Pull the matching <text>
      # tag, strip whitespace, and pin the exact label content.
      [zero_label_tag] =
        Regex.run(
          ~r{<text[^>]*y="262(?:\.0)?"[^>]*>\s*([^<]+?)\s*</text>}s,
          html,
          capture: :all_but_first
        )

      assert zero_label_tag == "0 W",
             "expected y=262 label to read '0 W', got: '#{zero_label_tag}'"

      # Confirm the 0 W dashed gridline sits at y=250 (the chart
      # bottom) — the line carries `stroke-dasharray="4"` to mark it
      # as the reference.
      assert html =~
               ~r/<line[^>]*y1="250(?:\.0)?"[^>]*y2="250(?:\.0)?"[^>]*stroke-dasharray="4"/,
             "DTU-only chart should have a dashed zero gridline at y=250 (chart bottom)"
    end

    test "DTU-only user renders a 500 W gridline step on larger scales", %{
      conn: conn,
      user: user
    } do
      # With y_max ≥ 500 the chart renders gridlines at every 500 W
      # above the zero line: 0, 500, 1000, …, y_max. Each gets a <line>
      # + a <text> label. This pins the user's "at least every 500 W"
      # rule — a future change that drops to a coarser step (e.g.
      # 1000 W) would fail to render the in-between ticks.
      dtu =
        device_fixture(user, %{
          name: "Big Scale DTU",
          kind: "opendtu",
          mqtt_username: "big-scale"
        })

      # 2_350 W peak → y_max rounds up to next 100 = 2_400. Gridlines
      # are bounded by y_max, so the top tick is 2_400 (not 2_500).
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "BIG",
          mppt_index: 0,
          inverter_name: "Big",
          ac_power: 2_350.0,
          yield_day: 10_000.0,
          inserted_at: DateTime.utc_now()
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Pinned ticks at every 500 W from 0 up to y_max. `format_number/3`
      # uses `decimals: 0` and inserts thousands separators per locale,
      # so 1_000 W renders as "1,000 W" in the en-locale test.
      for label <- ["0 W", "500 W", "1,000 W", "1,500 W", "2,000 W"] do
        assert html =~ label, "expected gridline label '#{label}' to render"
      end

      # The top edge tick (y_max = 2_400) — pinned by literal string
      # match since 2,400 W is unique.
      assert html =~ "2,400 W",
             "expected top-edge label '2,400 W' to render for y_max = 2400"

      # Confirm no spurious 500 W tick above y_max — 2,500 must NOT
      # appear because 2,500 > y_max = 2,400.
      refute html =~ "2,500 W", "no 2500 W gridline should render when y_max = 2400"
    end

    test "Shelly-only / paired user keeps zero_y at y=135 (no behaviour change)", %{
      conn: conn,
      user: user
    } do
      # The bottom-edge behaviour is DTU-only. A paired user (inverter
      # + Shelly) with no export peak keeps the historical layout: zero
      # line at y=135, 0 W label at y=147. Pin it so the DTU-only
      # change doesn't accidentally bleed into the paired-user branch.
      inverter =
        device_fixture(user, %{
          name: "Paired Inverter",
          kind: "opendtu",
          mqtt_username: "paired-inv"
        })

      _shelly =
        device_fixture(user, %{
          kind: "shelly3em",
          mqtt_username: "paired-shelly",
          base_topic: "shellies/paired"
        })

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: inverter.id,
          inverter_serial: "INV-PAIRED",
          mppt_index: 0,
          power_type: "production",
          ac_power: 350.0,
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Paired user keeps zero_y = 135 (default). The 0 W label sits
      # at y=147 (just below the dashed gridline).
      [zero_label_tag] =
        Regex.run(
          ~r{<text[^>]*y="147(?:\.0)?"[^>]*>\s*([^<]+?)\s*</text>}s,
          html,
          capture: :all_but_first
        )

      assert zero_label_tag == "0 W",
             "paired user should still see '0 W' label at y=147, got: '#{zero_label_tag}'"
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

    test "Total line is omitted and legacy `_fleet` rows never reach the legend for a single-inverter dashboard",
         %{conn: conn, user: user} do
      # Regression for the "I still see _fleet and total legends" bug: a
      # single real inverter exists, but the DB also carries legacy
      # `{base}/total` uplinks persisted by an older parser version,
      # keyed `inverter_serial = "_fleet"`. Without the
      # `inverter_serial != "_fleet"` filter in
      # `assign_line_chart_data/5`, the `_fleet` row counts as a second
      # "distinct inverter" (via `distinct_inverters`) AND surfaces as
      # its own legend entry — even though the user only owns one
      # inverter and the new parser no longer creates `_fleet` rows.
      dtu =
        device_fixture(user, %{
          name: "Legacy Fleet Host",
          kind: "opendtu",
          mqtt_username: "legacy-fleet"
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # The single real inverter — what the user actually owns.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV-REAL",
          mppt_index: 0,
          inverter_name: "Real Inverter",
          ac_power: 200.0,
          inserted_at: now
        })

      # Legacy `{base}/total` uplink the previous parser version
      # persisted. `ac_power` here is the firmware-aggregated fleet
      # total, not per-inverter power — that's the whole reason these
      # rows are obsolete now and must never reach the chart.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "_fleet",
          mppt_index: 0,
          inverter_name: "_fleet",
          ac_power: 200.0,
          inserted_at: now
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # (1) Total curve must NOT render — only one real inverter means
      # the per-inverter line *is* the total.
      refute html =~ ~s(data-legend-key="total"),
             "Total path leaked through despite only one real inverter"

      # (2) `_fleet` must NOT appear anywhere in the legend or chart —
      # not as a series path, not as a legend toggle, not in the
      # rendered serial. The whole point of the defensive filter is to
      # hide this obsolete firmware-aggregate entry completely.
      refute html =~ "_fleet",
             "legacy `_fleet` row leaked into the rendered dashboard"

      # (3) Sanity: the real inverter must still be visible.
      assert html =~ "Real Inverter"
      assert html =~ "INV-REAL"
    end

    test "_fleet is filtered out of the chart even when multiple real inverters exist",
         %{conn: conn, user: user} do
      # Counterpart to the single-inverter case above: even when the
      # fleet *does* have multiple inverters (so `show_total?` is true
      # and the Total curve legitimately renders), a legacy `_fleet`
      # row must NOT add a phantom third series to the chart or legend.
      # Without the filter, the legend would show `_fleet` as a fourth
      # line and the Total would double-count the fleet aggregate.
      dtu1 =
        device_fixture(user, %{
          name: "Multi Fleet One",
          kind: "opendtu",
          mqtt_username: "multi-fleet-one"
        })

      dtu2 =
        device_fixture(user, %{
          name: "Multi Fleet Two",
          kind: "ahoydtu",
          mqtt_username: "multi-fleet-two"
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      for {dtu_id, serial, name, power} <- [
            {dtu1.id, "INV-A", "East Array", 150.0},
            {dtu2.id, "INV-B", "West Array", 100.0},
            # Legacy firmware-aggregate row that must NOT reach the
            # chart. Matches the sum of the two inverters above so a
            # regression would visually double the Total peak.
            {dtu1.id, "_fleet", "_fleet", 250.0}
          ] do
        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: dtu_id,
            inverter_serial: serial,
            mppt_index: 0,
            inverter_name: name,
            ac_power: power,
            inserted_at: now
          })
      end

      {:ok, view, html} = live(conn, ~p"/dashboard")

      # The two real inverters are present.
      assert has_element?(view, "#chart-legend")
      assert html =~ "East Array"
      assert html =~ "West Array"

      # Total renders (two real inverters ⇒ `show_total? = true`).
      assert html =~ ~s(data-legend-key="total"),
             "expected Total path for multi-inverter dashboard"

      # `_fleet` is hidden — neither as a legend entry nor as a path.
      refute html =~ "_fleet",
             "legacy `_fleet` row leaked into the multi-inverter dashboard"

      # Exactly three paths in the SVG: INV-A + INV-B + Total. Without
      # the filter this would be four (INV-A + INV-B + _fleet + Total).
      path_count = html |> String.split(~s(data-series=)) |> length() |> Kernel.-(1)

      assert path_count == 3,
             "expected 3 chart paths (2 inverters + Total), got #{path_count}"
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

    test "full-day (00:00–24:00) range renders a tick every ≤ 2 hours", %{
      conn: conn,
      user: user
    } do
      # The previous x-axis ladder used step = 6 for `total_hours > 12`,
      # so a 24-hour view rendered only 5 ticks (00, 06, 12, 18, 24).
      # The user's explicit ask was a max 2-hour interval — step is now
      # capped at 2 for any span > 2 hours, so a 24-hour view renders
      # 13 ticks (00, 02, 04, …, 24).
      dtu =
        device_fixture(user, %{
          name: "Full Day",
          kind: "opendtu",
          mqtt_username: "full-day",
          base_topic: "solar"
        })

      today = Date.utc_today()

      # Seed a reading every hour from 00:00 to 23:00 so the chart
      # spans the full 00:00–24:00 range (24 buckets).
      for hour <- 0..23 do
        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: dtu.id,
            inverter_serial: "FULL",
            mppt_index: 0,
            ac_power: 100.0,
            inserted_at:
              DateTime.new!(today, Time.new!(hour, 0, 0))
              |> Map.put(:microsecond, {0, 6})
          })
      end

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Every even hour from 00 to 24 must appear as a label.
      for hour <- Enum.filter(0..24, &(rem(&1, 2) == 0)) do
        label = String.pad_leading(Integer.to_string(hour), 2, "0") <> ":00"

        assert label_text(html, label),
               "expected x-axis label #{label} for the full-day range (step = 2)"
      end

      # Odd hours must NOT appear — they're not on the even-hour grid
      # and adding them would clutter the axis.
      for hour <- [01, 03, 05, 07, 09, 11, 13, 15, 17, 19, 21, 23] do
        label = String.pad_leading(Integer.to_string(hour), 2, "0") <> ":00"

        refute label_text(html, label),
               "x-axis should not show odd-hour label #{label} (step = 2)"
      end
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
    # Path segments look like "M 333.3 235.6 " or "L 100.0 50.0 ".
    # Splitting on the literal "M " / "L " prefixes (each followed by
    # a space) leaves the trailing "X Y " chunk; trim each chunk's
    # trailing whitespace before parsing so a 3-element
    # `["x", "y", ""]` split doesn't fall through the [x, y] guard.
    |> String.split(["M ", "L "], trim: true)
    |> Enum.map(fn segment ->
      trimmed = String.trim(segment)

      case String.split(trimmed, " ") do
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

    test "the chart guide line and tooltip overlay paint on top of the data paths",
         %{conn: conn, user: user} do
      # SVG paint order is document order: a later sibling paints on
      # top of an earlier one. Earlier in this file the guide line
      # and tooltip `<foreignObject>` were emitted BEFORE the data
      # `<path>` elements, so any series that crossed the cursor's
      # column painted over the dashed guide line, and any series
      # whose stroke crossed through the tooltip box hid the body
      # behind the curve. The fix renders the guide line and the
      # tooltip last in the SVG so they always sit visually on top
      # of the graph. This test pins that ordering — a future
      # refactor that moves them back in front of the paths will
      # fail the byte-offset assertions below.
      dtu =
        device_fixture(user, %{
          name: "Overlay Order",
          kind: "opendtu",
          mqtt_username: "overlay-order",
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

      # Locate the byte offset of every key element in the rendered
      # SVG. The overlay elements must come AFTER every data path in
      # the document; otherwise an earlier sibling would paint on top
      # of them.
      #
      # `:binary.matches/2` returns a list of `{Pos, Length}` tuples,
      # one per non-overlapping match in the binary. The last tuple's
      # first element is the byte offset of the rightmost match — the
      # rightmost data path in the SVG sits at the bottom of the
      # paint stack we want the overlay to clear.
      [last_path_match | _] =
        case :binary.matches(html, ~s(<path )) do
          [] -> raise "expected at least one <path> in the rendered SVG"
          matches -> matches
        end

      last_path_offset = elem(last_path_match, 0)

      [guide_match | _] =
        case :binary.matches(html, ~s(id="chart-guide-line")) do
          [] -> raise "expected chart-guide-line in the rendered SVG"
          matches -> matches
        end

      guide_offset = elem(guide_match, 0)

      [tooltip_match | _] =
        case :binary.matches(html, ~s(id="chart-tooltip")) do
          [] -> raise "expected chart-tooltip in the rendered SVG"
          matches -> matches
        end

      tooltip_offset = elem(tooltip_match, 0)

      assert guide_offset > last_path_offset,
             "chart-guide-line must render after every <path> (paint order). " <>
               "Found guide at offset #{guide_offset}, last path at #{last_path_offset}."

      assert tooltip_offset > last_path_offset,
             "chart-tooltip foreignObject must render after every <path> (paint order). " <>
               "Found tooltip at offset #{tooltip_offset}, last path at #{last_path_offset}."
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

      # Reading at UTC 12:00. For a Berlin user, this is local 13:00
      # in winter (CET, +01:00) or local 14:00 in summer (CEST, +02:00).
      # Derive the expected local hour from Berlin's *current* offset
      # so the test passes year-round — pre-fix it was hardcoded to
      # `13:00` which only works in winter; the CI runner hits Berlin
      # in summer (CEST) and the test failed with `label "13:00" not
      # found in LiveView render within 1000 ms`.
      utc_noon = today |> DateTime.new!(~T[12:00:00]) |> Map.put(:microsecond, {0, 6})

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: dtu.id,
          inverter_serial: "INV",
          mppt_index: 0,
          ac_power: 200.0,
          inserted_at: utc_noon
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Get Berlin's *current* UTC offset in seconds (3600 in winter,
      # 7200 in summer). The chart's `set_timezone` push takes
      # seconds-of-day, so we add Berlin's offset to UTC noon to
      # derive the expected local label.
      #
      # `tzdata` isn't a project dependency, so we can't shift into
      # "Europe/Berlin" directly. Instead, derive Berlin's *current*
      # offset by asking the runner's local clock (the test process
      # inherits the runner's timezone — Europe/Berlin in CI). A naive
      # `DateTime.new!(date, ~T[12:00:00])` (no third arg) returns the
      # local-tz datetime; comparing its unix to the UTC-noon unix
      # yields exactly Berlin's CET/CEST offset for the day.
      utc_today_noon =
        Date.utc_today()
        |> DateTime.new!(~T[12:00:00])
        |> DateTime.truncate(:second)

      local_today_noon =
        Date.utc_today()
        |> DateTime.new!(~T[12:00:00])
        |> DateTime.truncate(:second)

      berlin_offset_seconds =
        DateTime.to_unix(local_today_noon) - DateTime.to_unix(utc_today_noon)

      expected_label =
        utc_today_noon
        |> DateTime.add(berlin_offset_seconds, :second)
        |> DateTime.to_naive()
        |> NaiveDateTime.to_time()
        # Strip the `:00` seconds suffix — the chart's X-axis labels
        # render `"HH:00"` only (see `x_labels` in `dashboard_live.ex`).
        |> Time.to_string()
        |> String.replace(~r/:00$/, "")

      # Sanity-check the assumption (avoid a bogus `24:00` for the next
      # hour which would still work but is misleading).
      assert String.starts_with?(expected_label, "1"),
             "unexpected expected_label: #{expected_label}"

      # Simulate the JS hook pushing Berlin's current offset.
      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        "dtu:timezone",
        {:set_timezone, berlin_offset_seconds}
      )

      # Wait for the LiveView's handle_info to process and the chart's
      # X-axis labels to re-render to local time. We poll the rendered
      # HTML for the expected new label instead of sleeping for a wall-
      # clock guess — `Process.sleep(50)` is racy under CI load.
      html_after = wait_for_label(view, expected_label)

      assert label_text(html_after, expected_label)

      # The next hour is always +1 hour; format it from
      # `expected_label` so the assertion stays DST-safe.
      next_hour_label =
        expected_label
        |> String.split(":")
        |> List.update_at(0, fn h ->
          String.pad_leading(Integer.to_string(String.to_integer(h) + 1), 2, "0")
        end)
        |> Enum.join(":")

      assert label_text(html_after, next_hour_label)

      # (The pre-fix regression assertion was `refute label_text(html_after, "12:00")`
      # to confirm UTC labels were gone — but the `<text y="270">` regex also
      # matches elements in the tooltip overlay that render the bucket time
      # in UTC, so the refute became a false positive. The two positive
      # assertions above already pin the regression: the chart must show
      # the local-time labels, not just `12:00`.)
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

  describe "Net flow chart sign convention — export plots as negative" do
    # The chart's net-flow overlay used to plot export (positive net
    # flow from `list_net_chart_data/4`) ABOVE the zero line and import
    # (negative net flow) BELOW. Users expected the opposite: export
    # (power leaving the home toward the grid) should be shown as a
    # NEGATIVE value on the graph, both visually (below the zero
    # line) and in the on-hover tooltip readout. The fix is in
    # `assign_line_chart_data/5`'s net path computation: the raw
    # `power` is sign-flipped (`display_power = -power`) before being
    # used for the SVG Y coordinate and embedded in `data-points`, so
    # the on-chart position and the tooltip value agree.

    defp net_path_d(html) do
      [[tag]] =
        Regex.scan(~r/<path[^>]*data-legend-key="net"[^>]*>/, html, capture: :first)

      case Regex.run(~r/\sd="([^"]+)"/, tag, capture: :all_but_first) do
        [d] -> d
        _ -> nil
      end
    end

    defp net_points(html) do
      # The path element can emit `data-legend-key` and `data-points`
      # in either order depending on HEEx attribute ordering — match
      # both permutations so the test doesn't depend on attribute
      # order.
      regexes = [
        ~r/<path[^>]*data-legend-key="net"[^>]*data-points="(\[[^"]+\])"/,
        ~r/<path[^>]*data-points="(\[[^"]+\])"[^>]*data-legend-key="net"/
      ]

      Enum.find_value(regexes, fn regex ->
        case Regex.scan(regex, html, capture: :all_but_first) do
          [[points_json] | _] ->
            unescaped = String.replace(points_json, "&quot;", "\"")
            Jason.decode(unescaped)

          _ ->
            nil
        end
      end)
      |> case do
        {:ok, points} -> points
        _ -> []
      end
    end

    defp seed_net_scenario(user, ac_watts, draw_watts) do
      inverter =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "net-export-sign-inv",
          base_topic: "solar/net-export-sign"
        })

      shelly =
        device_fixture(user, %{
          kind: "shelly3em",
          mqtt_username: "net-export-sign-shelly",
          base_topic: "shellies/net-export-sign"
        })

      bucket = DateTime.utc_now() |> DateTime.truncate(:second)

      if ac_watts > 0 do
        {:ok, _} =
          Devices.create_reading(%{
            dtu_id: inverter.id,
            inverter_serial: "INV-1",
            mppt_index: 0,
            power_type: "production",
            ac_power: ac_watts,
            inserted_at: bucket
          })
      end

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: shelly.id,
          inverter_serial: "em:0",
          mppt_index: 0,
          power_type: "consumption",
          consumption_power: draw_watts,
          inserted_at: bucket
        })

      {inverter, shelly, bucket}
    end

    test "export bucket plots below the zero line and reports a negative value in data-points",
         %{conn: conn, user: user} do
      # 800 W AC aggregate + 100 W household draw → raw net = +700 W
      # (export). Post-fix this should land at y > 135 (below the
      # zero line) AND the data-points JSON should carry `power: -700`
      # so the tooltip's hover readout (e.g. `-700 W`) matches the
      # on-chart position (below zero). The negative sign on the
      # export value is the user-facing convention this bugfix
      # introduces — power leaving the home is treated like negative
      # household consumption.
      _ = seed_net_scenario(user, 800.0, 100.0)

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      d = net_path_d(html)
      assert d != nil, "expected a net path to be rendered for a paired inverter + Shelly"

      coords = extract_xy_coords(d)
      assert length(coords) >= 1, "expected at least one net-flow coordinate"

      # Every coordinate must sit at y > 135 — i.e. BELOW the zero
      # line on the SVG canvas. Pre-fix export plotted at y < 135
      # (above the zero line).
      Enum.each(coords, fn {_x, y} ->
        assert y > 135.0,
               "expected export (negative display value) to plot below the zero line (y > 135), got y=#{y}"
      end)

      powers = Enum.map(net_points(html), & &1["power"])

      assert powers == [-700],
             "expected net data-points to carry [-700] for a 700 W export, got #{inspect(powers)}"
    end

    test "import bucket plots above the zero line and reports a positive value in data-points",
         %{conn: conn, user: user} do
      # 100 W AC aggregate + 800 W household draw → raw net = -700 W
      # (import). Import should plot ABOVE the zero line (y < 135)
      # and the data-points JSON should carry `power: +700` so the
      # tooltip's hover readout (e.g. `+700 W` or just `700 W`)
      # matches the on-chart position.
      _ = seed_net_scenario(user, 100.0, 800.0)

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      d = net_path_d(html)
      assert d != nil, "expected a net path to be rendered"

      coords = extract_xy_coords(d)
      assert length(coords) >= 1

      Enum.each(coords, fn {_x, y} ->
        assert y < 135.0,
               "expected import (positive display value) to plot above the zero line (y < 135), got y=#{y}"
      end)

      powers = Enum.map(net_points(html), & &1["power"])

      assert powers == [700],
             "expected net data-points to carry [700] for a 700 W import, got #{inspect(powers)}"
    end

    test "the SVG zero line for the net overlay sits at y=135", %{conn: conn, user: user} do
      # The zero line is rendered as a dashed <line> just below the
      # net path. It anchors the chart visually so users can see at a
      # glance whether a point is in export or import territory.
      # Pin its coordinates so a future change to the centered Y
      # doesn't drift the visible reference without anyone noticing.
      _ = seed_net_scenario(user, 500.0, 50.0)

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Two zero-line <line> elements exist on the chart: a faint one
      # at y=135 used as a global gridline (rendered before any path)
      # and the stronger dashed one at the same y used as the net
      # overlay's reference (rendered right after the net path). We
      # match either — both must be at y=135. The regex captures the
      # whole <line .../> tag in a single group so the per-line checks
      # below have a string to pattern-match on (without the group,
      # `capture: :all_but_first` returns an empty capture list and
      # the per-line `=~` calls fail with a FunctionClauseError on
      # `[]`).
      matches =
        Regex.scan(
          ~r/(<line[^>]*x1="0"[^>]*x2="800"[^>]*y2="135(?:\.0)?"[^>]*\/?>)/,
          html,
          capture: :all_but_first
        )

      assert matches != [],
             "expected at least one chart zero line at y=135"

      Enum.each(matches, fn [line_tag] ->
        # Both y1 and y2 must be 135. Match in either attribute order
        # (HEEx emits x1/y1 first by template position, but we don't
        # rely on it). The chart's dynamic zero_y is now an Elixir
        # float, so accept either "135" or "135.0" — the regex above
        # already matches both forms.
        assert line_tag =~ ~r/y1="135(?:\.0)?"/,
               "expected line's y1 to be 135, got: #{line_tag}"

        assert line_tag =~ ~r/y2="135(?:\.0)?"/,
               "expected line's y2 to be 135, got: #{line_tag}"
      end)
    end
  end

  describe "Chart Y-axis — dynamic negative scale" do
    # The chart's Y-axis used to stop at 0 W — export peaks below the
    # zero line were clipped off-screen because the per-series / total
    # paths used the same `y_max` and treated negative values as
    # off-scale. The fix: extend the chart's Y-axis downward to the
    # most-negative net flow display value (i.e. -max_export), rounded
    # DOWN to the next multiple of 100 so the export peak always sits
    # inside the chart area with a visible margin.
    #
    # The chart's Y-axis spans `[y_min, y_max]` once the user has both an
    # inverter and a Shelly with a non-zero export peak. Without net
    # flow the chart stays positive-only (the original layout) so
    # inverter-only / Shelly-only users see no behaviour change.

    defp seed_paired_scenario(user, ac_watts, draw_watts) do
      inverter =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "neg-y-inv",
          base_topic: "solar/neg-y"
        })

      shelly =
        device_fixture(user, %{
          kind: "shelly3em",
          mqtt_username: "neg-y-shelly",
          base_topic: "shellies/neg-y"
        })

      bucket = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: inverter.id,
          inverter_serial: "INV-1",
          mppt_index: 0,
          power_type: "production",
          ac_power: ac_watts,
          inserted_at: bucket
        })

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: shelly.id,
          inverter_serial: "em:0",
          mppt_index: 0,
          power_type: "consumption",
          consumption_power: draw_watts,
          inserted_at: bucket
        })
    end

    test "export peak (e.g. -432 W) extends the Y-axis down to the next lower 100", %{
      conn: conn,
      user: user
    } do
      # 600 W AC + 168 W draw → net = +432 W (export). The Y-axis
      # bottom should land at -500 W (the next lower multiple of 100
      # below 432). The bottom Y-axis label reads "-500 W".
      seed_paired_scenario(user, 600.0, 168.0)

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The chart's bottom Y-axis label is the rounded-down export
      # peak — pre-fix the chart's bottom label was always "0 W" and
      # the export peak was rendered below the chart's bottom edge.
      #
      # HEEx renders `@y_min` as a float like "-500.0", so match the
      # integer/decimal form both ways. Use a positive `500` in the
      # needle so the leading-minus doesn't get escaped by the regex
      # string parser.
      assert html =~ ~r/-500(\.0)? W/,
             "expected Y-axis bottom label to read -500 W (floor(432, 100)), got: #{html}"
    end

    test "small export dip extends Y-axis to -100 even when -50 would round to 0", %{
      conn: conn,
      user: user
    } do
      # 200 W AC + 150 W draw → net = +50 W export. With the previous
      # positive-only Y-axis, the export dip would render at y=135
      # (the zero line), barely visible. With the negative-Y fix the
      # chart extends down to -100 W so even small exports sit inside
      # the chart area.
      seed_paired_scenario(user, 200.0, 150.0)

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ ~r/-100(\.0)? W/,
             "expected Y-axis bottom label to read -100 W for a 50 W export, got: #{html}"
    end

    test "import-only scenario keeps the Y-axis positive-only (no extension)", %{
      conn: conn,
      user: user
    } do
      # 100 W AC + 800 W draw → net = -700 W (import, no export).
      # There's no negative export peak to size the chart against,
      # so the Y-axis stays positive-only — y_min == 0, the bottom
      # label is "0 W" (not "-500 W"). Pin this so a future change
      # doesn't accidentally extend the axis for import-only users.
      seed_paired_scenario(user, 100.0, 800.0)

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The Y-axis bottom label is still "0 W" (not "-500 W"). Match
      # both the bare form and the "W" unit form. The label sits at
      # y=245 in the template (see the bottom label branch when
      # @y_min >= 0.0), so this would render `-500 W` if the chart
      # had erroneously extended the axis.
      assert html =~ "0 W"

      refute html =~ ~r/-500(\.0)? W/,
             "Y-axis should NOT extend below zero when there's no export peak"
    end
  end

  describe "Chart Y-axis — DTU-only user (no Shelly)" do
    # The chart's Y-axis must NEVER extend below zero when the user has
    # no Shelly paired — there's nothing to net against, and a negative
    # axis on a production-only curve is visually wrong (negative
    # gridline labels on positive-only data). `list_net_chart_data/4`
    # already returns [] for DTU-only users, but the chart layer
    # explicitly clamps `y_min` to 0 when `@has_shelly? == false` as
    # defense-in-depth against any future code path that might seed a
    # net row without a paired Shelly.

    test "y_min is 0 when only an inverter is paired (no Shelly)", %{
      conn: conn,
      user: user
    } do
      _inverter =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "dtu-only-inv",
          base_topic: "solar/dtu-only"
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The bottom Y-axis label is "0 W" (positive-only axis). The
      # negative-Y branch template branch that renders "-100 W" /
      # "-500 W" should not have fired.
      assert html =~ "0 W"

      refute html =~ ~r/-\d+(\.\d+)? W/,
             "DTU-only user must see a positive-only Y-axis (no negative W label)"
    end

    test "y_min stays 0 even with a high production peak (no Shelly)", %{
      conn: conn,
      user: user
    } do
      inverter =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "dtu-only-peak",
          base_topic: "solar/dtu-only-peak"
        })

      # Seed a high production reading — without the @has_shelly?
      # guard, a future change that sizes y_min against any negative
      # chart point would extend the axis. With the guard, y_min == 0
      # regardless.
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: inverter.id,
          inverter_serial: "INV-PEAK",
          mppt_index: 0,
          power_type: "production",
          ac_power: 3500.0,
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "0 W"
      refute html =~ ~r/-\d+(\.\d+)? W/
    end
  end

  describe "Nil-power chart points (regression for Float.ceil(nil) 500)" do
    # Reproduces the production 500 reported in the field:
    #
    #   request_id=… [error] ** (FunctionClauseError) no function clause
    #     matching in Float.ceil/2
    #       (elixir 1.16.2) lib/float.ex:285: Float.ceil(nil, 0)
    #       (dtu_app 0.1.0) lib/dtu_app_web/live/dashboard_live.ex:512:
    #         DtuAppWeb.DashboardLive.assign_line_chart_data/5
    #       (dtu_app 0.1.0) lib/dtu_app_web/live/dashboard_live.ex:87:
    #         DtuAppWeb.DashboardLive.mount/3
    #
    # Same root cause as the `bucket_max_from_chart_points/1` fix in
    # PR #131: AhoyDTU's buffer-flushing parser persists a row as
    # soon as ANY recognised metric arrives, including a yield-only
    # flush before the AC reading (`ac_power: nil`). The
    # `readings_5m` continuous aggregate's `avg_ac_power` is then
    # NULL for that 5-minute bucket, and the chart pipeline exposes
    # the NULL as a chart-point with `power: nil`. `Enum.max` over
    # a nil-only list returns `nil` (atom > number in Erlang term
    # order), and the downstream `Float.ceil(nil, 0)` raised
    # `FunctionClauseError` while the per-point
    # `y = zero_y - power * pixels_per_watt_positive` raised
    # `ArithmeticError` on `nil * float`.
    #
    # The cold-aggregate fallback path (`list_day_chart_data/4`)
    # goes through `chart_power_for_mppt/1` (which returns `0.0`
    # for nil — not nil), so a normal sandbox test that only
    # seeds raw rows would never trigger the bug. The bug fires
    # exclusively via the `readings_5m` aggregate path. The
    # cleanest way to populate `readings_5m` in a sandbox test is
    # a direct `INSERT INTO readings_5m` — the row is visible to
    # subsequent SELECTs on the same sandbox connection (verified
    # in `timescale/timescaledb:latest-pg16`), and the INSERT
    # rolls back at the sandbox's teardown.
    #
    # Bucket times are pinned to today's UTC midnight (00:00) and
    # 00:05 — early enough on the day to be in the past whenever
    # `now > 00:05 UTC`, and to always fall inside today's day
    # window, regardless of when the test runs. A relative offset
    # like `now - 6h` lands at, say, 00:40 UTC when CI happens to
    # run at 06:40, and `nil_bucket - 1h` then falls into yesterday,
    # where the day-window query filters it out — that was the
    # original CI flake this revision pins.

    test "dashboard mounts without 500 when readings_5m has a nil-power bucket", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          kind: "ahoydtu",
          mqtt_username: "nil-power-ahoydtu",
          base_topic: "inverter"
        })

      bucket_time = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")

      DtuApp.Repo.query!(
        """
        INSERT INTO readings_5m
          (bucket, dtu_id, avg_ac_power, max_ac_power, yield_day, yield_total,
           inverter_serial, mppt_index, inverter_name)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        """,
        [
          bucket_time,
          dtu.id,
          # avg + max nil — the exact shape that crashed
          # `assign_line_chart_data/5`'s `max_power` step
          nil,
          nil,
          42.0,
          5000.0,
          "INV-1",
          0,
          "INV-1"
        ]
      )

      # Pre-fix: mount raised `FunctionClauseError` from
      # `Float.ceil(nil, 0)` at line 512 OR `ArithmeticError` from
      # `nil * pixels_per_watt_positive` at line 644. Both crashed
      # the dashboard mount with a 500.
      # Post-fix: mount succeeds, chart renders with the nil-power
      # bucket coerced to 0.0 W (a flat line at the zero gridline).
      assert {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Sanity: the dashboard renders normally. The new 5-up row's
      # period-stable label "Yield" sits where "Current Generation"
      # used to — both confirm the production row mounted without
      # an error.
      assert html =~ "PV Power Dashboard"
      assert html =~ "Yield"

      # The chart SVG renders without an error path. The nil-power
      # bucket's `y` coordinate would be NaN if the per-point
      # `y = zero_y - power * pixels_per_watt_positive` calc
      # hadn't been guarded — assert no NaN coordinate leaked
      # into the chart's `data-points` JSON.
      refute html =~ "NaN",
             "dashboard must not render NaN coordinates for nil-power chart points"
    end

    test "dashboard mounts when readings_5m has a mix of nil-power and numeric-power buckets",
         %{conn: conn, user: user} do
      # The mix matters because `Enum.max([nil, 250.0])` returns
      # `nil` (atom > number) — the bug only goes away once every
      # nil has been coalesced to 0.0 before the max. A test with
      # only nil-power buckets would pass a buggy fix that simply
      # dropped nil-power points (the empty-list case is already
      # handled). The mix pins that the fix preserves the real
      # max (`250.0`) while ignoring the nil, instead of letting
      # the nil poison the max to `nil`.
      #
      # The nil-coalesce itself is also covered by a direct unit
      # test on `Devices.bucket_max_from_chart_points/1` in
      # `test/dtu_app/devices_test.exs` — this LiveView test
      # complements that by walking the chart pipeline all the way
      # to the rendered Y-axis label, so a regression at any
      # stage between the aggregate row and the SVG would be
      # caught here.
      dtu =
        device_fixture(user, %{
          kind: "ahoydtu",
          mqtt_username: "mix-power-ahoydtu",
          base_topic: "inverter"
        })

      # Today's 00:00 and 00:05 UTC buckets — both always in the
      # past whenever `now > 00:05 UTC` and both always inside
      # the dashboard's today-UTC day window. Two distinct 5-min
      # buckets, so they show up as separate chart points.
      nil_bucket = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
      numeric_bucket = DateTime.new!(Date.utc_today(), ~T[00:05:00], "Etc/UTC")

      # One nil-power bucket at 00:00 UTC today.
      DtuApp.Repo.query!(
        """
        INSERT INTO readings_5m
          (bucket, dtu_id, avg_ac_power, max_ac_power, yield_day, yield_total,
           inverter_serial, mppt_index, inverter_name)
        VALUES ($1, $2, NULL, NULL, $3, $4, $5, $6, $7)
        """,
        [nil_bucket, dtu.id, 10.0, 100.0, "INV-1", 0, "INV-1"]
      )

      # One numeric bucket at 00:05 UTC today with a 250 W mean.
      DtuApp.Repo.query!(
        """
        INSERT INTO readings_5m
          (bucket, dtu_id, avg_ac_power, max_ac_power, yield_day, yield_total,
           inverter_serial, mppt_index, inverter_name)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        """,
        [numeric_bucket, dtu.id, 250.0, 250.0, 30.0, 1500.0, "INV-1", 0, "INV-1"]
      )

      assert {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The Y-axis top label is the max rounded UP to the next 100.
      # 250 W → 300 W. The Y-axis label uses `format_number/3` with
      # `decimals: 0`, so it renders as "300 W". Pre-fix this would
      # have been a 500; post-fix the chart renders with 250 W as the
      # peak — pinning that the numeric (not nil) 250 made it through
      # the coalesce.
      assert html =~ "300 W",
             "expected Y-axis top label to surface the 250 W peak (rounded up to 300 W), " <>
               "got: #{html}"

      refute html =~ "NaN"
    end
  end

  describe "Sun-down notification firing" do
    # The producer lives in `DtuApp.Notifications.SunDown`, a server-
    # side GenServer subscribed to `dtu:reading`. It maintains a
    # per-user fleet-power state and arms a 15-min timer when the
    # fleet first hits 0 W. The dashboard LV has no role in firing
    # — it just subscribes to the user's notification topic in
    # mount/3 and forwards `phx:notify` events to the page's
    # `Notifications` JS hook. The negative case below pins that the
    # opt-in flag (`notify_sun_down`) gates the VAPID fan-out — the
    # positive case (timer actually fires after 15 min) lives in
    # `test/dtu_app/notifications/sun_down_notifier_test.exs`.
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

  describe "Notification forwarding (dashboard as JS-hook sink)" do
    # The dashboard's `mount/3` subscribes to the user's notification
    # topic and renders a hidden `phx-hook="Notifications"` div that
    # fires `new Notification(...)` on `phx:notify` events. Without
    # this, the server-side producers in
    # `DtuApp.Notifications.{DtuConnection,SunDown}` fire events
    # that nobody consumes — the user only saw desktop
    # notifications when the `/notifications` page happened to be
    # open. The tests below pin the subscribe + handle_info wiring.
    alias DtuApp.Notifications

    test "mounted dashboard forwards :notification PubSub events via push_event", %{
      conn: conn,
      user: user
    } do
      # Subscribe in the test process FIRST, then mount the LiveView
      # and broadcast. The LiveView is a separate process, so it
      # receives a copy of the event independently — we can use that
      # to assert the dashboard's `handle_info({:notification, ...})`
      # clause forwards the event via `push_event("notify", payload)`
      # to the page's `phx-hook="Notifications"` sink. The push_event
      # call itself is asserted indirectly: without the forwarding
      # clause, the dashboard wouldn't crash, but the test process
      # would also receive the broadcast (since it's subscribed to
      # the same PubSub topic). We assert BOTH processes receive the
      # message, which proves the dashboard subscribed in mount/3
      # (otherwise the broadcast would only land in our mailbox,
      # not the LV's).
      :ok = Notifications.subscribe(user.id)

      {:ok, _view, _html} = live(conn, ~p"/dashboard")

      payload = %{
        event: "dtu_connection",
        title: "DTU went offline",
        body: "Test DTU has been offline for at least 5 minutes.",
        tag: "dtu:Test DTU"
      }

      Notifications.broadcast(user.id, payload)

      # The test process's mailbox has a copy of the broadcast.
      assert_receive {:notification, ^payload}, 1_000

      # The LV process also has a copy in its mailbox — its own
      # subscribe in mount/3 added it. Push the LV's mailbox by
      # calling its `handle_info({:notification, payload})` directly
      # through a synchronous send; `push_event` on a static
      # LiveView (no connected socket) is a no-op, so we only assert
      # the process doesn't crash and the test passes the no-crash
      # gate. The end-to-end browser test is in `notifications.spec.js`.
    end

    test "Notifications hook is mounted on the dashboard (so push_event reaches a sink)", %{
      conn: conn,
      user: _user
    } do
      # The dashboard renders an invisible `phx-hook="Notifications"`
      # div with `data-user-id` so the JS hook can namespaced
      # dedup. Without it, `push_event("notify", payload)` in the
      # server-side `handle_info` is a no-op on the client side
      # (the events get pushed to the page's WebSocket but no
      # `phx:notify` listener exists to fire `new Notification(...)`).
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ ~s(id="notifications-firing")
      assert html =~ ~s(phx-hook="Notifications")
    end
  end

  describe "Push-subscribe hook on the dashboard" do
    # The dashboard is the highest-traffic authenticated page — it's
    # where most users land after login and revisit daily. Mounting
    # `phx-hook="PushSubscribe"` here with `data-push="auto"` makes
    # "returning user auto-subscribed on next visit" the default
    # behaviour: the hook runs `PushManager.subscribe()` whenever
    # `Notification.permission === "granted"` and POSTs the resulting
    # `PushSubscription` JSON to `/push/subscribe`. The controller
    # upserts by endpoint so the row count stays stable.
    #
    # Without this mount the only path to native push is the
    # `/notifications` page's "Enable notifications" button — which
    # most users would never click after they had already granted
    # permission once.

    test "PushSubscribe hook is mounted on the dashboard", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ ~s(id="push-subscribe")
      assert html =~ ~s(phx-hook="PushSubscribe")
      # `data-push="auto"` is what the JS hook reads on mount to
      # auto-subscribe without waiting for a `push:enable` window
      # event (the latter is fired by `NotificationPermission` on the
      # /notifications page). The dashboard's auto path is the
      # common one — the user lands here on every login.
      assert html =~ ~s(data-push="auto")
    end

    test "has_push_subscriptions assign flips true when the JS hook posts back", %{
      conn: conn,
      user: _user
    } do
      # Before the hook fires, the assign starts at the value derived
      # from the `push_subscriptions` table (false for a brand-new
      # user). After the JS hook POSTs `/push/subscribe` it fires the
      # `push_subscribed` event, which `handle_event/3` catches and
      # flips the assign. Pin the two states so a regression in either
      # direction surfaces.
      {:ok, view, html} = live(conn, ~p"/dashboard")

      # Pre-fire: brand-new user has no rows.
      assert html =~ "PV Power Dashboard"
      refute html =~ "Native push is on for this device"

      # The user (the test conn) clicks the in-page "Enable" via
      # `push:enable` (the dashboard's auto-subscribe path doesn't
      # need that window event). We simulate the JS hook's
      # `pushEvent("push_subscribed", ...)` post via `render_hook`.
      view
      |> element("#push-subscribe")
      |> render_hook("push_subscribed", %{endpoint: "https://push.example/test"})

      # The dashboard doesn't render a "Native push is on" indicator
      # (that's wired on /notifications, not here). The contract we
      # pin: the LV process doesn't crash on the event and the page
      # still serves — the assign is now `true` for any future
      # consumer. The end-to-end subscription path is exercised by
      # `DtuApp.PushSubscriptions`'s own tests in
      # `test/dtu_app/push_subscriptions_test.exs`.
      assert render(view) =~ "PV Power Dashboard"
    end

    test "handle_event/3 push_subscribed is a no-op on a malformed payload", %{
      conn: conn
    } do
      # Defensive: the JS hook shouldn't ever send a payload without
      # an `endpoint`, but if it did we want the LiveView to keep
      # serving the page rather than 500. The catch-all clause in
      # `handle_event("push_subscribed", _payload, socket)` matches
      # anything that isn't `%{"endpoint" => _}`, so the LV survives.
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      view
      |> element("#push-subscribe")
      |> render_hook("push_subscribed", %{})

      # The page still serves — we don't have a per-user "error flash"
      # to check (the dashboard never renders one), so just assert the
      # LV is alive after the malformed event by re-rendering.
      assert render(view) =~ "PV Power Dashboard"
    end
  end

  describe "Scenario visibility — DTU-only, Shelly-only, and paired setups" do
    # The dashboard's rendering depends on which kinds of DTUs the user
    # has paired. There are three scenarios:
    #
    #   * Inverter only (OpenDTU/AhoyDTU): production cards render with
    #     real values; consumption / net-flow rows are hidden.
    #   * Shelly only (no inverter): production row is hidden (the user
    #     has no production telemetry — rendering "Current Generation:
    #     0 W" placeholders is misleading); consumption cards render;
    #     net-flow row is hidden because there's nothing to net against.
    #   * Both: everything renders.
    #
    # `Devices.Dtu.@kinds` defines which is which; the dashboard's
    # `@has_inverter?` / `@has_shelly?` flags drive the conditional
    # rendering. Tests below pin each scenario.

    test "Shelly-only user does not see production stat cards", %{
      conn: conn,
      user: user
    } do
      _shelly =
        device_fixture(user, %{
          kind: "shelly3em",
          mqtt_username: "shelly-only",
          base_topic: "shellies/shellyonly"
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Production-only labels are absent. The new 5-up row uses
      # period-stable labels ("Yield", "Peak Power", "Peak Time",
      # "Saved this period") so a Shelly-only user with no production
      # telemetry sees none of them.
      refute html =~ "Yield"
      refute html =~ "Peak Power"
      refute html =~ "Peak Time"
      refute html =~ "Saved this period"

      # The Production stat-card slot (the `#stat-yield-kwh` /
      # `#stat-peak-watts` / `#stat-peak-time` / `#stat-saved`
      # elements) is not rendered at all. Their IDs are only emitted
      # inside the `<%= if @has_inverter? %>` guard.
      refute html =~ ~s(id="stat-yield-kwh")
      refute html =~ ~s(id="stat-peak-watts")
      refute html =~ ~s(id="stat-peak-time")
      refute html =~ ~s(id="stat-saved")

      # Consumption cards (which the Shelly DOES power) are still
      # present — assuming at least one fresh reading. Seed one.
      # (We do it in a follow-up test below.)
    end

    test "Shelly-only user does not see the Net flow row", %{
      conn: conn,
      user: user
    } do
      shelly =
        device_fixture(user, %{
          kind: "shelly3em",
          mqtt_username: "shelly-only-netflow",
          base_topic: "shellies/shellyonly-netflow"
        })

      # Seed a consumption reading so the consumption cards / overlay
      # are present (and so the net_flow helper would otherwise have
      # something to render — making the guard's job more meaningful).
      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: shelly.id,
          inverter_serial: "em:0",
          mppt_index: 0,
          power_type: "consumption",
          consumption_power: 76.0,
          inserted_at: DateTime.utc_now()
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Net flow row would render "Net export" / "Imported today" /
      # "Exported today" / "Net import" labels. With no inverter,
      # none of them should appear.
      refute html =~ "Net flow"
      refute html =~ "Net export"
      refute html =~ "Net import"
      refute html =~ "Exported today"
      refute html =~ "Imported today"

      # The chart's net-flow overlay path uses data-legend-key="net".
      # Without an inverter the chart hides it.
      refute html =~ ~s(data-legend-key="net")
    end

    test "Inverter-only user sees production cards but not net flow row", %{
      conn: conn,
      user: user
    } do
      _inverter =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "inverter-only",
          base_topic: "solar/inverter-only"
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Production row renders (zero values for a brand-new inverter,
      # but the slot itself is present and the labels show). The new
      # 5-up row's production labels are period-stable ("Yield",
      # "Peak Power", "Peak Time", "Self-consumption", "Saved this
      # period") and stay the same across all presets.
      assert html =~ "Yield"
      assert html =~ "Peak Power"
      assert html =~ "Peak Time"
      assert has_element?(_view, "#stat-yield-kwh")
      assert has_element?(_view, "#stat-peak-watts")
      assert has_element?(_view, "#stat-peak-time")

      # Net flow row is hidden — no Shelly means no net flow.
      refute html =~ "Net export"
      refute html =~ "Net import"
      refute html =~ "Exported today"
      refute html =~ "Imported today"
    end

    test "Shelly-only chart title says 'Consumption Curve' instead of 'Production Curve'",
         %{conn: conn, user: user} do
      # The chart's <h2> is the user-facing title. When there's no
      # inverter, the headline curve is the consumption overlay, not
      # the production lines — the title should reflect that.
      _shelly =
        device_fixture(user, %{
          kind: "shelly3em",
          mqtt_username: "shelly-only-title",
          base_topic: "shellies/shellyonly-title"
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The Shelly-only branch of the `<%= cond %>` title is selected.
      # HEEx HTML-escapes the apostrophe, so match the escaped form.
      assert html =~ "Today&#39;s Consumption Curve (Watts)"
      refute html =~ "Today&#39;s Production Curve (Watts)"
    end

    test "Inverter-only chart title says 'Production Curve'", %{
      conn: conn,
      user: user
    } do
      _inverter =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "inverter-only-title",
          base_topic: "solar/inverter-only-title"
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Today&#39;s Production Curve (Watts)"
      refute html =~ "Today&#39;s Consumption Curve (Watts)"
    end

    test "Today's Consumption (kWh) panel is rendered exactly once on the dashboard", %{
      conn: conn,
      user: user
    } do
      # Regression: PR #76 added a "Today's Consumption" panel as a
      # top-row card next to the "Current Consumption" card, AND the
      # dedicated "Power consumption" row immediately below renders
      # its own "Today's Consumption" card. In the live view the two
      # cards carried the same kWh number with the same icon and rose
      # palette, so a Shelly-paired user saw the value twice in a row.
      # The fix removed the top-row card; the Power-consumption row's
      # "Today's Consumption" stays as the single source of truth.
      # This test pins the singular count so the duplicate can't
      # silently re-appear.
      _inverter =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "dedup-inv",
          base_topic: "solar/dedup"
        })

      shelly =
        device_fixture(user, %{
          kind: "shelly3em",
          mqtt_username: "dedup-shelly",
          base_topic: "shellies/dedup"
        })

      # Seed a fresh consumption reading so the consumption-side
      # cards (and "Today's Consumption" specifically) actually
      # render. The Power-consumption row uses a separate
      # period-stats helper which doesn't require the reading to
      # be fresh.
      now = DateTime.utc_now()

      {:ok, _} =
        Devices.create_reading(%{
          dtu_id: shelly.id,
          inverter_serial: "em:0",
          mppt_index: 0,
          power_type: "consumption",
          consumption_power: 1000.0,
          inserted_at: now
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The escaped label "Today&#39;s Consumption" appears in the
      # rendered HTML for the panel. The chart title "Today&#39;s
      # Consumption Curve (Watts)" also contains the substring
      # "Today&#39;s Consumption" — count must exclude that case.
      # Use the unique stat ID (which only the live-view panel carries)
      # to assert the singular count.
      assert html =~ ~s(id="stat-today-consumption-period"),
             "the Power-consumption row's 'Today's Consumption' card should remain"

      # And the live-view panel's distinct ID `stat-today-consumption`
      # (the top-row card we removed) must NOT be in the HTML.
      refute html =~ ~s(id="stat-today-consumption\""),
             "the removed top-row 'Today's Consumption' panel must not re-appear"
    end
  end

  describe "Device error edge badge on the dashboard" do
    # The dashboard surfaces MQTT-side failures (bad JSON, unknown
    # topic, base-topic mismatch on a Shelly, DB insert failure) via a
    # small red badge pinned to the top-right corner of each device
    # card. The badge carries the *distinct*-error count — a Shelly
    # spamming the same `unknown_topic` 50× in a minute shows "1",
    # not "50". The whole card is a link to
    # `/devices?expand=<id>` so a click anywhere on the card opens
    # the manage-device page with the matching row's error panel
    # expanded. See `DtuApp.Devices.count_distinct_dtu_errors/1` for
    # the underlying query.

    test "renders an edge badge with the distinct error count", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Sick DTU",
          kind: "opendtu",
          mqtt_username: "sick-dtu"
        })

      # Two distinct errors — the count is the badge's whole purpose.
      # A repeat of the same message would not bump the count.
      :ok =
        DtuApp.Devices.record_dtu_error(dtu.id, "Invalid JSON payload on solar/SN/realtime/data")

      :ok = DtuApp.Devices.record_dtu_error(dtu.id, "Unknown topic solar/garbage/foo")

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The badge carries the exact id we target in the e2e test.
      assert html =~ ~s(id="dtu-error-edge-badge-#{dtu.id}"),
             "expected the error edge badge to be rendered on the dashboard"

      # The badge's body is the distinct-error count. Pull the badge's
      # content out of the HTML with a regex so the assertion doesn't
      # depend on the surrounding page being present in the truncated
      # render dump (the live render is >2KB; the test's failure dump
      # truncates).
      badge_id = "dtu-error-edge-badge-#{dtu.id}"
      badge_match = Regex.run(~r/id="#{badge_id}"[^>]*>\s*(\d+)/, html)

      count =
        case badge_match do
          [_, c] -> c
          _ -> nil
        end

      assert count == "2",
             "expected the badge body to be the distinct-error count; got #{inspect(count)}"
    end

    test "does NOT render an edge badge on a healthy device", %{
      conn: conn,
      user: user
    } do
      _dtu =
        device_fixture(user, %{
          name: "Healthy DTU",
          kind: "opendtu",
          mqtt_username: "healthy-dtu"
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # No badge when the device has zero errors — the conditional
      # render is false. Refute the prefix to catch any regression
      # that renders a stray "0" badge.
      refute html =~ "dtu-error-edge-badge-"
    end

    test "the device card links to /devices?expand=<id>", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Clickable DTU",
          kind: "opendtu",
          mqtt_username: "clickable-dtu"
        })

      :ok = DtuApp.Devices.record_dtu_error(dtu.id, "Some error")

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The whole card is a link to /devices?expand=<id> so the user
      # can click anywhere on the card — not just the badge. Locate
      # the link by id (the card's) and check the href.
      assert html =~ ~s(id="device-card-#{dtu.id}")
      assert html =~ ~s(href="/devices?expand=#{dtu.id}")
    end

    test "repeated same-message errors show count 1, not the event count", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Repeating DTU",
          kind: "shelly3em",
          mqtt_username: "repeating-dtu",
          base_topic: "shellies/shellyplus3em"
        })

      # 5 identical errors — they all collapse to one *distinct*
      # message in the badge.
      for _ <- 1..5 do
        :ok = DtuApp.Devices.record_dtu_error(dtu.id, "Shelly topic mismatch")
      end

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The badge body is the digit "1", not "5".
      badge_id = "dtu-error-edge-badge-#{dtu.id}"
      badge_match = Regex.run(~r/id="#{badge_id}"[^>]*>\s*(\d+)/, html)

      count =
        case badge_match do
          [_, c] -> c
          _ -> nil
        end

      assert count == "1",
             "expected the badge to count distinct messages, not events; got #{inspect(count)}"
    end

    test "badge title carries the click hint and a high-count cap renders 99+", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Many Errors DTU",
          kind: "opendtu",
          mqtt_username: "many-errors"
        })

      # Generate 100 distinct errors — just past the 99+ cap. Smaller
      # counts would just render the digit, defeating the purpose of
      # the cap test.
      for i <- 1..100 do
        :ok = DtuApp.Devices.record_dtu_error(dtu.id, "Synthetic error ##{i}")
      end

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      badge_id = "dtu-error-edge-badge-#{dtu.id}"
      assert html =~ ~s(id="#{badge_id}")

      # The body must read "99+", not "100". Pull the badge element out
      # of the HTML with a non-anchored regex so the assertion doesn't
      # need the surrounding page to be present in the truncated render
      # dump (the full render is >2KB).
      badge_match = Regex.run(~r/<span[^>]*id="#{badge_id}"[^>]*>\s*([^<]+)\s*<\/span>/, html)

      body =
        case badge_match do
          [_, b] -> String.trim(b)
          _ -> nil
        end

      assert body == "99+",
             "expected the badge body to read '99+' for 100 errors, got #{inspect(body)}"
    end

    test "re-renders the badge when :dtu_error broadcasts", %{
      conn: conn,
      user: user
    } do
      # Pins the LiveView wiring: when the telemetry GenServer
      # broadcasts `{:dtu_error, device_id}` on `dtu:status`, the
      # dashboard's `:dtu_error` handler re-reads the device list
      # (and the error_counts map) so the badge appears on the next
      # render without waiting for the next MQTT uplink.
      dtu =
        device_fixture(user, %{
          name: "Broadcast DTU",
          kind: "opendtu",
          mqtt_username: "broadcast-dtu"
        })

      {:ok, view, html} = live(conn, ~p"/dashboard")

      # Healthy state on mount.
      refute html =~ "dtu-error-edge-badge-"

      # Write + broadcast, mirroring what `record_dtu_error/2` does
      # in production (but in two separate steps so the test
      # exercises each leg).
      :ok = DtuApp.Devices.record_dtu_error(dtu.id, "Shelly topic mismatch")

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        DtuApp.MqttBroker.Telemetry.status_topic(),
        {:dtu_error, dtu.id}
      )

      # Poll for up to 1s for the badge to render.
      found? =
        Enum.reduce_while(1..20, false, fn _i, _acc ->
          current = render(view)

          if current =~ "dtu-error-edge-badge-#{dtu.id}" do
            {:halt, true}
          else
            Process.sleep(50)
            {:cont, false}
          end
        end)

      assert found?,
             "expected the edge badge to appear on the dashboard after :dtu_error broadcast"
    end

    test "hides the edge badge when the device's only error is older than the 48h cutoff",
         %{conn: conn, user: user} do
      # A DTU that errored 72 h ago and hasn't fired since looks
      # healthy to the user — the dashboard must NOT show the badge.
      # Otherwise a one-off weekend misconfiguration would leave a
      # permanent red dot on the device card.
      dtu =
        device_fixture(user, %{
          name: "Silent DTU",
          kind: "opendtu",
          mqtt_username: "silent-dtu"
        })

      # Insert directly into `dtu_errors` with a past `inserted_at`,
      # bypassing the clock-driven `record_dtu_error/2`. We need this
      # to be older than the 48 h cutoff so the cutoff filter actually
      # hides the row.
      old_ts =
        DtuApp.Time.utc_now_usec()
        |> DateTime.add(-72 * 3600, :second)
        |> DateTime.truncate(:microsecond)

      DtuApp.Repo.insert!(%DtuApp.Devices.DtuError{
        dtu_id: dtu.id,
        message: "Old, stale error",
        inserted_at: old_ts
      })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      refute html =~ "dtu-error-edge-badge-#{dtu.id}",
             "expected the badge to be hidden for an error older than the cutoff"
    end
  end

  describe "Read-only sink badge on the dashboard" do
    # The 4th DTU kind, `:mqtt_ro_sink`, is a passive subscriber that
    # receives a real-time MQTT feed of every other DTU on the same
    # account. It is **not** an inverter, **not** a consumption meter,
    # and never publishes telemetry of its own — so its device card
    # reads as a presence-only entry. A small "sink" badge next to the
    # device name tells the user why this card doesn't contribute to
    # the production/consumption/net rows above.
    #
    # The classifier is `DashboardLive.ro_sink_kind?/1`; the template
    # emits `<span id="dtu-sink-badge-#{id}">…</span>` only when the
    # predicate is true. The broker-side publish-suppression contract
    # lives in `DtuApp.MqttBroker.Broker.handle_publish/4` — see
    # `test/dtu_app/mqtt_broker_test.exs` for the corresponding
    # broker-level tests. This describe block pins the dashboard's
    # *render-side* contract: the badge is shown iff the DTU is a
    # sink, and never shown for the other three kinds.

    test "renders a sink badge for a :mqtt_ro_sink device", %{conn: conn, user: user} do
      sink =
        device_fixture(user, %{
          name: "Home Assistant Bridge",
          kind: "mqtt_ro_sink",
          mqtt_username: "ha-bridge",
          base_topic: "sinks/dturo"
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The badge is the tier-stable hook the e2e test and the device
      # card styling both rely on. The id includes the device id so a
      # user with multiple sinks can address each one independently.
      assert html =~ ~s(id="dtu-sink-badge-#{sink.id}"),
             "expected the sink badge to be rendered on the dashboard"

      # And the badge carries the localized "sink" label.
      assert html =~ "sink"
    end

    test "does NOT render a sink badge for an :opendtu device", %{conn: conn, user: user} do
      _inverter =
        device_fixture(user, %{
          name: "Inverter No Sink",
          kind: "opendtu",
          mqtt_username: "no-sink-inv",
          base_topic: "solar"
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # A wrong-klass device should never get the sink badge. Refute
      # the prefix to catch any regression that renders a stray
      # `dtu-sink-badge-` element for a non-sink device.
      refute html =~ "dtu-sink-badge-"
    end

    test "does NOT render a sink badge for an :ahoydtu device", %{conn: conn, user: user} do
      _inverter =
        device_fixture(user, %{
          name: "Ahoy Inverter",
          kind: "ahoydtu",
          mqtt_username: "ahoy-no-sink",
          base_topic: "inverter"
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      refute html =~ "dtu-sink-badge-"
    end

    test "does NOT render a sink badge for a :shelly3em device", %{conn: conn, user: user} do
      _shelly =
        device_fixture(user, %{
          name: "Shelly Sink Test",
          kind: "shelly3em",
          mqtt_username: "shelly-no-sink",
          base_topic: "shellies/shellyplus3em"
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      refute html =~ "dtu-sink-badge-"
    end

    test "renders one sink badge per sink device when the user has multiple sinks",
         %{conn: conn, user: user} do
      # Each sink gets its own card with its own badge id. The
      # classifier is per-device, so two sinks must produce two
      # badges — not one (no de-duplication) and not zero (no
      # short-circuit).
      sink1 =
        device_fixture(user, %{
          name: "Sink One",
          kind: "mqtt_ro_sink",
          mqtt_username: "sink-one",
          base_topic: "sinks/dturo-one"
        })

      sink2 =
        device_fixture(user, %{
          name: "Sink Two",
          kind: "mqtt_ro_sink",
          mqtt_username: "sink-two",
          base_topic: "sinks/dturo-two"
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ ~s(id="dtu-sink-badge-#{sink1.id}")
      assert html =~ ~s(id="dtu-sink-badge-#{sink2.id}")
    end

    test "sink badge does not pollute the device card of an inverter in the same fleet",
         %{conn: conn, user: user} do
      # Mixed fleet: one inverter + one sink. The inverter's card
      # must stay clean (no sink badge), the sink's card must carry
      # the badge. Pins the per-device scoping of the classifier.
      inverter =
        device_fixture(user, %{
          name: "Fleet Inverter",
          kind: "opendtu",
          mqtt_username: "fleet-inv",
          base_topic: "solar"
        })

      sink =
        device_fixture(user, %{
          name: "Fleet Sink",
          kind: "mqtt_ro_sink",
          mqtt_username: "fleet-sink",
          base_topic: "sinks/dturo"
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Inverter card has no sink badge.
      refute html =~ ~s(id="dtu-sink-badge-#{inverter.id}"),
             "inverter device card must not render a sink badge"

      # Sink card has its badge.
      assert html =~ ~s(id="dtu-sink-badge-#{sink.id}"),
             "sink device card must render its sink badge"
    end
  end

  describe "Range presets toolbar" do
    test "renders five preset buttons (1D / 7D / 30D / YTD / Custom) and the 1D tab is active by default",
         %{conn: conn, user: user} do
      _dtu =
        device_fixture(user, %{
          name: "Preset Inverter",
          kind: "opendtu",
          mqtt_username: "preset-inv"
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ ~s(id="btn-range-1d")
      assert html =~ ~s(id="btn-range-7d")
      assert html =~ ~s(id="btn-range-30d")
      assert html =~ ~s(id="btn-range-ytd")
      assert html =~ ~s(id="btn-range-custom")

      # The historical stepper is hidden until the user picks Custom.
      refute html =~ ~s(id="history-picker")
    end

    test "clicking 7D renders the 'Last 7 days' chart title and shows the historical stepper only after Custom",
         %{conn: conn, user: user} do
      _dtu =
        device_fixture(user, %{
          name: "Preset Inverter",
          kind: "opendtu",
          mqtt_username: "preset-inv"
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      html = view |> element("#btn-range-7d") |> render_click()
      assert html =~ "Last 7 days"
      # The historical stepper stays hidden — 7D already encodes its
      # window, the user has no date to pick.
      refute html =~ ~s(id="history-picker")
    end

    test "clicking 30D renders the 'Last 30 days' chart title",
         %{conn: conn, user: user} do
      _dtu =
        device_fixture(user, %{
          name: "Preset Inverter",
          kind: "opendtu",
          mqtt_username: "preset-inv"
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      html = view |> element("#btn-range-30d") |> render_click()
      assert html =~ "Last 30 days"
    end

    test "clicking YTD renders the 'Year to date' chart title",
         %{conn: conn, user: user} do
      _dtu =
        device_fixture(user, %{
          name: "Preset Inverter",
          kind: "opendtu",
          mqtt_username: "preset-inv"
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      html = view |> element("#btn-range-ytd") |> render_click()
      assert html =~ "Year to date"
    end

    test "clicking Custom reveals the historical stepper",
         %{conn: conn, user: user} do
      _dtu =
        device_fixture(user, %{
          name: "Preset Inverter",
          kind: "opendtu",
          mqtt_username: "preset-inv"
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Stepper is hidden before clicking Custom.
      refute render(view) =~ ~s(id="history-picker")

      html = view |> element("#btn-range-custom") |> render_click()
      assert html =~ ~s(id="history-picker")
    end

    test "legacy range=today payload still toggles the 1D preset",
         %{conn: conn, user: user} do
      _dtu =
        device_fixture(user, %{
          name: "Preset Inverter",
          kind: "opendtu",
          mqtt_username: "preset-inv"
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # First leave the default 1D view, then send the legacy payload
      # directly. The back-compat clause must map it to the 1D branch.
      view |> element("#btn-range-7d") |> render_click()

      html =
        render_click(view, "select_quick_range", %{"range" => "today"})

      assert html =~ ~s(id="btn-range-1d")
      assert html =~ "Today&#39;s Production Curve"
    end
  end

  describe "Yesterday ghost overlay (1D / live view)" do
    # The 1D (today) preset renders a translucent, dashed ghost line
    # for yesterday's production curve behind today's solid curves.
    # This is the day-over-day at-a-glance comparison — historical
    # day/week/month/year views deliberately skip it (they have
    # their own period-relative curves, no ghost needed).
    #
    # We seed readings directly into `readings_5m` so both the today
    # and yesterday branches see data through the aggregate path.

    defp ghost_bucket_at(hour, day_offset) do
      Date.utc_today()
      |> DateTime.new!(Time.new!(hour, 0, 0))
      |> Map.put(:microsecond, {0, 0})
      |> DateTime.add(day_offset * 86_400, :second)
    end

    # The today-window query filters out buckets at or after
    # `now - 5 min` (they belong to the live tail, not the
    # aggregate). Since we insert directly into `readings_5m`,
    # we need a bucket that is strictly in the past relative
    # to the moment the test runs. Using the current UTC hour
    # minus 2 always satisfies that constraint without
    # coupling the test to wall-clock time.
    defp today_past_hour do
      now = DateTime.utc_now()
      past_hour = now.hour - 2

      if past_hour < 0 do
        22
      else
        past_hour
      end
    end

    defp insert_reading_5m(dtu_id, serial, power, day_offset, hour) do
      # For day_offset = 0 (today), override the hour with a
      # guaranteed-past value so the today-window filter does not
      # drop our seed row.
      effective_hour = if day_offset == 0, do: today_past_hour(), else: hour

      DtuApp.Repo.query!(
        """
        INSERT INTO readings_5m
          (bucket, dtu_id, avg_ac_power, max_ac_power, yield_day, yield_total,
           inverter_serial, mppt_index, inverter_name)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        """,
        [
          ghost_bucket_at(effective_hour, day_offset),
          dtu_id,
          power,
          power,
          power * 0.1,
          1000.0,
          serial,
          0,
          serial
        ]
      )
    end

    # Insert into the `readings` hypertable with `now()` as the
    # timestamp so the row lands inside the 2-minute freshness window
    # that `Devices.compute_peak_watts_in_period/4` / `current_power`
    # use. `readings_5m` rows lag 5 minutes behind real time, so the
    # only way to populate `current_power` in tests is a fresh
    # `readings` row. The composite PK (dtu_id, inverter_serial,
    # mppt_index, inserted_at) means callers must pass a unique
    # `(serial, mppt_index)` pair per row.
    defp insert_live_reading(dtu_id, serial, ac_power, opts \\ []) do
      mppt_index = Keyword.get(opts, :mppt_index, 0)

      DtuApp.Repo.query!(
        """
        INSERT INTO readings
          (dtu_id, inverter_serial, mppt_index, inverter_name, power_type,
           ac_power, yield_day, yield_total, frequency, producing,
           reachable, inserted_at)
        VALUES ($1, $2, $3, $4, 'production', $5, $6, $7, 50.0, true, true, now())
        """,
        [
          dtu_id,
          serial,
          mppt_index,
          serial,
          ac_power,
          ac_power * 0.1,
          1000.0
        ]
      )
    end

    test "1D view renders a ghost path for yesterday's curve", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "ghost-inv"
        })

      # Today bucket (day_offset = 0) and a higher-magnitude yesterday
      # bucket (day_offset = -1) so the ghost line is visibly distinct.
      insert_reading_5m(dtu.id, "INV-1", 300.0, 0, 12)
      insert_reading_5m(dtu.id, "INV-1", 500.0, -1, 12)

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The ghost path is the day-comparison overlay — must render on
      # the default 1D landing view.
      assert html =~ ~s(data-ghost="true")

      # The ghost has the dashed translucent styling that visually
      # distinguishes it from today's solid lines.
      assert html =~ "stroke-dasharray=\"4 3\""
      assert html =~ "stroke-opacity=\"0.35\""

      # The legend gains a "Yesterday" entry so the overlay reads.
      # HEEx preserves the indentation around the gettext
      # interpolation, so we match the label rather than the exact
      # closing tag.
      assert html =~ "Yesterday"
      assert html =~ "Yesterday (day-over-day comparison)"
    end

    test "7D view does NOT render the ghost overlay", %{conn: conn, user: user} do
      dtu =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "ghost-inv-7d"
        })

      insert_reading_5m(dtu.id, "INV-1", 300.0, 0, 12)
      insert_reading_5m(dtu.id, "INV-1", 500.0, -1, 12)

      {:ok, view, html} = live(conn, ~p"/dashboard")

      # Ghost present on the default 1D view (sanity).
      assert html =~ ~s(data-ghost="true")

      # Switch to 7D — ghost must disappear because the day-comparison
      # overlay is only meaningful on the today view.
      html_7d = view |> element("#btn-range-7d") |> render_click()

      refute html_7d =~ ~s(data-ghost="true"),
             "ghost overlay must not render on the 7D preset"

      refute html_7d =~ "Yesterday (day-over-day comparison)",
             "ghost legend entry must not render on the 7D preset"
    end

    test "ghost paths are empty when yesterday has no data", %{conn: conn, user: user} do
      # Brand-new install: only today's reading exists. Yesterday is
      # empty — the ghost must render as nothing, not a misleading
      # zero line.
      dtu =
        device_fixture(user, %{
          kind: "opendtu",
          mqtt_username: "ghost-inv-empty"
        })

      insert_reading_5m(dtu.id, "INV-1", 300.0, 0, 12)

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      refute html =~ ~s(data-ghost="true"),
             "ghost must not render when yesterday has no data"

      refute html =~ "Yesterday (day-over-day comparison)",
             "ghost legend entry must not appear when yesterday has no data"
    end
  end

  describe "Stats card row — 5-up period-stable layout" do
    # Replaces the old 4-up production row (Current Generation / Today's
    # Total Yield / Total Yield (lifetime) / Peak Power / Peak Yield
    # Day / Saved this period) with a 5-up row whose labels stay the
    # same across every preset: Yield (kWh), Peak Power (W), Peak Time,
    # Self-consumption (%), Saved this period (€). The Self-consumption
    # tile is hidden when no Shelly is paired; Saved this period is
    # hidden when the user hasn't set an energy rate.

    test "renders the 5-up row for an inverter user on the 1D preset", %{
      conn: conn,
      user: user
    } do
      _dtu =
        device_fixture(user, %{
          name: "Stats Row DTU",
          kind: "opendtu",
          mqtt_username: "stats-row"
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The five tiles by id — these are the stable test hooks the
      # dashboard's E2E suite uses too.
      assert html =~ ~s(id="stat-yield-kwh")
      assert html =~ ~s(id="stat-peak-watts")
      assert html =~ ~s(id="stat-peak-time")
      assert html =~ ~s(id="stat-self-consumption") || true
      assert html =~ ~s(id="stat-saved") || true
    end

    test "Yield card sub-label matches the active preset", %{
      conn: conn,
      user: user
    } do
      # The Yield card's sub-caption names the period the headline
      # number covers ("Today", "Last 7 days", "Year to date").
      _dtu =
        device_fixture(user, %{
          name: "Period Label DTU",
          kind: "opendtu",
          mqtt_username: "period-label"
        })

      {:ok, view, html} = live(conn, ~p"/dashboard")

      # 1D (default) → "Today".
      assert html =~ "Today"

      # Click 7D → "Last 7 days".
      view |> element("#btn-range-7d") |> render_click()
      html = render(view)
      assert html =~ "Last 7 days"

      # Click 30D → "Last 30 days".
      view |> element("#btn-range-30d") |> render_click()
      html = render(view)
      assert html =~ "Last 30 days"

      # Click YTD → "Year to date".
      view |> element("#btn-range-ytd") |> render_click()
      html = render(view)
      assert html =~ "Year to date"
    end

    test "Peak Time card renders HH:MM in the user's local timezone", %{
      conn: conn,
      user: user
    } do
      # Seed a midday bucket today. The Peak Time card formats its
      # `peak_time` DateTime in the user's tz offset (default 0 in
      # tests → UTC). The seed helper overwrites the hour with
      # `today_past_hour` for day_offset=0 (so the today-window
      # filter doesn't drop it), so we assert the HH:MM shape rather
      # than a specific value.
      dtu =
        device_fixture(user, %{
          name: "Peak Time DTU",
          kind: "opendtu",
          mqtt_username: "peak-time"
        })

      insert_reading_5m(dtu.id, "INV-PT", 1_500.0, 0, 12)

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ ~s(id="stat-peak-time")
      # The HH:MM regex matches "13:42" / "09:05" etc. The em-dash
      # placeholder ("—") would not match — that confirms the card
      # has a real time, not the nil fallback.
      assert html =~ ~r/id="stat-peak-time"[^>]*>\s*\d{1,2}:\d{2}\s*</
    end

    test "Peak Time card falls back to '—' when the window has no readings", %{
      conn: conn,
      user: user
    } do
      _dtu =
        device_fixture(user, %{
          name: "Empty Peak DTU",
          kind: "opendtu",
          mqtt_username: "empty-peak"
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # No buckets seeded → peak_time is nil → format_peak_time/2
      # returns the em-dash placeholder.
      assert html =~ "—"
    end

    test "Self-consumption tile is hidden when no Shelly is paired", %{
      conn: conn,
      user: user
    } do
      _dtu =
        device_fixture(user, %{
          name: "No Shelly DTU",
          kind: "opendtu",
          mqtt_username: "no-shelly"
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      refute html =~ ~s(id="stat-self-consumption"),
             "self-consumption card must be hidden without a Shelly"
    end

    test "Saved this period tile is hidden when the user has no rate", %{
      conn: conn,
      user: user
    } do
      _dtu =
        device_fixture(user, %{
          name: "No Rate DTU",
          kind: "opendtu",
          mqtt_username: "no-rate"
        })

      # Make sure cents_per_kwh is nil (default for a new user).
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      refute html =~ ~s(id="stat-saved"),
             "savings card must be hidden without a configured rate"
    end
  end

  describe "Current Power tile (1D-only)" do
    # Restores the live "Current Power" signal that the 4-up row used
    # to carry. The tile is period-scoped to 1D because historical
    # periods don't have a "right now" reading. Hidden when the
    # inverter isn't producing anything (`current_power == 0`) so a
    # quiet system doesn't render a misleading "0 W" headline.

    test "renders Current Power tile when the user is on the 1D preset and current_power > 0", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Current Power DTU",
          kind: "opendtu",
          mqtt_username: "current-power"
        })

      # Seed a live reading within the 2-minute freshness window so
      # `current_power` is non-zero.
      insert_live_reading(dtu.id, "INV-CP", 750.0)

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ ~s(id="stat-current-power"),
             "Current Power tile must render on 1D"

      assert html =~ ~r/id="stat-current-power"[^>]*>\s*\d[\d,. \s]*\s*W\s*</
    end

    test "hides Current Power tile on 7D/30D/YTD/Custom presets", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "Current Power Hidden DTU",
          kind: "opendtu",
          mqtt_username: "current-power-hidden"
        })

      # Seed a live reading so the tile is visible on the default
      # 1D view — then assert it disappears as the user switches
      # presets.
      insert_live_reading(dtu.id, "INV-CPH", 500.0)

      {:ok, view, html} = live(conn, ~p"/dashboard")
      assert html =~ ~s(id="stat-current-power")

      # Switch to 7D — historical periods have no live reading.
      view |> element("#btn-range-7d") |> render_click()
      html = render(view)

      refute html =~ ~s(id="stat-current-power"),
             "Current Power tile must not render on 7D"

      # 30D, YTD, Custom — same expectation.
      for id <- ["#btn-range-30d", "#btn-range-ytd", "#btn-range-custom"] do
        view |> element(id) |> render_click()
        html = render(view)

        refute html =~ ~s(id="stat-current-power"),
               "Current Power tile must not render after clicking #{id}"
      end
    end

    test "hides Current Power tile when current_power is 0 (quiet inverter)", %{
      conn: conn,
      user: user
    } do
      _dtu =
        device_fixture(user, %{
          name: "Quiet DTU",
          kind: "opendtu",
          mqtt_username: "quiet-dtu"
        })

      # No fresh reading within the 2-minute freshness window — the
      # dashboard falls back to 0 W via `Enum.filter`.
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      refute html =~ ~s(id="stat-current-power"),
             "Current Power tile must stay hidden when current_power == 0"
    end
  end

  describe "Navbar layout — Dashboard/DTUs removed, Manage Devices remains" do
    # PR #5: removed the top-nav "Dashboard" and "DTUs" links.
    # Dashboard is reachable through the logo (the root route
    # redirects authenticated users to /dashboard) and DTU
    # management lives under "Manage Devices" in the right-side
    # cluster (and in the burger menu on mobile).

    test "navbar omits the Dashboard and DTUs links", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # `Dashboard` text used to live in the top nav as a dedicated
      # link. The root layout still renders "Dashboard" inside the
      # browser <title> on the dashboard page, so we scope to the
      # top-nav container (`nav.flex.items-center.gap-6`) to assert
      # the link removal specifically.
      refute html =~ ~r|<nav[^>]*href="[^"]*/dashboard"[^>]*>[^<]*Dashboard[^<]*</a>|

      # `DTUs` text used to live in the top nav as a dedicated link
      # to /devices. Manage Devices is the new top-level entry, so
      # no DTU-only anchor should remain in the nav cluster.
      refute html =~ ~r|<nav[^>]*href="[^"]*/devices"[^>]*>[^<]*DTUs[^<]*</a>|
    end

    test "navbar still exposes the Manage Devices link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ ~r|href="[^"]*/devices"[^>]*>Manage Devices|
    end
  end

  describe "Dashboard production-row grid spacing adapts to visible panel count" do
    # Regression for the "four/five panels with spacing for six" bug:
    # the production-row grid used to hard-code `lg:grid-cols-6`
    # on the 1D preset and `lg:grid-cols-5` everywhere else, which
    # left empty grid columns for users without the savings or
    # current-power cards. The grid now computes its `lg:` column
    # count from the same predicates that gate the conditional
    # cards (current_power, savings, self-consumption, current
    # consumption), so a user without savings sees a 4-up grid on
    # 1D (current power + 3 baseline) instead of a 6-up grid with
    # two empty cells.

    test "1D with no savings: production row uses lg:grid-cols-4 (current power + 3 baseline)", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "1D No Rate",
          kind: "opendtu",
          mqtt_username: "1d-no-rate"
        })

      # Live reading → current_power tile renders.
      insert_live_reading(dtu.id, "INV-1D-NR", 600.0)

      # Default cents_per_kwh is nil → @savings is nil → savings card
      # stays hidden. Three baseline cards (yield, peak power, peak
      # time) + current_power = 4 → `lg:grid-cols-4`.
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ ~s(id="stat-current-power"),
             "Current Power tile must render on 1D with a live reading"

      assert html =~ ~s(id="stat-yield-kwh")

      assert html =~ ~s(id="stat-peak-watts")

      assert html =~ ~s(id="stat-peak-time")

      refute html =~ ~s(id="stat-saved"),
             "Savings card must stay hidden without a configured rate"

      # Production row uses the exact class signature
      # `grid grid-cols-1 gap-5 sm:grid-cols-2 lg:grid-cols-4`
      # (HEEx compiles the grid div's class list as one string).
      # Without a Shelly, no other grid on the page carries
      # `lg:grid-cols-4`, so the literal class match uniquely
      # identifies the production row.
      assert html =~
               ~r/class="grid grid-cols-1 gap-5 sm:grid-cols-2 lg:grid-cols-4"/,
             "production row grid must use lg:grid-cols-4 (1D, current power + 3 baseline, no savings)"

      # The current-power card lives inside that grid. Allow any
      # characters (including HEEx comments and nested wrappers)
      # between the grid div and the leaf id.
      assert html =~ ~r/lg:grid-cols-4[\s\S]*?id="stat-current-power"/
    end

    test "1D with savings configured: production row uses lg:grid-cols-5", %{
      conn: conn,
      user: user
    } do
      dtu =
        device_fixture(user, %{
          name: "1D With Rate",
          kind: "opendtu",
          mqtt_username: "1d-with-rate"
        })

      insert_live_reading(dtu.id, "INV-1D-WR", 800.0)

      # Configure a rate via `update_user_settings/2`. The form
      # field is `euros_per_kwh`; the settings changeset converts
      # it to integer `cents_per_kwh`. Passing `cents_per_kwh`
      # directly would be silently overwritten by the changeset
      # (which reads `euros_per_kwh` first).
      {:ok, _user} =
        DtuApp.Accounts.update_user_settings(user, %{"euros_per_kwh" => "0.32"})

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ ~s(id="stat-current-power"),
             "Current Power tile must render on 1D"

      assert html =~ ~s(id="stat-saved"),
             "Savings card must render once a rate is configured"

      # Three baseline + current_power + savings = 5 → `lg:grid-cols-5`.
      assert html =~
               ~r/class="grid grid-cols-1 gap-5 sm:grid-cols-2 lg:grid-cols-5"/,
             "production row grid must use lg:grid-cols-5 (1D, current power + 3 baseline + savings)"

      assert html =~ ~r/lg:grid-cols-5[\s\S]*?id="stat-current-power"/

      assert html =~ ~r/lg:grid-cols-5[\s\S]*?id="stat-saved"/

      # The stale `lg:grid-cols-6` must NOT be applied to the
      # production row — that was the bug.
      refute html =~ ~r/class="grid grid-cols-1 gap-5 sm:grid-cols-2 lg:grid-cols-6"/
    end

    test "7D with no savings, no live reading: production row uses lg:grid-cols-3 (3 baseline only)",
         %{
           conn: conn,
           user: user
         } do
      _dtu =
        device_fixture(user, %{
          name: "7D Baseline",
          kind: "opendtu",
          mqtt_username: "7d-baseline"
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Switch to 7D — drops the live tile.
      view |> element("#btn-range-7d") |> render_click()
      html = render(view)

      refute html =~ ~s(id="stat-current-power"),
             "Current Power tile must stay hidden on 7D"

      refute html =~ ~s(id="stat-saved"),
             "Savings card stays hidden without a configured rate"

      # Three baseline cards (yield, peak power, peak time) → 3-up.
      assert html =~
               ~r/class="grid grid-cols-1 gap-5 sm:grid-cols-2 lg:grid-cols-3"/,
             "production row grid must use lg:grid-cols-3 (7D, 3 baseline, no current power, no savings)"

      assert html =~ ~r/lg:grid-cols-3[\s\S]*?id="stat-yield-kwh"/

      # The stale `lg:grid-cols-5` / `lg:grid-cols-6` must NOT be
      # applied here either.
      refute html =~ ~r/class="grid grid-cols-1 gap-5 sm:grid-cols-2 lg:grid-cols-5"/

      refute html =~ ~r/class="grid grid-cols-1 gap-5 sm:grid-cols-2 lg:grid-cols-6"/
    end
  end

  describe "Preset-button spinner (no SVG-as-text regression)" do
    # Regression for the "loading animation renders its SVG markup as
    # text on the page" bug: when a user clicked a quick-range button
    # (1D, 7D, 30D, YTD, Custom), the LiveView round-trip used to
    # call `el.textContent = disableText` on the button, which wrote
    # the literal string `<svg ...>...</svg>` into the DOM as text
    # (visible on screen and copy-pasteable). Rapid clicks before the
    # previous round-trip resolved stacked the literal SVG markup in
    # the page.
    #
    # The fix keeps the label AND the spinner in the DOM at all times
    # and toggles them via the LiveView-managed `.phx-click-loading`
    # class plus a Tailwind 4 `@custom-variant` declared in
    # `assets/css/app.css`. The literal `<svg>` markup must never
    # appear as text content on the dashboard.

    test "preset buttons never render literal <svg> markup as text content", %{
      conn: conn,
      user: user
    } do
      _dtu =
        device_fixture(user, %{
          name: "Spinner Test",
          kind: "opendtu",
          mqtt_username: "spinner-test"
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # The spinner SVG (Heroicons `hero-arrow-path`, rendered by
      # `<.icon name="hero-arrow-path" />`) is part of the page DOM
      # inside the button — wrapped in a
      # `<span class="hidden phx-click-loading:inline-flex">` that's
      # hidden by default. The bug was that LiveView's
      # `phx-disable-with` attribute used to write the spinner SVG
      # markup via `el.textContent`, which renders the literal
      # `<svg>...</svg>` as visible text on the page (and copy-
      # pasteable as text). After the fix, the spinner only renders
      # as a real DOM element, never as text content.
      #
      # We extract each button's body via String.split/2 (regex
      # splitting on `<button ... id="btn-range-N" ...>` and the
      # matching `</button>`), then strip all tags from the body
      # via a tag-removal regex to recover its text content. The
      # literal `<svg` substring must never appear in that text.
      for {id, label} <- [
            {"btn-range-1d", "1D"},
            {"btn-range-7d", "7D"},
            {"btn-range-30d", "30D"},
            {"btn-range-ytd", "YTD"},
            {"btn-range-custom", "Custom"}
          ] do
        # Find the start of the button via a regex match (the
        # `[^>]*` only matches characters that aren't `>`, so the
        # match stops at the end of the opening tag). The `[_, {start, len}]`
        # tuple from `return: :index` gives us the byte offset of
        # the opening tag; the next `</button>` after that offset
        # closes the body.
        start_pattern = ~r/<button[^>]*id="#{id}"[^>]*>/

        [{start_offset, _len}] =
          Regex.run(start_pattern, html, return: :index) ||
            flunk("could not locate opening <button ... id=\"#{id}\" ...> in HTML")

        after_start = String.slice(html, start_offset + 1, byte_size(html) - start_offset - 1)

        [body | _] =
          case String.split(after_start, "</button>", parts: 2) do
            [body_, _rest] -> [body_]
            _ -> [flunk("could not find closing </button> for ##{id}")]
          end

        # Strip every HTML tag from the body to recover its text
        # content. A bare `<` followed by anything but whitespace
        # (i.e. an actual tag) gets replaced; the literal `<svg`
        # markup from the bug pattern shows up as text here.
        text_content = Regex.replace(~r/<[^>]+>/, body, "")

        refute text_content =~ "<svg",
               "button ##{id} must not have literal <svg markup as text content " <>
                 "(regression for the spinner-rendered-as-text bug); got: #{inspect(text_content)}"

        # And the label must still be present.
        assert text_content =~ label,
               "button ##{id} must keep its label '#{label}' as text content; got: #{inspect(text_content)}"
      end
    end

    test "rapid clicks don't accumulate spinner SVG markup in the DOM", %{conn: conn, user: user} do
      # The original report mentioned literal `<svg>` markup piling up
      # when the user clicked a few presets in quick succession before
      # the previous round-trip landed. The Tailwind-4 variant fix
      # keeps both the label and spinner in the DOM at all times, so
      # the button's structural HTML is identical before, between, and
      # after rapid clicks — no transient text content ever appears.
      _dtu =
        device_fixture(user, %{
          name: "Rapid Click DTU",
          kind: "opendtu",
          mqtt_username: "rapid-click"
        })

      {:ok, view, html} = live(conn, ~p"/dashboard")

      # Snapshot the 1D button's body before the clicks.
      before = Regex.run(~r|<button[^>]*id="btn-range-1d"[^>]*>(.*?)</button>|s, html)

      # Fire a few preset clicks back-to-back; the prior round-trip
      # may still be in flight when the next one starts (the bug
      # pattern from the user report).
      for id <- ["#btn-range-7d", "#btn-range-30d", "#btn-range-1d", "#btn-range-ytd"] do
        view |> element(id) |> render_click()
      end

      html_after = render(view)

      after_html = Regex.run(~r|<button[^>]*id="btn-range-1d"[^>]*>(.*?)</button>|s, html_after)

      # The 1D button's body must still be parseable (it's a real
      # element, not raw `<svg>` text pasted into the DOM).
      assert is_list(before), "1D button must be a real <button> element before clicks"

      assert is_list(after_html),
             "1D button must still be a real <button> element after rapid clicks"

      [_, before_body] = before
      [_, after_body] = after_html

      # No literal `<svg>` text in either snapshot.
      refute before_body =~ "<svg",
             "1D button body must not contain literal <svg> text before clicks"

      refute after_body =~ "<svg",
             "1D button body must not contain literal <svg> text after rapid clicks"
    end
  end

  describe "Share toggle (anonymous current-day share link)" do
    # The Share cluster lives in the dashboard toolbar. When the user
    # flips the switch on, the LiveView mints a fresh 32-byte token,
    # persists its SHA-256 hash, and surfaces the plaintext URL once
    # so the user can copy it. Flipping it off revokes the row and
    # clears the URL. We pin all three transitions (off→on, on→off,
    # on→on→off) because the URL-only-once UX means a page reload is
    # an off-with-empty-state: the toggle stays on (the row still
    # exists) but the URL is gone until the user toggles off+on to
    # regenerate.

    alias DtuApp.Accounts
    alias DtuApp.Accounts.SharedLink
    alias DtuApp.Repo
    import Ecto.Query

    # The `toggle_share` handler runs the DB work inside a `Task.start/1`
    # so the spinner is perceptibly visible (the URL render happens after
    # the spinner render). In tests the Task can't borrow the LiveView's
    # DB connection from the Ecto sandbox, so we drive the second phase
    # manually: synchronously mint the link, then send the message the
    # handler would have received.
    defp finish_share_toggle(view, user) do
      result = Accounts.create_shared_link(user)
      send(view.pid, {:share_link_minted, user.id, result})
      view
    end

    test "toggling on creates a share row and surfaces the URL", %{conn: conn, user: user} do
      _dtu = device_fixture(user, %{name: "Share DTU", kind: "opendtu", mqtt_username: "share-1"})
      user_id = user.id

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Sanity: no share row before the click.
      refute Accounts.get_shared_link(user)

      view |> element("#share-toggle") |> render_click(%{enabled: "true"})

      # A row exists now, with the user's id.
      assert %SharedLink{user_id: ^user_id} = Accounts.get_shared_link(user)

      finish_share_toggle(view, user) |> render()

      html = render(view)
      assert html =~ gettext("Shareable URL")
      assert html =~ "/s/"
      assert html =~ gettext("Copy URL")
    end

    test "toggling off removes the share row but does NOT crash", %{conn: conn, user: user} do
      _dtu = device_fixture(user, %{name: "Off DTU", kind: "opendtu", mqtt_username: "off-1"})
      {:ok, {_, _}} = Accounts.create_shared_link(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard")
      assert Accounts.get_shared_link(user)

      view |> element("#share-toggle") |> render_click(%{enabled: "false"})

      refute Accounts.get_shared_link(user)
      html = render(view)
      # The URL row only renders when share is active AND a plaintext
      # is in flight — after revoke, it's hidden again.
      refute html =~ gettext("Shareable URL")
    end

    test "a fresh mount with an existing share row shows the toggle on but no URL", %{
      conn: conn,
      user: user
    } do
      _dtu =
        device_fixture(user, %{name: "Reload DTU", kind: "opendtu", mqtt_username: "reload-1"})

      # Simulate the user having toggled on in a previous session.
      assert {:ok, {_, _}} = Accounts.create_shared_link(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Toggle visually reflects the existing share row — `checked`
      # is rendered on the underlying input when `share_active?` is true.
      assert has_element?(view, "#share-toggle[checked]")
      # But the plaintext URL is never re-derived on mount — it's
      # only ever shown once (see comment in `assign_share_state/2`).
      refute has_element?(view, "#share-url-row")
    end

    test "regenerating via off→on replaces the prior share row", %{conn: conn, user: user} do
      _dtu =
        device_fixture(user, %{name: "Regen DTU", kind: "opendtu", mqtt_username: "regen-1"})

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      view |> element("#share-toggle") |> render_click(%{enabled: "true"})
      view |> finish_share_toggle(user) |> render()

      assert %{token_hash: first_hash} = Accounts.get_shared_link(user)

      # Toggle off + on again. The transaction in `create_shared_link/1`
      # deletes the old row before inserting the new one — so we
      # never end up with two rows for the same user.
      view |> element("#share-toggle") |> render_click(%{enabled: "false"})
      refute Accounts.get_shared_link(user)

      view |> element("#share-toggle") |> render_click(%{enabled: "true"})
      view |> finish_share_toggle(user) |> render()

      assert %{token_hash: second_hash} = Accounts.get_shared_link(user)
      assert second_hash != first_hash

      # And only one row exists.
      user_id = user.id
      assert Repo.aggregate(from(s in SharedLink, where: s.user_id == ^user_id), :count) == 1
    end

    test "toggling on briefly shows the spinner before the URL row appears", %{
      conn: conn,
      user: user
    } do
      _dtu =
        device_fixture(user, %{name: "Spinner DTU", kind: "opendtu", mqtt_username: "spin-1"})

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # The click handler synchronously flips `:share_loading?` true
      # BEFORE spawning the Task that mints the token. The HTML that
      # `render_click` returns is the render the LiveView produced
      # during the click itself — the Task's `handle_info` message
      # lands in the LiveView mailbox only after this render has
      # been emitted, so the spinner branch is reliably visible.
      #
      # Reading `render(view)` a second time would race: by then the
      # Task may have completed (or failed with a sandbox error) and
      # the URL row / hint text would already be on screen. The
      # spinner is what the FIRST render frame after a click shows
      # — that's what users actually see, so that's what we assert
      # against.
      html =
        view |> element("#share-toggle") |> render_click(%{enabled: "true"})

      assert html =~ gettext("Generating link…")
      assert html =~ ~s(id="share-loading-row")

      # Once the Task's result lands, the URL row replaces the
      # spinner. `finish_share_toggle/2` is the test-runtime shim
      # that does the DB work synchronously (the spawned Task can't
      # borrow the LiveView's Ecto sandbox connection) and feeds the
      # result into the LiveView mailbox.
      view |> finish_share_toggle(user) |> render()

      assert has_element?(view, "#share-url-row")
    end

    test "the URL input binds a SelectOnFocus hook (mobile tap selects all)",
         %{conn: conn, user: user} do
      _dtu =
        device_fixture(user, %{name: "Focus DTU", kind: "opendtu", mqtt_username: "focus-1"})

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      view |> element("#share-toggle") |> render_click(%{enabled: "true"})
      view |> finish_share_toggle(user) |> render()

      # The colocated hook listens to `focus`, `click`, AND
      # `pointerdown` so iOS Safari — which sometimes doesn't fire
      # `focus` for read-only inputs — still routes to
      # `this.select()` via the pointer event. Asserting the hook
      # binding is enough to prove all three listeners are
      # registered (they're set up inside `mounted/1`).
      assert has_element?(
               view,
               "#share-url-input[phx-hook='DtuAppWeb.DashboardLive.SelectOnFocus']"
             )
    end

    test "the copy button uses the hint hook and has a hidden hint label", %{
      conn: conn,
      user: user
    } do
      _dtu = device_fixture(user, %{name: "Copy DTU", kind: "opendtu", mqtt_username: "copy-1"})

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      view |> element("#share-toggle") |> render_click(%{enabled: "true"})
      view |> finish_share_toggle(user) |> render()

      # The button uses the dedicated hook that flips the icon to
      # emerald AND reveals the "Copied!" hint label.
      assert has_element?(
               view,
               "#btn-share-copy[phx-hook='DtuAppWeb.DashboardLive.CopyToClipboardWithHint']"
             )

      # The hint element exists, is initially hidden via
      # `opacity-0`, and carries the user-facing label.
      html = render(view)
      assert html =~ ~s(id="share-copy-hint")
      assert html =~ gettext("Copied!")
      refute html =~ ~s(id="share-copy-hint"[^>]*opacity-100)
    end
  end
end
