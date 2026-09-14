defmodule DtuApp.MqttBroker.Telemetry.AhoyDtu do
  @moduledoc """
  AhoyDTU uplink parser + handler.

  Lives behind `DtuApp.MqttBroker.Telemetry.handle_info/2`'s
  `:ahoydtu` branch. AhoyDTU publishes two layouts on the same
  `base_topic`:

      {base}/{inverter}/ch{0..6}/{Metric}      -> single scalar (numeric layout)
      {base}/{inverter}/ch{0..6}               -> JSON object   (JSON layout)
      {base}/total                              -> {:ignored, :ignored_topic}
      {base}/total/{Metric}                    -> {:ignored, :ignored_topic}

  Anything else is `{:ignored, :ignored_topic}` — the parser
  currently emits a single `{:error, :ignored_topic}` reason
  (downgraded to a Logger.info line, not a `dtu_errors` row, see
  the parent `Telemetry` module's rationale).

  ## State

  `state.buffers` is owned here too, with the same
  `%{{dtu_id, {inverter, channel}} => row_map}` shape as
  `OpenDtu`. The buffer flushes on every recognised metric
  arrival — the previous "only flush when AC power arrives"
  regression stuck yield-only rows in RAM forever; the fix
  flushes whenever *any* recognised metric lands.

  ## Yield semantics

  AhoyDTU publishes `YieldTotal` in **kWh** and `YieldDay` in
  **Wh**. The column holds Wh uniformly (OpenDTU + AhoyDTU are
  indistinguishable downstream), so we normalise via
  `cast_ahoy_yield/1` at the parser boundary. See
  `PayloadHelpers.cast_ahoy_yield/1` for the rationale.

  ## Per-MPPT yield suppression

  AhoyDTU's ch1..6 are per-MPPT DC strings. The firmware does
  NOT publish per-MPPT yields (`YieldDay` / `YieldTotal` are
  ch0-only). Even on firmware versions that did publish them,
  ch1..6's values are sub-totals already summed into ch0's value
  (AhoyDTU ch0 is the cumulative inverter-level figure). Letting
  per-MPPT yields land as separate rows would cause the
  dashboard's `MAX(yield_day)` aggregation to sum them into
  today's total — double-counting. The parser suppresses
  per-MPPT yields at two sites: numeric-layout per-MPPT
  (`metric in ["YieldDay", "YieldTotal"] and channel >= 1` →
  `:other`) and JSON-layout per-MPPT (`ahoy_json_to_pairs/2`'s
  ch1..6 branch only extracts `dc_power`).
  """

  import DtuApp.MqttBroker.Telemetry.PayloadHelpers

  require Logger

  def handle(client_id, device_info, topic_str, payload, state, safe_db_call) do
    case parse(topic_str, device_info.base_topic, payload) do
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

          case safe_db_call.(fn ->
                 DtuApp.Devices.create_reading_and_touch_power_at(reading_attrs)
               end) do
            {:ok, db_reading} ->
              Logger.debug(
                "[Telemetry] Saved AhoyDTU reading for DTU #{device_info.id} " <>
                  "inverter=#{name} channel=#{channel}"
              )

              Phoenix.PubSub.broadcast(
                DtuApp.PubSub,
                DtuApp.MqttBroker.Telemetry.reading_topic(),
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

            :ok ->
              # safe_db_call caught a sandbox-teardown exception — skip
              # the rest of this uplink's processing and leave the state
              # untouched.
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

  defp record_dtu_error(device_id, message) do
    DtuApp.MqttBroker.Telemetry.record_dtu_error(device_id, message)
  end

  defp parse(topic_str, base_topic, payload) do
    case String.split(topic_str, "/") do
      # Numeric layout: {base}/{name}/ch{0..6}/{Metric} -> one scalar.
      [binary_base, name, <<"ch", rest::binary>> = channel, metric]
      when binary_base == base_topic and channel != "total" ->
        # If the payload is itself JSON, defer to the JSON-layout clause below;
        # otherwise treat it as a single numeric scalar.
        if json_object?(payload) do
          {:error, :ignored_topic}
        else
          channel_idx = channel_index(rest)
          # AhoyDTU firmware publishes `YieldDay` / `YieldTotal` only on
          # ch0 — the inverter-aggregate counter. Per-MPPT channels
          # (ch1..6) carry only per-string DC power. We coerce a per-MPPT
          # yield metric to `:other` here so it falls through to the
          # "ignored metric" path in the buffer handler and the row
          # lands without a yield field. Mirrors `ahoy_json_to_pairs/2`,
          # which drops yield fields from per-MPPT JSON layouts the
          # same way. Without this guard the parser stored per-MPPT
          # yield values as separate rows, and the dashboard's
          # `MAX(yield_day)` aggregation summed them into today's
          # total — double-counting the inverter's actual production
          # (ch0 already = ch1 + ch2 by the firmware's design).
          metric_atom =
            if channel_idx >= 1 and metric in ["YieldDay", "YieldTotal"],
              do: :other,
              else: parse_metric(metric)

          value = parse_value(metric_atom, payload)
          {:ok, name, channel_idx, [{metric_atom, value}]}
        end

      # JSON layout: {base}/{name}/ch{0..6} -> a JSON object of many metrics.
      [binary_base, name, <<"ch", rest::binary>> = channel]
      when binary_base == base_topic and channel != "total" ->
        case Jason.decode(payload) do
          {:ok, json_map} when is_map(json_map) ->
            pairs = json_to_pairs(json_map, channel)
            {:ok, name, channel_index(rest), pairs}

          _ ->
            {:error, :ignored_topic}
        end

      # AhoyDTU fleet-wide totals on `{base}/total` and
      # `{base}/total/{Metric}` — the firmware sums every inverter's
      # `YieldDay` / `YieldTotal` (and emits that aggregate on the
      # `total` topic) and as a side-effect publishes `ac_power` /
      # `dc_power` totals that we don't currently consume. We
      # deliberately **drop** these uplinks at the parser boundary
      # rather than persisting a fleet-aggregate row keyed by
      # `inverter_serial = "_fleet"`, for two reasons:
      #
      #   1. The AhoyDTU firmware doesn't always publish `total` —
      #      the rate-limited path skips emission when nothing has
      #      changed since the last tick, so any code path that
      #      prefers `_fleet` becomes a half-reliable source of
      #      truth. Falling back to a per-inverter aggregation is
      #      the same code path either way.
      #
      #   2. Treating per-inverter `yield_day` counters as
      #      monotonic Wh figures that reset at midnight and
      #      climbing through the day, the day's total per inverter
      #      IS its last `yield_day` reading. Summing that across
      #      every inverter yields the fleet's daily total without
      #      the firmware's intermediate aggregation step (and
      #      without its rounding). Same logic, same shape, one
      #      fewer special case.
      #
      # The dashboard computes today's / lifetime yield via
      # `get_daily_stats/3`'s "sum each inverter's last reading"
      # path (and the per-day historical chart via
      # `list_range_yield_data/4`'s equivalent). No `_fleet` rows
      # ever enter the DB.
      #
      # As a defence against any legacy `_fleet` rows that were
      # persisted by older parser versions (pre-this change), the
      # query-layer still filters `inverter_serial != "_fleet"` in
      # the chart data paths — see
      # `DtuApp.Devices.list_day_readings_for_chart/4` and friends.
      [binary_base, "total"]
      when binary_base == base_topic ->
        {:error, :ignored_topic}

      [binary_base, "total", _metric]
      when binary_base == base_topic ->
        {:error, :ignored_topic}

      _ ->
        {:error, :ignored_topic}
    end
  end

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
  # Per-MPPT yields on the numeric-topic layout are also dropped at the
  # parse site in `parse/3`.
  defp json_to_pairs(json, "ch0") do
    [
      {:ac_power, cast_float(json["P_AC"])},
      {:dc_power, cast_float(json["P_DC"])},
      {:yield_day, cast_float(json["YieldDay"])},
      {:yield_total, cast_ahoy_yield(json["YieldTotal"])},
      {:frequency, cast_float(json["F_AC"])},
      {:temperature, cast_float(json["Temp"])},
      {:producing, parse_value(:producing, json["producing"])}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp json_to_pairs(json, _dc_channel) do
    # Per-MPPT DC channels (ch1..6) carry only `P_DC`. The firmware
    # does **not** publish `YieldDay` / `YieldTotal` for these
    # channels — the inverter-level yield is carried on ch0 only —
    # so the parser drops any yield fields from per-MPPT payloads.
    [
      {:dc_power, cast_float(json["P_DC"])}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp parse_metric("P_AC"), do: :ac_power
  defp parse_metric("P_DC"), do: :dc_power
  defp parse_metric("YieldDay"), do: :yield_day
  defp parse_metric("YieldTotal"), do: :yield_total
  defp parse_metric("F_AC"), do: :frequency
  defp parse_metric("Temp"), do: :temperature
  defp parse_metric("producing"), do: :producing
  defp parse_metric("reachable"), do: :reachable
  defp parse_metric(_), do: :other

  defp parse_value(metric, payload) when metric in [:producing, :reachable] do
    case payload do
      "1" -> true
      "0" -> false
      "true" -> true
      "false" -> false
      _ -> nil
    end
  end

  defp parse_value(:yield_total, payload) do
    cast_ahoy_yield(payload)
  end

  defp parse_value(_metric, payload) do
    cast_float(payload)
  end
end
