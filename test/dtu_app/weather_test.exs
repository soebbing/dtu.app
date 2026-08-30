defmodule DtuApp.WeatherTest do
  @moduledoc """
  Pins the contract for `DtuApp.Weather` — the public facade that
  orchestrates `Weather.Cache` + `Weather.OpenMeteo`.

  The contract is "graceful degradation": the dashboard must never
  break over weather. So:

    * nil lat / lon → `nil` (no HTTP, no cache write)
    * cache hit → cached payload, no HTTP
    * cache miss + 200 → fetch + cache + return
    * cache miss + 4xx → `nil` (caller falls back to "no data")
    * `current_condition/2` buckets the most-recent cloud-cover
      reading into `:clear | :partly_cloudy | :mostly_cloudy |
      :overcast`. Buckets are pinned so the WMO-style label on the
      card stays stable.
  """

  use ExUnit.Case, async: false

  alias DtuApp.Weather

  setup do
    # Each test gets a fresh cache so reads/writes don't bleed across
    # tests (Cache is backed by a singleton ETS table).
    :ets.delete_all_objects(DtuApp.Weather.Cache)
    :ok
  end

  describe "cloud_cover_for/2" do
    test "nil latitude returns nil without HTTP or cache write" do
      assert Weather.cloud_cover_for(nil, 13.41, past_days: 1) == nil
      # No entries were written.
      assert :ets.tab2list(DtuApp.Weather.Cache) == []
    end

    test "nil longitude returns nil without HTTP or cache write" do
      assert Weather.cloud_cover_for(52.52, nil, past_days: 1) == nil
      assert :ets.tab2list(DtuApp.Weather.Cache) == []
    end

    test "cache hit returns the cached payload without HTTP" do
      key = DtuApp.Weather.Cache.key(52.52, 13.41, ~D[2026-08-30])
      DtuApp.Weather.Cache.put(key, {:cached, :payload})

      # Even if Req.Test would return fresh data, a hit must short-circuit
      # so a flaky network doesn't replace a fresh cache.
      assert Weather.cloud_cover_for(52.52, 13.41, past_days: 1) ==
               {:cached, :payload}
    end

    test "cache miss + Open-Meteo 200 fetches and caches the payload" do
      Req.Test.stub(DtuApp.Weather.OpenMeteo, fn conn ->
        body = %{
          "hourly" => %{
            # Open-Meteo's real-world shape: compact ISO-8601, no
            # seconds, no offset (UTC by spec).
            "time" => [
              "2026-08-29T00:00",
              "2026-08-29T01:00",
              "2026-08-29T02:00"
            ],
            "cloud_cover" => [10, 30, 60]
          }
        }

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      result = Weather.cloud_cover_for(52.52, 13.41, past_days: 1)

      assert {:ok, %{hourly: %{time: [_t1, _t2, _t3], cloud_cover: [10, 30, 60]}}} =
               result

      key = DtuApp.Weather.Cache.key(52.52, 13.41, ~D[2026-08-30])

      assert %{hourly: %{cloud_cover: [10, 30, 60]}} =
               DtuApp.Weather.Cache.get(key)
    end

    test "cache miss + Open-Meteo 4xx returns nil (graceful degradation)" do
      Req.Test.stub(DtuApp.Weather.OpenMeteo, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(503, ~s({"error": "down"}))
      end)

      assert Weather.cloud_cover_for(52.52, 13.41, past_days: 1) == nil
    end
  end

  describe "current_condition/3" do
    test "nil coords returns nil" do
      assert Weather.current_condition(nil, 13.41) == nil
      assert Weather.current_condition(52.52, nil) == nil
    end

    test "0% cloud cover → :clear" do
      assert Weather.bucket_condition(0) == :clear
      assert Weather.bucket_condition(25) == :clear
    end

    test "25..50% cloud cover → :partly_cloudy" do
      assert Weather.bucket_condition(26) == :partly_cloudy
      assert Weather.bucket_condition(50) == :partly_cloudy
    end

    test "50..85% cloud cover → :mostly_cloudy" do
      assert Weather.bucket_condition(51) == :mostly_cloudy
      assert Weather.bucket_condition(85) == :mostly_cloudy
    end

    test "85+% cloud cover → :overcast" do
      assert Weather.bucket_condition(86) == :overcast
      assert Weather.bucket_condition(100) == :overcast
    end

    test "current_condition/2 picks the most-recent reading from the cache" do
      key = DtuApp.Weather.Cache.key(52.52, 13.41, ~D[2026-08-30])

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      recent_time = now
      earlier_time = DateTime.add(now, -1 * 3600, :second)

      DtuApp.Weather.Cache.put(key, %{
        hourly: %{
          time: [earlier_time, recent_time],
          cloud_cover: [10, 90]
        }
      })

      assert Weather.current_condition(52.52, 13.41) == :overcast
    end
  end
end
