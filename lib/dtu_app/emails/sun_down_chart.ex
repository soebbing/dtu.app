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

      render_svg(points)
    end
  end

  # ── SVG fragments ───────────────────────────────────────────────────────

  defp empty_svg do
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{@viewbox_w} #{@viewbox_h}" role="img" aria-label="#{escape(gettext("Today's power curve"))}">
      <rect x="0" y="0" width="#{@viewbox_w}" height="#{@viewbox_h}" fill="#f8fafc" stroke="#e2e8f0"/>
      <text x="#{@viewbox_w / 2}" y="#{@viewbox_h / 2}" font-family="ui-sans-serif, system-ui, sans-serif" font-size="13" fill="#64748b" text-anchor="middle">
        #{escape(gettext("No chart available"))}
      </text>
    </svg>
    """
  end

  # Render an SVG with a single `<path>` for the AC-aggregate line.
  # Defensive against the populated-but-missing-points edge case (user
  # owns devices but the day window has no readings): treat as empty.
  defp render_svg([]), do: empty_svg()

  defp render_svg(points) when is_list(points) do
    path_d = build_path(points)
    axis_labels = axis_labels_svg()

    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{@viewbox_w} #{@viewbox_h}" role="img" aria-label="#{escape(gettext("Today's power curve"))}">
      <rect x="0" y="0" width="#{@viewbox_w}" height="#{@viewbox_h}" fill="#f8fafc" stroke="#e2e8f0"/>
      <path d="#{path_d}" fill="none" stroke="#{@brand_emerald}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>
      #{axis_labels}
    </svg>
    """
  end

  # Ascii axis labels are deliberately NOT gettext'd — they're
  # language-neutral HH:MM markers.
  defp axis_labels_svg do
    """
    <text x="#{@padding_left}" y="#{@viewbox_h - 8}" font-family="ui-sans-serif, system-ui, sans-serif" font-size="11" fill="#64748b">00:00</text>
    <text x="#{@viewbox_w - @padding_right}" y="#{@viewbox_h - 8}" font-family="ui-sans-serif, system-ui, sans-serif" font-size="11" fill="#64748b" text-anchor="end">24:00</text>
    """
  end

  # Build the `d=` attribute for the chart path. The chart runs from
  # the top of the inner area (max power) to the bottom (zero), so
  # each point's `y` is `viewBox_h - padding_bottom - (power / max) * inner_h`.
  defp build_path(points) do
    max_power =
      points
      |> Enum.map(& &1.power)
      |> Enum.max()
      |> Kernel./(1)
      |> max(1.0)

    n = max(length(points) - 1, 1)
    inner_w = @viewbox_w - @padding_left - @padding_right
    inner_h = @viewbox_h - @padding_top - @padding_bottom

    points
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {p, i} ->
      x = @padding_left + i * inner_w / n
      y = @viewbox_h - @padding_bottom - p.power / max_power * inner_h
      "L#{Float.round(x, 1)},#{Float.round(y, 1)}"
    end)
    |> then(fn cmd -> "M" <> cmd end)
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
