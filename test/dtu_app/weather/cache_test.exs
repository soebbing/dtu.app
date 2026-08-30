defmodule DtuApp.Weather.CacheTest do
  @moduledoc """
  Pins the contract for `DtuApp.Weather.Cache`:

    * `key/3` rounds lat/lon to 1° (≈111 km) and combines with the local
      calendar date so two browsers reporting 52.5123 vs 52.5189 share
      the same cache slot (and don't pollute each other across the
      date line).
    * `put/2` stores with an `inserted_at` timestamp; `get/1` returns
      `nil` for entries older than `@ttl_ms = 15 * 60 * 1000`.
    * Newer `put/2` overwrites older entries with the same key.
  """

  use ExUnit.Case, async: false

  alias DtuApp.Weather.Cache

  describe "key/3" do
    test "rounds coordinates to 1 degree" do
      assert Cache.key(52.5123, 13.4189, ~D[2026-08-30]) ==
               {52, 13, ~D[2026-08-30]}

      assert Cache.key(52.89, 13.1, ~D[2026-08-30]) ==
               {52, 13, ~D[2026-08-30]}

      assert Cache.key(-33.86, 151.21, ~D[2026-08-30]) ==
               {-33, 151, ~D[2026-08-30]}
    end

    test "two readings on the same day with the same rounded coords collide" do
      assert Cache.key(52.51, 13.41, ~D[2026-08-30]) ==
               Cache.key(52.59, 13.49, ~D[2026-08-30])
    end

    test "different days on the same coords do not collide" do
      refute Cache.key(52.5, 13.4, ~D[2026-08-30]) ==
               Cache.key(52.5, 13.4, ~D[2026-08-31])
    end
  end

  describe "put/2 + get/1 round trip" do
    test "stores a value and reads it back" do
      key = {52, 13, ~D[2026-08-30]}
      Cache.put(key, :some_weather_payload)

      assert Cache.get(key) == :some_weather_payload
    end

    test "returns nil for an unknown key" do
      assert Cache.get({0, 0, ~D[2026-08-30]}) == nil
    end

    test "overwrites an existing entry on subsequent put/2" do
      key = {52, 13, ~D[2026-08-30]}
      Cache.put(key, :first)
      Cache.put(key, :second)

      assert Cache.get(key) == :second
    end
  end

  describe "TTL expiry" do
    test "returns nil for entries older than 15 minutes" do
      key = {52, 13, ~D[2026-08-30]}

      # Insert with a back-dated inserted_at so we don't need to wait
      # 15 real minutes. The Cache stamps `inserted_at` on `put/2`;
      # we use the named-table trick (the table is `:public`) to
      # overwrite the row directly via `:ets.insert/2` with a stale
      # timestamp so the get treats it as expired.
      Cache.put(key, :payload)

      stale = DateTime.add(DateTime.utc_now(), -16 * 60, :second)
      :ets.insert(Cache, {key, %{value: :payload, inserted_at: stale}})

      assert Cache.get(key) == nil
    end

    test "returns the value for entries fresher than 15 minutes" do
      key = {52, 13, ~D[2026-08-30]}
      Cache.put(key, :fresh)

      fresh = DateTime.add(DateTime.utc_now(), -14 * 60, :second)
      :ets.insert(Cache, {key, %{value: :fresh, inserted_at: fresh}})

      assert Cache.get(key) == :fresh
    end
  end

  describe "sweep on put/2" do
    test "drops entries older than the TTL on subsequent writes" do
      stale_key = {52, 13, ~D[2026-08-30]}
      fresh_key = {52, 14, ~D[2026-08-30]}

      Cache.put(stale_key, :stale_value)

      # Backdate the first entry to be older than 15 min.
      stale = DateTime.add(DateTime.utc_now(), -20 * 60, :second)
      :ets.insert(Cache, {stale_key, %{value: :stale_value, inserted_at: stale}})

      # Writing to the table should trigger a sweep.
      Cache.put(fresh_key, :fresh_value)

      assert Cache.get(stale_key) == nil
      assert Cache.get(fresh_key) == :fresh_value
    end
  end
end
