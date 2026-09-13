defmodule DtuAppWeb.DashboardLive.Weather do
  @moduledoc """
  Cloud-cover band + current-condition helpers used by the dashboard
  LiveView.

  The cluster:

    * `build_cloud_cover_band/5` — projects the user's hourly
      cloud-cover series onto the chart's visible X range.
    * `weather_current_condition/1` + `weather_current_pct/1` —
      read the most recent hourly sample for the current-condition
      card. Both short-circuit to `nil` when the user has no
      coordinates (so the card hides cleanly).
    * `most_recent_pct/2` — pure helper that finds the latest
      `(time, cloud_cover_pct)` pair from a `Weather` hourly response.
    * `weather_fingerprint/5` — value-comparable tuple of the five
      weather inputs (coords / date / x-range / tz) that gates the
      async re-fetch in `kickoff_weather_fetch/6`.
    * `fetch_weather_snapshot/5` — builds the snapshot map
      (`cloud_cover_line`, `current_cloud_cover`,
      `current_cloud_cover_pct`).
    * `apply_weather_snapshot/2` — applies the snapshot to a socket.
    * `kickoff_weather_fetch/6` — orchestrates the fetch (inline on
      HTTP / initial-WS render, deferred `Task` on subsequent WS
      callbacks) under the fingerprint gate.
    * `assign_weather_placeholders/1` — assigns empty cloud-cover
      / current-cloud-cover values so the chart and card have
      something to render before the snapshot lands.

  ## HTTP vs WebSocket split

  `kickoff_weather_fetch/6` is the only HTTP-vs-WebSocket split in
  the dashboard's mount path. The HTTP render is one-shot (no
  follow-up render) so the fetch runs inline; the WebSocket mount
  and subsequent callbacks run a deferred `Task` so the
  already-rendered chart doesn't flicker.

  ## Failure handling

  `Weather.cloud_cover_for/3` already returns `nil` on nil coords
  or upstream failure, so no try/rescue is needed in the happy
  path. `kickoff_weather_fetch/6`'s inline branch DOES wrap the
  apply in a try/catch — the rationale (captive portals,
  non-JSON 200s from upstream) is in the call-site comment.
  """

  require Logger

  alias DtuApp.Weather

  @spec build_cloud_cover_band(map(), Date.t(), integer(), integer(), integer()) :: map() | nil
  # Project the Open-Meteo hourly cloud-cover series onto the
  # visible X range of the dashboard chart. Returns a struct-shaped
  # map the SVG renderer consumes (`path`, `area_path`, `has_data`,
  # `points`, `ticks`); see `ChartHelpers.cloud_cover_line/6` for
  # the projection math. The chart width is hard-coded to 800 to
  # mirror the original inline `build_cloud_cover_band/5` that
  # lived in `DashboardLive` before this extraction — the SVG
  # renderer is fixed-size at 800×230 across breakpoints, so this
  # constant matches every other call site in the dashboard.
  def build_cloud_cover_band(user, local_date, x_min_seconds, x_max_seconds, tz_offset_seconds) do
    case DtuApp.Weather.cloud_cover_for(user.latitude, user.longitude, past_days: 30) do
      nil ->
        DtuAppWeb.DashboardLive.ChartHelpers.cloud_cover_line(
          nil,
          local_date,
          x_min_seconds,
          x_max_seconds,
          tz_offset_seconds,
          800
        )

      {:ok, %{hourly: %{time: times, cloud_cover: values}}} ->
        readings =
          Enum.zip(times, values) |> Enum.map(fn {time, pct} -> %{time: time, pct: pct} end)

        DtuAppWeb.DashboardLive.ChartHelpers.cloud_cover_line(
          readings,
          local_date,
          x_min_seconds,
          x_max_seconds,
          tz_offset_seconds,
          800
        )

      _ ->
        DtuAppWeb.DashboardLive.ChartHelpers.cloud_cover_line(
          nil,
          local_date,
          x_min_seconds,
          x_max_seconds,
          tz_offset_seconds,
          800
        )
    end
  end

  @spec weather_current_condition(map()) :: String.t() | nil
  # Current weather condition (e.g. "Clear", "Cloudy") for the
  # current-condition card. Coords are required — `nil` for either
  # hides the card.
  def weather_current_condition(%{latitude: nil}), do: nil
  def weather_current_condition(%{longitude: nil}), do: nil

  def weather_current_condition(user) do
    Weather.current_condition(user.latitude, user.longitude)
  end

  @spec weather_current_pct(map()) :: number() | nil
  # Most-recent cloud-cover percentage for the card's tooltip /
  # visual fill. Coords are required — `nil` for either hides the
  # card. Pulls the latest hourly sample from the past-30-days
  # cloud-cover window (so the value tracks the user's true local
  # time, not the UTC server time).
  def weather_current_pct(%{latitude: nil}), do: nil
  def weather_current_pct(%{longitude: nil}), do: nil

  def weather_current_pct(user) do
    case Weather.cloud_cover_for(user.latitude, user.longitude, past_days: 30) do
      {:ok, %{hourly: %{time: times, cloud_cover: values}}} ->
        case most_recent_pct(times, values) do
          nil -> nil
          pct -> pct
        end

      _ ->
        nil
    end
  end

  @spec most_recent_pct([DateTime.t()], [number()]) :: number() | nil
  # Return the cloud-cover pct at the most recent timestamp in the
  # parallel `times` / `values` arrays. Empty inputs (no hourly
  # response) return `nil`; a single-element response returns the
  # one value verbatim. Multi-element responses zip + max-by Unix
  # seconds — same shape as `Weather`'s response ordering, so the
  # last-by-time entry is what we want.
  def most_recent_pct([], _), do: nil
  def most_recent_pct(_, []), do: nil
  def most_recent_pct([_t], [v]), do: v

  def most_recent_pct(times, values) do
    pairs = Enum.zip(times, values)
    {_t, pct} = Enum.max_by(pairs, fn {t, _} -> DateTime.to_unix(t, :second) end)
    pct
  end

  @spec weather_fingerprint(map(), Date.t(), integer(), integer(), integer()) :: tuple()
  # Cloud-cover fingerprint — see `kickoff_weather_fetch/6` for the
  # full rationale. The five inputs that determine whether the
  # Open-Meteo response would differ from the snapshot we already
  # hold, packed into a single value-comparable tuple:
  #
  #   * `user.latitude` / `user.longitude` — different fetch bucket
  #     (`Weather.Cache.key/3` rounds to 1°, but only when the
  #     coords cross that integer boundary);
  #   * `local_date` — the daily-band start anchors on the user's
  #     local date, so different dates need different snapshots;
  #   * `(x_min_seconds, x_max_seconds)` — chart's visible range;
  #     outside-of-range samples get clipped by
  #     `ChartHelpers.cloud_cover_band/4`, so the same daily fetch
  #     can satisfy several ranges within the same day;
  #   * `tz_offset_seconds` — affects where the local-day band
  #     starts; without it, a Berlin user on UTC+2 and a London
  #     user on UTC+0 would share a snapshot keyed by the same
  #     wall-clock UTC fetch.
  def weather_fingerprint(user, local_date, x_min, x_max, tz_offset_seconds) do
    {user.latitude, user.longitude, local_date, x_min, x_max, tz_offset_seconds}
  end

  @spec assign_weather_placeholders(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  # Pre-fetch placeholders so the chart and current-condition card
  # always have something to render before the snapshot lands.
  # Called from `kickoff_weather_fetch/6` inside the
  # `fingerprint_changed?` branch so steady-state `:reading`
  # broadcasts don't wipe the populated assigns.
  def assign_weather_placeholders(socket) do
    socket
    |> Phoenix.Component.assign(:cloud_cover_line, %{
      path: "",
      area_path: "",
      has_data: false,
      points: [],
      ticks: [0, 25, 50, 75, 100]
    })
    |> Phoenix.Component.assign(:current_cloud_cover, nil)
    |> Phoenix.Component.assign(:current_cloud_cover_pct, nil)
  end

  @spec fetch_weather_snapshot(map(), Date.t(), integer(), integer(), integer()) :: map()
  # Build the snapshot map from the three weather sub-functions.
  # Returns a struct the `apply_weather_snapshot/2` step assigns
  # onto the socket. Pure — no socket coupling here.
  def fetch_weather_snapshot(user, local_date, x_min, x_max, tz) do
    %{
      cloud_cover_line: build_cloud_cover_band(user, local_date, x_min, x_max, tz),
      current_cloud_cover: weather_current_condition(user),
      current_cloud_cover_pct: weather_current_pct(user)
    }
  end

  @spec apply_weather_snapshot(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def apply_weather_snapshot(socket, snapshot) do
    socket
    |> Phoenix.Component.assign(:cloud_cover_line, Map.fetch!(snapshot, :cloud_cover_line))
    |> Phoenix.Component.assign(:current_cloud_cover, Map.fetch!(snapshot, :current_cloud_cover))
    |> Phoenix.Component.assign(
      :current_cloud_cover_pct,
      Map.fetch!(snapshot, :current_cloud_cover_pct)
    )
  end

  @spec kickoff_weather_fetch(
          Phoenix.LiveView.Socket.t(),
          map(),
          Date.t(),
          integer(),
          integer(),
          integer()
        ) :: Phoenix.LiveView.Socket.t()
  # Perf #5: weather fetch dispatch. Three call sites:
  #
  #   1. HTTP render (the initial GET's static response). One-shot,
  #      no follow-up render — the fetch has to run inline or the
  #      HTML ships without the cloud-cover band + current-condition
  #      card. `connected?/1` is `false` here, so the `else` branch
  #      fires unconditionally.
  #   2. WebSocket `mount/3` (the channel upgrade after the static
  #      HTML). The HTTP render already shipped weather, so the user
  #      has already seen the populated band before this mount even
  #      runs. We still run synchronously here for two reasons:
  #      (a) `LiveViewTest.live/2`'s returned `html` reflects this
  #      connected render, and existing cloud-cover tests assert
  #      weather is in that html; (b) the sync cost is amortised by
  #      the 15-min `Weather.Cache`, so a cache hit lands in
  #      microseconds. Detected via `socket.assigns[:initial_mount?]`,
  #      which `mount/3` sets to `true` and `assign_line_chart_data/6`
  #      flips to `false` after this function runs.
  #   3. WebSocket callbacks (`handle_event`, `handle_info` — e.g.
  #      preset switches, `set_location`, `set_timezone`). The chart
  #      is already on screen; deferring weather here shaves the
  #      re-render latency without losing the band (the
  #      `{:weather_update, ...}` message lands a moment later and
  #      `handle_info/2` re-renders with the populated assigns).
  #
  # The Task uses `send(parent, ...)` rather than `Phoenix.PubSub` so
  # the message targets this LV process specifically — a stale fetch
  # for a disconnected user never wakes another tab's process. Errors
  # in the fetch fall through to the helpers' nil/empty defaults; the
  # `Weather.cloud_cover_for/3` facade already returns `nil` on nil
  # coords or upstream failure, so a try/rescue isn't needed (and would
  # mask real bugs if added).
  def kickoff_weather_fetch(socket, user, local_date, x_min, x_max, tz) do
    initial_mount? = socket.assigns[:initial_mount?] == true
    fingerprint = weather_fingerprint(user, local_date, x_min, x_max, tz)

    # Fingerprint gate. The five weather inputs (lat / lon / local
    # date / visible X range / tz offset) determine the snapshot
    # uniquely — if none of them changed since the last fetch, the
    # existing `cloud_cover_line` / `current_cloud_cover` /
    # `current_cloud_cover_pct` assigns are still valid and we must
    # NOT reset them. Without this gate, every PubSub `:reading`
    # broadcast ran `assign_dashboard_data/5 → assign_weather_placeholders/1`,
    # wiping the line for one render before the async refetch
    # re-applied it — visible as a flicker every few seconds on a
    # connected inverter. The reset moves inside the
    # `fingerprint_changed?` branch below so steady-state broadcasts
    # pass through untouched.
    #
    # `set_location` and `set_timezone` change `user.latitude /
    # longitude` and `tz_offset_seconds` respectively, so they
    # naturally fall through to the changed branch and trigger a
    # fresh fetch. Range switches change `local_date` /
    # `x_min_seconds` / `x_max_seconds`, same path. The initial HTTP
    # render and the very first WebSocket sync fetch land here with
    # `weather_input_fingerprint == nil`, so the changed branch
    # always fires on mount.
    if socket.assigns[:weather_input_fingerprint] == fingerprint do
      socket
    else
      socket =
        socket
        |> assign_weather_placeholders()
        |> Phoenix.Component.assign(:weather_input_fingerprint, fingerprint)

      if Phoenix.LiveView.connected?(socket) and not initial_mount? do
        parent = self()

        Task.start(fn ->
          snapshot = fetch_weather_snapshot(user, local_date, x_min, x_max, tz)
          send(parent, {:weather_update, snapshot})
        end)

        socket
      else
        # HTTP render, OR initial WebSocket mount (initial_mount?).
        # Compute inline so the rendered HTML includes the band +
        # current-condition.
        #
        # Defensive: wrap the inline snapshot in try/catch so a
        # weather-side failure (e.g. Open-Meteo returning a 200 with
        # non-JSON body — captive portal, regional outage) leaves
        # the placeholder chart visible (`assign_weather_placeholders/1`
        # already ran above) instead of crashing the LV. The
        # `Task.start` branch above already fails quietly; this
        # brings the inline branch in line with that contract.
        try do
          apply_weather_snapshot(
            socket,
            fetch_weather_snapshot(user, local_date, x_min, x_max, tz)
          )
        catch
          kind, reason ->
            Logger.warning(
              "[dashboard] inline weather snapshot failed (#{kind}: " <>
                "#{Exception.message(reason)}) — continuing with placeholders"
            )

            socket
        end
      end
    end
  end
end
