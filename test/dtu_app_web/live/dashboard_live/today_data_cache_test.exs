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
end
