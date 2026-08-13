defmodule DtuAppWeb.DeviceLive.DetailsTest do
  @moduledoc """
  Tests the device-details LiveView: mounting, security (foreign
  device → redirect), the topic tree, and the live `:topic_seen`
  refresh path.

  The LiveView depends on `DtuApp.MqttBroker.TopicRegistry`
  (running in the supervision tree) for the topic snapshot, and on
  the same `dtu:uplink` PubSub topic the parser consumes — we drive
  the registry by feeding it the same tuple shape the broker emits.
  """

  use DtuAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import DtuApp.DevicesFixtures

  alias DtuApp.Devices
  alias DtuApp.MqttBroker.TopicRegistry
  alias DtuAppWeb.DeviceLive.Details

  setup :register_and_log_in_user

  setup do
    :ok = TopicRegistry.clear()
    on_exit(fn -> TopicRegistry.clear() end)
    :ok
  end

  describe "mount / security" do
    test "renders the device name + base_topic for an owned device", %{conn: conn, user: user} do
      dtu =
        device_fixture(user, %{
          name: "Roof Inverter",
          kind: "opendtu",
          base_topic: "solar"
        })

      {:ok, _view, html} = live(conn, ~p"/devices/#{dtu.id}/details")

      assert html =~ "Roof Inverter"
      assert html =~ "solar"
    end

    test "redirects to /devices for a non-owned id", %{conn: conn, user: _user} do
      other_user = DtuApp.AccountsFixtures.user_fixture()
      _dtu = device_fixture(other_user, %{name: "Foreign"})

      # A valid integer id that doesn't belong to `user`.
      assert {:error, {:live_redirect, %{to: "/devices"}}} =
               live(conn, ~p"/devices/99999999/details")
    end

    test "redirects to /devices for a non-integer id", %{conn: conn} do
      # Phoenix.LiveView routes the malformed id with a 302 redirect
      # to /devices (the live_redirect on mount's fallback). Pin the
      # redirect target so the user doesn't end up on an empty
      # `/devices/abc/details` page.
      conn = get(conn, "/devices/abc/details")
      assert conn.status == 302
      assert conn |> Phoenix.ConnTest.redirected_to() =~ "/devices"
    end
  end

  describe "topic tree" do
    test "renders an empty-state when no topics have been seen yet", %{conn: conn, user: user} do
      dtu = device_fixture(user, %{name: "Quiet DTU", kind: "opendtu"})

      {:ok, _view, html} = live(conn, ~p"/devices/#{dtu.id}/details")

      assert html =~ "Waiting for live data"
    end

    test "renders each captured topic with its payload", %{conn: conn, user: user} do
      dtu =
        device_fixture(user, %{
          name: "Talkative DTU",
          kind: "opendtu",
          base_topic: "solar"
        })

      # Drive the registry with a synthetic uplink — the same tuple
      # shape the broker's `handle_publish/4` callback emits.
      msg = {:uplink, "client_1", device_for(dtu), "solar/HM1/0/power", "245.5"}
      TopicRegistry.handle_info(msg, %{})

      {:ok, _view, html} = live(conn, ~p"/devices/#{dtu.id}/details")

      # The base_topic (`solar`) is stripped — the tree starts at
      # the firmware's namespace segment (`HM1`).
      assert html =~ "HM1"
      # The leaf segment + payload both appear.
      assert html =~ "power"
      assert html =~ "245.5"
      # The topic-count badge in the section header.
      assert html =~ "1 topic"
      refute has_element?(_view, "[data-test=topic-node-solar]")
    end

    test "tree builds a hierarchical view (nested topics render as branches)",
         %{conn: conn, user: user} do
      dtu =
        device_fixture(user, %{
          name: "Nested DTU",
          kind: "opendtu",
          base_topic: "solar"
        })

      info = device_for(dtu)

      for {topic, payload} <- [
            {"solar/HM1", "root"},
            {"solar/HM1/0/power", "245"},
            {"solar/HM1/0/yieldday", "100"},
            {"solar/HM1/realtime/data", "{}"}
          ] do
        TopicRegistry.handle_info(
          {:uplink, "client_1", info, topic, payload},
          %{}
        )
      end

      {:ok, _view, html} = live(conn, ~p"/devices/#{dtu.id}/details")

      # Branches rendered for intermediate segments.
      assert html =~ "HM1"
      # Leaves rendered for terminal segments.
      assert html =~ "power"
      assert html =~ "yieldday"
      assert html =~ "realtime"
    end

    test "JSON payloads pretty-print", %{conn: conn, user: user} do
      dtu =
        device_fixture(user, %{
          name: "JSON DTU",
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      json_payload =
        ~s({"a_energy":{"total":1234.5},"b_energy":{"total":6789.0}})

      TopicRegistry.handle_info(
        {:uplink, "client_1", device_for(dtu), "shellies/shellyplus3em/status/em:0",
         json_payload},
        %{}
      )

      {:ok, _view, html} = live(conn, ~p"/devices/#{dtu.id}/details")

      # JSON pretty-printing inserts newlines + indentation; the
      # rendered HTML must show the structure rather than the raw
      # single-line blob.
      assert html =~ "&quot;a_energy&quot;"
      assert html =~ "&quot;total&quot;: 1234.5"
      # Negative: the raw unindented blob should NOT appear (HEEx
      # HTML-escapes the { and } but doesn't insert newlines on its
      # own).
      refute html =~ "{&quot;a_energy&quot;"
    end
  end

  describe "live updates" do
    test "a :topic_seen broadcast refreshes the topic snapshot",
         %{conn: conn, user: user} do
      dtu =
        device_fixture(user, %{
          name: "Live DTU",
          kind: "opendtu",
          base_topic: "solar"
        })

      {:ok, view, html} = live(conn, ~p"/devices/#{dtu.id}/details")
      assert html =~ "Waiting for live data"

      # Feed a fresh uplink + broadcast — the LV re-fetches the
      # snapshot on the broadcast and re-renders.
      info = device_for(dtu)

      TopicRegistry.handle_info(
        {:uplink, "client_1", info, "solar/HM1/0/power", "100.0"},
        %{}
      )

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        TopicRegistry.topics_topic(),
        {:topic_seen, dtu.id}
      )

      rendered? =
        Enum.reduce_while(1..20, false, fn _i, _acc ->
          current = render(view)

          if current =~ "100.0" do
            {:halt, true}
          else
            Process.sleep(50)
            {:cont, false}
          end
        end)

      assert rendered?,
             "expected the topic snapshot to refresh after :topic_seen broadcast"
    end

    test "a :topic_seen broadcast for a different dtu is ignored",
         %{conn: conn, user: user} do
      dtu = device_fixture(user, %{name: "Isolated DTU", kind: "opendtu"})

      {:ok, view, _html} = live(conn, ~p"/devices/#{dtu.id}/details")

      # Broadcast for a non-existent DTU id. The LV's handle_info
      # clause short-circuits on `device.id == dtu_id`.
      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        TopicRegistry.topics_topic(),
        {:topic_seen, 99_999}
      )

      # No crash + the empty state stays put (Process.sleep + render
      # to confirm no spurious re-render).
      Process.sleep(50)
      assert render(view) =~ "Waiting for live data"
    end
  end

  describe "error panel" do
    test "renders the 'no errors' empty state when the device is healthy",
         %{conn: conn, user: user} do
      dtu = device_fixture(user, %{name: "Healthy DTU", kind: "opendtu"})

      {:ok, _view, html} = live(conn, ~p"/devices/#{dtu.id}/details")

      assert html =~ "No errors recorded for this DTU yet."
    end

    test "renders error groups for a misconfigured device",
         %{conn: conn, user: user} do
      dtu =
        device_fixture(user, %{
          name: "Misconfigured DTU",
          kind: "shelly3em",
          base_topic: "shellies/shellyplus3em"
        })

      :ok =
        Devices.record_dtu_error(
          dtu.id,
          ~s|Shelly topic mismatch (expected "shellies/shellyplus3em", got "shellyplus3em-aabbcc/status/em:0")|
        )

      {:ok, _view, html} = live(conn, ~p"/devices/#{dtu.id}/details")

      # The kind chip + the topic chip + the per-message count all
      # appear — same vocabulary as the index's expansion panel.
      assert html =~ "Shelly"
      assert html =~ "shellies/shellyplus3em"
      assert html =~ "1 occurrence"
    end

    test "a :dtu_error broadcast refreshes the error panel",
         %{conn: conn, user: user} do
      dtu = device_fixture(user, %{name: "Errors Live", kind: "opendtu"})

      {:ok, view, html} = live(conn, ~p"/devices/#{dtu.id}/details")

      # Empty state on mount.
      assert html =~ "No errors recorded for this DTU yet."

      :ok = Devices.record_dtu_error(dtu.id, "OpenDTU uplink rejected")

      Phoenix.PubSub.broadcast(
        DtuApp.PubSub,
        DtuApp.MqttBroker.Telemetry.status_topic(),
        {:dtu_error, dtu.id}
      )

      found? =
        Enum.reduce_while(1..20, false, fn _i, _acc ->
          current = render(view)

          if current =~ "OpenDTU uplink rejected" do
            {:halt, true}
          else
            Process.sleep(50)
            {:cont, false}
          end
        end)

      assert found?,
             "expected the error panel to refresh after :dtu_error broadcast"
    end
  end

  describe "build_tree/2 (unit)" do
    test "groups flat topics into a sorted tree" do
      topics = %{
        "solar/HM1/0/power" => {"p", ~U[2026-01-01 00:00:00Z]},
        "solar/HM1/0/yieldday" => {"y", ~U[2026-01-01 00:00:00Z]},
        "solar/HM1/realtime" => {"r", ~U[2026-01-01 00:00:00Z]}
      }

      tree = Details.build_tree(topics, base_topic: "solar")

      # One root node for `HM1`.
      assert length(tree) == 1
      [hm1] = tree
      assert hm1.segment == "HM1"
      assert hm1.kind == :branch

      # Children: `0` (with two leaves inside) and `realtime` (one leaf).
      child_segments = Enum.map(hm1.children, & &1.segment)
      assert "0" in child_segments
      assert "realtime" in child_segments
    end

    test "strips the base_topic prefix" do
      topics = %{"solar/HM1/0/power" => {"p", ~U[2026-01-01 00:00:00Z]}}

      [hm1] = Details.build_tree(topics, base_topic: "solar")
      # The root is `HM1`, NOT `solar/HM1`.
      assert hm1.segment == "HM1"
    end

    test "returns [] when the topic map is empty" do
      assert Details.build_tree(%{}, base_topic: "solar") == []
    end

    test "returns [] for non-map input (defensive)" do
      assert Details.build_tree(nil) == []
    end
  end

  # Synthetic `device_info` matching the broker's `handle_publish/4`
  # callback's `state.device` field. `id` distinguishes topics across
  # DTUs; `kind` / `base_topic` are present so the parser can also
  # consume the same tuple without crashing.
  defp device_for(dtu) do
    %{
      id: dtu.id,
      user_id: dtu.user_id,
      kind: :opendtu,
      base_topic: dtu.base_topic,
      name: dtu.name
    }
  end
end
