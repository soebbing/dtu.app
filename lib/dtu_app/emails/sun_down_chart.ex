defmodule DtuApp.Emails.SunDownChart do
  @moduledoc """
  Render today's power curve as an inline SVG for the `sun_down`
  transactional email.

  ## Email-client constraints

    * No external CSS, no JS, no `<img src="cid:...">` — most email
      clients strip all of those.
    * Light theme only — `<style>` blocks are stripped by Gmail,
      Outlook, and most webmail clients, so the dark variant of the
      dashboard chart would never make it to the inbox.
    * Single `<path>` element, brand emerald (`#10b981`) stroke.

  ## Data path

  Reuses `DtuApp.Devices.list_day_chart_data_for_dashboard/4` so the
  bucketing matches the in-page dashboard exactly — the email chart
  and the dashboard chart read from the same hot path. The `Date` is
  expanded to a UTC `[00:00:00Z, 23:59:59Z]` window before the
  call.

  When the user owns no devices, or has no readings in the requested
  window, the function returns an empty-state SVG containing a
  centred `gettext("No chart available")` label — the email
  template can drop the SVG in verbatim either way.
  """

  use Gettext, backend: DtuAppWeb.Gettext

  alias DtuApp.Accounts.User
  alias DtuApp.Devices

  # Chart dimensions — match the dashboard's viewBox so the email
  # chart composites visually with the in-page chart.
  @viewbox_w 800
  @viewbox_h 280
  @padding_left 32
  @padding_right 16
  @padding_top 16
  @padding_bottom 32
  @brand_emerald "#10b981"
  @gridline_color "#e2e8f0"
  @tick_label_color "#64748b"
  @axis_title_color "#475569"
  @yesterday_color "#6b7280"

  # Font fallback chain. `Liberation Sans` ships in the runtime image
  # via `ttf-liberation` (Alpine 3.21 main repo, OFL-1.1, ~3 MB) — it
  # covers all the ASCII glyphs the chart uses (digits, colon,
  # comma, "W", "Peak:", "Power") and is metric-compatible with
  # Microsoft Arial so layout doesn't shift. `sans-serif` is the
  # pango/fontconfig generic fallback; `Liberation Sans` resolves
  # FIRST so the chain is deterministic regardless of what other
  # fonts the container happens to carry. Pre-PR `ui-sans-serif` /
  # `system-ui` are CSS-only names that pango can't resolve against
  # the container's fontconfig database — they triggered the
  # □□□□ square-rectangle rendering bug in prod (rsvg-convert
  # couldn't find a glyph for any character and emitted `.notdef`).
  @font_family "Liberation Sans, sans-serif"
  @yesterday_stroke_opacity "0.35"
  @yesterday_stroke_dasharray "4 3"
  @gridline_count 5
  @fill_opacity "0.12"

  @doc """
  Render today's power curve for `user` on `date` as an inline SVG
  string.

  Returns a binary starting with
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 280"`
  so callers can drop the result into either an HTML email
  template or a plain-text fallback without further wrapping.

  When the user has no devices (or no readings in the day), returns
  an empty-state SVG containing a centred
  `gettext("No chart available")` label.
  """
  @spec render(User.t(), Date.t()) :: String.t()
  def render(%User{} = user, %Date{} = date) do
    if Devices.list_devices(user) == [] do
      empty_svg()
    else
      utc_start = DateTime.new!(date, ~T[00:00:00])
      utc_end = DateTime.new!(date, ~T[23:59:59])

      points =
        Devices.list_day_chart_data_for_dashboard(user, utc_start, utc_end)

      # Yesterday's ghost line — same scope (fleet-wide, since the
      # `dtu_id` argument defaults to `nil`) and the same window shape,
      # just shifted -1 day. Empty list when there's no data; the
      # overlay helper renders an empty string in that case.
      yesterday_points =
        Devices.list_yesterday_chart_data_for_dashboard(user, utc_start, utc_end)

      render_svg(points, yesterday_points)
    end
  end

  # ── SVG fragments ───────────────────────────────────────────────────────

  defp empty_svg do
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{@viewbox_w} #{@viewbox_h}" role="img" aria-label="#{escape(gettext("Today's power curve"))}">
      <rect x="0" y="0" width="#{@viewbox_w}" height="#{@viewbox_h}" fill="#f8fafc" stroke="#e2e8f0"/>
      <text x="#{@viewbox_w / 2}" y="#{@viewbox_h / 2}" font-family="#{@font_family}" font-size="13" fill="#64748b" text-anchor="middle">
        #{escape(gettext("No chart available"))}
      </text>
    </svg>
    """
  end

  # Pure points → SVG. Public-but-internal (`@doc false`) so tests can
  # exercise the nil-power guard without going through the DB. Pre-PR
  # this was `render_svg/1`, a private function that called
  # `build_path/1` on the input list verbatim. The list can contain
  # `%{power: nil}` entries when a 5-minute bucket in the
  # `readings_5m` continuous aggregate has zero production rows but
  # the SELECT still returns a row (NULL avg_ac_power); same for a
  # partially-populated live-tail bucket. `Enum.max/1` of a list with
  # mixed `nil` + numbers raises ArgumentError, but `Enum.max/1` of a
  # list with **only** nil entries (or a single non-number) returns
  # without raising, then `Kernel./(1)` on that nil/non-number raises
  # `ArithmeticError: bad argument in arithmetic expression` and kills
  # the GenServer (PR regression — observed in prod on
  # 2026-09-16 for the sun_down regenerate handler, but the same path
  # exists on the daily producer). Defensively filter to numeric
  # powers, and fall back to `empty_svg/0` when nothing usable
  # survives the filter — the email renders "No chart available"
  # instead of crashing the dispatcher.
  #
  # `yesterday_points` is an optional second list (defaults to `[]`)
  # rendered behind today's curve as a dashed gray ghost line — the
  # same recipe the dashboard's line chart uses for the "yesterday"
  # reference overlay (`stroke-opacity="0.35"`, `stroke-dasharray="4 3"`).
  # When the list is empty the overlay is omitted entirely.
  @doc false
  @spec render_svg([map()], [map()]) :: String.t()
  def render_svg(points, yesterday_points \\ [])
      when is_list(points) and is_list(yesterday_points) do
    case Enum.filter(points, &match?(%{power: v} when is_number(v), &1)) do
      [] ->
        empty_svg()

      renderable ->
        max_power = renderable |> Enum.map(& &1.power) |> Enum.max() |> max(1.0)
        path_d = build_path(renderable, max_power)
        gridlines = y_gridlines_svg(max_power)
        y_labels = y_axis_labels_svg(max_power)
        x_labels = x_axis_labels_svg()
        peak = peak_marker_svg(renderable, max_power)
        title = axis_title_svg()
        yesterday_overlay = yesterday_overlay_svg(yesterday_points, max_power)
        chart_label = gettext("Today's power curve")

        Enum.join(
          [
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 #{@viewbox_w} #{@viewbox_h}\" role=\"img\" aria-label=\"#{escape(chart_label)}\">",
            "<rect x=\"0\" y=\"0\" width=\"#{@viewbox_w}\" height=\"#{@viewbox_h}\" fill=\"#f8fafc\" stroke=\"#e2e8f0\"/>",
            gridlines,
            yesterday_overlay,
            "<path d=\"#{path_d}\" fill=\"#{@brand_emerald}\" fill-opacity=\"#{@fill_opacity}\" stroke=\"#{@brand_emerald}\" stroke-width=\"2\" stroke-linejoin=\"round\" stroke-linecap=\"round\"/>",
            y_labels,
            x_labels,
            peak,
            title,
            "</svg>"
          ],
          "\n  "
        )
    end
  end

  # Build the `d=` attribute for the chart path. The chart runs from
  # the top of the inner area (max power) to the bottom (zero), so
  # each point's `y` is `viewbox_h - padding_bottom - (power / max) * inner_h`.
  #
  # Pre-PR this had `|> Kernel./(1) |> max(1.0)` to coerce the
  # `Enum.max/1` result to a float and clamp the lower bound. The
  # `Kernel./(1)` is a no-op for floats (`x / 1 == x`) and was only
  # needed because, in older Elixir versions, `max(integer, float)`
  # raised. In current Elixir (≥ 1.10) `:erlang.max/2` accepts mixed
  # numeric types, so the `Kernel./(1)` chain is dead code AND a
  # crash vector: if a non-numeric slips past the `render_svg/1`
  # filter (a regression we haven't imagined yet), `nil / 1` raises
  # `ArithmeticError`. Drop the no-op, clamp with `max/2` directly.
  defp build_path(points, max_power) do
    n = max(length(points) - 1, 1)
    inner_w = @viewbox_w - @padding_left - @padding_right
    inner_h = @viewbox_h - @padding_top - @padding_bottom
    baseline_y = 1.0 * @viewbox_h - @padding_bottom

    line_segments = line_segments_for(points, n, inner_w, inner_h, baseline_y, max_power)

    first_x = 1.0 * @padding_left
    last_x = 1.0 * @padding_left + n * inner_w / n

    "M#{first_x},#{baseline_y} #{line_segments} L#{last_x},#{baseline_y} Z"
  end

  # Build the `Lx1,y1 Lx2,y2 ...` segment string for a list of points.
  # Shared between `build_path/2` (today's filled area) and
  # `yesterday_overlay_svg/2` (the dashed ghost line) so the geometry
  # stays in lock-step — if the y-mapping changes, both update together.
  defp line_segments_for(points, n, inner_w, inner_h, baseline_y, max_power) do
    points
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {p, i} ->
      x = 1.0 * @padding_left + i * inner_w / n
      y = baseline_y - p.power / max_power * inner_h
      "L#{Float.round(x, 1)},#{Float.round(y, 1)}"
    end)
  end

  # Yesterday ghost line: a dashed, low-opacity gray overlay matching
  # the dashboard's `line_chart_panel.ex` styling. When yesterday has
  # no data points the function returns an empty string — the
  # overlay is silently dropped rather than rendering an empty `<path>`
  # that would still be stroked by Chromium as a degenerate dot at
  # the first point.
  defp yesterday_overlay_svg(yesterday_points, max_power) do
    case Enum.filter(yesterday_points, &match?(%{power: v} when is_number(v), &1)) do
      [] ->
        ""

      renderable ->
        n = max(length(renderable) - 1, 1)
        inner_w = @viewbox_w - @padding_left - @padding_right
        inner_h = @viewbox_h - @padding_top - @padding_bottom
        baseline_y = 1.0 * @viewbox_h - @padding_bottom

        line_segments =
          line_segments_for(renderable, n, inner_w, inner_h, baseline_y, max_power)

        first_x = 1.0 * @padding_left

        ~s/<path d="M#{first_x},#{baseline_y} #{line_segments}" fill="none" stroke="#{@yesterday_color}" stroke-width="1.5" stroke-opacity="#{@yesterday_stroke_opacity}" stroke-dasharray="#{@yesterday_stroke_dasharray}" stroke-linecap="round" stroke-linejoin="round"\/>/
    end
  end

  # ── Gridlines ─────────────────────────────────────────────────────────

  defp y_gridlines_svg(_max_power) do
    inner_top = 1.0 * @padding_top
    inner_bottom = 1.0 * @viewbox_h - @padding_bottom

    Enum.map_join(0..(@gridline_count - 1), "\n  ", fn i ->
      ratio = i / (@gridline_count - 1)
      y = inner_bottom - ratio * (inner_bottom - inner_top)

      ~s/<line x1="#{1.0 * @padding_left}" y1="#{y}" x2="#{1.0 * @viewbox_w - @padding_right}" y2="#{y}" stroke="#{@gridline_color}" stroke-width="1"\/>/
    end)
  end

  # ── Y-axis labels ──────────────────────────────────────────────────────

  defp y_axis_labels_svg(max_power) do
    inner_top = 1.0 * @padding_top
    inner_bottom = 1.0 * @viewbox_h - @padding_bottom
    locale = Gettext.get_locale(DtuAppWeb.Gettext)

    Enum.map_join(0..(@gridline_count - 1), "\n  ", fn i ->
      ratio = i / (@gridline_count - 1)
      watts = Float.round(max_power * ratio, 1)
      y = inner_bottom - ratio * (inner_bottom - inner_top)

      # Y-axis watt label: locale-formatted number + the SI unit " W".
      # We pass the number through `gettext/1` as a binary interpolation
      # so a locale that flips the unit order ("1,700 W" vs "W 1,700"
      # in some future right-to-left layout) can re-order both pieces.
      # All current locales (en/de/fr) keep "W" as a suffix and the
      # msgstr for " W" is identical to the msgid — see
      # priv/gettext/{de,fr}/LC_MESSAGES/default.po.
      ~s/<text x="#{1.0 * @padding_left - 4}" y="#{y - 4}" font-family="#{@font_family}" font-size="10" fill="#{@tick_label_color}" text-anchor="end">#{escape(gettext("%{n} W", n: Devices.format_number(watts, 0, locale)))}<\/text>/
    end)
  end

  # ── X-axis labels ──────────────────────────────────────────────────────

  defp x_axis_labels_svg do
    inner_left = 1.0 * @padding_left
    inner_right = 1.0 * @viewbox_w - @padding_right
    y = 1.0 * @viewbox_h - 8

    # X-axis times. The dashboard uses the SAME four msgids
    # (shared_dashboard_live.ex:325 ff.) so DE/FR translations stay in
    # lockstep — and for these locales the msgstr is identical to the
    # msgid (24h notation, no AM/PM, no leading-zero variants). The
    # `gettext/1` wrap is here so a future locale that wants, say,
    # "00:00h" / "06 Uhr" / 12-hour AM/PM has a hook to localize
    # without changing the chart code.
    times = [
      {gettext("00:00"), 0.0},
      {gettext("06:00"), 0.25},
      {gettext("12:00"), 0.5},
      {gettext("18:00"), 0.75}
    ]

    Enum.map_join(times, "\n  ", fn {label, ratio} ->
      x = inner_left + ratio * (inner_right - inner_left)
      anchor = if ratio == 0.0, do: "start", else: "middle"

      ~s/<text x="#{x}" y="#{y}" font-family="#{@font_family}" font-size="11" fill="#{@tick_label_color}" text-anchor="#{anchor}">#{label}<\/text>/
    end)
  end

  # ── Peak marker ────────────────────────────────────────────────────────

  defp peak_marker_svg(points, max_power) do
    case Enum.find_index(points, &(&1.power == max_power)) do
      nil ->
        ""

      idx ->
        n = max(length(points) - 1, 1)
        inner_w = @viewbox_w - @padding_left - @padding_right
        inner_h = @viewbox_h - @padding_top - @padding_bottom

        x = 1.0 * @padding_left + idx * inner_w / n
        y = 1.0 * @viewbox_h - @padding_bottom - max_power / max_power * inner_h
        label_x = max(x - 8, 1.0 * @padding_left)
        label_y = max(y - 8, 1.0 * @padding_top + 12)
        locale = Gettext.get_locale(DtuAppWeb.Gettext)

        """
        <circle cx="#{Float.round(x, 1)}" cy="#{Float.round(y, 1)}" r="3" fill="#{@brand_emerald}" stroke="#ffffff" stroke-width="1"/>
        <text x="#{Float.round(label_x, 1)}" y="#{Float.round(label_y, 1)}" font-family="#{@font_family}" font-size="10" font-weight="600" fill="#{@axis_title_color}" text-anchor="end">#{escape(gettext("Peak: %{n} W", n: Devices.format_number(max_power, 0, locale)))}</text>
        """
    end
  end

  # ── Axis title ─────────────────────────────────────────────────────────

  defp axis_title_svg do
    inner_mid_y = (@padding_top + (@viewbox_h - @padding_bottom)) / 2
    # `x = 12` keeps the rotated text inside the viewBox after the -90°
    # pivot at the same coordinate — pre-PR used `x = 0` and the text
    # ended up half-clipped outside the visible area.
    ~s/<text x="12" y="#{inner_mid_y}" font-family="#{@font_family}" font-size="10" fill="#{@axis_title_color}" text-anchor="middle" transform="rotate(-90 12 #{inner_mid_y})">#{escape(gettext("Power"))}<\/text>/
  end

  # Escape user-facing strings (gettext msgids ship as source strings
  # but the .po translations can contain arbitrary text — any of which
  # could carry `&`, `<`, `>` once translated).
  defp escape(s) when is_binary(s),
    do:
      s
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  defp escape(_), do: ""
end
