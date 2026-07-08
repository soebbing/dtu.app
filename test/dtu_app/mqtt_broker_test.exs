defmodule DtuApp.MqttBrokerTest do
  use DtuApp.DataCase

  import DtuApp.AccountsFixtures
  import DtuApp.DevicesFixtures

  alias DtuApp.MqttBroker.Credentials
  alias DtuApp.MqttBroker.Telemetry
  alias DtuApp.Devices

  setup do
    # The broker and its Credentials cache are gated off in the test env, so
    # start the cache here for the auth/parser tests that need it.
    start_supervised!(DtuApp.MqttBroker.Credentials)
    user = user_fixture()
    {:ok, user: user}
  end

  describe "MQTT Credentials & Authentication" do
    test "authenticates with valid username and password", %{user: user} do
      dtu = device_fixture(user, %{mqtt_username: "my-dtu", mqtt_password: "supersecure"})

      # Seed cache
      Credentials.refresh(dtu.mqtt_username)

      assert {:ok, cached_device} = Credentials.verify("my-dtu", "supersecure")
      assert cached_device.id == dtu.id
      assert cached_device.user_id == user.id
    end

    test "fails verification with invalid password", %{user: user} do
      dtu = device_fixture(user, %{mqtt_username: "my-dtu2", mqtt_password: "supersecure"})

      Credentials.refresh(dtu.mqtt_username)

      assert {:error, :unauthorized} = Credentials.verify("my-dtu2", "wrongpassword")
    end

    test "fails verification with non-existent username" do
      assert {:error, :unauthorized} = Credentials.verify("unknown", "any")
    end
  end

  describe "Telemetry Ingestion & DB Storage" do
    test "parses OpenDTU payload and saves a reading", %{user: user} do
      dtu =
        device_fixture(user, %{kind: "opendtu", mqtt_username: "opendtu-1", base_topic: "solar"})

      Credentials.refresh(dtu.mqtt_username)

      # Build simulated authenticated device info
      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :opendtu,
        base_topic: "solar",
        name: dtu.name
      }

      payload = ~s({
        "AC": {
          "Power": {
            "v": 245.5
          },
          "Frequency": {
            "v": 50.1
          }
        },
        "DC": {
          "Power": {
            "v": 250.0
          }
        },
        "yield_day": 4320.0,
        "yield_total": 125000.0,
        "INV": {
          "Temperature": {
            "v": 35.5
          }
        },
        "status": {
          "producing": 1,
          "reachable": 1
        }
      })

      topic = "solar/123456789/realtime/data"

      msg = {:uplink, "client_1", device_info, topic, payload}
      {:noreply, _new_state} = Telemetry.handle_info(msg, %{ahoy_buffers: %{}})

      # Assert reading is inserted
      assert [reading] = Devices.list_recent_readings(user, dtu.id)
      assert reading.inverter_serial == "123456789"
      assert reading.ac_power == 245.5
      assert reading.frequency == 50.1
      assert reading.yield_day == 4320.0
      assert reading.producing == true
    end

    test "parses AhoyDTU payload, buffers, and saves a reading on ac_power trigger", %{user: user} do
      dtu =
        device_fixture(user, %{
          kind: "ahoydtu",
          mqtt_username: "ahoydtu-1",
          base_topic: "inverter"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :ahoydtu,
        base_topic: "inverter",
        name: dtu.name
      }

      state = %{ahoy_buffers: %{}}

      # Send temperature
      msg1 = {:uplink, "client_2", device_info, "inverter/balcony-inv/ch0/Temp", "34.5"}
      {:noreply, state} = Telemetry.handle_info(msg1, state)

      # Send yield_day
      msg2 = {:uplink, "client_2", device_info, "inverter/balcony-inv/ch0/YieldDay", "1.23"}
      {:noreply, state} = Telemetry.handle_info(msg2, state)

      # Assert no reading in DB yet
      assert [] == Devices.list_recent_readings(user, dtu.id)

      # Send active power (the trigger)
      msg3 = {:uplink, "client_2", device_info, "inverter/balcony-inv/ch0/P_AC", "150.0"}
      {:noreply, _state} = Telemetry.handle_info(msg3, state)

      # Assert reading in DB now with all buffered values!
      assert [reading] = Devices.list_recent_readings(user, dtu.id)
      assert reading.inverter_serial == "balcony-inv"
      assert reading.ac_power == 150.0
      assert reading.temperature == 34.5
      assert reading.yield_day == 1.23
    end

    test "parses AhoyDTU JSON-layout per-channel payload in one uplink", %{user: user} do
      dtu =
        device_fixture(user, %{
          kind: "ahoydtu",
          mqtt_username: "ahoydtu-json",
          base_topic: "inverter"
        })

      Credentials.refresh(dtu.mqtt_username)

      device_info = %{
        id: dtu.id,
        user_id: user.id,
        kind: :ahoydtu,
        base_topic: "inverter",
        name: dtu.name
      }

      # AhoyDTU "JSON" setting: one JSON object per channel. ch0 carries the
      # AC-side values plus the calculated DC power total.
      payload =
        ~s({"U_AC": 233.3, "P_AC": 320.0, "F_AC": 50.01, "Temp": 41.2,
            "YieldDay": 2.5, "YieldTotal": 980.0, "P_DC": 330.0})

      msg = {:uplink, "client_json", device_info, "inverter/balcony-inv/ch0", payload}
      {:noreply, _state} = Telemetry.handle_info(msg, %{ahoy_buffers: %{}})

      assert [reading] = Devices.list_recent_readings(user, dtu.id)
      assert reading.inverter_serial == "balcony-inv"
      assert reading.ac_power == 320.0
      assert reading.dc_power == 330.0
      assert reading.frequency == 50.01
      assert reading.temperature == 41.2
      assert reading.yield_day == 2.5
      assert reading.yield_total == 980.0
    end
  end
end
