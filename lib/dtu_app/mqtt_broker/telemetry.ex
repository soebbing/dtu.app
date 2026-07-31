defmodule DtuApp.MqttBroker.Telemetry do
  @moduledoc """
  Consumes MQTT uplinks from DTUs and parses OpenDTU-format or AhoyDTU-format telemetry.

  ## Topic layouts

  ### OpenDTU

      {base}/{inverter_serial}/realtime/data            # consolidated JSON (AC + status)
      {base}/{inverter_serial}/name                     # friendly inverter name (string)
      {base}/{inverter_serial}/{0-9}/{field}            # per-channel metric, e.g. 1/power
      {base}/{inverter_serial}/status/producing         # 0 or 1
      {base}/{inverter_serial}/status/reachable         # 0 or 1

  Channel `0` is the AC aggregate (the value also published via `realtime/data`,
  so we ignore per-field `0/*` uplinks to avoid double-counting); channels `1..N`
  are individual DC MPPT inputs and become `mppt_index = N` rows in `readings`.

  ### AhoyDTU

      {base}/{inverter_name}/ch0/{Metric}                # numeric scalar per metric
      {base}/{inverter_name}/ch0                         # JSON object of ch0 metrics
      {base}/{inverter_name}/ch{1..6}/{Metric}           # DC per-string inputs
      {base}/{inverter_name}/ch{1..6}                    # JSON per DC input
      {base}/total/...                                   # ignored (recomputed by the dashboard)

  Per-channel metrics arrive on staggered intervals (P_AC in one uplink, YieldDay
  in the next), so we buffer them per `(inverter, channel)` and flush a row
  whenever any meaningful metric arrives.

  ## Outputs

  Every parsed reading is persisted as a row in `readings` and republished on
  the `dtu:reading` PubSub topic. OpenDTU's `{serial}/name` topic updates
  `readings.inverter_name` retroactively for every existing row of that
  `(dtu_id, inverter_serial)` pair so the chart legend picks the friendly name
  up immediately. OpenDTU's `{serial}/status/{producing|reachable}` uplinks
  update the latest reading for that inverter.

  ## Stale-DTU sweep

  In addition to MQTT-presence-driven `online` flips, a periodic sweep
  (every `stale_dtu_sweep_interval_ms`, default 60 s) flips the
  `online` flag to `false` for any DTU whose `last_seen_at` is older
  than `stale_after_seconds` (default 300 s). Catches the case where a
  DTU drops off the network silently — WiFi blip, NAT timeout, power
  cycle without a clean MQTT DISCONNECT — so the dashboard's "online"
  badge doesn't lie. When the sweep flips any DTU, it broadcasts
  `{:dtu_status_changed, ids}` on the `dtu:status` topic; the
  dashboard subscribes and refreshes the device list.
  """

  use GenServer

  require Logger

  alias DtuApp.MqttBroker.Broker

  @reading_topic "dtu:reading"
  @status_topic "dtu:status"

  # How often the GenServer runs the stale-DTU sweep. Short enough
  # that an "online" badge catches up within ~one interval of the
  # threshold; long enough that the DB UPDATE is not on a hot path.
  @stale_dtu_sweep_interval_ms 60_000

  # --- Public API -------------------------------------------------------------

  @doc "The PubSub topic parsed readings are broadcast on."
  def reading_topic, do: @reading_topic

  @doc "The PubSub topic DTU status changes are broadcast on."
  def status_topic, do: @status_topic

  @doc "Subscribe the calling process to parsed readings."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(DtuApp.PubSub, @reading_topic)

  @doc "Subscribe the calling process to DTU status changes."
  @spec subscribe_status() :: :ok | {:error, term()}
  def subscribe_status, do: Phoenix.PubSub.subscribe(DtuApp.PubSub, @status_topic)

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  # --- GenServer --------------------------------------------------------------

  @impl true
  def init(:ok) do
    Broker.subscribe_uplink()
    Broker.subscribe_presence()
    schedule_stale_dtu_sweep()
    Logger.info("[Telemetry] subscribed to DTU uplinks and presence")
    {:ok, %{buffers: %{}}}
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

  # Periodic sweep: flips `online` to false for any DTU whose
  # `last_seen_at` is older than the staleness threshold. Re-schedules
  # itself so the timer never expires.
  @impl true
  def handle_info(:sweep_stale_dtus, state) do
    run_stale_dtu_sweep()
    schedule_stale_dtu_sweep()
    {:noreply, state}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_stale_dtu_sweep do
    Process.send_after(self(), :sweep_stale_dtus, @stale_dtu_sweep_interval_ms)
  end

  @doc false
  # Run the stale-DTU sweep and broadcast which DTUs flipped.
  # Public so tests can invoke the sweep without waiting for the timer.
  def run_stale_dtu_sweep do
    case DtuApp.Devices.mark_stale_dtus_offline() do
      {0, _ids} ->
        :ok

      {count, ids} ->
        Logger.info("[Telemetry] marked #{count} stale DTU(s) offline: #{inspect(ids)}")

        Phoenix.PubSub.broadcast(
          DtuApp.PubSub,
          @status_topic,
          {:dtu_status_changed, ids}
        )
    end
  end

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

  # --- OpenDTU ----------------------------------------------------------------

  # The OpenDTU parser returns one of:
  #   {:reading, attrs}   — insert a reading row
  #   {:buffer, serial, channel, pairs} — buffer the pairs and flush a row
  #   {:name, serial, name} — retroactively rename all rows for this serial
  #   {:status, serial, %{producing: ..., reachable: ...}} — patch the latest row
  #   {:ignored, reason} — log at debug and move on
  defp handle_opendtu(client_id, device_info, topic_str, payload, state) do
    case parse_opendtu(topic_str, device_info.base_topic, payload) do
      {:reading, attrs} ->
        attrs = Map.put(attrs, :dtu_id, device_info.id)
        flush_opendtu_reading(client_id, device_info, attrs, state)

      {:buffer, serial, channel, pairs} ->
        flush_opendtu_buffer(client_id, device_info, serial, channel, pairs, state)

      {:name, serial, name} ->
        {:ok, count} = DtuApp.Devices.update_inverter_name(device_info.id, serial, name)

        Logger.debug(
          "[Telemetry] OpenDTU inverter name for DTU #{device_info.id} " <>
            "serial=#{serial} -> #{name} (#{count} rows backfilled)"
        )

        {:noreply, state}

      {:status, serial, flags} ->
        case DtuApp.Devices.patch_latest_reading_status(device_info.id, serial, flags) do
          {:ok, _} ->
            {:noreply, state}

          {:error, reason} ->
            Logger.debug("[Telemetry] OpenDTU status patch skipped: #{inspect(reason)}")
            {:noreply, state}
        end

      {:ignored, reason} ->
        Logger.debug("[Telemetry] OpenDTU parse skipped: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp flush_opendtu_reading(client_id, device_info, attrs, state) do
    case DtuApp.Devices.create_reading(attrs) do
      {:ok, db_reading} ->
        Logger.debug(
          "[Telemetry] Saved OpenDTU reading for DTU #{device_info.id} " <>
            "serial=#{attrs[:inverter_serial]} mppt=#{attrs[:mppt_index]}"
        )

        Phoenix.PubSub.broadcast(
          DtuApp.PubSub,
          @reading_topic,
          {:reading, client_id, db_reading}
        )

        {:noreply, state}

      {:error, changeset} ->
        Logger.warning("[Telemetry] Failed to save OpenDTU reading: #{inspect(changeset.errors)}")

        {:noreply, state}
    end
  end

  # Per-MPPT DC input topics arrive as independent uplinks, so we buffer
  # multiple fields per (serial, channel) and flush whenever a recognised
  # field lands. Mirrors the AhoyDTU per-channel buffer.
  defp flush_opendtu_buffer(client_id, device_info, serial, channel, pairs, state) do
    buffer_key = {device_info.id, {serial, channel}}

    initial = %{
      inverter_serial: serial,
      mppt_index: channel,
      # Friendly name is filled in retroactively when `{serial}/name` arrives.
      inverter_name: nil,
      ac_power: nil,
      dc_power: nil,
      yield_day: nil,
      yield_total: nil,
      frequency: nil,
      temperature: nil,
      producing: nil,
      reachable: nil
    }

    current = Map.get(state.buffers, buffer_key, initial)

    updated_buffer =
      Enum.reduce(pairs, current, fn {metric_atom, value}, buf ->
        if metric_atom == :other, do: buf, else: Map.put(buf, metric_atom, value)
      end)

    new_buffers = Map.put(state.buffers, buffer_key, updated_buffer)
    new_state = %{state | buffers: new_buffers}

    flush? = Enum.any?(pairs, fn {metric_atom, _value} -> metric_atom != :other end)

    if flush? do
      reading_attrs = Map.put(updated_buffer, :dtu_id, device_info.id)
      flush_opendtu_reading(client_id, device_info, reading_attrs, new_state)
    else
      {:noreply, new_state}
    end
  end

  defp parse_opendtu(topic_str, base_topic, payload) do
    case String.split(topic_str, "/") do
      # Inverter-friendly name published by OpenDTU's web UI. Retroactively
      # attached to every existing reading for this (dtu_id, inverter_serial).
      [binary_base, serial, "name"] when binary_base == base_topic ->
        {:name, serial, payload}

      # Per-inverter status flags (1/0 scalar).
      [binary_base, serial, "status", field]
      when binary_base == base_topic and field in ["producing", "reachable"] ->
        case parse_bool(payload) do
          {:ok, value} -> {:status, serial, %{field => value}}
          :error -> {:ignored, :bad_status_value}
        end

      # Consolidated realtime JSON — the AC aggregate + status + temperature.
      [binary_base, serial, "realtime", "data"] when binary_base == base_topic ->
        case Jason.decode(payload) do
          {:ok, json} ->
            attrs = %{
              inverter_serial: serial,
              # `0` = AC aggregate (same convention as AhoyDTU ch0). Per-MPPT
              # DC inputs land on rows with mppt_index 1..N.
              mppt_index: 0,
              inverter_name: nil,
              ac_power: cast_float(get_in(json, ["AC", "Power", "v"])),
              dc_power: cast_float(get_in(json, ["DC", "Power", "v"])),
              yield_day: cast_float(get_in(json, ["AC", "YieldDay", "v"])),
              yield_total: cast_float(get_in(json, ["AC", "YieldTotal", "v"])),
              frequency: cast_float(get_in(json, ["AC", "Frequency", "v"])),
              temperature: cast_float(get_in(json, ["INV", "Temperature", "v"])),
              producing: truthy?(get_in(json, ["status", "producing"])),
              reachable: truthy?(get_in(json, ["status", "reachable"]))
            }

            {:reading, attrs}

          _ ->
            {:ignored, :bad_json}
        end

      # AC channel (channel 0) per-field topics — already covered by
      # realtime/data, so we ignore to avoid double-counting.
      [binary_base, _serial, "0", _field] when binary_base == base_topic ->
        {:ignored, :ac_per_field_redundant}

      # DC MPPT per-field topic (channels 1..N). Map a recognised field to
      # a known metric atom; everything else becomes `:other` (ignored for
      # flush but kept for future fields without code changes).
      [binary_base, serial, channel_str, field] when binary_base == base_topic ->
        case Integer.parse(channel_str) do
          {channel, ""} when channel >= 1 ->
            metric_atom = opendtu_metric(field)

            if metric_atom == :other do
              {:ignored, :unknown_opendtu_field}
            else
              value = opendtu_metric_value(metric_atom, payload)
              {:buffer, serial, channel, [{metric_atom, value}]}
            end

          _ ->
            {:ignored, :bad_channel}
        end

      _ ->
        {:ignored, :unknown_topic}
    end
  end

  # Map an OpenDTU per-MPPT field name to one of the metric atoms the Reading
  # schema can store. Fields we don't persist (voltage, current, irradiation,
  # DC-string friendly name) become `:other` and are dropped from the flush.
  defp opendtu_metric("power"), do: :dc_power
  defp opendtu_metric("yieldday"), do: :yield_day
  defp opendtu_metric("yieldtotal"), do: :yield_total
  defp opendtu_metric(_), do: :other

  defp opendtu_metric_value(metric, payload)
       when metric in [:yield_day, :yield_total, :dc_power] do
    cast_float(payload)
  end

  # --- AhoyDTU ----------------------------------------------------------------

  defp handle_ahoydtu(client_id, device_info, topic_str, payload, state) do
    case parse_ahoydtu(topic_str, device_info.base_topic, payload) do
      {:ok, name, channel, pairs} when pairs != [] ->
        # Each (inverter, channel) pair gets its own row in `readings` —
        # ch0 = mppt_index 0 (the AC-side aggregate), ch1..N = MPPT 1..N.
        # The buffer is keyed by `{inverter_name, channel}` so the per-channel
        # metrics that arrive at staggered intervals still land in the
        # same row until we flush.
        buffer_key = {device_info.id, {name, channel}}

        initial = %{
          inverter_serial: name,
          mppt_index: channel,
          inverter_name: name,
          ac_power: nil,
          dc_power: nil,
          yield_day: nil,
          yield_total: nil,
          frequency: nil,
          temperature: nil,
          producing: nil,
          reachable: nil
        }

        current = Map.get(state.buffers, buffer_key, initial)

        updated_buffer =
          Enum.reduce(pairs, current, fn {metric_atom, value}, buf ->
            if metric_atom == :other, do: buf, else: Map.put(buf, metric_atom, value)
          end)

        new_buffers = Map.put(state.buffers, buffer_key, updated_buffer)
        new_state = %{state | buffers: new_buffers}

        # Bugfix: the buffer was previously only flushed to the DB when an
        # AC power reading arrived in the same uplink. AC power is only
        # published while the inverter is actively producing, so any
        # yield-only or temperature-only uplink would silently sit in RAM
        # and never reach the DB — leaving "Today's Total Yield" stuck at 0
        # for AhoyDTU users. Flush whenever *any* recognised metric arrives
        # so the buffer is always written through. Unrecognised metrics
        # (`:other`) alone are ignored, which would only produce a no-op row.
        flush? =
          Enum.any?(pairs, fn {metric_atom, _value} -> metric_atom != :other end)

        if flush? do
          reading_attrs = Map.put(updated_buffer, :dtu_id, device_info.id)

          case DtuApp.Devices.create_reading(reading_attrs) do
            {:ok, db_reading} ->
              Logger.debug(
                "[Telemetry] Saved AhoyDTU reading for DTU #{device_info.id} " <>
                  "inverter=#{name} channel=#{channel}"
              )

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

  defp parse_ahoydtu(topic_str, base_topic, payload) do
    case String.split(topic_str, "/") do
      # Numeric layout: {base}/{name}/ch{0..6}/{Metric} -> one scalar.
      [binary_base, name, <<"ch", rest::binary>> = channel, metric]
      when binary_base == base_topic and channel != "total" ->
        # If the payload is itself JSON, defer to the JSON-layout clause below;
        # otherwise treat it as a single numeric scalar.
        if json_object?(payload) do
          {:error, :ignored_topic}
        else
          metric_atom = parse_ahoy_metric(metric)
          value = parse_ahoy_value(metric_atom, payload)
          {:ok, name, channel_index(rest), [{metric_atom, value}]}
        end

      # JSON layout: {base}/{name}/ch{0..6} -> a JSON object of many metrics.
      [binary_base, name, <<"ch", rest::binary>> = channel]
      when binary_base == base_topic and channel != "total" ->
        case Jason.decode(payload) do
          {:ok, json_map} when is_map(json_map) ->
            pairs = ahoy_json_to_pairs(json_map, channel)
            {:ok, name, channel_index(rest), pairs}

          _ ->
            {:error, :ignored_topic}
        end

      # AhoyDTU fleet totals {base}/total/... — recomputed across the user's
      # devices by the dashboard, so ignore here.
      _ ->
        {:error, :ignored_topic}
    end
  end

  # --- Shared parsing helpers -------------------------------------------------

  # Extract the integer MPPT index from a channel segment like "ch0" -> 0,
  # "ch1" -> 1, "ch12" -> 12. Falls back to 0 on parse failure so a bad
  # topic doesn't crash the parser.
  defp channel_index(<<>>), do: 0
  defp channel_index(rest), do: Integer.parse(rest) |> elem(0) |> Kernel.||(0)

  # Buffer-then-flush for OpenDTU per-MPPT per-field topics happens in
  # `flush_opendtu_buffer/6` — the parser only tags the metric, the handler
  # owns the state.

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

  defp parse_bool("1"), do: {:ok, true}
  defp parse_bool("0"), do: {:ok, false}
  defp parse_bool("true"), do: {:ok, true}
  defp parse_bool("false"), do: {:ok, false}
  defp parse_bool(_), do: :error
end
