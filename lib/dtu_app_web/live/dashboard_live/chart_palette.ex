defmodule DtuAppWeb.DashboardLive.ChartPalette do
  @moduledoc """
  Deterministic colour assignments for the dashboard's chart series.

  Extracted from `DtuAppWeb.DashboardLive` so the dashboard module
  isn't carrying a 40-line constant table + helpers it could just
  delegate to. Lives next to `DtuAppWeb.DashboardLive.ChartHelpers`
  in the `dashboard_live/` directory.

  Two surfaces:

    * `@palette` + `inverte_order_to_color/1` assign each (DTU id,
      inverter serial) pair a hue from a fixed 10-colour wheel.
      Same input → same hue, so the chart doesn't flicker on
      re-render.
    * `@tailwind_colors` + `tooltip_to_hex/2` resolve Tailwind
      `(base, shade)` pairs to concrete hex strings. The
      `ChartTooltip` JS hook renders swatches as inline
      `style="background-color: …"` (CSS custom properties aren't
      reachable from the colocated hook without shipping the
      Tailwind output as JSON), so we hand it a flat hex map.
  """

  # 10-hue base palette. Wraps modulo `length(@palette)` so a 15-DTU
  # install gets colour-reuse but never two adjacent inverters with
  # the same hue. Matches Tailwind v3's default named palette.
  @palette ~w(emerald amber sky violet rose fuchsia cyan lime orange teal)

  # Map a (base, shade) Tailwind palette pair to a hex color string.
  # Values are the Tailwind v3 default emerald/amber/sky/violet/rose/
  # fuchsia/cyan/lime/orange/teal palette at the requested shade.
  # Only the 400 / 600 / 800 / 900 shades are needed by the chart —
  # production + consumption + total + net each pick one shade per
  # series. Picking a 500 from habit was a silent crash that 500'd
  # the whole dashboard for users with a paired Shelly — `tooltip_to_hex/2`
  # falls back to neutral grey for any pair not in the map so a
  # future misconfiguration degrades to "boring colours" instead of
  # "no dashboard at all".
  @tailwind_colors %{
    {"emerald", "400"} => "#34d399",
    {"emerald", "600"} => "#059669",
    {"emerald", "800"} => "#065f46",
    {"emerald", "900"} => "#064e3b",
    {"amber", "400"} => "#fbbf24",
    {"amber", "600"} => "#d97706",
    {"amber", "800"} => "#92400e",
    {"amber", "900"} => "#78350f",
    {"sky", "400"} => "#38bdf8",
    {"sky", "600"} => "#0284c7",
    {"sky", "800"} => "#075985",
    {"sky", "900"} => "#0c4a6e",
    {"violet", "400"} => "#a78bfa",
    {"violet", "600"} => "#7c3aed",
    {"violet", "800"} => "#5b21b6",
    {"violet", "900"} => "#4c1d95",
    {"rose", "400"} => "#fb7185",
    {"rose", "600"} => "#e11d48",
    {"rose", "800"} => "#9f1239",
    {"rose", "900"} => "#881337",
    {"fuchsia", "400"} => "#e879f9",
    {"fuchsia", "600"} => "#c026d3",
    {"fuchsia", "800"} => "#86198f",
    {"fuchsia", "900"} => "#701a75",
    {"cyan", "400"} => "#22d3ee",
    {"cyan", "600"} => "#0891b2",
    {"cyan", "800"} => "#155e75",
    {"cyan", "900"} => "#164e63",
    {"lime", "400"} => "#a3e635",
    {"lime", "600"} => "#65a30d",
    {"lime", "800"} => "#3f6212",
    {"lime", "900"} => "#365314",
    {"orange", "400"} => "#fb923c",
    {"orange", "600"} => "#ea580c",
    {"orange", "800"} => "#9a3412",
    {"orange", "900"} => "#7c2d12",
    {"teal", "400"} => "#2dd4bf",
    {"teal", "600"} => "#0d9488",
    {"teal", "800"} => "#115e59",
    {"teal", "900"} => "#134e4a"
  }

  @fallback_hex "#6b7280"

  @doc """
  Resolve a Tailwind (`base`, `shade`) pair to a hex color, falling
  back to a neutral grey when the pair isn't in `@tailwind_colors`.
  The grey fallback keeps the chart readable even when the palette
  is misconfigured.

  Public so the regression test in
  `test/dtu_app_web/live/dashboard_live_test.exs` can pin both the
  happy-path and the missing-shade fallback.
  """
  @spec tooltip_to_hex(String.t(), String.t()) :: String.t()
  def tooltip_to_hex(base, shade) do
    case Map.fetch(@tailwind_colors, {base, shade}) do
      {:ok, hex} -> hex
      :error -> @fallback_hex
    end
  end

  @doc """
  Assign each `(dtu_id, inverter_serial)` pair a base hue from
  `@palette`, in the order they first appear in `series_points`.

  `series_points` is the same `[{series_tuple, [coords...]}]` map
  the dashboard's chart-building pipeline produces — only the
  `dtu_id` (elem 0) and `inverter_serial` (elem 1) of the series
  tuple are read; the rest is discarded.

  Returns a `%{{dtu_id, inverter_serial} => base_color}` map the
  dashboard then merges with a fixed shade per series to form the
  final Tailwind pair passed to `tooltip_to_hex/2`.

  Stable across requests — the same fleet renders with the same
  colours session-to-session so the chart doesn't flicker.
  """
  @spec inverte_order_to_color([{tuple(), list()}]) :: %{{integer(), String.t()} => String.t()}
  def inverte_order_to_color(series_points) do
    series_points
    |> Enum.map(fn {series, _} -> {elem(series, 0), elem(series, 1)} end)
    |> Enum.uniq()
    |> Enum.with_index()
    |> Map.new(fn {{dtu_id, serial}, idx} ->
      {{dtu_id, serial}, Enum.at(@palette, rem(idx, length(@palette)))}
    end)
  end
end
