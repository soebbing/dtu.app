defmodule DtuApp.Devices.UserDtuIdsCacheTest do
  # Cache state is process-shared (named ETS table), so the suite
  # can't run `async: true` — sibling tests would race on the
  # same user_id key. The 30-second TTL is fine for non-async
  # sequencing because every test starts by `invalidate`-ing any
  # prior state.
  use DtuApp.DataCase, async: false

  alias DtuApp.Devices.UserDtuIdsCache

  describe "get/2 — nil user short-circuits" do
    test "returns [] without calling the fetcher (anon user has no devices)" do
      # Use a process-dict flag instead of an outer-scope variable so
      # the closure's `called? = true` doesn't shadow the read in the
      # outer scope (Elixir warns on the shadow even though the
      # capture semantics are correct).
      Process.delete(:cache_test_fetcher_called)

      result =
        UserDtuIdsCache.get(nil, fn ->
          Process.put(:cache_test_fetcher_called, true)
          [1, 2, 3]
        end)

      assert result == []
      refute Process.get(:cache_test_fetcher_called), "fetcher must not run when user_id is nil"
    end
  end

  describe "get/2 — first call runs the fetcher and caches" do
    test "the second call within the TTL returns the cached value without re-running the fetcher" do
      user_id = System.unique_integer([:positive])

      # Start from a clean slate — siblings or a prior test might have
      # already populated this key.
      UserDtuIdsCache.invalidate(user_id)

      calls =
        fn ->
          # `self()` here is the caller (the test process) — the
          # race-safe fetch path runs the fetcher in the caller's
          # process, not in a GenServer process, so we can use
          # `self()` directly without capturing the test pid.
          send(self(), {:fetch, System.monotonic_time()})
          [42, 43]
        end

      first = UserDtuIdsCache.get(user_id, calls)
      second = UserDtuIdsCache.get(user_id, calls)

      assert first == [42, 43]
      assert second == [42, 43]

      # Only one :fetch message landed — the second call hit the cache.
      assert_received {:fetch, _}
      refute_received {:fetch, _}
    end
  end

  describe "invalidate/1" do
    test "drops the cached entry so the next get/2 re-runs the fetcher" do
      user_id = System.unique_integer([:positive])
      UserDtuIdsCache.invalidate(user_id)

      UserDtuIdsCache.get(user_id, fn -> [1] end)
      assert UserDtuIdsCache.get(user_id, fn -> flunk("cache should still be warm") end) == [1]

      UserDtuIdsCache.invalidate(user_id)

      # Cache miss now — the new fetcher must run.
      assert UserDtuIdsCache.get(user_id, fn -> [9, 9, 9] end) == [9, 9, 9]
    end

    test "is a no-op on an unknown user_id (and on nil)" do
      # Should not raise, should not crash the GenServer.
      assert :ok = UserDtuIdsCache.invalidate(nil)
      assert :ok = UserDtuIdsCache.invalidate(999_999_999)
    end
  end

  describe "stale-entry fallback" do
    test "after the 30s TTL expires, get/2 re-runs the fetcher (manual clock advance via :ets rewrite)" do
      user_id = System.unique_integer([:positive])
      UserDtuIdsCache.invalidate(user_id)

      UserDtuIdsCache.get(user_id, fn -> [1] end)

      # Rewrite the `stored_at` to a time 31 s in the past so the
      # next read sees a stale entry and triggers a refresh. We
      # bypass `put/1` (which writes the current clock) because
      # we need to *fake* the TTL passage, not wait 30 s in tests.
      now_ms = :erlang.system_time(:millisecond)
      stale_ms = now_ms - 31_000

      # Read-modify-write the cached row.
      [{^user_id, %{value: value, stored_at: _}}] = :ets.lookup(UserDtuIdsCache, user_id)

      :ets.insert(UserDtuIdsCache, {user_id, %{value: value, stored_at: stale_ms}})

      # Next read must re-run the fetcher because the row is now
      # older than the 30 s TTL.
      result = UserDtuIdsCache.get(user_id, fn -> [2, 3, 4] end)
      assert result == [2, 3, 4]
    end
  end

  describe "concurrent miss path (Tier 2 / Perf #11 race fix)" do
    test "parallel misses for the same user collapse to a single fetcher run" do
      # The race that motivated the refactor: a
      # `Phoenix.LiveViewTest.live/2` call invokes `mount/3` twice
      # (HTTP render + WebSocket upgrade) on different processes,
      # both racing through `owned_dtu_ids/2`. The naive "peek then
      # put" pattern lets both peekers see the cache row is
      # missing and both fire `SELECT id FROM dtus`. The race-safe
      # `get/2` collapses concurrent misses via `:ets.insert_new/2`
      # — the second arrival sees the first writer's value and
      # polls instead of re-fetching.
      user_id = System.unique_integer([:positive])
      UserDtuIdsCache.invalidate(user_id)

      call_counter = :counters.new(1, [])

      task_fun = fn ->
        ids =
          UserDtuIdsCache.get(user_id, fn ->
            :counters.add(call_counter, 1, 1)
            send(self(), {:fetcher_ran, self()})

            [user_id]
            # Tiny sleep so a second concurrent caller has time
            # to also peek-and-fetch in the naive implementation.
            |> tap(fn _ -> Process.sleep(20) end)
          end)

        # Return `ids` so `Task.await/1` gives it back — the
        # `send/2` call's return value is the message tuple, not
        # the ids we want to assert on.
        ids
      end

      task_a = Task.async(task_fun)
      task_b = Task.async(task_fun)
      task_c = Task.async(task_fun)

      results = [Task.await(task_a), Task.await(task_b), Task.await(task_c)]

      # All three callers saw the same id list.
      assert length(Enum.uniq(results)) == 1
      assert hd(results) == [user_id]
      # The fetcher ran at most once — concurrent misses serialised.
      assert :counters.get(call_counter, 1) <= 1
    end
  end
end
