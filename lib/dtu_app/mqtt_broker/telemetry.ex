defmodule DtuApp.MqttBroker.Telemetry do
  @moduledoc """
  Consumes MQTT uplinks from DTUs and parses OpenDTU-format or AhoyDTU-format telemetry.

  OpenDTU publishes a consolidated JSON message on `{base}/{inverter_serial}/realtime/data`.
  AhoyDTU publishes individual metrics under `{base}/{inverter_name}/ch0/{metric}`.

  This module turns those raw uplinks into structured `Reading` records, saves them to the
  database, and republishes them on the `dtu:reading` PubSub topic. It also listens to presence
  broadcasts to update the physical DTUs' online/offline statuses in the database.
  """

  use GenServer

  require Logger

  alias DtuApp.MqttBroker.Broker

  @reading_topic "dtu:reading"

  # --- Public API -------------------------------------------------------------

  @doc "The PubSub topic parsed readings are broadcast on."
  def reading_topic, do: @reading_topic

  @doc "Subscribe the calling process to parsed readings."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(DtuApp.PubSub, @reading_topic)

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  # --- GenServer --------------------------------------------------------------

  @impl true
  def init(:ok) do
    Broker.subscribe_uplink()
    Broker.subscribe_presence()
    Logger.info("[Telemetry] subscribed to DTU uplinks and presence")
    {:ok, %{ahoy_buffers: %{}}}
  end

  @impl true
  def handle_info({:uplink, client_id, device_info, topic_str, payload}, state) do
    if is_nil(device_info) do
      # Ignore unauthenticated uplinks
      {:noreply, state}
    else
      case device_info.kind do
        :opendtu ->
          handle_opendtu(client_id, device_info, topic_str, payload, state)

        :ahoydtu ->
          handle_ahoydtu(client_id, device_info, topic_str, payload, state)
      end
    end
  end

  # Handle presence tracking for DTUs
  @impl true
  def handle_info({:dtu_connected, _client_id, device_id}, state) do
    if device_id do
      update_dtu_status(device_id, true)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:dtu_disconnected, _client_id, device_id}, state) do
    if device_id do
      update_dtu_status(device_id, false)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  # --- Ingestion & Parsing Helpers --------------------------------------------

  defp update_dtu_status(device_id, online) do
    try do
      DtuApp.Repo.get(DtuApp.Devices.Dtu, device_id)
      |> case do
        nil ->
          :ok

        dtu ->
          dtu
          |> Ecto.Changeset.change(%{online: online, last_seen_at: DateTime.utc_now()})
          |> DtuApp.Repo.update()
      end
    rescue
      _ -> :ok
    end
  end

  defp handle_opendtu(client_id, device_info, topic_str, payload, state) do
    case parse_opendtu(topic_str, device_info.base_topic, payload) do
      {:ok, reading_attrs} ->
        reading_attrs = Map.put(reading_attrs, :dtu_id, device_info.id)

        case DtuApp.Devices.create_reading(reading_attrs) do
          {:ok, db_reading} ->
            Logger.debug("[Telemetry] Saved OpenDTU reading for DTU #{device_info.id}")

            Phoenix.PubSub.broadcast(
              DtuApp.PubSub,
              @reading_topic,
              {:reading, client_id, db_reading}
            )

            {:noreply, state}

          {:error, changeset} ->
            Logger.warning(
              "[Telemetry] Failed to save OpenDTU reading: #{inspect(changeset.errors)}"
            )

            {:noreply, state}
        end

      {:error, reason} ->
        Logger.debug("[Telemetry] OpenDTU parse skipped: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp handle_ahoydtu(client_id, device_info, topic_str, payload, state) do
    case parse_ahoydtu(topic_str, device_info.base_topic, payload) do
      {:ok, name, pairs} when pairs != [] ->
        device_buffers = Map.get(state.ahoy_buffers, device_info.id, %{})

        inverter_buffer =
          Map.get(device_buffers, name, %{
            inverter_serial: name,
            ac_power: nil,
            dc_power: nil,
            yield_day: nil,
            yield_total: nil,
            frequency: nil,
            temperature: nil,
            producing: nil,
            reachable: nil
          })

        updated_inverter =
          Enum.reduce(pairs, inverter_buffer, fn {metric_atom, value}, buf ->
            if metric_atom == :other, do: buf, else: Map.put(buf, metric_atom, value)
          end)

        updated_device_buffers = Map.put(device_buffers, name, updated_inverter)
        new_ahoy_buffers = Map.put(state.ahoy_buffers, device_info.id, updated_device_buffers)
        new_state = %{state | ahoy_buffers: new_ahoy_buffers}

        # Trigger a DB write whenever an AC power reading arrives in this uplink
        # (the numeric layout sends one metric per topic; the JSON layout sends
        # several at once — either way, ac_power is the flush signal).
        has_ac_power = Enum.any?(pairs, fn {m, v} -> m == :ac_power and not is_nil(v) end)

        if has_ac_power do
          reading_attrs = Map.put(updated_inverter, :dtu_id, device_info.id)

          case DtuApp.Devices.create_reading(reading_attrs) do
            {:ok, db_reading} ->
              Logger.debug("[Telemetry] Saved AhoyDTU reading for DTU #{device_info.id}")

              Phoenix.PubSub.broadcast(
                DtuApp.PubSub,
                @reading_topic,
                {:reading, client_id, db_reading}
              )

              {:noreply, new_state}

            {:error, changeset} ->
              Logger.warning(
                "[Telemetry] Failed to save AhoyDTU reading: #{inspect(changeset.errors)}"
              )

              {:noreply, new_state}
          end
        else
          {:noreply, new_state}
        end

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  defp parse_opendtu(topic_str, base_topic, payload) do
    case String.split(topic_str, "/") do
      [binary_base, serial, "realtime", "data"] when binary_base == base_topic ->
        case Jason.decode(payload) do
          {:ok, json} ->
            reading_attrs = %{
              inverter_serial: serial,
              ac_power: cast_float(get_in(json, ["AC", "Power", "v"])),
              dc_power: cast_float(get_in(json, ["DC", "Power", "v"])),
              yield_day: cast_float(get_in(json, ["yield_day"])),
              yield_total: cast_float(get_in(json, ["yield_total"])),
              frequency: cast_float(get_in(json, ["AC", "Frequency", "v"])),
              temperature: cast_float(get_in(json, ["INV", "Temperature", "v"])),
              producing: truthy?(get_in(json, ["status", "producing"])),
              reachable: truthy?(get_in(json, ["status", "reachable"]))
            }

            {:ok, reading_attrs}

          _ ->
            {:error, :bad_json}
        end

      _ ->
        {:error, :ignored_topic}
    end
  end

  defp parse_ahoydtu(topic_str, base_topic, payload) do
    case String.split(topic_str, "/") do
      # Numeric layout: {base}/{name}/ch{0..6}/{Metric} -> one scalar.
      [binary_base, name, <<"ch", _::binary>> = channel, metric]
      when binary_base == base_topic and channel != "total" ->
        # If the payload is itself JSON, defer to the JSON-layout clause below;
        # otherwise treat it as a single numeric scalar.
        if json_object?(payload) do
          {:error, :ignored_topic}
        else
          metric_atom = parse_ahoy_metric(metric)
          value = parse_ahoy_value(metric_atom, payload)
          {:ok, name, [{metric_atom, value}]}
        end

      # JSON layout: {base}/{name}/ch{0..6} -> a JSON object of many metrics.
      [binary_base, name, <<"ch", _::binary>> = channel]
      when binary_base == base_topic and channel != "total" ->
        case Jason.decode(payload) do
          {:ok, json_map} when is_map(json_map) ->
            pairs = ahoy_json_to_pairs(json_map, channel)
            {:ok, name, pairs}

          _ ->
            {:error, :ignored_topic}
        end

      # AhoyDTU fleet totals {base}/total/... — recomputed across the user's
      # devices by the dashboard, so ignore here.
      _ ->
        {:error, :ignored_topic}
    end
  end

  # Map an AhoyDTU per-channel JSON object into normalized {metric, value} pairs.
  # ch0 carries AC-side values (incl. calculated P_DC); ch1..6 carry DC inputs.
  # Only DC-specific fields are taken from ch1..6 to avoid clobbering ch0's P_DC.
  defp ahoy_json_to_pairs(json, "ch0") do
    [
      {:ac_power, cast_float(json["P_AC"])},
      {:dc_power, cast_float(json["P_DC"])},
      {:yield_day, cast_float(json["YieldDay"])},
      {:yield_total, cast_float(json["YieldTotal"])},
      {:frequency, cast_float(json["F_AC"])},
      {:temperature, cast_float(json["Temp"])},
      {:producing, parse_ahoy_value(:producing, json["producing"])}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp ahoy_json_to_pairs(json, _dc_channel) do
    [
      {:dc_power, cast_float(json["P_DC"])},
      {:yield_day, cast_float(json["YieldDay"])},
      {:yield_total, cast_float(json["YieldTotal"])}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp json_object?(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, value} when is_map(value) -> true
      _ -> false
    end
  end

  defp parse_ahoy_metric("P_AC"), do: :ac_power
  defp parse_ahoy_metric("P_DC"), do: :dc_power
  defp parse_ahoy_metric("YieldDay"), do: :yield_day
  defp parse_ahoy_metric("YieldTotal"), do: :yield_total
  defp parse_ahoy_metric("F_AC"), do: :frequency
  defp parse_ahoy_metric("Temp"), do: :temperature
  defp parse_ahoy_metric("producing"), do: :producing
  defp parse_ahoy_metric("reachable"), do: :reachable
  defp parse_ahoy_metric(_), do: :other

  defp parse_ahoy_value(metric, payload) when metric in [:producing, :reachable] do
    case payload do
      "1" -> true
      "0" -> false
      "true" -> true
      "false" -> false
      _ -> nil
    end
  end

  defp parse_ahoy_value(_metric, payload) do
    cast_float(payload)
  end

  defp cast_float(nil), do: nil
  defp cast_float(val) when is_integer(val), do: val * 1.0
  defp cast_float(val) when is_float(val), do: val

  defp cast_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp cast_float(_), do: nil

  defp truthy?(1), do: true
  defp truthy?(0), do: false
  defp truthy?(true), do: true
  defp truthy?(false), do: false
  defp truthy?(_), do: nil
end
