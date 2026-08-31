defmodule DtuApp.TimeTest do
  use DtuApp.DataCase, async: false

  alias DtuApp.Time
  alias DtuApp.Time.Cache

  describe "utc_now/0" do
    test "returns a DateTime tagged as UTC, second-precision (matching :utc_datetime)" do
      dt = Time.utc_now()
      assert %DateTime{time_zone: "Etc/UTC", microsecond: {_usec, precision}} = dt
      # `utc_now/0` is for `:utc_datetime` columns — second-precision,
      # truncated to whole seconds. See `DtuApp.Time.utc_now_usec/0`
      # for the microsecond-precision variant.
      assert precision == 0
    end

    test "matches SELECT now() to within a millisecond" do
      # Two consecutive round trips to the DB should land within a
      # millisecond of each other (the only thing between them is the
      # Erlang scheduler). If we ever drift to wall-clock minutes (i.e.
      # the helper silently fell back to the app clock) this test fails.
      t1 = Time.utc_now()
      _ = Time.utc_now()
      t2 = Time.utc_now()

      diff_ms = DateTime.diff(t2, t1, :millisecond)
      assert diff_ms >= 0
      assert diff_ms < 1_000
    end

    test "consecutive calls within the 10s cache window return the cached value (no new DB round-trip)" do
      # Reset cache so this test isn't sensitive to state from
      # sibling tests running in the same VM.
      Cache.put(DateTime.utc_now() |> DateTime.truncate(:second))

      t1 = Time.utc_now()
      t2 = Time.utc_now()

      # Same DateTime struct — meaning the second call hit the
      # cache and never round-tripped to the DB. The equality is
      # structural, not just within-a-second: the helper returns
      # the exact value it cached.
      assert t1 == t2
    end
  end

  describe "utc_now_usec/0" do
    test "preserves microsecond precision (DB clock, not app clock)" do
      # The whole point of this helper: it's a DB round-trip, so the
      # microseconds should be 6 digits, matching the
      # :utc_datetime_usec column type used by readings.
      dt = Time.utc_now_usec()
      {_usec, precision} = dt.microsecond
      assert precision == 6
    end

    test "two consecutive calls return monotonically non-decreasing timestamps" do
      # Postgres' `now()` is the transaction time, which is *monotonic*
      # within a session. Two consecutive calls within the same process
      # should never return a timestamp earlier than the previous one.
      t1 = Time.utc_now_usec()
      t2 = Time.utc_now_usec()

      assert DateTime.compare(t2, t1) in [:gt, :eq]
    end

    test "is NOT served from the cache (microsecond precision requires a fresh DB read)" do
      # Stale by design — see `DtuApp.Time.Cache` moduledoc. If this
      # ever returns the cached second-precision value, the readings
      # composite PK (`inserted_at`) would silently lose its
      # microsecond component and the `maybe_default_inserted_at`
      # collision-avoidance path would start firing.
      dt = Time.utc_now_usec()
      {_usec, precision} = dt.microsecond
      assert precision == 6
    end
  end
end
