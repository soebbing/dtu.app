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

  ### Shelly Plus 3EM (Gen3+)

      {base}/status/em:0                                 # consolidated JSON, em component
      {base}/online                                      # retained "true"/"false" LWT

  The 3EM publishes a single JSON object on `status/em:0` carrying the
  total/phase active power, energy counters, voltage, current, freq
  and pf. We persist one row per uplink with `power_type =
  "consumption"`, summing the per-phase fields upstream into a single
  `consumption_power` value. `online` is a retained LWT — the broker
  toggles it on abrupt disconnect, which surfaces on the dashboard via
  the derived `Dtu.online?/2` (the regular last-seen path).

  ## Outputs

  Every parsed reading is persisted as a row in `readings` and republished on
  the `dtu:reading` PubSub topic. OpenDTU's `{serial}/name` topic updates
  `readings.inverter_name` retroactively for every existing row of that
  `(dtu_id, inverter_serial)` pair so the chart legend picks the friendly name
  up immediately. OpenDTU's `{serial}/status/{producing|reachable}` uplinks
  update the latest reading for that inverter.

  ## Online status (derived from `last_seen_at`)

  Every uplink (and every CONNECT / DISCONNECT) touches the DTU's
  `last_seen_at` column. The dashboard and the device-list LiveView
  render an "online" badge by calling `DtuApp.Devices.Dtu.online?/2`,
  which is `true` iff `now - last_seen_at < 300 s`. Because every
  uplink touches the timestamp, the badge reflects the DTU's actual
  liveness in real time — even a DTU that stays MQTT-connected but
  stops publishing (silent WiFi drop, NAT timeout, …) flips to
  "offline" within five minutes of its last PUBLISH.

  Every uplink also broadcasts `:dtu_seen` on the `dtu:status` topic
  with the affected `device_id`. Subscribed LiveViews re-read their
  device list and the badge updates without any DB-write loop or
  periodic sweep.
  """

  use GenServer

  require Logger

  alias DtuApp.MqttBroker.Broker
  alias DtuApp.Devices.Dtu

  @reading_topic "dtu:reading"
  @status_topic "dtu:status"

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

  @doc """
  Record the most recent MQTT-side error for a DTU.

  Called from every parser path that previously logged and forgot
  (bad JSON, unknown topic, base-topic mismatch on a Shelly, DB-side
  validation failure, …). Persists the message on `dtus.last_error` /
  `last_error_at` and broadcasts `:dtu_error` on `dtu:status` so the
  dashboard and device-list LiveViews can re-render the error bubble /
  fill on the affected device without waiting for the next uplink.

  Always returns `:ok` — the function swallows DB errors and logs them
  at warn, matching `touch_last_seen/1`'s "don't crash the telemetry
  GenServer" contract. A missed error write is acceptable; the next
  uplink that hits the same condition will retry.

  Empty / whitespace-only messages are no-ops (the caller's content
  is the only user-visible part of the bubble, so an empty string
  would produce a useless empty bubble).
  """
  @spec record_dtu_error(integer() | nil, String.t()) :: :ok
  def record_dtu_error(device_id, message) when is_integer(device_id) and is_binary(message) do
    trimmed = String.trim(message)

    if trimmed == "" do
      :ok
    else
      try do
        case DtuApp.Devices.update_dtu_error(device_id, trimmed) do
          :ok ->
            Phoenix.PubSub.broadcast(
              DtuApp.PubSub,
              @status_topic,
              {:dtu_error, device_id}
            )

          {:error, :not_found} ->
            # Device was deleted between the uplink arriving and our
            # write — silent no-op, the next inbound message will
            # notice and short-circuit earlier.
            :ok

          {:error, reason} ->
            Logger.warning(
              "[Telemetry] record_dtu_error(#{device_id}) DB write failed: #{inspect(reason)}"
            )

            :ok
        end
      rescue
        e ->
          Logger.warning("[Telemetry] record_dtu_error(#{device_id}) raised: #{inspect(e)}")

          :ok
      end
    end
  end

  def record_dtu_error(_device_id, _message), do: :ok

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  # --- GenServer --------------------------------------------------------------

  @impl true
  def init(:ok) do
    Broker.subscribe_uplink()
    Broker.subscribe_presence()
    Logger.info("[Telemetry] subscribed to DTU uplinks and presence")
    {:ok, %{buffers: %{}}}
  end

  @impl true
  def handle_info({:uplink, client_id, device_info, topic_str, payload}, state) do
    if is_nil(device_info) do
      # Ignore unauthenticated uplinks
      {:noreply, state}
    else
      # Touch `last_seen_at` first so the dashboard's online badge can
      # flip from offline → online within one publish interval of the
      # DTU waking up — independent of which parser branch (or no
      # branch at all, e.g. an unknown topic) runs below.
      touch_last_seen(device_info.id)

      case device_info.kind do
        :opendtu ->
          handle_opendtu(client_id, device_info, topic_str, payload, state)

        :ahoydtu ->
          handle_ahoydtu(client_id, device_info, topic_str, payload, state)

        :shelly3em ->
          handle_shelly(client_id, device_info, topic_str, payload, state)
      end
    end
  end

  # Handle presence tracking for DTUs. CONNECT / DISCONNECT both touch
  # `last_seen_at` so the derived `Dtu.online?/2` flips accordingly;
  # we no longer carry a stored `online` boolean.
  @impl true
  def handle_info({:dtu_connected, _client_id, device_id}, state) do
    if device_id, do: touch_last_seen(device_id)
    {:noreply, state}
  end

  @impl true
  def handle_info({:dtu_disconnected, _client_id, device_id}, state) do
    if device_id, do: touch_last_seen(device_id)
    {:noreply, state}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  # --- Ingestion & Parsing Helpers --------------------------------------------

  # Update `dtus.last_seen_at` for `device_id` to the DB clock. Used
  # on every MQTT activity (uplink, CONNECT, DISCONNECT) so the
  # derived `Dtu.online?/2` reflects real-time liveness. Broadcasts
  # `:dtu_seen` on `dtu:status` so subscribed LiveViews can refresh
  # their device list and the badge flips within one publish interval.
  #
  # `last_seen_at` is typed `:utc_datetime_usec`, so we use the
  # microsecond-precision `utc_now_usec/0` (otherwise Ecto would
  # reject the write with `:utc_datetime_usec expects microsecond
  # precision`).
  #
  # Errors are swallowed (`rescue _`): the worst case is a missed
  # badge flip on the next render, and the next uplink will retry
  # anyway. Logging at warn keeps the noise floor low but leaves a
  # breadcrumb for debugging.
  defp touch_last_seen(device_id) do
    DtuApp.Repo.get(Dtu, device_id)
    |> case do
      nil ->
        :ok

      dtu ->
        try do
          dtu
          |> Ecto.Changeset.change(%{last_seen_at: DtuApp.Time.utc_now_usec()})
          |> DtuApp.Repo.update()

          Phoenix.PubSub.broadcast(
            DtuApp.PubSub,
            @status_topic,
            {:dtu_seen, device_id}
          )
        rescue
          e ->
            Logger.warning("[Telemetry] touch_last_seen(#{device_id}) failed: #{inspect(e)}")
            :ok
        end
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
        flush_opendtu_reading(client_id, device_info, attrs, payload, state)

      {:buffer, serial, channel, pairs} ->
        flush_opendtu_buffer(client_id, device_info, serial, channel, pairs, payload, state)

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

  defp flush_opendtu_reading(client_id, device_info, attrs, payload, state) do
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

        snippet = format_payload_snippet(payload)

        base =
          "Failed to save OpenDTU reading: #{inspect(changeset.errors)}"

        record_dtu_error(
          device_info.id,
          if(snippet == "", do: base, else: base <> " — payload: " <> snippet)
        )

        {:noreply, state}
    end
  end

  # Per-MPPT DC input topics arrive as independent uplinks, so we buffer
  # multiple fields per (serial, channel) and flush whenever a recognised
  # field lands. Mirrors the AhoyDTU per-channel buffer.
  defp flush_opendtu_buffer(client_id, device_info, serial, channel, pairs, payload, state) do
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
      flush_opendtu_reading(client_id, device_info, reading_attrs, payload, new_state)
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

              snippet = format_payload_snippet(payload)

              base =
                "Failed to save AhoyDTU reading: #{inspect(changeset.errors)}"

              record_dtu_error(
                device_info.id,
                if(snippet == "", do: base, else: base <> " — payload: " <> snippet)
              )

              {:noreply, new_state}
          end
        else
          {:noreply, new_state}
        end

      {:error, _reason} ->
        # The AhoyDTU parser currently emits only one `{:error, _}` reason:
        # `:ignored_topic`. Three cases it covers today:
        #
        #   * JSON payload on a numeric-layout topic (mode-set mismatch — the
        #     user toggled AhoyDTU to JSON after subscribing to numeric).
        #   * non-JSON / unparseable payload on a JSON-layout topic.
        #   * `{base}/total/...` (AhoyDTU fleet totals, intentionally
        #     ignored — the dashboard recomputes across the user's devices).
        #   * Anything else that doesn't match the parser's topic patterns.
        #
        # All of these are "topic provided by the client, that currently is
        # not being read" — not user-visible errors. Downgrade to
        # `Logger.info` with topic + payload so a developer reading logs can
        # identify exactly what was sent. No `dtu_errors` row is written —
        # the user's manage-device error panel isn't polluted with metadata
        # the user can't act on.
        log_unknown_uplink("AhoyDTU", device_info.id, topic_str, payload)
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

  # --- Shelly Plus 3EM (Gen3+) -----------------------------------------------

  defp handle_shelly(client_id, device_info, topic_str, payload, state) do
    case parse_shelly(topic_str, device_info.base_topic, payload) do
      {:reading, pairs} when pairs != [] ->
        attrs =
          %{
            inverter_serial: "em:0",
            mppt_index: 0,
            inverter_name: nil,
            # Distinguishes a consumption row from an OpenDTU/AhoyDTU
            # production row. The dashboard branches on this to keep
            # totals separate.
            power_type: "consumption",
            ac_power: nil,
            dc_power: nil,
            yield_day: nil,
            yield_total: nil,
            frequency: nil,
            temperature: nil,
            producing: nil,
            reachable: nil
          }
          |> Map.merge(Map.new(pairs))
          |> Map.put(:dtu_id, device_info.id)

        case DtuApp.Devices.create_reading(attrs) do
          {:ok, db_reading} ->
            Logger.debug(
              "[Telemetry] Saved Shelly reading for DTU #{device_info.id} " <>
                "consumption_power=#{inspect(db_reading.consumption_power)} " <>
                "consumption_energy_total=#{inspect(db_reading.consumption_energy_total)}"
            )

            Phoenix.PubSub.broadcast(
              DtuApp.PubSub,
              @reading_topic,
              {:reading, client_id, db_reading}
            )

            {:noreply, state}

          {:error, changeset} ->
            Logger.warning(
              "[Telemetry] Failed to save Shelly reading: #{inspect(changeset.errors)}"
            )

            snippet = format_payload_snippet(payload)

            base =
              "Failed to save Shelly reading: #{inspect(changeset.errors)}"

            record_dtu_error(
              device_info.id,
              if(snippet == "", do: base, else: base <> " — payload: " <> snippet)
            )

            {:noreply, state}
        end

      {:ignored, :unknown_topic} ->
        # The most common cause is a Shelly whose MQTT prefix doesn't match
        # the device's base_topic here (the Shelly default is
        # `shellyplus3em-XXXXXXXXXXXX`). Unlike the OpenDTU/AhoyDTU
        # equivalent, we *do* surface this to the user — there's a fix-it
        # action (set the Shelly's MQTT prefix), and the symptom
        # ("device shows as online but no values") is hard to diagnose
        # from logs alone.
        Logger.warning(
          "[Telemetry] Shelly uplink on topic #{inspect(topic_str)} did not match " <>
            "the device's base_topic #{inspect(device_info.base_topic)} — " <>
            "is the device's MQTT prefix set correctly?"
        )

        snippet = format_payload_snippet(payload)

        base =
          "Shelly topic mismatch (expected #{inspect(device_info.base_topic)}, " <>
            "got #{inspect(topic_str)}) — check the device's MQTT prefix"

        record_dtu_error(
          device_info.id,
          if(snippet == "", do: base, else: base <> " — payload: " <> snippet)
        )

        {:noreply, state}

      {:ignored, :online_lwt} ->
        # The retained LWT from the Shelly is informational only — the
        # broker's disconnect path + `last_seen_at` updates already
        # cover liveness, so an LWT landing on this topic is normal,
        # not an error.
        {:noreply, state}

      {:ignored, reason} ->
        Logger.debug("[Telemetry] Shelly parse skipped: #{inspect(reason)}")

        snippet = format_payload_snippet(payload)

        base =
          "Shelly uplink rejected (#{inspect(reason)} on topic #{inspect(topic_str)})"

        record_dtu_error(
          device_info.id,
          if(snippet == "", do: base, else: base <> " — payload: " <> snippet)
        )

        {:noreply, state}
    end
  end

  defp parse_shelly(topic_str, base_topic, payload) do
    case String.split(topic_str, "/") do
      # `online` retained LWT — we don't act on it explicitly; the broker's
      # disconnect path + `last_seen_at` updates already cover liveness.
      # Topic matches when the device's `base_topic` is the single prefix
      # segment OR the first two segments of a multi-segment prefix.
      [binary_base, "online"] when binary_base == base_topic ->
        {:ignored, :online_lwt}

      [b1, b2, "online"] when b1 <> "/" <> b2 == base_topic ->
        {:ignored, :online_lwt}

      # `status/em:0` carries the consolidated meter status. Real Shelly
      # payload keys (per the EM component API):
      #   total_act_power                 — net instantaneous power (W, signed)
      #   a/b/c_act_power                 — per-phase active power (W)
      #   a_voltage, a_current, a_freq,   — per-phase electrical telemetry
      #     a_pf
      #   a_energy, b_energy, c_energy    — per-phase NESTED energy objects:
      #     a_energy.total                 — lifetime Wh counter
      #     a_energy.by_minute             — minute-resolution Wh array
      #     a_energy.minute_ts             — minute array timestamp
      # We deliberately drop voltage / current / freq / pf — the dashboard
      # doesn't render them yet, and persisting them would just cost DB space.
      #
      # The topic's prefix must match the device's `base_topic`. We accept
      # both single-segment prefixes (`shellies`) and multi-segment prefixes
      # (`shellies/shellyplus3em`) by matching either the full prefix as one
      # segment or as two concatenated segments joined by a "/".
      [binary_base, "status", "em:0"] when binary_base == base_topic ->
        case Jason.decode(payload) do
          {:ok, json} when is_map(json) ->
            {:reading, shelly_json_to_pairs(json)}

          _ ->
            {:ignored, :bad_json}
        end

      [b1, b2, "status", "em:0"] when b1 <> "/" <> b2 == base_topic ->
        case Jason.decode(payload) do
          {:ok, json} when is_map(json) ->
            {:reading, shelly_json_to_pairs(json)}

          _ ->
            {:ignored, :bad_json}
        end

      _ ->
        {:ignored, :unknown_topic}
    end
  end

  # Map a Shelly `em:0` JSON payload into the {metric_atom, value} pairs
  # the consumption-side reading cares about.
  #
  # The previous version tried to sum flat `a_act_energy`, `b_act_energy`,
  # `c_act_energy` keys — those names are from the OLD Shelly 3EM (Gen1)
  # and don't exist in the Gen3+ payload at all. The real Gen3+ layout
  # nests each phase's energy under `a_energy.total` / `b_energy.total` /
  # `c_energy.total`, and there is no separate *daily* counter — Shelly
  # publishes a lifetime `total` only. So we populate:
  #
  #   * consumption_power           from total_act_power
  #   * consumption_energy_total   from sum(a_energy.total, b_energy.total,
  #                                       c_energy.total)
  #
  # The dashboard's "Today's Consumption" is computed in SQL from
  # `MAX(consumption_energy_total) - MIN(consumption_energy_total)` over the
  # day — see `get_consumption_daily_stats/2`.
  defp shelly_json_to_pairs(json) do
    pairs =
      [
        {:consumption_power, shelly_total_act_power(json)},
        {:consumption_energy_total, shelly_sum_phase_energy(json)}
      ]

    Enum.reject(pairs, fn {_k, v} -> is_nil(v) end)
  end

  # Sum per-phase active power into a single household figure. The
  # 3EM's `total_act_power` is documented as the sum, but we keep the
  # implementation defensive against missing fields (some firmwares
  # have reported only the per-phase fields during early-access previews).
  defp shelly_total_act_power(json) do
    case cast_float(json["total_act_power"]) do
      nil -> shelly_sum_phase(json, ["a_act_power", "b_act_power", "c_act_power"])
      v -> v
    end
  end

  defp shelly_sum_phase(json, keys) do
    keys
    |> Enum.map(&cast_float(json[&1]))
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  # Sum the per-phase `*.energy.total` lifetime counters. Each phase's
  # energy object is itself a map with `total` (Wh), `by_minute` (array),
  # and `minute_ts` (int). The 3EM doesn't expose a daily counter, so the
  # lifetime total is the closest thing we have — the dashboard computes
  # "Today's Consumption" by differencing the first and last reading of
  # the day.
  #
  # Returns `nil` if no phase has a populated `.total` (e.g. a freshly-
  # reset Shelly that hasn't accrued any energy yet). The caller filters
  # nil pairs out of the saved row.
  defp shelly_sum_phase_energy(json) do
    sum =
      Enum.reduce(["a_energy", "b_energy", "c_energy"], 0.0, fn key, acc ->
        case json[key] do
          %{"total" => t} when not is_nil(t) -> acc + cast_float(t)
          _ -> acc
        end
      end)

    if sum == 0.0, do: nil, else: sum
  end

  # --- Shared helpers ----------------------------------------------------------

  # Log an "ignored" uplink (one we didn't recognise) at `Logger.info`. The
  # DTU is otherwise healthy — the firmware just publishes a topic we
  # don't yet parse (or formats it in a way we don't handle). Downgrading
  # these from `record_dtu_error/2` (which used to persist a row + show
  # a user-visible error bubble) to a plain info log keeps the user's
  # manage-device error panel focused on real issues they can act on,
  # while preserving enough breadcrumbs in the log for a developer to
  # figure out what topic the firmware started publishing.
  #
  # The payload is included in the line so a developer grepping the log
  # for an unfamiliar topic immediately sees the wire-level bytes the
  # device sent on that topic — no second lookup needed.
  defp log_unknown_uplink(kind, device_id, topic_str, payload) do
    snippet = format_payload_snippet(payload)

    Logger.info(fn ->
      suffix = if snippet == "", do: "", else: " — payload: " <> snippet

      "[Telemetry] " <>
        kind <>
        " DTU=" <>
        to_string(device_id) <> " topic not yet handled: " <> inspect(topic_str) <> suffix
    end)
  end

  # Format a (binary) MQTT payload for inclusion in a user-visible error
  # message or a Logger line. `format_payload_snippet/1` returns the
  # first 200 chars (with an ellipsis if truncated) — used in long error
  # messages and logs where a multi-KB Shelly status JSON would drown the
  # line. The UI panel renders the snippet inside `<pre class="whitespace-pre-wrap">`
  # so JSON-like payloads keep their shape.
  #
  # Returns `""` for nil so the caller can simply concat without a special
  # case — important for messages that mix topic-only and payload-having
  # errors.
  @payload_snippet_limit 200

  defp format_payload_snippet(nil), do: ""

  defp format_payload_snippet(payload) when is_binary(payload) do
    cond do
      byte_size(payload) <= @payload_snippet_limit -> sanitize_payload(payload)
      true -> sanitize_payload(binary_part(payload, 0, @payload_snippet_limit)) <> "…"
    end
  end

  defp format_payload_snippet(_), do: ""

  # Replace ASCII control characters (other than newlines) with `?` so a
  # payload with NULs / tabs doesn't break the Logger formatter or make
  # the UI panel's text wrap unpredictably. A `null` byte in the input
  # would otherwise terminate C-string tooling downstream.
  defp sanitize_payload(payload) when is_binary(payload) do
    payload
    |> :unicode.characters_to_binary()
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/, "?")
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
  # ch0 carries the inverter-level AC aggregate (P_AC, calculated
  # P_DC, frequency, temperature, and the consolidated `YieldDay` /
  # `YieldTotal` counters); ch1..6 carry only the per-string DC inputs
  # (P_DC). The `YieldDay` / `YieldTotal` firmware fields are
  # **inverter-aggregate only** — AhoyDTU does not publish them per
  # MPPT, and even on firmware versions that do, the per-MPPT values
  # are sub-totals the firmware has already summed into ch0's value
  # (AhoyDTU ch0 is the cumulative inverter-level value).
  #
  # Persisting ch1..6 yield fields as separate rows would therefore
  # double-count the inverter's true daily / lifetime production. The
  # parser deliberately extracts only `dc_power` from per-MPPT JSON
  # payloads and lets ch0 be the single source of truth for yield.
  #
  # `cast_ahoy_yield/1` normalises AhoyDTU's kWh-published `YieldTotal`
  # to Wh at the parser boundary so the column holds Wh uniformly
  # with OpenDTU. `YieldDay` lands verbatim (AhoyDTU publishes it in
  # Wh on this firmware). The dashboard's existing
  # `Devices.get_daily_stats/3` `/ 1000` Wh → kWh divisor renders
  # the firmware's kWh figure verbatim.
  defp ahoy_json_to_pairs(json, "ch0") do
    [
      {:ac_power, cast_float(json["P_AC"])},
      {:dc_power, cast_float(json["P_DC"])},
      {:yield_day, cast_float(json["YieldDay"])},
      {:yield_total, cast_ahoy_yield(json["YieldTotal"])},
      {:frequency, cast_float(json["F_AC"])},
      {:temperature, cast_float(json["Temp"])},
      {:producing, parse_ahoy_value(:producing, json["producing"])}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp ahoy_json_to_pairs(json, _dc_channel) do
    # Per-MPPT DC channels (ch1..6) carry only `P_DC`. The firmware
    # does **not** publish `YieldDay` / `YieldTotal` for these
    # channels — the inverter-level yield is carried on ch0 only —
    # so the parser drops any yield fields from per-MPPT payloads.
    [
      {:dc_power, cast_float(json["P_DC"])}
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

  # AhoyDTU's `YieldTotal` arrives in **kWh** on the numeric-topic
  # layout (e.g. `balcony-inv/ch0/YieldTotal`); `YieldDay` arrives
  # in **Wh** (matching OpenDTU's convention) — see
  # `ahoy_json_to_pairs/2` for the per-field rationale. `cast_ahoy_yield/1`
  # multiplies the lifetime counter by 1000 so the column holds Wh;
  # the daily counter is parsed verbatim via `cast_float/1`. The
  # dashboard's existing `get_daily_stats/3` `/1000` divisor renders
  # the correct kWh figure for both the daily and the lifetime fields.
  #
  # Per-MPPT numeric topics (`ch1..6/YieldDay` and `ch1..6/YieldTotal`)
  # are **not** extracted here — AhoyDTU publishes inverter-aggregate
  # yield on ch0 only; ch1..6 carry only DC power per-string. Any
  # per-MPPT yield uplink falls through to `parse_ahoy_value/2`'s
  # default `cast_float/1` clause, which lands a raw (mostly stale)
  # Wh value in the row. The dashboard's per-MPPT overcounting is
  # eliminated because the ch0 (mppt_index = 0) row carries the
  # canonical value; the per-MPPT rows are ignored.
  defp parse_ahoy_value(:yield_total, payload) do
    cast_ahoy_yield(payload)
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

  # AhoyDTU publishes its **lifetime cumulative** counter
  # (`YieldTotal`) in **kWh** on both the JSON and numeric-topic
  # layouts. The daily counter (`YieldDay`) is published in **Wh**
  # (matching OpenDTU's convention) — see `ahoy_json_to_pairs/2`
  # for the per-field rationale. Everything downstream
  # (`readings.yield_total`, the chart,
  # `Devices.get_daily_stats/3`'s `/ 1000` Wh → kWh divisor) assumes
  # **Wh** semantics uniformly, so we normalise AhoyDTU's `YieldTotal`
  # kWh value to Wh at the parser boundary by multiplying by 1000.
  #
  # Multiplying at the parser keeps the rest of the pipeline oblivious
  # to the firmware difference. OpenDTU rows and AhoyDTU rows are
  # indistinguishable in the DB column and the dashboard query —
  # `get_daily_stats/3` treats them uniformly. A future per-DTU
  # settings toggle (e.g. "AhoyDTU uses Wh instead of kWh for the
  # lifetime counter") only changes this one call site, not every
  # reader.
  #
  # `nil` falls through so the buffer/dashboard's existing `nil` handling
  # (treat as 0, omit from the row) keeps working for HALF-published
  # payloads where some fields are present and others aren't.
  defp cast_ahoy_yield(nil), do: nil
  defp cast_ahoy_yield(value) when is_float(value), do: value * 1000.0
  defp cast_ahoy_yield(value) when is_integer(value), do: value * 1000.0

  defp cast_ahoy_yield(value) when is_binary(value) do
    case cast_float(value) do
      nil -> nil
      v when is_number(v) -> v * 1000.0
    end
  end

  defp cast_ahoy_yield(_), do: nil

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
