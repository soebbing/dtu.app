defmodule DtuApp.MqttBroker.Telemetry.PayloadHelpers do
  @moduledoc """
  Small, side-effect-free helpers shared by the OpenDTU / AhoyDTU /
  Shelly parsers in this folder. Extracted from
  `DtuApp.MqttBroker.Telemetry` so each parser module owns its
  own parsing + dispatch logic and this module owns the boring
  utility code that has nothing to do with any particular device
  kind:

    * JSON / boolean / float coercion (`json_object?/1`,
      `parse_bool/1`, `cast_float/1`, `truthy?/1`)
    * AhoyDTU-specific unit normalisation (`cast_ahoy_yield/1` —
      kWh → Wh at the parser boundary, see that function's doc)
    * Log-message formatting (`log_unknown_uplink/4`,
      `format_payload_snippet/1`, `sanitize_payload/1`)
    * Topic-segment integer parsing (`channel_index/1`)

  All functions are pure — no `Phoenix.PubSub`, no `Repo`, no
  `Logger.info` outside the `log_unknown_uplink/4` helper which
  is a Logger-only convenience the parsers all share.

  No tests of their own: they're exercised through every parser
  test, which is the right unit. Coverage is `mqtt_broker_test.exs`
  end-to-end via `Telemetry.handle_info/2`.
  """

  require Logger

  @payload_snippet_limit 200

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
  def log_unknown_uplink(kind, device_id, topic_str, payload) do
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
  def format_payload_snippet(nil), do: ""

  def format_payload_snippet(payload) when is_binary(payload) do
    cond do
      byte_size(payload) <= @payload_snippet_limit -> sanitize_payload(payload)
      true -> sanitize_payload(binary_part(payload, 0, @payload_snippet_limit)) <> "…"
    end
  end

  def format_payload_snippet(_), do: ""

  # Replace ASCII control characters (other than newlines) with `?` so a
  # payload with NULs / tabs doesn't break the Logger formatter or make
  # the UI panel's text wrap unpredictably. A `null` byte in the input
  # would otherwise terminate C-string tooling downstream.
  def sanitize_payload(payload) when is_binary(payload) do
    payload
    |> :unicode.characters_to_binary()
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/, "?")
  end

  # Extract the integer MPPT index from a channel segment like "ch0" -> 0,
  # "ch1" -> 1, "ch12" -> 12. Falls back to 0 on parse failure so a bad
  # topic doesn't crash the parser.
  def channel_index(<<>>), do: 0

  def channel_index(rest), do: Integer.parse(rest) |> elem(0) |> Kernel.||(0)

  def json_object?(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, value} when is_map(value) -> true
      _ -> false
    end
  end

  def parse_bool("1"), do: {:ok, true}
  def parse_bool("0"), do: {:ok, false}
  def parse_bool("true"), do: {:ok, true}
  def parse_bool("false"), do: {:ok, false}
  def parse_bool(_), do: :error

  def truthy?(1), do: true
  def truthy?(0), do: false
  def truthy?(true), do: true
  def truthy?(false), do: false
  def truthy?(_), do: nil

  def cast_float(nil), do: nil
  def cast_float(val) when is_integer(val), do: val * 1.0
  def cast_float(val) when is_float(val), do: val

  def cast_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> nil
    end
  end

  def cast_float(_), do: nil

  # AhoyDTU publishes its **lifetime cumulative** counter
  # (`YieldTotal`) in **kWh** on both the JSON and numeric-topic
  # layouts. The daily counter (`YieldDay`) is published in **Wh**
  # (matching OpenDTU's convention). Everything downstream
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
  def cast_ahoy_yield(nil), do: nil
  def cast_ahoy_yield(value) when is_float(value), do: value * 1000.0
  def cast_ahoy_yield(value) when is_integer(value), do: value * 1000.0

  def cast_ahoy_yield(value) when is_binary(value) do
    case cast_float(value) do
      nil -> nil
      v when is_number(v) -> v * 1000.0
    end
  end

  def cast_ahoy_yield(_), do: nil
end
