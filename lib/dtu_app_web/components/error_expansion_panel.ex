defmodule DtuAppWeb.ErrorExpansionPanel do
  @moduledoc """
  The rose-tinted "error history" panel that opens beneath a row in
  the device list when the user clicks the row's content area.

  Bundles four layers:

    1. **Panel chrome** — rose-tinted background + left/right/bottom
       border that mirrors the row's rose warning fill so the panel
       reads as a continuation of the row above it. `data-test=
       "error-panel"` is the selector the dashboard's
       `?expand=<id>` deep-link integration tests target.

    2. **Heading + close button** — either the empty-state caption
       ("No errors recorded for this DTU yet.") when the device
       has no recorded errors, or the "Errors (N distinct, M total
       occurrences)" heading that aggregates over the supplied
       `error_groups`. The close button is a sibling of the
       heading (right-aligned) and triggers
       `phx-click="close_expanded_errors"` on the parent LV.

    3. **Per-group rendering** — one `<li>` per
       `%{message, occurrences, last_seen}` group. Each message is
       parsed via
       `DtuAppWeb.DeviceLive.Index.parse_error_message/1` and
       rendered with three layers: kind chip + reason text (the
       structured summary), optional topic chip (rendered only
       when the parser recognised the topic-bearing format), and
       optional payload snippet (rendered as a `<details>`-folded
       `<pre>` so multi-line / structured payloads keep their
       indentation; the full payload is the message string
       truncated upstream to 200 chars by
       `Telemetry.format_payload_snippet/1`).

    4. **Relative-time footer** — "%{count} occurrences · last
       seen %{when}" per group, using the LV's
       `format_relative/1` helper.

  Rendered OUTSIDE the `phx-update="stream"` container in
  `device_live/index.html.heex`. Putting it inside the container
  would cause the `:dtu_seen` / `:dtu_error` broadcasts (which
  call `stream/3 reset: true`) to wipe the panel's DOM nodes on
  every refetch — the close button's `phx-click` handler would
  race against those resets and the user's click would silently
  do nothing. Keeping the panel as a separate sibling block means
  the stream owns only the row elements and the panel survives
  any stream reset untouched.

  Was the inline block in
  `DtuAppWeb.DeviceLive.Index.html.heex` (formerly
  lines 152-269, ~120 lines). Extracted so the empty-state vs
  grouped-state branch, the close button's stable id, and the
  parsed-error rendering (kind chip + reason + topic + payload +
  relative-time footer) all get a stable render-only test
  surface — important because the parser output shape
  (`%{kind, reason, topic, payload, raw}`) is the easiest place
  for a silent regression (a missing `parsed.topic` branch, an
  escaped `payload`, an off-by-one on the byte-count label).

  Sister to `DtuAppWeb.DeviceRow` (PR #287) — the row above
  toggles the panel via `toggle_expanded_errors`; this is the
  panel that opens in response.
  """

  use DtuAppWeb, :html

  alias DtuAppWeb.DeviceLive.Index

  # Friendly relative-time label for each error group's "last
  # seen" footer. Lightweight format that reads naturally in
  # both English and German (`vor 5 Minuten`) — the dashboard's
  # `relative_time_label/1` is private, so the LiveView used to
  # inline a similar-enough helper here rather than coupling the
  # two LiveViews. We move the helper into this component so
  # the LV stops reaching into component-internal state.
  # Returns "just now" for sub-minute timestamps.
  defp format_relative(%DateTime{} = dt) do
    diff_seconds = DateTime.diff(DtuApp.Time.utc_now(), dt, :second)

    cond do
      diff_seconds < 60 -> gettext("just now")
      diff_seconds < 3600 -> gettext("%{n} minutes ago", n: div(diff_seconds, 60))
      diff_seconds < 86_400 -> gettext("%{n} hours ago", n: div(diff_seconds, 3600))
      true -> gettext("%{n} days ago", n: div(diff_seconds, 86_400))
    end
  end

  attr :device, :map,
    required: true,
    doc: """
    The DTU whose error history is being shown. Only the `id`
    and `name` fields are read by this component — `id` drives
    the panel's `device-error-panel-<id>` and close button's
    `btn-close-error-panel-<id>` ids (e2e selectors), `name` is
    reserved for future per-row labels.
    """

  attr :error_groups, :list,
    default: [],
    doc: """
    The rolled-up error groups for this device, in
    most-recent-first order. Each group is a
    `%{message: String.t(), occurrences: non_neg_integer(),
    last_seen: DateTime.t()}` map produced by
    `DtuApp.Devices.list_dtu_error_groups/1`. The component
    parses each `message` via
    `DtuAppWeb.DeviceLive.Index.parse_error_message/1` so the
    template only sees the structured parts (`kind`, `reason`,
    `topic`, `payload`) plus the raw message string. An empty
    list renders the empty-state caption.
    """

  def error_expansion_panel(assigns) do
    ~H"""
    <div
      id={"device-error-panel-#{@device.id}"}
      class="bg-rose-50/40 dark:bg-rose-950/20 border-l-4 border-r border-b border-rose-300 dark:border-rose-700 px-4 py-4 mt-0"
      data-test="error-panel"
    >
      <div class="flex items-start justify-between gap-4 mb-3">
        <h4 class="text-sm font-semibold text-rose-900 dark:text-rose-200">
          <%= if @error_groups == [] do %>
            {gettext("No errors recorded for this DTU yet.")}
          <% else %>
            {gettext(
              "Errors (%{distinct} distinct, %{occurrences} total occurrences)",
              distinct: length(@error_groups),
              occurrences:
                Enum.reduce(@error_groups, 0, fn g, acc ->
                  acc + g.occurrences
                end)
            )}
          <% end %>
        </h4>
        <button
          type="button"
          phx-click="close_expanded_errors"
          id={"btn-close-error-panel-#{@device.id}"}
          class="text-xs font-medium text-zinc-500 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100 transition"
          aria-label={gettext("Close error panel")}
        >
          ✕ {gettext("Close")}
        </button>
      </div>

      <%= if @error_groups != [] do %>
        <ul class="space-y-3">
          <%= for group <- @error_groups do %>
            <% parsed = Index.parse_error_message(group.message) %>
            <li class="flex items-start gap-2 text-sm text-rose-800 dark:text-rose-200">
              <.icon
                name="hero-exclamation-triangle"
                class="size-4 shrink-0 mt-0.5 text-rose-500"
              />
              <div class="min-w-0 flex-1 space-y-1.5">
                <%!-- Top row: structured summary — kind chip + reason
                     text, with the topic as a styled code chip below if
                     the parser recognised the topic-bearing format. The
                     mono / chip treatment gives the message type
                     immediate hierarchy so a quick scan tells the user
                     what the issue is ("AhoyDTU" / "Shelly" / etc.). --%>
                <div class="flex flex-wrap items-baseline gap-2">
                  <span class="inline-flex shrink-0 items-center rounded px-1.5 py-0.5 text-xs font-semibold bg-rose-100 dark:bg-rose-900/50 text-rose-700 dark:text-rose-200">
                    {parsed.kind}
                  </span>
                  <span class="break-words text-rose-800 dark:text-rose-100">
                    {parsed.reason}
                  </span>
                </div>

                <%= if parsed.topic do %>
                  <div class="flex items-center gap-1.5 text-xs">
                    <span class="text-rose-600/80 dark:text-rose-400/80 font-medium">
                      {gettext("topic:")}
                    </span>
                    <code
                      class="font-mono text-rose-900 dark:text-rose-100 bg-rose-50 dark:bg-rose-950/40 px-1.5 py-0.5 rounded break-all border border-rose-200/60 dark:border-rose-800/40"
                      data-test="error-topic"
                    >
                      {parsed.topic}
                    </code>
                  </div>
                <% end %>

                <%= if parsed.payload do %>
                  <%!-- Payload: rendered as a `<pre>` so multi-line /
                       structured payloads (Shelly JSON, OpenDTU realtime
                       JSON, etc.) keep their indentation and a quick
                       scan surfaces syntax errors. `whitespace-pre-wrap`
                       + `break-all` keeps both short and long payloads
                       inside the panel width. The full payload is the
                       message string itself (truncated upstream to
                       200 chars by `format_payload_snippet/1`); for
                       longer payloads the user copies via Cmd+L → copy
                       in the raw `dtu_errors` row. --%>
                  <details class="text-xs">
                    <summary class="cursor-pointer text-rose-600/80 dark:text-rose-400/80 font-medium select-none">
                      {gettext("payload (%{n} chars)", n: byte_size(parsed.payload))}
                    </summary>
                    <pre
                      class="mt-1 font-mono text-rose-900 dark:text-rose-100 bg-rose-50 dark:bg-rose-950/40 px-2 py-1.5 rounded whitespace-pre-wrap break-all max-h-40 overflow-auto border border-rose-200/60 dark:border-rose-800/40"
                      data-test="error-payload"
                    ><code>{parsed.payload}</code></pre>
                  </details>
                <% end %>

                <p class="mt-1 text-xs text-rose-600/80 dark:text-rose-400/80">
                  {gettext(
                    "%{count} occurrences · last seen %{when}",
                    count: group.occurrences,
                    when: format_relative(group.last_seen)
                  )}
                </p>
              </div>
            </li>
          <% end %>
        </ul>
      <% end %>
    </div>
    """
  end
end
