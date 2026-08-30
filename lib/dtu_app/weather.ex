defmodule DtuApp.Weather do
  @moduledoc """
  Public facade for weather data. Orchestrates `Weather.Cache` (TTL
  in-memory store) and `Weather.OpenMeteo` (the HTTP client).

  The contract is "graceful degradation": the dashboard must never
  break over weather. `cloud_cover_for/3` returns `nil` whenever
  coords are missing or the upstream call fails, so callers can
  plug the result into a `case ... do nil -> "" end` and let the
  rest of the chart render normally.

  Reads are cheap (`:public, :named_table` ETS — no GenServer hop).
  Writes go through the Cache GenServer so the lazy sweep on every
  `put/2` stays single-threaded.

  Caching strategy:
    * Cache key is `{trunc(lat), trunc(lon), Date.utc_today()}`. One
      fetch per ~111 km per day per user. Hits return the cached
      payload without HTTP. Misses call Open-Meteo and store the
      result for 15 minutes (the Cache TTL — older entries are
      pruned on the next write).
    * The date in the key means a long-lived tab re-fetches after
      midnight (UTC). The chart's local-day handling already
      pivots on the user's calendar date, so this is consistent.
  """

  alias DtuApp.Weather.{Cache, OpenMeteo}

  @doc """
  Returns cloud-cover data for `lat` / `lon`, fetching from
  Open-Meteo if the cache is empty for today.

  Returns `nil` when:
    * `lat` or `lon` is `nil`
    * the upstream call fails (network error or HTTP 4xx/5xx)

  Returns `{:ok, decoded_payload}` on cache hit or successful fetch.
  """
  @spec cloud_cover_for(
          float() | integer() | Decimal.t() | nil,
          float() | integer() | Decimal.t() | nil,
          keyword()
        ) :: {:ok, map()} | nil
  def cloud_cover_for(nil, _lon, _opts), do: nil
  def cloud_cover_for(_lat, nil, _opts), do: nil

  def cloud_cover_for(lat, lon, opts) when is_number(lat) and is_number(lon) do
    key = Cache.key(lat, lon, Date.utc_today())

    case Cache.get(key) do
      nil ->
        case OpenMeteo.hourly_cloud_cover(lat, lon, opts) do
          {:ok, decoded} = ok ->
            Cache.put(key, decoded)
            ok

          _ ->
            nil
        end

      cached ->
        cached
    end
  end

  @doc """
  Returns one of `:clear | :partly_cloudy | :mostly_cloudy | :overcast`
  for `lat` / `lon` based on the most-recent cloud-cover reading
  cached today.

  Returns `nil` when coords are missing or no data has been cached
  yet — the caller (the stat card slot) treats that as "don't
  render the card".
  """
  @spec current_condition(
          float() | integer() | Decimal.t() | nil,
          float() | integer() | Decimal.t() | nil
        ) :: :clear | :partly_cloudy | :mostly_cloudy | :overcast | nil
  def current_condition(nil, _lon), do: nil
  def current_condition(_lat, nil), do: nil

  def current_condition(lat, lon) when is_number(lat) and is_number(lon) do
    key = Cache.key(lat, lon, Date.utc_today())

    case Cache.get(key) do
      %{hourly: %{time: times, cloud_cover: values}}
      when is_list(times) and is_list(values) ->
        case most_recent_pair(times, values) do
          nil -> nil
          {_, pct} -> bucket_condition(pct)
        end

      _ ->
        nil
    end
  end

  # Bucket boundaries chosen to match how the major weather apps
  # phrase conditions:
  #   0–25%   → :clear          "clear" / "sunny"
  #   25–50%  → :partly_cloudy  "partly cloudy" / "mostly sunny"
  #   50–85%  → :mostly_cloudy  "mostly cloudy"
  #   85–100% → :overcast       "overcast"
  #
  # The boundaries are inclusive on the lower end so 25% is still
  # :clear — the major apps round up to "partly cloudy" only when
  # coverage crosses a perceptual threshold. Tuned for a 1-hour
  # sampling interval; with finer granularity we'd want to factor
  # in the duration of each reading, but Open-Meteo's hourly
  # resolution is already coarse.
  @doc false
  @spec bucket_condition(integer()) ::
          :clear | :partly_cloudy | :mostly_cloudy | :overcast
  def bucket_condition(pct) when is_integer(pct) and pct >= 0 and pct <= 25, do: :clear
  def bucket_condition(pct) when is_integer(pct) and pct >= 26 and pct <= 50, do: :partly_cloudy
  def bucket_condition(pct) when is_integer(pct) and pct >= 51 and pct <= 85, do: :mostly_cloudy
  def bucket_condition(pct) when is_integer(pct) and pct >= 86 and pct <= 100, do: :overcast

  # Picks the latest (time, value) pair. Times are UTC `DateTime`s
  # returned by `OpenMeteo.decode/1`; we sort by the DateTime's
  # internal representation. Returns `nil` for empty inputs so the
  # caller doesn't have to special-case "no readings".
  defp most_recent_pair([], _), do: nil
  defp most_recent_pair(_, []), do: nil

  defp most_recent_pair([t], [v]), do: {t, v}

  defp most_recent_pair(times, values) do
    pairs = Enum.zip(times, values)
    Enum.max_by(pairs, fn {t, _} -> DateTime.to_unix(t, :second) end)
  end
end
