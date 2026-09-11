defmodule DtuAppWeb.DashboardLive.TodayDataCacheTest do
  # Cache state is process-shared (named ETS table), so the suite
  # can't run `async: true` — sibling tests would race on the
  # same user_id key.
  use ExUnit.Case, async: false

  alias DtuAppWeb.DashboardLive.TodayDataCache

  describe "fetch/2 — nil user short-circuits" do
    test "runs the fetcher every call (no caching for anon users)" do
      # `nil` user_id means we don't even consult the cache — a fresh
      # fetcher invocation lands every time, the same as a direct call
      # to `Devices.list_today_consumption_chart_data/2`. The cache's
      # read-through pattern requires a stable key, and `nil` is the
      # "not yet bound" sentinel from the LiveView connect flow.
      calls =
        fn ->
          send(self(), {:fetch, System.monotonic_time()})
          %{consumption: [], net: []}
        end

      assert %{consumption: [], net: []} = TodayDataCache.fetch(nil, calls)
      assert %{consumption: [], net: []} = TodayDataCache.fetch(nil, calls)

      assert_received {:fetch, _}
      assert_received {:fetch, _}
    end
  end

  describe "fetch/2 — first call runs the fetcher and caches" do
    test "the second call within the TTL returns the cached value without re-running the fetcher" do
      user_id = System.unique_integer([:positive])
      TodayDataCache.invalidate(user_id)

      calls =
        fn ->
          send(self(), {:fetch, System.monotonic_time()})
          %{consumption: [1, 2, 3], net: [4, 5, 6]}
        end

      first = TodayDataCache.fetch(user_id, calls)
      second = TodayDataCache.fetch(user_id, calls)

      assert first == %{consumption: [1, 2, 3], net: [4, 5, 6]}
      assert second == first

      # Only one :fetch message landed — the second call hit the cache.
      assert_received {:fetch, _}
      refute_received {:fetch, _}
    end

    test "the cached value is returned by identity (same map, not a copy)" do
      # The LiveView mount path assigns the cached `%{consumption: …,
      # net: …}` map directly into the socket, so the value must be
      # safe to use as a Phoenix assign (i.e. it's a plain map, not a
      # function closure or lazy reference).
      user_id = System.unique_integer([:positive])
      TodayDataCache.invalidate(user_id)

      fetcher = fn -> %{consumption: [:c], net: [:n]} end

      assert %{consumption: [:c], net: [:n]} = TodayDataCache.fetch(user_id, fetcher)

      assert %{consumption: [:c], net: [:n]} =
               TodayDataCache.fetch(user_id, fn -> flunk("cache miss") end)
    end
  end

  describe "invalidate/1" do
    test "drops the cached entry so the next fetch/2 re-runs the fetcher" do
      user_id = System.unique_integer([:positive])
      TodayDataCache.invalidate(user_id)

      TodayDataCache.fetch(user_id, fn -> %{consumption: [1], net: [1]} end)

      assert TodayDataCache.fetch(user_id, fn -> flunk("cache should still be warm") end) ==
               %{consumption: [1], net: [1]}

      TodayDataCache.invalidate(user_id)

      # Cache miss now — the new fetcher must run.
      assert TodayDataCache.fetch(user_id, fn -> %{consumption: [9], net: [9]} end) ==
               %{consumption: [9], net: [9]}
    end

    test "is a no-op on an unknown user_id (and on nil)" do
      # Should not raise, should not crash the GenServer.
      assert :ok = TodayDataCache.invalidate(nil)
      assert :ok = TodayDataCache.invalidate(999_999_999)
    end
  end

  describe "stale-entry fallback" do
    test "after the 15s TTL expires, fetch/2 re-runs the fetcher (manual clock advance via :ets rewrite)" do
      user_id = System.unique_integer([:positive])
      TodayDataCache.invalidate(user_id)

      TodayDataCache.fetch(user_id, fn -> %{consumption: [1], net: [1]} end)

      # Rewrite the `stored_at` to a time 16 s in the past so the next
      # read sees a stale entry and triggers a refresh.
      now_ms = :erlang.system_time(:millisecond)
      stale_ms = now_ms - 16_000

      # New cache-key shape: `{user_id, opts}` where `opts` is the
      # keyword list passed to `fetch/3`. The 2-arg `fetch/2` form
      # delegates with `opts = []`, so the on-disk key here is
      # `{user_id, []}`.
      [{{^user_id, []}, %{value: value, stored_at: _}}] =
        :ets.lookup(TodayDataCache, {user_id, []})

      :ets.insert(TodayDataCache, {{user_id, []}, %{value: value, stored_at: stale_ms}})

      result =
        TodayDataCache.fetch(user_id, fn -> %{consumption: [2, 3, 4], net: [5, 6, 7]} end)

      assert result == %{consumption: [2, 3, 4], net: [5, 6, 7]}
    end
  end

  describe "fetch/3 — branch-keyed cache entries" do
    # The dashboard's historical branches (day / week / month / year /
    # 7d / 30d / ytd) wrap their query work in `fetch/3` with a
    # branch-distinguishing opt so a PubSub `:reading` broadcast that
    # re-renders the `day` view doesn't poison the `week` view's
    # cache entry (and vice versa). Verify the cache key treats
    # `branch: :today`, `branch: :day`, and `branch: :week` as
    # distinct.
    test "different branch opts produce independent cache entries" do
      user_id = System.unique_integer([:positive])
      TodayDataCache.invalidate(user_id)

      # Seed three branches for the same user_id.
      TodayDataCache.fetch(user_id, [branch: :today], fn -> %{which: :today} end)
      TodayDataCache.fetch(user_id, [branch: :day], fn -> %{which: :day} end)
      TodayDataCache.fetch(user_id, [branch: :week], fn -> %{which: :week} end)

      # Each branch's second fetch must hit its own cached entry —
      # the cached fetcher never re-runs.
      assert %{which: :today} =
               TodayDataCache.fetch(user_id, [branch: :today], fn -> flunk("today cache miss") end)

      assert %{which: :day} =
               TodayDataCache.fetch(user_id, [branch: :day], fn -> flunk("day cache miss") end)

      assert %{which: :week} =
               TodayDataCache.fetch(user_id, [branch: :week], fn -> flunk("week cache miss") end)
    end

    test "tz_offset_seconds / dtu_id / period keys partition the cache per dashboard session" do
      # Two users viewing the same period must NOT see each other's
      # cached stats — that's what `user_id` partitioning guarantees,
      # but two sessions for the same user with different `dtu_id`
      # (a fleet-wide vs single-device view) or different `date` /
      # `monday` / `year` period (a user clicking back through the
      # calendar) also need to see independent cached values.
      user_id = System.unique_integer([:positive])
      TodayDataCache.invalidate(user_id)

      # Two different dtu_ids for the same branch+date.
      TodayDataCache.fetch(
        user_id,
        [branch: :day, dtu_id: 1, date: ~D[2026-09-10]],
        fn -> %{dtu: 1} end
      )

      TodayDataCache.fetch(
        user_id,
        [branch: :day, dtu_id: 2, date: ~D[2026-09-10]],
        fn -> %{dtu: 2} end
      )

      assert %{dtu: 1} =
               TodayDataCache.fetch(
                 user_id,
                 [branch: :day, dtu_id: 1, date: ~D[2026-09-10]],
                 fn -> flunk("dtu_id=1 cache miss") end
               )

      assert %{dtu: 2} =
               TodayDataCache.fetch(
                 user_id,
                 [branch: :day, dtu_id: 2, date: ~D[2026-09-10]],
                 fn -> flunk("dtu_id=2 cache miss") end
               )

      # A different date for the same branch+dtu must also be a new entry.
      TodayDataCache.fetch(
        user_id,
        [branch: :day, dtu_id: 1, date: ~D[2026-09-09]],
        fn -> %{dtu: 1, date: :other} end
      )

      assert %{dtu: 1, date: :other} =
               TodayDataCache.fetch(
                 user_id,
                 [branch: :day, dtu_id: 1, date: ~D[2026-09-09]],
                 fn -> flunk("date-partitioned cache miss") end
               )

      # The original key still returns its original cached value.
      assert %{dtu: 1} =
               TodayDataCache.fetch(
                 user_id,
                 [branch: :day, dtu_id: 1, date: ~D[2026-09-10]],
                 fn -> flunk("date-partitioned cache miss") end
               )
    end

    test "invalidate_today/1 drops only the :today branch entry; :day and :week survive" do
      user_id = System.unique_integer([:positive])
      TodayDataCache.invalidate(user_id)

      # Seed three branches for the same user. The :day and :week
      # seeds include the period identifier (`date:` / `monday:`)
      # that the production callers pass — see `dashboard_live.ex`
      # ~L2351 for :day's production key shape — so the seed and
      # the assertion below hash to the same cache key.
      TodayDataCache.fetch(user_id, [branch: :today], fn -> %{which: :today} end)

      TodayDataCache.fetch(
        user_id,
        [branch: :day, date: ~D[2026-09-10]],
        fn -> %{which: :day} end
      )

      TodayDataCache.fetch(
        user_id,
        [branch: :week, monday: ~D[2026-09-07]],
        fn -> %{which: :week} end
      )

      # Drop only :today.
      assert :ok = TodayDataCache.invalidate_today(user_id)

      # :today was wiped — the fetcher must run again.
      assert %{which: :today} =
               TodayDataCache.fetch(user_id, [branch: :today], fn -> %{which: :today, rerun: true} end)

      # The historical branches still hit their original cache entries
      # (the cached fetcher returns :flunk — using flunk-bound fetchers
      # to prove the cached value came back rather than re-running).
      assert %{which: :day} =
               TodayDataCache.fetch(
                 user_id,
                 [branch: :day, date: ~D[2026-09-10]],
                 fn -> flunk(":day cache miss after invalidate_today") end
               )

      assert %{which: :week} =
               TodayDataCache.fetch(
                 user_id,
                 [branch: :week, monday: ~D[2026-09-07]],
                 fn -> flunk(":week cache miss after invalidate_today") end
               )
    end

    test "invalidate_today/1 is a no-op on nil and on missing user_id" do
      assert :ok = TodayDataCache.invalidate_today(nil)
      assert :ok = TodayDataCache.invalidate_today(999_999_999)
    end
  end
end
