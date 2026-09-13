defmodule DtuApp.Devices.ReadingExports do
  @moduledoc """
  CSV / export-side reading queries.

  `list_recent_readings/3` is the manage-device panel's "show me the
  last N readings" helper; `stream_readings_for_export/4` and the
  `@export_page_size` tunable back the CSV export endpoint.

  The "today" / chart-data queries live elsewhere (`ChartData`,
  `ConsumptionChartData`, `Stats`). This module is the export +
  small lookup surface only.

  Re-exported through `DtuApp.Devices` via `defdelegate` so existing
  `Devices.list_recent_readings/3`-style call sites continue to work
  unchanged after the extraction.
  """

  import Ecto.Query

  alias DtuApp.Accounts.User
  alias DtuApp.Devices.ChartHelpers
  alias DtuApp.Devices.Reading
  alias DtuApp.Repo

  @doc "List recent readings for a specific user-owned DTU."
  def list_recent_readings(%User{} = user, dtu_id, limit \\ 100) do
    if ChartHelpers.owned?(user, dtu_id) do
      Repo.all(
        from r in Reading,
          where: r.dtu_id == ^dtu_id,
          order_by: [desc: r.inserted_at],
          limit: ^limit
      )
    else
      []
    end
  end

  # Page size for `stream_readings_for_export/5`. Each row is one reading
  # (~250 bytes uncompressed) so 5 000 rows per fetch ≈ 1.25 MB raw —
  # well under the connection's send buffer and small enough that the
  # CSV encoder finishes each batch in a few ms. Larger pages save DB
  # round-trips but inflate per-batch memory; smaller pages do the
  # inverse. The current value is the same page size the dashboard's
  # `TodayDataCache` uses for its async refresh slices (see
  # `dashboard_live.ex`), which keeps the export's per-batch cost
  # bounded by what the rest of the app already accepts.
  @export_page_size 5_000

  @doc """
  Page size (rows) used by `stream_readings_for_export/5`. Exposed for
  tests so they can override via `Application.put_env(:dtu_app,
  :export_page_size, N)` if a particular scenario needs a smaller
  page to exercise a multi-batch stream without seeding tens of
  thousands of readings.
  """
  def export_page_size, do: @export_page_size

  @doc """
  Stream all readings for `user`'s DTU `dtu_id` whose `inserted_at`
  falls within the inclusive UTC range `[utc_start, utc_end]`. Returns
  an `Ecto.Stream` of `%Reading{}` structs ordered by `inserted_at`
  ASC, batched in `export_page_size/0` row slices.

  ## Ownership + tenant isolation

  The function refuses any DTU the user does not own: `owned?/2`
  returns false for a foreign DTU and we short-circuit with an empty
  stream. The empty stream is the only safe cross-tenant response —
  the CSV controller treats it identically to "no readings in the
  window", so a malicious query for another user's DTU renders a
  header-only CSV (no data leak) rather than a 403.

  ## Why a stream, not a list?

  A 30-day export at 30 s uplink cadence is ~85 000 raw rows per
  device — too many to load into memory at once. The stream is
  backed by `Ecto.Repo.stream/2`, which uses PostgreSQL's libpq
  cursor protocol to fetch one page at a time. The CSV controller
  consumes the stream via `Enum.each/2`, writing one CSV batch per
  page and flushing to the chunked response. Memory stays bounded
  to one page (~5 000 rows) regardless of the export's total size.

  ## Sort order

  ASC by `inserted_at` so the output CSV is time-ordered top-to-
  bottom — the natural shape for any downstream consumer (Excel's
  default sort, pandas' default index, gnuplot's default x-axis).
  The composite primary key `(dtu_id, inverter_serial, mppt_index,
  inserted_at)` puts `inserted_at` last, so an ASC scan walks the
  hypertable chronologically within each `(dtu_id, inverter_serial,
  mppt_index)` slice.
  """
  @spec stream_readings_for_export(User.t(), integer(), DateTime.t(), DateTime.t()) ::
          Ecto.Stream.t() | []
  def stream_readings_for_export(%User{} = user, dtu_id, utc_start, utc_end)
      when is_integer(dtu_id) and is_struct(utc_start, DateTime) and is_struct(utc_end, DateTime) do
    if ChartHelpers.owned?(user, dtu_id) do
      page_size = export_page_size()

      Reading
      |> where(
        [r],
        r.dtu_id == ^dtu_id and r.inserted_at >= ^utc_start and r.inserted_at <= ^utc_end
      )
      |> order_by(asc: :inserted_at)
      |> Repo.stream(max_rows: page_size)
    else
      # Cross-tenant probe → empty stream. The controller handles it
      # the same way as "no data in the window" (header-only CSV).
      # Returning `[]` instead of `Ecto.Stream` keeps `Enum.each/2`
      # happy — both shapes are enumerable.
      []
    end
  end
end
