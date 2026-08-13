defmodule DtuApp.MqttBroker.TopicRegistryTest do
  @moduledoc """
  Exercises the live-topic buffer that powers the device-details
  LiveView. The GenServer subscribes to the same `dtu:uplink` PubSub
  topic the parser consumes, so we drive it by feeding the same
  tuple shape the broker emits.

  The registry is a singleton GenServer named `DtuApp.MqttBroker.TopicRegistry`.
  Tests start it under `start_supervised!/1` (cleared automatically
  between tests) and feed it synthetic uplink tuples via
  `handle_info/2` — the same path the broker's `handle_publish/4`
  callback uses in production.
  """

  use DtuApp.DataCase, async: false

  alias DtuApp.MqttBroker.TopicRegistry

  setup do
    # The registry is started in the application's main supervision
    # tree, alongside `Telemetry`. Tests use `clear/0` to wipe the
    # in-memory cache between cases so we don't leak topics across
    # tests.
    :ok = TopicRegistry.clear()
    on_exit(fn -> TopicRegistry.clear() end)
    :ok
  end

  # Synthetic `device_info` matching the broker's `handle_publish/4`
  # callback's `state.device` field. `id` distinguishes topics across
  # DTUs; `kind` / `base_topic` are present so the parser can also
  # consume the same tuple without crashing.
  defp device_info(id) do
    %{
      id: id,
      user_id: 1,
      kind: :opendtu,
      base_topic: "solar",
      name: "DTU-#{id}"
    }
  end

  describe "uplink capture" do
    test "captures a topic + payload from an uplink" do
      msg = {:uplink, "client_1", device_info(100), "solar/HM1/0/power", "245.5"}
      assert {:noreply, %{}} = TopicRegistry.handle_info(msg, %{})

      topics = TopicRegistry.get_topics_for(100)
      assert Map.has_key?(topics, "solar/HM1/0/power")

      assert {"245.5", %DateTime{}} = topics["solar/HM1/0/power"]
    end

    test "captures multiple topics for one DTU" do
      for {topic, payload} <- [
            {"solar/HM1/0/power", "245.5"},
            {"solar/HM1/realtime/data", "{\"AC\":{}}"},
            {"solar/HM1/0/yieldday", "4320"}
          ] do
        msg = {:uplink, "client_1", device_info(100), topic, payload}
        TopicRegistry.handle_info(msg, %{})
      end

      topics = TopicRegistry.get_topics_for(100)
      assert map_size(topics) == 3
      assert {"245.5", _} = topics["solar/HM1/0/power"]
      assert {"{\"AC\":{}}", _} = topics["solar/HM1/realtime/data"]
      assert {"4320", _} = topics["solar/HM1/0/yieldday"]
    end

    test "overwrites the payload when the same topic is published again" do
      msg1 = {:uplink, "client_1", device_info(100), "solar/HM1/0/power", "100.0"}
      msg2 = {:uplink, "client_1", device_info(100), "solar/HM1/0/power", "200.0"}

      TopicRegistry.handle_info(msg1, %{})
      assert {"100.0", _} = TopicRegistry.get_topics_for(100)["solar/HM1/0/power"]

      TopicRegistry.handle_info(msg2, %{})
      assert {"200.0", _} = TopicRegistry.get_topics_for(100)["solar/HM1/0/power"]
    end

    test "scopes topics by DTU id — different DTUs don't share state" do
      TopicRegistry.handle_info(
        {:uplink, "client_1", device_info(100), "solar/HM1/0/power", "100"},
        %{}
      )

      TopicRegistry.handle_info(
        {:uplink, "client_1", device_info(200), "solar/HM2/0/power", "200"},
        %{}
      )

      assert {"100", _} = TopicRegistry.get_topics_for(100)["solar/HM1/0/power"]
      assert {"200", _} = TopicRegistry.get_topics_for(200)["solar/HM2/0/power"]
      # No cross-contamination.
      refute Map.has_key?(TopicRegistry.get_topics_for(100), "solar/HM2/0/power")
    end

    test "ignores pre-auth uplinks (device_info is nil)" do
      msg = {:uplink, "client_anon", nil, "solar/HM1/0/power", "100"}
      assert {:noreply, %{}} = TopicRegistry.handle_info(msg, %{})

      # Nothing for any DTU id since the uplink wasn't tied to one.
      assert TopicRegistry.get_topics_for(1) == %{}
    end

    test "truncates oversized payloads" do
      # Cap is 4096 bytes; append `…` (U+2026, 3 bytes in UTF-8) after
      # the cut. Use a payload that's exactly 1 byte over the cap so
      # the truncation is unambiguous.
      oversized = String.duplicate("x", 4097)

      msg = {:uplink, "client_1", device_info(100), "solar/HM1/firmware", oversized}
      TopicRegistry.handle_info(msg, %{})

      {stored, _received_at} = TopicRegistry.get_topics_for(100)["solar/HM1/firmware"]
      # The first 4096 bytes + the trailing 3-byte `…` → 4099 bytes.
      assert byte_size(stored) == 4099
      assert String.ends_with?(stored, "…")
    end
  end

  describe "PubSub fan-out" do
    test "broadcasts :topic_seen on the topics PubSub topic after every uplink" do
      Phoenix.PubSub.subscribe(DtuApp.PubSub, TopicRegistry.topics_topic())

      msg = {:uplink, "client_1", device_info(100), "solar/HM1/0/power", "100"}
      TopicRegistry.handle_info(msg, %{})

      assert_receive {:topic_seen, 100}, 200
    end

    test "topic_seen event carries the affected dtu_id only" do
      Phoenix.PubSub.subscribe(DtuApp.PubSub, TopicRegistry.topics_topic())

      msg = {:uplink, "client_1", device_info(42), "solar/HM1/0/power", "100"}
      TopicRegistry.handle_info(msg, %{})

      assert_receive {:topic_seen, 42}, 200

      # No other device-id event in the mailbox (asynchronous,
      # but only one uplink was sent so only one event arrives).
      refute_receive {:topic_seen, _other}, 50
    end
  end

  describe "topic-count cap" do
    test "evicts the oldest topic when the per-DTU cap is exceeded" do
      # The cap is 200. Pre-populate exactly 200 entries with
      # monotonically growing `received_at` timestamps, then trigger
      # one more uplink through the public path — the cap-eviction
      # logic must drop the smallest-timestamp entry so the map
      # returns to 200 entries.
      #
      # We seed timestamps directly via ETS because `DtuApp.Time.utc_now_usec/0`
      # rounds to the DB's microsecond clock and a fast loop can
      # collapse multiple inserts onto the same µs — making the FIFO
      # eviction non-deterministic. The registry's public surface
      # always uses `utc_now_usec/0`; this test only bypasses it to
      # exercise the eviction policy itself.
      base = DtuApp.Time.utc_now_usec()

      :ets.insert(
        TopicRegistry.Topics,
        {100,
         Map.new(0..199, fn i ->
           # `i` µs after `base` — 200 distinct microseconds.
           {"solar/HM1/#{i}", {to_string(i), DateTime.add(base, i, :microsecond)}}
         end)}
      )

      # One more uplink → cap exceeded → oldest evicted.
      msg = {:uplink, "client_1", device_info(100), "solar/HM1/new", "new"}
      TopicRegistry.handle_info(msg, %{})

      topics = TopicRegistry.get_topics_for(100)
      assert map_size(topics) == 200

      # The first topic (`0`) had the smallest timestamp, must be
      # evicted to make room.
      refute Map.has_key?(topics, "solar/HM1/0")

      # The newest topics are present.
      assert Map.has_key?(topics, "solar/HM1/new")
      assert Map.has_key?(topics, "solar/HM1/199")
      assert Map.has_key?(topics, "solar/HM1/198")
    end

    test "evicts the lex-smallest topic when multiple entries share a timestamp" do
      # Regression test for a CI flake: when multiple entries
      # share a `received_at` (a fast uplink burst that lands on
      # the same DB clock µs, or a test seeding via ETS with
      # truncated DateTime precision), `Enum.min_by/2`'s default
      # tiebreak is map iteration order — non-deterministic across
      # Erlang versions. The eviction uses `{received_at, topic}`
      # as the sort key so the lex-smallest topic wins among ties,
      # keeping the "FIFO within a µs" contract stable.
      #
      # Seed 201 entries all with the *same* `received_at`. After
      # one more uplink the map holds 202 entries; the eviction
      # loop drops 2 entries — both from the tied set, in lex order
      # (`solar/HM1/00`, then `solar/HM1/01`). The new entry has a
      # strictly-later `received_at` and survives.
      same = DateTime.utc_now() |> DateTime.truncate(:second)

      :ets.insert(
        TopicRegistry.Topics,
        {200,
         Map.new(0..200, fn i ->
           # Pad to two digits so `"solar/HM1/00"` < `"solar/HM1/01"`
           # < ... < `"solar/HM1/99"` < `"solar/HM1/100"` < ...
           # by lexical comparison. With identical timestamps, the
           # tiebreaker picks the lex-smallest: `"solar/HM1/00"`.
           {"solar/HM1/#{Integer.to_string(i) |> String.pad_leading(2, "0")}",
            {to_string(i), same}}
         end)}
      )

      msg = {:uplink, "client_1", device_info(200), "solar/HM1/new", "new"}
      TopicRegistry.handle_info(msg, %{})

      topics = TopicRegistry.get_topics_for(200)
      assert map_size(topics) == 200

      # The two lex-smallest tied entries are gone.
      refute Map.has_key?(topics, "solar/HM1/00")
      refute Map.has_key?(topics, "solar/HM1/01")

      # The new entry survives (its later timestamp keeps it).
      assert Map.has_key?(topics, "solar/HM1/new")

      # The third-smallest tied entry is the smallest survivor —
      # pin its presence so a regression that drops arbitrary
      # tied entries would also fail here.
      assert Map.has_key?(topics, "solar/HM1/02")
    end
  end

  describe "topic staleness (prune)" do
    test "drops entries older than the staleness window" do
      now = DtuApp.Time.utc_now()

      # Insert a topic with a backdated `received_at`. We can't do
      # this directly via the public API (the registry always uses
      # the current clock), so we hit the ETS table by hand to seed
      # an old entry and then trigger a synchronous prune via the
      # `prune_now/0` test hook.
      :ets.insert(
        TopicRegistry.Topics,
        {200,
         %{
           "old/topic" => {"old_payload", DateTime.add(now, -3600, :second)},
           "fresh/topic" => {"fresh_payload", now}
         }}
      )

      :ok = TopicRegistry.prune_now()

      topics = TopicRegistry.get_topics_for(200)
      # Stale entry was pruned.
      refute Map.has_key?(topics, "old/topic")
      # Fresh entry survives.
      assert topics["fresh/topic"] == {"fresh_payload", now}
    end

    test "drops the per-DTU row entirely when every entry is stale" do
      now = DtuApp.Time.utc_now()

      :ets.insert(
        TopicRegistry.Topics,
        {300,
         %{
           "stale/only" => {"payload", DateTime.add(now, -3600, :second)}
         }}
      )

      :ok = TopicRegistry.prune_now()

      # The ETS row for this DTU was deleted — `get_topics_for/1`
      # returns the empty-map default.
      assert TopicRegistry.get_topics_for(300) == %{}
      assert :ets.lookup(TopicRegistry.Topics, 300) == []
    end
  end

  describe "snapshot reads" do
    test "get_topics_for/1 returns an empty map for an unknown dtu_id" do
      assert TopicRegistry.get_topics_for(99_999) == %{}
    end

    test "get_topics_for/1 is safe for non-integer arguments" do
      assert TopicRegistry.get_topics_for(nil) == %{}
      assert TopicRegistry.get_topics_for("not-a-number") == %{}
    end
  end

  describe "clear/0" do
    test "wipes all buffered topics" do
      TopicRegistry.handle_info(
        {:uplink, "client_1", device_info(100), "solar/HM1/0/power", "100"},
        %{}
      )

      assert map_size(TopicRegistry.get_topics_for(100)) == 1
      :ok = TopicRegistry.clear()
      assert TopicRegistry.get_topics_for(100) == %{}
    end
  end
end
