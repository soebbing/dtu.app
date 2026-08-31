defmodule DtuApp.Weather.OpenMeteo do
  @moduledoc """
  Thin HTTP client for Open-Meteo's free, no-API-key Forecast API.

  Currently exposes `hourly_cloud_cover/3`, which returns the past
  `past_days` days of hourly cloud-cover readings for a given
  coordinate pair, plus 1 day of forecast. Open-Meteo documents
  `past_days` as 0–92 (default 0); callers asking for more get
  clamped to 92 so the provider is a safe boundary.

  No Finch pool is configured here — `Req` brings its own default
  pool, which is the right scope for a single-purpose third-party
  call. Push traffic is intentionally kept on its own pool
  (`DtuAppWeb.WebPushFinch`) and never mixed with anything else;
  weather calls follow the same discipline in spirit, just by
  happening to use the default Req pool.

  The provider is intentionally stateless: every call hits the wire
  if you call it. Caching is the facade's responsibility
  (`DtuApp.Weather` + `DtuApp.Weather.Cache`) so the same provider
  can be reused from contexts that don't want a TTL.
  """

  @base_url "https://api.open-meteo.com/v1/forecast"
  @max_past_days 92
  @forecast_days 1

  @doc """
  Returns hourly cloud-cover readings for `lat` / `lon` covering the
  past `past_days` days plus `@forecast_days` of forecast.

  On HTTP 200 returns `{:ok, decoded_body}` where the body has been
  decoded into an Elixir map and the `time` strings have been parsed
  to `DateTime.t()`.

  On HTTP 4xx/5xx returns `{:error, %{status: integer(), body: String.t()}}`.

  Returns `nil` when `lat` or `lon` is `nil` — the "no coords → no
  call" contract is what lets the dashboard render nothing for
  users who denied geolocation, without a special-case upstream.
  """
  @spec hourly_cloud_cover(
          float() | integer() | Decimal.t() | nil,
          float() | integer() | Decimal.t() | nil,
          keyword()
        ) ::
          {:ok, %{hourly: %{time: [DateTime.t()], cloud_cover: [integer()]}}}
          | {:error, %{status: integer(), body: String.t()}}
          | nil
  def hourly_cloud_cover(nil, _lon, _opts), do: nil
  def hourly_cloud_cover(_lat, nil, _opts), do: nil

  # Coerce `Decimal.t()` coords down to float before the
  # `is_number/1`-guarded clause. `Weather.cloud_cover_for/3` only
  # hits this on cache miss, so the symptom of leaving this broken
  # would be a FunctionClauseError on first-load + clear-cache —
  # harder to repro than the always-hit facade path. Honoring the
  # `@spec` cheaply is the right fix.
  def hourly_cloud_cover(%Decimal{} = lat, %Decimal{} = lon, opts),
    do: hourly_cloud_cover(Decimal.to_float(lat), Decimal.to_float(lon), opts)

  def hourly_cloud_cover(%Decimal{} = lat, lon, opts) when is_number(lon),
    do: hourly_cloud_cover(Decimal.to_float(lat), lon, opts)

  def hourly_cloud_cover(lat, %Decimal{} = lon, opts) when is_number(lat),
    do: hourly_cloud_cover(lat, Decimal.to_float(lon), opts)

  def hourly_cloud_cover(lat, lon, opts) when is_number(lat) and is_number(lon) do
    past_days = clamp_past_days(opts[:past_days] || 1)

    params = %{
      "latitude" => to_string(lat),
      "longitude" => to_string(lon),
      "hourly" => "cloud_cover",
      "past_days" => to_string(past_days),
      "forecast_days" => to_string(@forecast_days)
    }

    req_opts =
      Application.get_env(:dtu_app, __MODULE__, [])
      |> Keyword.merge(
        base_url: @base_url,
        params: params,
        decode_body: false,
        # Surface HTTP errors immediately rather than retrying — the
        # caller (`DtuApp.Weather`) treats any non-200 as `nil`, and
        # waiting through Req's default 3-retry backoff (≈12s) makes
        # the dashboard mount feel broken even though the failure is
        # silent.
        retry: false
      )

    case Req.request(req_opts) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, decode(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body_to_string(body)}}

      {:error, exception} ->
        {:error, %{status: 0, body: Exception.message(exception)}}
    end
  end

  defp clamp_past_days(n) when is_integer(n) and n >= 1, do: min(n, @max_past_days)
  defp clamp_past_days(_), do: 1

  # Open-Meteo returns ISO-8601 timestamps in the compact form
  # `"2026-08-30T00:00"` (no seconds, no offset). Elixir 1.18's
  # `DateTime.from_iso8601/1` rejects this form, so we normalise to
  # `"…T00:00:00Z"` (UTC by spec) and parse via `NaiveDateTime` →
  # `DateTime.from_naive/2`. Times are UTC by spec — see
  # https://open-meteo.com/en/docs ("UTC time zone").
  defp decode(body) when is_binary(body) do
    %{"hourly" => %{"time" => times, "cloud_cover" => values}} = Jason.decode!(body)

    parsed_times =
      for t <- times do
        normalise_iso8601!(t)
      end

    %{
      hourly: %{
        time: parsed_times,
        cloud_cover: values
      }
    }
  end

  defp normalise_iso8601!(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _offset} ->
        dt

      {:error, :invalid_format} ->
        # Open-Meteo returns compact `"2026-08-30T00:00"` (no
        # seconds, no offset). Elixir 1.18's strict ISO parser
        # rejects this, so normalise to `"…T00:00:00Z"` (UTC by
        # spec — see https://open-meteo.com/en/docs) and parse via
        # NaiveDateTime → DateTime.from_naive/2.
        padded = timestamp |> pad_seconds() |> ensure_utc_suffix()
        {:ok, naive} = NaiveDateTime.from_iso8601(padded)
        {:ok, dt} = DateTime.from_naive(naive, "Etc/UTC")
        dt
    end
  end

  # If the timestamp has no seconds component, append ":00".
  defp pad_seconds(timestamp) do
    case String.split(timestamp, "T") do
      [_date, time] ->
        case String.split(time, ":") do
          [_h, _m] -> timestamp <> ":00"
          _ -> timestamp
        end

      _ ->
        timestamp
    end
  end

  defp ensure_utc_suffix(s) do
    if String.ends_with?(s, "Z"), do: s, else: s <> "Z"
  end

  defp body_to_string(body) when is_binary(body), do: body
  defp body_to_string(body), do: Jason.encode!(body)
end
