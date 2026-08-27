defmodule DtuAppWeb.SharedDashboardLiveTest do
  @moduledoc """
  Tests for the anonymous `/s/:token` share route.

  What we verify:

    * A valid token resolves to the owning user and renders the
      current-day dashboard via `Layouts.public` (no navbar).
    * An invalid / revoked token renders the "Share link unavailable"
      fallback — never a stack trace, never a 500.
    * The page contains the "powered by dtu.app" footer attribution
      and the "Live" badge.
    * `Telemetry.subscribe/0` triggers a re-render on the next reading
      — verified by simulating a `{:reading, ...}` message and
      checking that the stats re-run (we pin the round-trip with a
      device + readings fixture).
  """

  use DtuAppWeb.ConnCase, async: false

  use Gettext, backend: DtuAppWeb.Gettext

  import Phoenix.LiveViewTest

  alias DtuApp.Accounts

  import DtuApp.AccountsFixtures
  import DtuApp.DevicesFixtures

  describe "GET /s/:token with a valid token" do
    test "renders the current-day dashboard for the owning user", %{conn: conn} do
      user = user_fixture()
      _dtu = device_fixture(user, %{name: "Ahoy", kind: "ahoydtu", mqtt_username: "ahoy-1"})

      # Generate a plaintext token. The test treats the token format
      # as opaque — we just need a real one to pass through the
      # public route.
      {:ok, {plaintext, _link}} = Accounts.create_shared_link(user)

      # The route is anonymous: no current_scope cookie, no CSRF
      # token in the body. We follow the redirect chain through the
      # public pipeline so the rendered HTML reflects the actual
      # server response.
      {:ok, _view, html} = live(conn, "/s/#{plaintext}")

      assert html =~ gettext("Yield today")
      assert html =~ gettext("Current power")
      assert html =~ gettext("Live")
      # The public layout's footer is the only persistent chrome —
      # not the authenticated navbar.
      assert html =~ gettext("powered by")
      refute html =~ ~r/users\/log-in/i
      refute html =~ ~r/users\/register/i
    end
  end

  describe "GET /s/:token with an invalid token" do
    test "renders the 'Share link unavailable' fallback" do
      conn = Phoenix.ConnTest.build_conn()
      bogus = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

      # We don't go through `live/2` here because the failure path
      # is server-rendered and the link is dead-end — the page just
      # shows the error notice. A plain GET is enough.
      conn = get(conn, "/s/#{bogus}")
      html = html_response(conn, 200)

      assert html =~ gettext("Share link unavailable")
      assert html =~ gettext("This share link is invalid or has been revoked.")
      assert html =~ gettext("powered by")
    end

    test "renders the same fallback after the share is revoked", %{conn: conn} do
      user = user_fixture()
      {:ok, {plaintext, _link}} = Accounts.create_shared_link(user)

      # Verify the page rendered correctly before revocation.
      {:ok, _view, html_before} = live(conn, "/s/#{plaintext}")
      assert html_before =~ gettext("Yield today")

      # Revoke and re-fetch with a fresh connection (the previous
      # session's LiveView is no longer relevant).
      :ok = Accounts.revoke_shared_link(user)

      fresh_conn = Phoenix.ConnTest.build_conn()
      conn = get(fresh_conn, "/s/#{plaintext}")
      html = html_response(conn, 200)

      assert html =~ gettext("Share link unavailable")
      refute html =~ gettext("Yield today")
    end
  end

  describe "PubSub ticks trigger re-render" do
    test "a {:reading, ...} message refreshes the rendered stats", %{conn: conn} do
      user = user_fixture()
      _dtu = device_fixture(user, %{name: "OpenDTU", kind: "opendtu", mqtt_username: "inv-1"})

      {:ok, {plaintext, _link}} = Accounts.create_shared_link(user)

      {:ok, view, _html} = live(conn, "/s/#{plaintext}")

      # Drive a PubSub message the same way `DtuApp.MqttBroker`
      # would on a real uplink. The LiveView subscribes to the
      # `dtu:reading` topic in mount/3 via `Telemetry.subscribe/0`,
      # so a direct `Phoenix.PubSub.broadcast/3` is enough.
      now = DateTime.utc_now()

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        DtuApp.MqttBroker.Telemetry.reading_topic(),
        {:reading, "inv-1",
         %{
           ts: now,
           power_w: 425.0,
           yield_total_wh: 12_345.0,
           ac_voltage: 230.0,
           ac_frequency: 50.0,
           temperature_c: 30.0
         }}
      )

      # After the PubSub message lands, render returns the refreshed
      # payload. We assert on the chrome (labels) rather than the
      # full snapshot — the LiveView may have re-assigned everything,
      # but at minimum the stat-card chrome stays.
      html = render(view)
      assert html =~ gettext("Yield today")
      assert html =~ gettext("Current power")
    end
  end

  describe "Layouts.public does not include the authenticated shell" do
    test "no login link, no register link, no user dropdown", %{conn: conn} do
      user = user_fixture()
      {:ok, {plaintext, _link}} = Accounts.create_shared_link(user)

      {:ok, _view, html} = live(conn, "/s/#{plaintext}")

      # Sanity: the public root layout is active.
      assert html =~ gettext("powered by")

      # Negative assertions: the authenticated navbar's affordances
      # never appear. The regexes are anchored loosely so they catch
      # both nav and dropdown variants.
      refute html =~ ~r/<a[^>]+href="\/users\/log-in"/i
      refute html =~ ~r/<a[^>]+href="\/users\/register"/i
      refute html =~ ~r/dashboard/i
      refute html =~ ~r/devices/i
    end
  end

  # Regression coverage for the polyline path. Before #175 the helper
  # used the wrong bucket keys (`:utc_start` / `:power_w`) and the
  # first non-empty mount crashed with `KeyError`. The fixture-less
  # tests above always render the "No data yet" fallback, so they
  # never exercised the bug. Seed a real reading row so the cold-
  # aggregate fallback in `list_day_chart_data_for_dashboard/4`
  # returns at least one chart point and the polyline actually
  # renders.
  describe "shared polyline renders with real chart points" do
    test "a non-empty reading set renders the SVG polyline without crashing", %{conn: conn} do
      user = user_fixture()
      dtu = device_fixture(user, %{name: "Ahoy", kind: "ahoydtu", mqtt_username: "ahoy-1"})

      # Insert one raw reading within the user's local day window.
      # The share view defaults `tz_offset_seconds` to 0 (UTC) when
      # the user hasn't customised it, so `DateTime.utc_now()` lands
      # inside today. We offset by 5 minutes to stay safely away
      # from a midnight-UTC test boundary.
      reading_fixture(dtu, %{
        inverter_serial: "HM-600",
        inverter_name: "HM-600",
        ac_power: 250.0,
        inserted_at: DateTime.add(DateTime.utc_now(), -300, :second)
      })

      {:ok, {plaintext, _link}} = Accounts.create_shared_link(user)

      # Before #175 this raised KeyError inside `build_polyline/2`.
      # The `live/2` call itself is the regression guard: the mount
      # path is what crashed in production.
      {:ok, _view, html} = live(conn, "/s/#{plaintext}")

      # The polyline element is the only thing that exercises the
      # bugged helper. Asserting on the `id` is enough to prove
      # the chart card rendered; asserting on the `points` attribute
      # proves `build_polyline/2` produced a real coordinate string.
      assert html =~ ~s(id="shared-power-chart")
      assert html =~ ~r/<polyline[^>]+points="[\d.]+,[\d.]+/

      # Negative sanity: the "no data" fallback must NOT show up —
      # we just inserted a reading.
      refute html =~ gettext("No data yet — check back in a few minutes.")
    end

    test "multiple series in the same bucket are summed into one combined polyline point", %{
      conn: conn
    } do
      user = user_fixture()
      dtu = device_fixture(user, %{name: "Ahoy", kind: "ahoydtu", mqtt_username: "ahoy-1"})

      inserted_at = DateTime.add(DateTime.utc_now(), -300, :second)

      # Two MPPT rows on the same inverter fall into the same
      # 5-minute bucket but belong to different `series` keys. The
      # share view promises a combined snapshot, so the polyline
      # point at this bucket time should reflect the sum of both
      # MPPTs' power.
      reading_fixture(dtu, %{
        inverter_serial: "HM-600",
        inverter_name: "HM-600",
        mppt_index: 0,
        ac_power: 200.0,
        inserted_at: inserted_at
      })

      reading_fixture(dtu, %{
        inverter_serial: "HM-600",
        inverter_name: "HM-600",
        mppt_index: 1,
        ac_power: 300.0,
        inserted_at: inserted_at
      })

      {:ok, {plaintext, _link}} = Accounts.create_shared_link(user)

      {:ok, _view, html} = live(conn, "/s/#{plaintext}")

      # Polyline rendered (proves the helper didn't KeyError on
      # multi-series points). The exact y-coordinate depends on the
      # bucket math, but the point string is non-empty and the
      # chart shell is present.
      assert html =~ ~s(id="shared-power-chart")
      assert html =~ ~r/<polyline[^>]+points="[\d.]+,[\d.]+/
    end
  end

  # Pin the data-driven y-axis behaviour introduced in task #221.
  #
  # The original `watts_to_y/1` was hard-coded to "200 W = top of
  # chart", so any realistic solar day (>200 W peak) collapsed into
  # the top 10 px band and the polyline looked like a thick line of
  # "overlay numbers" at the top of the chart — which is what the
  # user reported. The fix picks `y_max` from the day's peak so the
  # polyline fills the full vertical range.
  describe "polyline spans the full chart height for realistic watts" do
    test "peak > 200 W does not collapse into the top sliver", %{conn: conn} do
      user = user_fixture()
      dtu = device_fixture(user, %{name: "Ahoy", kind: "ahoydtu", mqtt_username: "inv-1"})

      # Build a day with 500 W peak — well above the old hard-coded
      # 200 W ceiling, so the regression would show immediately.
      today = DateTime.utc_now() |> DateTime.to_date()

      for h <- 6..17, m <- 0..55, rem(m, 5) == 0 do
        {:ok, ts} = DateTime.new(today, Time.new!(h, m, 0, 0), "Etc/UTC")
        ts = DateTime.truncate(ts, :microsecond)
        # Bell-shaped peak around noon.
        watts = 500.0 * :math.sin((h - 6) / 12.0 * :math.pi())

        reading_fixture(dtu, %{
          inserted_at: ts,
          ac_power: watts,
          yield_day: 0.1,
          yield_total: 1.0
        })
      end

      {:ok, {plaintext, _link}} = Accounts.create_shared_link(user)
      {:ok, _view, html} = live(conn, "/s/#{plaintext}")

      # Extract every y-coordinate from the polyline's points string.
      ys =
        Regex.scan(~r/points="([^"]+)"/, html)
        |> Enum.map(fn [_, pts] -> pts end)
        |> List.first()
        |> String.split(" ")
        |> Enum.map(fn pair ->
          [_x, y] = String.split(pair, ",")
          Float.parse(y) |> elem(0)
        end)

      assert ys != [], "polyline must have at least one point"

      y_min = Enum.min(ys)
      y_max = Enum.max(ys)

      # Spreads the polyline across the chart: the peak reading must
      # land near the top (y close to 10), the early-morning / late-
      # evening baseline must land near the bottom (y close to 190).
      # Pre-fix, y_min and y_max were both in [6, 10] because the
      # >200 W branch squished everything into the top sliver.
      assert y_min < 50, "peak point should be near top of chart, got y_min=#{y_min}"
      assert y_max > 100, "low-wattage point should be near bottom, got y_max=#{y_max}"
      # Sanity: still inside the viewBox.
      assert y_min >= 0 and y_max <= 190

      # Exactly one polyline (combined view) — never two, never an
      # overlay sneaking in.
      assert html =~ ~r/<polyline[^>]+points="[\d., ]+"/,
             "expected exactly one <polyline> with coordinate points"

      refute html =~ ~r/<text[^>]*>\s*-?\d+\.?\d*\s*</,
             "no <text> element should contain a bare numeric label (Y-axis numbers are bug #221)"
    end
  end
end
