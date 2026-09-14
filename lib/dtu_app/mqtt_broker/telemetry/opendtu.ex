defmodule DtuApp.MqttBroker.Telemetry.OpenDtu do
  @moduledoc """
  OpenDTU uplink parser + handler.

  Lives behind `DtuApp.MqttBroker.Telemetry.handle_info/2`'s
  `:opendtu` branch — every OpenDTU-flavoured MQTT publish hits
  `handle/5` here and we route the parsed result into either
  the per-MPPT buffer (`flush_buffer/6`), a single-reading flush
  (`flush_reading/5`), a retroactively-applied inverter name
  (`safe_db_call` → `Devices.update_inverter_name/3`), or a status
  patch (`Devices.patch_latest_reading_status/3`).

  Topic patterns OpenDTU publishes:

      {base}/{serial}/name                                 -> {:name, ...}
      {base}/{serial}/status/{producing|reachable}         -> {:status, ...}
      {base}/{serial}/realtime/data                        -> {:reading, ...} (JSON aggregate)
      {base}/{serial}/0/{field}                            -> {:ignored, :ac_per_field_redundant}
      {base}/{serial}/{channel}/{field}  (channel >= 1)    -> {:buffer, ...}

  Anything else is `{:ignored, :unknown_topic}`. The buffer
  flush writes through on every recognised metric arrival —
  yield-only / temperature-only uplinks don't sit in RAM
  anymore (regression covered by `flush_buffer/6`).

  ## State

  `state.buffers` is a `%{{dtu_id, {serial, channel}} => row_map}`
  cache of in-flight per-MPPT metrics. The handler is a GenServer
  callback, so the buffer survives across multiple publishes; each
  per-MPPT field arrives in its own uplink. Owned here, never
  written to from anywhere else.
  """

  import DtuApp.MqttBroker.Telemetry.PayloadHelpers

  require Logger

  @doc """
  Handle an OpenDTU `:uplink` payload.

  Returns `{:noreply, new_state}` — the GenServer contract. The
  state transition is "swap `state.buffers` for a new map with
  one entry updated (if the parse returned `{:buffer, ...}`)".

  Side-effects (DB writes, PubSub broadcasts) are wrapped in
  `safe_db_call/1` (delegated to the parent `Telemetry` module
  via the `safe_db_call` arg passed by `handle/4`) so a
  sandbox-teardown race during `:test` doesn't kill the
  GenServer.
  """
  def handle(client_id, device_info, topic_str, payload, state, safe_db_call) do
    case parse(topic_str, device_info.base_topic, payload) do
      {:reading, attrs} ->
        attrs = Map.put(attrs, :dtu_id, device_info.id)
        flush_reading(client_id, device_info, attrs, payload, state, safe_db_call)

      {:buffer, serial, channel, pairs} ->
        flush_buffer(client_id, device_info, serial, channel, pairs, payload, state, safe_db_call)

      {:name, serial, name} ->
        case safe_db_call.(fn ->
               DtuApp.Devices.update_inverter_name(device_info.id, serial, name)
             end) do
          {:ok, count} ->
            Logger.debug(
              "[Telemetry] OpenDTU inverter name for DTU #{device_info.id} " <>
                "serial=#{serial} -> #{name} (#{count} rows backfilled)"
            )

            {:noreply, state}

          :ok ->
            # safe_db_call caught a sandbox-teardown exception — skip the
            # rest of this uplink's processing and leave the state untouched.
            {:noreply, state}
        end

      {:status, serial, flags} ->
        case safe_db_call.(fn ->
               DtuApp.Devices.patch_latest_reading_status(device_info.id, serial, flags)
             end) do
          {:ok, _} ->
            {:noreply, state}

          {:error, reason} ->
            # `:no_readings` is a benign transient (the first
            # `realtime/data` uplink hasn't arrived yet) and is logged
            # at debug only — it doesn't deserve a user-visible error
            # bubble on every early session start. Any other reason is
            # a real error.
            if reason != :no_readings do
              record_dtu_error(
                device_info.id,
                "OpenDTU status patch failed: #{inspect(reason)}"
              )
            end

            Logger.debug("[Telemetry] OpenDTU status patch skipped: #{inspect(reason)}")
            {:noreply, state}

          :ok ->
            # safe_db_call caught a sandbox-teardown exception — skip the
            # rest of this uplink's processing and leave the state untouched.
            {:noreply, state}
        end

      {:ignored, reason} ->
        # Three categories:
        #
        #  * `:ac_per_field_redundant` — *expected* case for an OpenDTU that
        #    publishes both `realtime/data` and per-field `0/*` topics.
        #    Duplicate-path suppression is part of the parser contract,
        #    not a user-visible error.
        #
        #  * `:unknown_topic`, `:unknown_opendtu_field` — the firmware is
        #    publishing a topic (or a per-MPPT metric name) we don't yet
        #    parse. The DTU is otherwise healthy; we just haven't wired
        #    up that field. Downgrade to Logger.info with the topic +
        #    payload so a developer reading logs can identify what the
        #    device is sending without polluting the user's error bubble.
        #    No `dtu_errors` row is written.
        #
        #  * everything else (`:bad_json`, `:bad_status_value`,
        #    `:bad_channel`) — the DTU is sending malformed payloads we
        #    couldn't parse. Surface as a real error with the topic +
        #    payload (truncated to 200 chars) so the user can see exactly
        #    what was sent.
        case reason do
          :ac_per_field_redundant ->
            :ok

          topic when topic in [:unknown_topic, :unknown_opendtu_field] ->
            log_unknown_uplink("OpenDTU", device_info.id, topic_str, payload)

          other ->
            snippet = format_payload_snippet(payload)
            base = "OpenDTU uplink rejected (#{inspect(other)} on topic #{inspect(topic_str)})"

            record_dtu_error(
              device_info.id,
              if(snippet == "", do: base, else: base <> " — payload: " <> snippet)
            )
        end

        Logger.debug("[Telemetry] OpenDTU parse skipped: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # `record_dtu_error/2` is a public helper on the parent
  # `Telemetry` module — we don't want every parser module to know
  # about telemetry-counter plumbing, but the *callback* has to be
  # reachable from inside the parser. We pass it in via the env
  # at handle/5 entry to keep parser modules pure (no compile-time
  # cycle through `Telemetry`).
  defp record_dtu_error(device_id, message) do
    DtuApp.MqttBroker.Telemetry.record_dtu_error(device_id, message)
  end

  # `create_reading_and_touch_power_at/1` inserts the reading and, for
  # the AC-aggregate row (`mppt_index = 0`), also touches the owning
  # DTU's `last_power_at` column. That timestamp is what the
  # dashboard's "online" indicators (green dot, online/offline pill)
  # gate on, so the badges flip in sync with the live power data
  # rather than with arbitrary MQTT activity. See
  # `Dtu.producing_power?/2` for the rule.
  defp flush_reading(client_id, device_info, attrs, payload, state, safe_db_call) do
    case safe_db_call.(fn -> DtuApp.Devices.create_reading_and_touch_power_at(attrs) end) do
      {:ok, db_reading} ->
        Logger.debug(
          "[Telemetry] Saved OpenDTU reading for DTU #{device_info.id} " <>
            "serial=#{attrs[:inverter_serial]} mppt=#{attrs[:mppt_index]}"
        )

        Phoenix.PubSub.broadcast(
          DtuApp.PubSub,
          DtuApp.MqttBroker.Telemetry.reading_topic(),
          {:reading, client_id, db_reading}
        )

        {:noreply, state}

      {:error, changeset} ->
        Logger.warning("[Telemetry] Failed to save OpenDTU reading: #{inspect(changeset.errors)}")

        snippet = format_payload_snippet(payload)

        base =
          "Failed to save OpenDTU reading: #{inspect(changeset.errors)}"

        record_dtu_error(
          device_info.id,
          if(snippet == "", do: base, else: base <> " — payload: " <> snippet)
        )

        {:noreply, state}

      :ok ->
        # safe_db_call caught a sandbox-teardown exception — skip the
        # rest of this uplink's processing and leave the state untouched.
        {:noreply, state}
    end
  end

  # Per-MPPT DC input topics arrive as independent uplinks, so we buffer
  # multiple fields per (serial, channel) and flush whenever a recognised
  # field lands. Mirrors the AhoyDTU per-channel buffer.
  defp flush_buffer(client_id, device_info, serial, channel, pairs, payload, state, safe_db_call) do
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
      flush_reading(client_id, device_info, reading_attrs, payload, new_state, safe_db_call)
    else
      {:noreply, new_state}
    end
  end

  defp parse(topic_str, base_topic, payload) do
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
            metric_atom = metric(field)

            if metric_atom == :other do
              {:ignored, :unknown_opendtu_field}
            else
              value = metric_value(metric_atom, payload)
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
  defp metric("power"), do: :dc_power
  defp metric("yieldday"), do: :yield_day
  defp metric("yieldtotal"), do: :yield_total
  defp metric(_), do: :other

  defp metric_value(metric, payload) when metric in [:yield_day, :yield_total, :dc_power] do
    cast_float(payload)
  end
end
