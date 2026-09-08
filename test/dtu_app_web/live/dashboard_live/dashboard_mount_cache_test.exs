defmodule DtuAppWeb.DashboardLive.DashboardMountCacheTest do
  # Cache state is process-shared (named ETS table), so the suite
  # can't run `async: true` — sibling tests would race on the
  # same `{user_id, dtu_id, tz_offset_seconds}` key.
  use ExUnit.Case, async: false

  alias DtuAppWeb.DashboardLive.DashboardMountCache

  defp unique_user_id, do: System.unique_integer([:positive])

  describe "fetch/4 — first call runs the fetcher and caches" do
    test "the second call within the TTL returns the cached value without re-running the fetcher" do
      user_id = unique_user_id()
      DashboardMountCache.invalidate(user_id, nil, 0)

      calls =
        fn ->
          send(self(), {:fetch, System.monotonic_time()})
          %{devices: [:d1], has_push_subscriptions: true}
        end

      first = DashboardMountCache.fetch(user_id, nil, 0, calls)
      second = DashboardMountCache.fetch(user_id, nil, 0, calls)

      assert first == %{devices: [:d1], has_push_subscriptions: true}
      assert second == first

      # Only one :fetch message landed — the second call hit the cache.
      assert_received {:fetch, _}
      refute_received {:fetch, _}
    end

    test "different (dtu_id, tz_offset_seconds) pairs produce different cache entries" do
      # A DTU switch or tz change must produce a fresh seed fetch
      # rather than reusing the previous user's cached value — the
      # closure captures `dtu_id` and `tz_offset_seconds`, so a hit
      # with the wrong key would yield stats for the wrong DTU or
      # for the wrong time-window math.
      user_id = unique_user_id()
      DashboardMountCache.invalidate(user_id, nil, 0)
      DashboardMountCache.invalidate(user_id, 42, 0)

      DashboardMountCache.fetch(user_id, nil, 0, fn -> %{for: :all} end)

      assert %{for: :one} =
               DashboardMountCache.fetch(user_id, 42, 0, fn -> %{for: :one} end)

      assert %{for: :tz_3600} =
               DashboardMountCache.fetch(user_id, nil, 3600, fn -> %{for: :tz_3600} end)
    end
  end

  describe "invalidate/3" do
    test "drops the cached entry for the (user_id, dtu_id, tz) tuple so the next fetch re-runs the fetcher" do
      user_id = unique_user_id()
      DashboardMountCache.invalidate(user_id, nil, 0)

      DashboardMountCache.fetch(user_id, nil, 0, fn -> %{seed: :first} end)

      assert DashboardMountCache.fetch(user_id, nil, 0, fn ->
               flunk("cache should still be warm")
             end) ==
               %{seed: :first}

      DashboardMountCache.invalidate(user_id, nil, 0)

      assert %{seed: :second} =
               DashboardMountCache.fetch(user_id, nil, 0, fn -> %{seed: :second} end)
    end

    test "invalidate/2 (user_id only) drops every cached entry for that user regardless of dtu_id/tz" do
      # The dashboard refresh path doesn't always know which
      # `(dtu_id, tz)` slot it last cached — `invalidate/2` is the
      # blast-radius helper for "the user's devices or tz changed,
      # drop everything."
      user_id = unique_user_id()
      DashboardMountCache.invalidate(user_id, nil, 0)
      DashboardMountCache.invalidate(user_id, 42, 0)
      DashboardMountCache.invalidate(user_id, nil, 3600)

      DashboardMountCache.fetch(user_id, nil, 0, fn -> %{slot: :a} end)
      DashboardMountCache.fetch(user_id, 42, 0, fn -> %{slot: :b} end)
      DashboardMountCache.fetch(user_id, nil, 3600, fn -> %{slot: :c} end)

      DashboardMountCache.invalidate(user_id)

      assert %{slot: :a_fresh} =
               DashboardMountCache.fetch(user_id, nil, 0, fn -> %{slot: :a_fresh} end)

      assert %{slot: :b_fresh} =
               DashboardMountCache.fetch(user_id, 42, 0, fn -> %{slot: :b_fresh} end)

      assert %{slot: :c_fresh} =
               DashboardMountCache.fetch(user_id, nil, 3600, fn -> %{slot: :c_fresh} end)
    end

    test "invalidate/3 is a no-op for unknown entries" do
      # Safe to call on never-cached user_ids; the ETS delete must
      # not raise.
      DashboardMountCache.invalidate(unique_user_id(), nil, 0)
      DashboardMountCache.invalidate(unique_user_id(), 99, 3600)
      DashboardMountCache.invalidate(nil, nil, 0)
    end
  end

  describe "stale-entry fallback" do
    test "after the 60s TTL expires, fetch/4 re-runs the fetcher (manual clock advance via :ets rewrite)" do
      # Same technique as `UserDtuIdsCache` tests: rewrite the
      # stored_at to a time past the TTL so the next read sees a
      # stale entry and triggers a refresh.
      user_id = unique_user_id()
      DashboardMountCache.invalidate(user_id, nil, 0)

      DashboardMountCache.fetch(user_id, nil, 0, fn -> %{seed: :first} end)

      now_ms = :erlang.system_time(:millisecond)
      stale_ms = now_ms - 61_000

      [{{^user_id, nil, 0}, %{value: value, stored_at: _}}] =
        :ets.lookup(DashboardMountCache, {user_id, nil, 0})

      :ets.insert(
        DashboardMountCache,
        {{user_id, nil, 0}, %{value: value, stored_at: stale_ms}}
      )

      assert %{seed: :second} =
               DashboardMountCache.fetch(user_id, nil, 0, fn -> %{seed: :second} end)
    end
  end

  describe "concurrent miss path" do
    test "parallel misses for the same slot collapse to a single fetcher run" do
      # Same race the dashboard HTTP+WS double-mount exhibits:
      # two processes peek the cache, both see the slot empty, and
      # would both fire the four seed queries. The race-safe
      # `fetch/4` collapses concurrent misses via `:ets.insert_new/2`
      # — the second arrival sees the first writer's value and
      # polls instead of re-fetching.
      user_id = unique_user_id()
      DashboardMountCache.invalidate(user_id, nil, 0)

      call_counter = :counters.new(1, [])

      task_fun = fn ->
        seed =
          DashboardMountCache.fetch(user_id, nil, 0, fn ->
            :counters.add(call_counter, 1, 1)
            send(self(), {:fetcher_ran, self()})

            %{seed: :fresh}
            # Tiny sleep so a second concurrent caller has time
            # to also peek-and-fetch in the naive implementation.
            |> tap(fn _ -> Process.sleep(20) end)
          end)

        seed
      end

      task_a = Task.async(task_fun)
      task_b = Task.async(task_fun)
      task_c = Task.async(task_fun)

      results = [Task.await(task_a), Task.await(task_b), Task.await(task_c)]

      # All three callers saw the same seed map.
      assert length(Enum.uniq(results)) == 1
      assert hd(results) == %{seed: :fresh}
      # The fetcher ran at most once — concurrent misses serialised.
      assert :counters.get(call_counter, 1) <= 1
    end
  end
end
