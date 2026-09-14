defmodule DtuApp.MqttBroker.Telemetry.Shelly do
  @moduledoc """
  Shelly Plus 3EM (Gen3+) uplink parser + handler.

  Lives behind `DtuApp.MqttBroker.Telemetry.handle_info/2`'s
  `:shelly3em` branch. The Shelly publishes a JSON status object
  on `{base}/status/em:0` (or `emdata:0` on some firmware versions)
  carrying per-phase active power, per-phase energy totals, and
  total instantaneous power — we extract just the consumption-
  side fields and write a `power_type: "consumption"` row.

  Topic patterns:

      {base}/online          -> {:ignored, :online_lwt}     (LWT only)
      {base}/status/em:0     -> {:reading, pairs}           (JSON status)
      {base}/status/emdata:0 -> {:reading, pairs}           (older firmwares)
      {bare base}            -> {:ignored, :unknown_suffix}
      anything else          -> {:ignored, :unknown_suffix} if prefix matches,
                                {:ignored, :prefix_mismatch} if not

  `:prefix_mismatch` is the only `:ignored` reason that surfaces
  as a user-visible `dtu_errors` row + warning log, because the
  fix-it action is concrete (set the Shelly's MQTT prefix).

  ## State

  Shelly uplinks don't buffer — each JSON status publish is a
  complete reading. `state.buffers` is therefore untouched by
  this handler; we just pass `state` through unchanged on
  every reply.
  """

  import DtuApp.MqttBroker.Telemetry.PayloadHelpers

  require Logger

  def handle(client_id, device_info, topic_str, payload, state, safe_db_call) do
    case parse(topic_str, device_info.base_topic, payload) do
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

        case safe_db_call.(fn -> DtuApp.Devices.create_reading_and_touch_power_at(attrs) end) do
          {:ok, db_reading} ->
            Logger.debug(
              "[Telemetry] Saved Shelly reading for DTU #{device_info.id} " <>
                "consumption_power=#{inspect(db_reading.consumption_power)} " <>
                "consumption_energy_total=#{inspect(db_reading.consumption_energy_total)}"
            )

            Phoenix.PubSub.broadcast(
              DtuApp.PubSub,
              DtuApp.MqttBroker.Telemetry.reading_topic(),
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

          :ok ->
            # safe_db_call caught a sandbox-teardown exception — skip the
            # rest of this uplink's processing and leave the state untouched.
            {:noreply, state}
        end

      {:ignored, :prefix_mismatch} ->
        # The topic is from a Shelly device, but the MQTT prefix doesn't
        # match the device's `base_topic` here (Shelly's firmware default
        # is `shellyplus3em-XXXXXXXXXXXX`). Unlike OpenDTU/AhoyDTU
        # equivalent, we *do* surface this to the user — there's a
        # fix-it action (set the Shelly's MQTT prefix), and the
        # symptom ("device shows as online but no values") is hard to
        # diagnose from logs alone.
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

      {:ignored, :unknown_suffix} ->
        # The device's prefix is correctly configured (we matched it
        # above in `parse/3`'s `String.starts_with?/2` branch), but the
        # topic suffix is one we don't currently parse. The Shelly
        # Plus 3EM publishes several informational topics we don't
        # consume — `/info` (device-id / firmware / model JSON),
        # `/events`, `/events/rpc`, and outgoing `command/...` echoes
        # — which are firmware-emitted extras, not user-visible
        # errors. Log at info with topic + payload so a developer
        # reading logs can identify what the device is sending; do
        # NOT call `record_dtu_error/2` so the user's manage-device
        # error panel isn't polluted with metadata they can't act on.
        # Mirrors `log_unknown_uplink/4`'s OpenDTU / AhoyDTU path.
        log_unknown_uplink("Shelly", device_info.id, topic_str, payload)
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

  defp record_dtu_error(device_id, message) do
    DtuApp.MqttBroker.Telemetry.record_dtu_error(device_id, message)
  end

  defp parse(topic_str, base_topic, payload) do
    # Distinguish two "did not parse" cases the user can experience:
    #
    #   * `:prefix_mismatch` — the topic doesn't start with the device's
    #     configured `base_topic`. Real user-fixable error: the Shelly's
    #     MQTT prefix is unset / wrong. Surface as a WARN + persistent
    #     `dtu_errors` row + user-visible error bubble.
    #   * `:unknown_suffix` — prefix is correct, but the suffix is one
    #     we don't currently parse (`/info`, `/events`, `/events/rpc`,
    #     outgoing `command/...` echoes). Informational only — the
    #     firmware just emits extras we don't consume. Surface as
    #     `Logger.info` (no `dtu_errors` row, no user-visible error)
    #     so a developer reading logs can identify what the device is
    #     sending without polluting the manage-device error panel.
    #
    # Before this split, both cases fell through to a single
    # `{:ignored, :unknown_topic}` clause that always surfaced a
    # "Shelly topic mismatch — check the device's MQTT prefix" warning,
    # even for `/info` uplinks where the prefix IS correct. That
    # produced a misleading red-herring error the user couldn't act on.
    cond do
      topic_str == base_topic ->
        # Topic IS the prefix (no suffix). Defensive — a real Shelly
        # never publishes on the bare prefix. Treat as unknown_suffix.
        {:ignored, :unknown_suffix}

      String.starts_with?(topic_str, base_topic <> "/") ->
        # Strip the validated prefix so we can match the suffix
        # uniformly, independent of whether `base_topic` was one
        # segment (`shellies`) or many (`shellies/shellyplus3em`).
        # The previous two-arm `[binary_base, ...]` + `[b1, b2, ...]`
        # split was a workaround for that same problem.
        topic_str
        |> String.replace_prefix(base_topic <> "/", "")
        |> parse_suffix(payload)

      true ->
        {:ignored, :prefix_mismatch}
    end
  end

  # Parse the suffix portion of a Shelly topic (the part after the
  # device's `base_topic`). The prefix has already been validated
  # upstream, so we only need to discriminate the suffixes we
  # actually consume from everything else.
  defp parse_suffix(suffix, payload) do
    case String.split(suffix, "/") do
      # `online` retained LWT — we don't act on it explicitly; the
      # broker's disconnect path + `last_seen_at` updates already cover
      # liveness.
      ["online"] ->
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
      # Both `em:0` and `emdata:0` are accepted as valid suffixes — the
      # latter is published by some Shelly Plus 3EM firmware versions
      # alongside the more common `em:0`. The two suffixes carry the
      # same payload shape (a JSON object with the per-phase /
      # total_act_power fields below), so a single `json_to_pairs/1`
      # consumer is reused. Without the `emdata:0` clause, an
      # otherwise-correctly-prefixed uplink falls through to
      # `{:ignored, :unknown_suffix}` and is logged at info — the
      # prefix IS correct, only the suffix doesn't match.
      ["status", em] when em in ["em:0", "emdata:0"] ->
        case Jason.decode(payload) do
          {:ok, json} when is_map(json) ->
            {:reading, json_to_pairs(json)}

          _ ->
            {:ignored, :bad_json}
        end

      _ ->
        {:ignored, :unknown_suffix}
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
  defp json_to_pairs(json) do
    pairs =
      [
        {:consumption_power, total_act_power(json)},
        {:consumption_energy_total, sum_phase_energy(json)}
      ]

    Enum.reject(pairs, fn {_k, v} -> is_nil(v) end)
  end

  # Sum per-phase active power into a single household figure. The
  # 3EM's `total_act_power` is documented as the sum, but we keep the
  # implementation defensive against missing fields (some firmwares
  # have reported only the per-phase fields during early-access previews).
  defp total_act_power(json) do
    case cast_float(json["total_act_power"]) do
      nil -> sum_phase(json, ["a_act_power", "b_act_power", "c_act_power"])
      v -> v
    end
  end

  defp sum_phase(json, keys) do
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
  defp sum_phase_energy(json) do
    sum =
      Enum.reduce(["a_energy", "b_energy", "c_energy"], 0.0, fn key, acc ->
        case json[key] do
          %{"total" => t} when not is_nil(t) -> acc + cast_float(t)
          _ -> acc
        end
      end)

    if sum == 0.0, do: nil, else: sum
  end
end
