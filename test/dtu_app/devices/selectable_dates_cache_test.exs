defmodule DtuApp.Devices.SelectableDatesCacheTest do
  # Cache state is process-shared (named ETS table), so the suite
  # can't run `async: true` — sibling tests would race on the
  # same user_id key. The 30-second TTL is fine for non-async
  # sequencing because every test starts by `invalidate`-ing any
  # prior state.
  use DtuApp.DataCase, async: false

  alias DtuApp.Devices.SelectableDatesCache

  describe "get/3 — first call runs the fetcher and caches" do
    test "the second call within the TTL returns the cached value without re-running the fetcher" do
      user_id = System.unique_integer([:positive])
      SelectableDatesCache.invalidate(user_id)

      calls =
        fn ->
          # `self()` here is the caller (the test process) — the
          # race-safe fetch path runs the fetcher in the caller's
          # process, not in a GenServer process, so we can use
          # `self()` directly without capturing the test pid.
          send(self(), {:fetch, System.monotonic_time()})
          [~D[2026-09-08]]
        end

      first = SelectableDatesCache.get(user_id, nil, calls)
      second = SelectableDatesCache.get(user_id, nil, calls)

      assert first == [~D[2026-09-08]]
      assert second == [~D[2026-09-08]]

      # Only one :fetch message landed — the second call hit the cache.
      assert_received {:fetch, _}
      refute_received {:fetch, _}
    end

    test "the dtu_id arg participates in the key (per-DTU slots don't collide)" do
      user_id = System.unique_integer([:positive])
      SelectableDatesCache.invalidate(user_id)

      assert SelectableDatesCache.get(user_id, nil, fn -> [~D[2026-09-01]] end) == [
               ~D[2026-09-01]
             ]

      # Same user_id, different dtu_id — must miss the cache and run
      # the fetcher (the cached nil-slot is not reused).
      assert SelectableDatesCache.get(user_id, 42, fn -> [~D[2026-09-02]] end) == [~D[2026-09-02]]
    end
  end

  describe "invalidate/1 and /2" do
    test "invalidate/1 drops every (user_id, dtu_id) slot for a user" do
      user_id = System.unique_integer([:positive])
      SelectableDatesCache.invalidate(user_id)

      SelectableDatesCache.get(user_id, nil, fn -> [~D[2026-09-01]] end)
      SelectableDatesCache.get(user_id, 42, fn -> [~D[2026-09-02]] end)

      # Both slots warm — invalidate the user and the next get
      # re-runs the fetcher for each.
      SelectableDatesCache.invalidate(user_id)

      assert SelectableDatesCache.get(user_id, nil, fn -> [~D[2026-09-03]] end) == [
               ~D[2026-09-03]
             ]

      assert SelectableDatesCache.get(user_id, 42, fn -> [~D[2026-09-04]] end) == [~D[2026-09-04]]
    end

    test "invalidate/2 drops a single (user_id, dtu_id) slot, leaves others alone" do
      user_id = System.unique_integer([:positive])
      SelectableDatesCache.invalidate(user_id)

      SelectableDatesCache.get(user_id, nil, fn -> [~D[2026-09-01]] end)
      SelectableDatesCache.get(user_id, 42, fn -> [~D[2026-09-02]] end)

      SelectableDatesCache.invalidate(user_id, 42)

      # nil-slot stays warm — second call must hit cache.
      assert SelectableDatesCache.get(user_id, nil, fn -> flunk("cache should still be warm") end) ==
               [~D[2026-09-01]]

      # 42-slot invalidated — fetcher must run again.
      assert SelectableDatesCache.get(user_id, 42, fn -> [~D[2026-09-05]] end) == [~D[2026-09-05]]
    end

    test "are no-ops on unknown / nil inputs" do
      # Should not raise, should not crash the cache.
      assert :ok = SelectableDatesCache.invalidate(nil)
      assert :ok = SelectableDatesCache.invalidate(999_999_999)
      assert :ok = SelectableDatesCache.invalidate(999_999_999, nil)
      assert :ok = SelectableDatesCache.invalidate(999_999_999, 999_999_999)
    end
  end

  describe "stale-entry fallback" do
    test "after the 30s TTL expires, get/3 re-runs the fetcher (manual clock advance via :ets rewrite)" do
      user_id = System.unique_integer([:positive])
      SelectableDatesCache.invalidate(user_id)

      SelectableDatesCache.get(user_id, nil, fn -> [~D[2026-09-01]] end)

      # Rewrite `stored_at` to a time 31 s in the past so the next
      # read sees a stale entry and triggers a refresh. We bypass
      # `invalidate/1` (which deletes the row) because we need to
      # *fake* the TTL passage, not wait 30 s in tests.
      now_ms = :erlang.system_time(:millisecond)
      stale_ms = now_ms - 31_000

      key = {user_id, nil}

      [{^key, %{value: value, stored_at: _}}] = :ets.lookup(SelectableDatesCache, key)

      :ets.insert(SelectableDatesCache, {key, %{value: value, stored_at: stale_ms}})

      # Next read must re-run the fetcher because the row is now
      # older than the 30 s TTL.
      assert SelectableDatesCache.get(user_id, nil, fn -> [~D[2026-09-09]] end) == [
               ~D[2026-09-09]
             ]
    end
  end

  describe "concurrent miss path (Tier 2 / Perf #35 race fix)" do
    test "parallel misses for the same (user_id, dtu_id) collapse to a single fetcher run" do
      # The race that motivated the refactor: a
      # `Phoenix.LiveViewTest.live/2` call invokes `mount/3` twice
      # (HTTP render + WebSocket upgrade) on different processes,
      # both racing through `list_selectable_dates/2`. The naive
      # "peek then put" pattern lets both peekers see the cache
      # row is missing and both fire `SELECT DISTINCT
      # (bucket::date) FROM readings_5m`. The race-safe `get/3`
      # collapses concurrent misses via `:ets.insert_new/2` — the
      # second arrival sees the first writer's value and polls
      # instead of re-fetching.
      user_id = System.unique_integer([:positive])
      SelectableDatesCache.invalidate(user_id)

      call_counter = :counters.new(1, [])

      task_fun = fn ->
        dates =
          SelectableDatesCache.get(user_id, nil, fn ->
            :counters.add(call_counter, 1, 1)
            send(self(), {:fetcher_ran, self()})

            [~D[2026-09-01]]
            # Tiny sleep so a second concurrent caller has time
            # to also peek-and-fetch in the naive implementation.
            |> tap(fn _ -> Process.sleep(20) end)
          end)

        # Return `dates` so `Task.await/1` gives it back — the
        # `send/2` call's return value is the message tuple, not
        # the dates we want to assert on.
        dates
      end

      task_a = Task.async(task_fun)
      task_b = Task.async(task_fun)
      task_c = Task.async(task_fun)

      results = [Task.await(task_a), Task.await(task_b), Task.await(task_c)]

      # All three callers saw the same date list.
      assert length(Enum.uniq(results)) == 1
      assert hd(results) == [~D[2026-09-01]]
      # The fetcher ran at most once — concurrent misses serialised.
      assert :counters.get(call_counter, 1) <= 1
    end
  end
end
