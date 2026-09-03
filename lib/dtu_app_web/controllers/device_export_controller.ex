defmodule DtuAppWeb.DeviceExportController do
  @moduledoc """
  CSV export of historical readings for a single DTU.

  Drives the per-device "Download CSV" affordance (see
  `DtuAppWeb.DeviceLive.Details` / `DtuAppWeb.DeviceLive.Index`). One
  HTTP action — `csv/2` — that streams the raw rows in
  `readings` for a user-owned DTU as an RFC 4180 CSV download.

  ## Why a controller (not a LiveView)?

  LiveView is the right tool for interactive UI, but a CSV download
  isn't interactive: the user clicks once, the server streams bytes,
  and the browser shows a save dialog. A controller action is
  simpler, doesn't pay the LiveView socket/serialise cost, and
  matches how `PushController` handles the non-interactive
  Web-Push plumbing.

  ## Stream + chunked response

  The action uses `Plug.Conn.send_chunked/2` so the response starts
  sending before the full body is computed — a multi-day export
  doesn't fit in one BEAM buffer. `DtuApp.Devices.stream_readings_for_export/4`
  is an `Ecto.Stream` (libpq cursor protocol, see `Ecto.Repo.stream/2`)
  so memory stays bounded to `Devices.export_page_size/0` rows
  regardless of the window's total size.

  ## Tenant isolation

  Ownership is enforced inside the query helper — a foreign DTU
  yields an empty stream, which the controller renders as a
  header-only CSV. No 403 / 404 path is needed because the
  ownership check happens before any row materialises, so a probe
  for someone else's DTU can't observe the row count or any
  timing-based side channel.

  ## Time range

  `start` and `end` query params are user-supplied ISO-8601 dates
  (`YYYY-MM-DD`). They are interpreted in the user's local
  timezone (`current_scope.user.tz_offset_seconds`), then translated
  to a UTC range via `DtuApp.Devices.local_day_utc_range/2`.
  Missing / malformed params fall back to "today UTC" for `end`
  and "30 days ago UTC" for `start` — same defaults the dashboard
  uses for the 30D preset.

  ## Columns

  All 14 raw fields of `DtuApp.Devices.Reading` are exported. The
  AC-aggregate row (`mppt_index = 0`) carries `ac_power`; per-MPPT
  rows (`mppt_index >= 1`) carry `dc_power`. Empty cells are
  emitted for the field that doesn't apply to a given row — never
  `0`, since `0 W` is a meaningful reading and would be
  indistinguishable from "the firmware didn't publish this field".

  ## Locale / number formatting

  Headers and cell values are emitted in en-US convention (dot as
  decimal separator, ISO-8601 UTC for `inserted_at`). Numbers are
  passed through their raw float representation; the dashboard's
  locale-specific rounding happens client-side at display time.
  """

  use DtuAppWeb, :controller

  alias DtuApp.Devices
  alias DtuApp.Devices.Reading

  require Logger

  # CSV header order — pinned so users can rely on column 1 = timestamp.
  # `nil` cells in a row render as empty strings (`NimbleCSV.RFC4180.quote/1`
  # returns `""` for `nil`), which is the RFC 4180-compliant way to
  # represent "this field doesn't apply to this row" (e.g. `ac_power`
  # is `nil` on per-MPPT rows, `dc_power` is `nil` on the AC-aggregate).
  @csv_header [
    "inserted_at",
    "dtu_id",
    "inverter_serial",
    "inverter_name",
    "mppt_index",
    "power_type",
    "ac_power",
    "dc_power",
    "frequency",
    "temperature",
    "yield_day",
    "yield_total",
    "consumption_power",
    "consumption_energy_day",
    "consumption_energy_total",
    "producing",
    "reachable"
  ]

  # Default range when the caller doesn't supply `start` / `end`. 30
  # days matches the dashboard's "30D" preset, which is the most
  # common export length users reach for ("I want last month's data
  # to plug into my own spreadsheet").
  @default_window_days 30

  @doc """
  `GET /devices/:id/export.csv` — streams the device's raw readings
  as a CSV download.

  Query params:
    * `start` (optional) — inclusive lower-bound date in `YYYY-MM-DD`,
      interpreted in the user's local timezone. Defaults to 30 days
      before `end`.
    * `end`   (optional) — inclusive upper-bound date in `YYYY-MM-DD`,
      interpreted in the user's local timezone. Defaults to today.

  Responses:
    * `200 text/csv` — header + zero-or-more data rows. An empty
      window still returns `200` with the header only (no error —
      the user gets a CSV they can open).
    * `302` — to `/users/log-in` when the session is unauthenticated
      (the router's `:require_authenticated_user` plug handles this).
    * `400` — when the `start` / `end` params are unparseable.
  """
  def csv(conn, %{"id" => id} = params) do
    user = conn.assigns.current_scope.user
    dtu_id = parse_id!(id)

    {utc_start, utc_end} = parse_range!(user, params)

    filename = build_filename(dtu_id, utc_start, utc_end)

    conn =
      conn
      |> put_resp_content_type("text/csv; charset=utf-8")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_chunked(200)

    # Header first — every CSV starts with the column row, even when
    # the window has no readings. `NimbleCSV.RFC4180.dump_to_iodata/1`
    # returns iodata so we feed it straight to `Plug.Conn.chunk/2`
    # without building an intermediate binary. Sent outside the
    # transaction below because no DB access is needed for the header
    # and we want the first chunk on the wire ASAP (the browser's
    # download dialog usually fires after the first bytes arrive).
    {:ok, conn} = Plug.Conn.chunk(conn, NimbleCSV.RFC4180.dump_to_iodata([@csv_header]))

    # The cursor must stay open while we iterate, so BOTH the stream
    # creation (`Repo.stream/2`) and its consumption run inside a
    # single `Repo.transaction/1`. PostgreSQL cursors are
    # transaction-scoped — closing the transaction (e.g. by exiting
    # the transaction callback) closes the cursor, and any further
    # `FETCH` raises `cannot reduce stream outside of transaction`.
    # By wrapping the whole pipeline here, the cursor stays bound to
    # the transaction's connection for the duration of the chunked
    # send.
    {:ok, conn} =
      DtuApp.Repo.transaction(fn ->
        stream = Devices.stream_readings_for_export(user, dtu_id, utc_start, utc_end)

        stream
        |> Stream.map(&row_for/1)
        |> Stream.chunk_every(Devices.export_page_size())
        |> Enum.reduce_while(conn, fn rows, conn ->
          case Plug.Conn.chunk(conn, NimbleCSV.RFC4180.dump_to_iodata(rows)) do
            {:ok, conn} -> {:cont, conn}
            {:error, _reason} -> {:halt, conn}
          end
        end)
      end)

    conn
  rescue
    e in ArgumentError ->
      Logger.warning("[DeviceExportController] #{e.message}")
      conn |> put_status(:bad_request) |> json(%{error: e.message})
  end

  # ----- helpers ---------------------------------------------------------

  defp parse_id!(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> raise ArgumentError, "device id must be an integer"
    end
  end

  defp parse_id!(_), do: raise(ArgumentError, "device id must be an integer")

  # Parse the `start` / `end` query params (YYYY-MM-DD, user-local)
  # into an inclusive UTC range. Missing or unparseable values fall
  # back to the dashboard's 30D preset; this matches what a user
  # clicking "Download CSV" without picking a range would expect.
  defp parse_range!(user, params) do
    today = Date.utc_today()
    default_end = today
    default_start = Date.add(today, -@default_window_days)

    {start_date, end_date} =
      case {Map.get(params, "start"), Map.get(params, "end")} do
        {nil, nil} ->
          {default_start, default_end}

        {nil, end_str} ->
          {Date.add(parse_date!(end_str), -@default_window_days), parse_date!(end_str)}

        {start_str, nil} ->
          {parse_date!(start_str), default_end}

        {start_str, end_str} ->
          {parse_date!(start_str), parse_date!(end_str)}
      end

    if Date.compare(start_date, end_date) == :gt do
      raise ArgumentError, "start date is after end date"
    end

    tz_offset = user.tz_offset_seconds || 0
    # Two-call window: each `local_day_utc_range/2` returns
    # `{utc_start_of_day, utc_end_of_day}` (start first, end second).
    # We need the start of `start_date` and the end of `end_date`,
    # so destructure each call accordingly. Using
    # `local_day_utc_range/2` per-endpoint gives us the right TZ
    # alignment for each bound (a user in `Europe/Berlin` (UTC+1 /
    # UTC+2 DST) gets the local-day boundary, not the UTC one).
    {utc_start, _} = Devices.local_day_utc_range(start_date, tz_offset)
    {_, utc_end} = Devices.local_day_utc_range(end_date, tz_offset)
    {utc_start, utc_end}
  end

  defp parse_date!(nil), do: raise(ArgumentError, "missing date")

  defp parse_date!(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, d} -> d
      _ -> raise ArgumentError, "date must be in YYYY-MM-DD format"
    end
  end

  defp parse_date!(_), do: raise(ArgumentError, "date must be in YYYY-MM-DD format")

  # Positionally aligned with `@csv_header`. `inserted_at` renders as
  # ISO-8601 UTC; floats pass through (shortest round-trippable
  # representation — `1.0` → "1.0"); booleans → "true"/"false";
  # nils → "" (NimbleCSV encodes nil cells as empty fields).
  defp row_for(%Reading{} = r) do
    [
      DateTime.to_iso8601(r.inserted_at),
      r.dtu_id,
      r.inverter_serial,
      r.inverter_name,
      r.mppt_index,
      r.power_type,
      r.ac_power,
      r.dc_power,
      r.frequency,
      r.temperature,
      r.yield_day,
      r.yield_total,
      r.consumption_power,
      r.consumption_energy_day,
      r.consumption_energy_total,
      r.producing,
      r.reachable
    ]
  end

  # Filename for the Content-Disposition header. Format:
  # `dtu-<id>-readings-<start>_<end>.csv` — uses the inclusive date
  # range so a user exporting "today" sees `…2026-09-03_2026-09-03.csv`
  # in their downloads folder.
  defp build_filename(dtu_id, utc_start, utc_end) do
    start_date = utc_start |> DateTime.to_date() |> Date.to_iso8601()
    end_date = utc_end |> DateTime.to_date() |> Date.to_iso8601()
    "dtu-#{dtu_id}-readings-#{start_date}_#{end_date}.csv"
  end
end
