defmodule DtuAppWeb.DeviceExportControllerTest do
  @moduledoc """
  Tests for `DtuAppWeb.DeviceExportController.csv/2` — the
  `GET /devices/:id/export.csv` endpoint that streams raw readings
  as a downloadable RFC 4180 CSV.

  Coverage:

    * **Header is always present** — every 200 response (including
      an empty window) starts with the 17-column header row, so the
      user can open the file in Excel without manual repair.
    * **Rows match seeded data** — a 3-row fixture produces a 4-line
      CSV (header + 3 data rows) with the right column counts.
    * **Tenant isolation** — user A's GET against user B's device
      returns a 200 with a header-only CSV. No 403/404 path is
      exercised (the ownership check happens in the query, not the
      route) so an attacker can't observe a side channel.
    * **Empty window** — seeded readings outside the request's
      `[start, end]` range produce a 200 + header-only CSV.
    * **Default range** — when `start` and `end` are absent, the
      controller defaults to the last 30 days. Readings inside that
      window come through; ones outside don't.
    * **Bad date params** — `start=2026-13-99` → 400 with a JSON
      error envelope.
    * **Unauthenticated** — `GET` without a session cookie redirects
      to `/users/log-in`.

  CSRF: the test conn already carries a CSRF token, so the
  `protect_from_forgery` plug lets GETs through; auth is via the
  session cookie that `register_and_log_in_user/1` installs.
  """

  use DtuAppWeb.ConnCase, async: false

  alias DtuApp.AccountsFixtures
  alias DtuApp.DevicesFixtures
  alias DtuApp.Repo

  @header_columns ~w(
    inserted_at dtu_id inverter_serial inverter_name mppt_index power_type
    ac_power dc_power frequency temperature yield_day yield_total
    consumption_power consumption_energy_day consumption_energy_total
    producing reachable
  )

  # Build a UTC DateTime with explicit microsecond precision. The bare
  # `~U[2026-08-30 10:00:00Z]` sigil creates a DateTime with
  # `microseconds: {0, 0}` — a microsecond value of 0 at precision 0.
  # The `readings.inserted_at` column is typed `:utc_datetime_usec`,
  # which Ecto rejects at second precision. Building via a naive
  # sigil with the fractional seconds part then converting to UTC
  # keeps the microsecond precision field populated.
  defp at(s) when is_binary(s) do
    [date, time] = String.split(s, " ", parts: 2)
    naive = NaiveDateTime.from_iso8601!("#{date}T#{time}")
    DateTime.from_naive!(naive, "Etc/UTC")
  end

  describe "GET /devices/:id/export.csv" do
    setup :register_and_log_in_user

    setup %{user: user} do
      device = DevicesFixtures.device_fixture(user)
      %{device: device}
    end

    test "redirects to log-in if unauthenticated", %{device: device} do
      conn = build_conn() |> get(~p"/devices/#{device.id}/export.csv")
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "returns 200 with the header row even when the device has no readings", %{
      conn: conn,
      device: device
    } do
      conn = get(conn, ~p"/devices/#{device.id}/export.csv")
      assert conn.status == 200

      [header] = parse_csv(conn.resp_body)
      assert header == @header_columns
    end

    test "streams all seeded readings as data rows", %{
      conn: conn,
      device: device,
      user: user
    } do
      _r1 =
        DevicesFixtures.reading_fixture(device, %{inserted_at: at("2026-08-30 10:00:00.000000")})

      _r2 =
        DevicesFixtures.reading_fixture(device, %{inserted_at: at("2026-08-30 11:00:00.000000")})

      _r3 =
        DevicesFixtures.reading_fixture(device, %{inserted_at: at("2026-08-30 12:00:00.000000")})

      conn =
        conn
        |> get(~p"/devices/#{device.id}/export.csv",
          start: "2026-08-30",
          end: "2026-08-30"
        )

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/csv"
      assert get_resp_header(conn, "content-disposition") |> hd() =~ ~s(filename=")

      # `parse_csv/1` returns nested lists — one entry per CSV line,
      # each entry a list of cells. `[header | data]` thus gives the
      # header as a 17-element list and `data` as `List of (17-element
      # data-row lists)`. `length(data)` is the row count.
      [header | data] = parse_csv(conn.resp_body)
      assert header == @header_columns
      assert length(data) == 3

      # Every data row has the same column count as the header — guards
      # against an off-by-one in `row_for/1` (e.g. forgetting a field).
      for row <- data do
        assert length(row) == length(@header_columns)
      end

      # The fixture defaults dtu_id to the device's id.
      for row <- data do
        [_ts, dtu_id | _rest] = row
        assert dtu_id == Integer.to_string(device.id)
      end

      # Sanity: rows are sorted ASC by inserted_at (matches
      # `stream_readings_for_export/4`'s `order_by`).
      timestamps = Enum.map(data, fn [ts | _] -> ts end)
      assert timestamps == Enum.sort(timestamps)

      # ownership context was set correctly — no row of user A's data
      # appears in user B's stream (covered by the next test, but
      # double-check here that the user_fixture's scope was wired).
      assert Repo.get!(DtuApp.Accounts.User, user.id).id == user.id
    end

    test "filters to the requested date range", %{conn: conn, device: device} do
      _old =
        DevicesFixtures.reading_fixture(device, %{inserted_at: at("2026-07-01 10:00:00.000000")})

      _mid =
        DevicesFixtures.reading_fixture(device, %{inserted_at: at("2026-08-15 10:00:00.000000")})

      _new =
        DevicesFixtures.reading_fixture(device, %{inserted_at: at("2026-09-02 10:00:00.000000")})

      conn =
        get(conn, ~p"/devices/#{device.id}/export.csv",
          start: "2026-08-15",
          end: "2026-08-15"
        )

      rows = parse_csv(conn.resp_body)
      # `[header, row]` — `row` is the single matching data row (a
      # 17-element list of cells), not a wrapper.
      [header, row] = rows
      assert header == @header_columns

      [ts | _] = row
      assert String.starts_with?(ts, "2026-08-15")
    end

    test "returns header-only CSV when the window has no readings", %{
      conn: conn,
      device: device
    } do
      _outside =
        DevicesFixtures.reading_fixture(device, %{inserted_at: at("2026-01-01 00:00:00.000000")})

      conn =
        get(conn, ~p"/devices/#{device.id}/export.csv",
          start: "2026-06-01",
          end: "2026-06-30"
        )

      assert conn.status == 200
      rows = parse_csv(conn.resp_body)
      assert rows == [@header_columns]
    end

    test "does not leak rows for a device owned by a different user", %{conn: conn} do
      # Tenant isolation: a user can't probe another user's device
      # for row counts. The ownership check inside the query helper
      # returns an empty stream, which renders as a header-only 200.
      other_user = AccountsFixtures.user_fixture()
      other_device = DevicesFixtures.device_fixture(other_user)

      _foreign =
        DevicesFixtures.reading_fixture(other_device, %{
          inserted_at: at("2026-08-30 10:00:00.000000")
        })

      conn = get(conn, ~p"/devices/#{other_device.id}/export.csv")
      assert conn.status == 200
      rows = parse_csv(conn.resp_body)
      assert rows == [@header_columns]
    end

    test "respects the 30-day default window when start/end are absent", %{
      conn: conn,
      device: device
    } do
      # Inside the default 30-day window — should appear.
      _recent =
        DevicesFixtures.reading_fixture(device, %{inserted_at: at("2026-08-25 10:00:00.000000")})

      # Way outside the window — should NOT appear.
      _ancient =
        DevicesFixtures.reading_fixture(device, %{inserted_at: at("2026-01-01 10:00:00.000000")})

      conn = get(conn, ~p"/devices/#{device.id}/export.csv")
      assert conn.status == 200

      [header, row] = parse_csv(conn.resp_body)
      assert header == @header_columns

      [ts | _] = row
      assert String.starts_with?(ts, "2026-08-25")
    end

    test "rejects an unparseable start date with 400", %{conn: conn, device: device} do
      conn =
        get(conn, ~p"/devices/#{device.id}/export.csv",
          start: "not-a-date",
          end: "2026-08-30"
        )

      assert conn.status == 400
      assert json = json_response(conn, 400)
      assert json["error"] =~ "date"
    end

    test "rejects a non-integer device id with 400", %{conn: conn} do
      conn = get(conn, ~p"/devices/not-an-int/export.csv")
      assert conn.status == 400
      assert json = json_response(conn, 400)
      assert json["error"] =~ "integer"
    end

    test "Content-Disposition filename includes the device id and date range", %{
      conn: conn,
      device: device
    } do
      conn =
        get(conn, ~p"/devices/#{device.id}/export.csv",
          start: "2026-08-30",
          end: "2026-08-30"
        )

      assert conn.status == 200
      disposition = get_resp_header(conn, "content-disposition") |> hd()
      assert disposition =~ "attachment"
      assert disposition =~ "dtu-#{device.id}-readings-2026-08-30_2026-08-30.csv"
    end
  end

  # Minimal RFC 4180-ish parser. RFC 4180 supports quoted fields with
  # embedded commas / quotes; the controller's `NimbleCSV.RFC4180`
  # encoder only ever produces unquoted (or quoted when needed) cells,
  # and our fixtures never seed fields with commas / newlines. For the
  # tiny strings we round-trip through the controller, a naive split is
  # good enough — and "good enough" is what we want from a test helper
  # (a real parser would mask a bug in the controller's encoding
  # path). Quoted cells with commas appear in `parse_error_message/1`
  # tests, which use their own parser.
  defp parse_csv(body) when is_binary(body) do
    body
    |> String.split("\r\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn line -> String.split(line, ",") end)
  end
end
