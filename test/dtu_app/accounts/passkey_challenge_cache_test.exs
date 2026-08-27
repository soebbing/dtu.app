defmodule DtuApp.Accounts.PasskeyChallengeCacheTest do
  use ExUnit.Case, async: false

  alias DtuApp.Accounts.PasskeyChallengeCache

  setup do
    # Each test starts with an empty cache. The GenServer is app-wide,
    # so we drain it by sweeping manually.
    sweep_all()
    :ok
  end

  describe "put/2 + fetch_and_delete/1" do
    test "round-trips an entry" do
      PasskeyChallengeCache.put("req-1", %{challenge: <<1, 2, 3>>, kind: :registration})
      assert {:ok, entry} = PasskeyChallengeCache.fetch_and_delete("req-1")
      assert entry.challenge == <<1, 2, 3>>
      assert entry.kind == :registration
      assert %DateTime{} = entry.inserted_at
    end

    test "fetch_and_delete is one-shot" do
      PasskeyChallengeCache.put("req-1", %{challenge: <<1>>, kind: :authentication})
      assert {:ok, _} = PasskeyChallengeCache.fetch_and_delete("req-1")
      assert {:error, :not_found} = PasskeyChallengeCache.fetch_and_delete("req-1")
    end

    test "returns :not_found for unknown key" do
      assert {:error, :not_found} = PasskeyChallengeCache.fetch_and_delete("nope")
    end
  end

  describe "TTL sweep" do
    test "entries older than TTL are pruned on the next put" do
      # Backdate an entry by directly inserting into the ETS table.
      table = :ets.whereis(PasskeyChallengeCache)
      old = DateTime.add(DateTime.utc_now(), -10 * 60, :second)
      :ets.insert(table, {"stale", %{kind: :registration, inserted_at: old}})

      # The next put triggers sweep.
      PasskeyChallengeCache.put("fresh", %{kind: :registration})

      assert {:error, :not_found} = PasskeyChallengeCache.fetch_and_delete("stale")
      assert {:ok, _} = PasskeyChallengeCache.fetch_and_delete("fresh")
    end

    test "recent entries survive a put" do
      PasskeyChallengeCache.put("recent", %{kind: :registration})
      PasskeyChallengeCache.put("newer", %{kind: :authentication})
      assert {:ok, _} = PasskeyChallengeCache.fetch_and_delete("recent")
      assert {:ok, _} = PasskeyChallengeCache.fetch_and_delete("newer")
    end
  end

  defp sweep_all do
    table = :ets.whereis(PasskeyChallengeCache)
    :ets.delete_all_objects(table)
  end
end
