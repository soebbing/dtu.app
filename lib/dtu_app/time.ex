defmodule DtuApp.Time do
  @moduledoc """
  Database-clock helpers.

  Every persisted timestamp in this app — token `inserted_at`, reading
  `inserted_at`, DTU `last_seen_at`, user `confirmed_at`, etc. — must come
  from the database, not the application container. Two reasons:

    1. **Single source of truth.** The DB is the only process every
       container can rely on to have a stable wall clock. App containers
       may be on different hosts, may have stale NTP, or may be running
       with an unset timezone, and writing timestamps from those clocks
       would silently skew every time-windowed query.

    2. **No clock skew on read.** Time-windowed queries
       (`token.inserted_at > ^cutoff`, `last_seen_at > ^cutoff`, …) round-
       trip through the DB. If the write side used the app clock and the
       read side used `now()` on the DB, a few minutes of drift would
       already mis-classify freshly-issued magic links as "expired", or
       flip a DTU's "online" badge minutes early/late. Both sides now use
       `DtuApp.Time.utc_now/0`, so the value the DB stores and the value
       the DB compares against come from the same `SELECT now()` round
       trip.

  `utc_now/0` is a tiny extra query per call, but every call site that
  uses it was either inside a bigger `Repo.insert` / `Repo.update_all` /
  `Repo.all` query (no extra round-trip) or runs at human speeds
  (dashboard render, magic-link click). For high-frequency telemetry
  ingestion, the `Dtu.last_seen_at` write still goes through `utc_now/0`
  — a few extra milliseconds on each uplink is fine for the invariant
  this gives us.

  The companion migration
  (`priv/repo/migrations/<ts>_set_db_clock_defaults_for_time_columns.exs`)
  also sets `DEFAULT now()` on every timestamp column so any direct
  `INSERT` that doesn't supply a value still gets the DB clock.

  ## Postgres ↔ Elixir timestamp types

  Postgres `timestamp without time zone` decodes to `%NaiveDateTime{}` in
  Postgrex — there's no timezone information on the value, by design.
  Ecto then re-tags the field as `:utc_datetime` on the schema side,
  which is conventionally a UTC `DateTime`.

  To produce a `%DateTime{}` that's *guaranteed* to be in UTC regardless
  of the DB session's `TIME ZONE` setting (which we don't pin), we ask
  for `now() AT TIME ZONE 'UTC'` — that yields a `timestamp` whose
  components are UTC, which we then lift to a UTC-tagged `%DateTime{}`
  via `DateTime.from_naive!/2`.
  """

  alias DtuApp.Repo

  @doc """
  Return the database's current timestamp as a `%DateTime{}` in UTC,
  truncated to seconds — matching the `:utc_datetime` Ecto type.

  Used wherever the application previously called `DateTime.utc_now()`:
  token issuance, `last_seen_at` writes, `confirm_changeset`, the
  dashboard's "today" / "X minutes ago" helpers, and the cutoffs fed
  into time-windowed queries.
  """
  @spec utc_now() :: DateTime.t()
  def utc_now do
    Repo
    |> query_now()
    |> lift_to_utc_datetime()
    |> DateTime.truncate(:second)
  end

  @doc """
  Return the database's current timestamp with microsecond precision,
  for columns typed `:utc_datetime_usec` (e.g. `readings.inserted_at`).
  """
  @spec utc_now_usec() :: DateTime.t()
  def utc_now_usec do
    Repo
    |> query_now()
    |> lift_to_utc_datetime()
    |> DateTime.truncate(:microsecond)
  end

  # Private helpers

  # `SELECT now() AT TIME ZONE 'UTC'` returns the current instant with
  # its components already in UTC, regardless of the DB session's
  # `TIME ZONE` setting. Postgrex decodes `timestamp without time zone`
  # to `%NaiveDateTime{}`.
  defp query_now(repo) do
    # Call `Ecto.Adapters.SQL.query!/4` directly with all four args to
    # avoid the ambiguity of `Repo.query!/N` resolving through `use
    # Ecto.Repo`'s implicit delegation. See the Ecto source for the
    # `(repo, sql, params, opts)` arity at
    # `deps/ecto_sql/lib/ecto/adapters/sql.ex`.
    %Postgrex.Result{rows: [[naive]]} =
      Ecto.Adapters.SQL.query!(repo, "SELECT now() AT TIME ZONE 'UTC'", [], [])

    naive
  end

  # Lift a `%NaiveDateTime{}` (no offset) to a `%DateTime{}` tagged as
  # UTC. The query above guarantees the components are UTC, so this
  # lift is exact and doesn't depend on the host or DB session timezone.
  defp lift_to_utc_datetime(%NaiveDateTime{} = naive),
    do: DateTime.from_naive!(naive, "Etc/UTC")
end
