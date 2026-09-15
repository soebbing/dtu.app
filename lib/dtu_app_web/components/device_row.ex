defmodule DtuAppWeb.DeviceRow do
  @moduledoc """
  A single DTU's row in the device list. Bundles four layers:

    1. **Outer container** — the flex row with `divide-y` styling
       inherited from the parent `<div id="devices" phx-update="stream">`.
       When `device.last_error` is set, the row swaps to a
       rose-tinted background + thicker left border so a
       misconfigured DTU is unmissable. Otherwise it renders
       neutral white/zinc so a healthy device row reads as
       "everything is fine".
    2. **Clickable content area** — name + kind/credentials line +
       optional inline error message strip + the emerald/grey
       "producing power" dot. Clicking this area toggles the
       error expansion panel for the row's device (open if
       closed, close if open). The dot uses
       `DtuApp.Devices.Dtu.producing_power?/1` (not
       `online?/1`) so the green/grey state agrees with the
       dashboard's device-card pill and current-power card.
    3. **Inline error message strip** — only rendered when
       `device.last_error` is set. Truncated via CSS but the
       full string is also carried on the `title=` attribute
       so a hover surfaces the untruncated message.
    4. **Action cluster** — Details (`navigate` to the
       device-details LiveView), Edit (`patch` to the edit
       form), and Remove (`phx-click="confirm_delete"`).
       Each button has a stable id so e2e tests can target
       them directly.

  The component receives `device` + `expanded?` from the
  LiveView's stream; the parent keeps the `phx-update="stream"`
  + the `for` loop. Keeping the row as its own component
  means the row's conditional styling (rose tint), the
  click-to-toggle semantics, and the inline error strip
  get a stable render-only test surface — important because
  the rose background is the easiest place for a regression
  to hide (a wrong conditional silently turns the row
  neutral).

  Was the inline block in
  `DtuAppWeb.DeviceLive.Index.html.heex` (formerly
  lines 26-149). Extracted so the device list template keeps
  just the stream wrapper + the empty-state row and the
  per-row bundle (chrome + content + actions) has its own
  render-only test surface.

  Sister to the upcoming error-expansion-panel extraction
  (the panel that lives below the device list and renders
  when a row's content area is clicked).
  """

  use DtuAppWeb, :html

  alias DtuApp.Devices.Dtu

  attr :device, :map,
    required: true,
    doc: """
    The DTU row to render. Must carry `id`, `name`, `kind`,
    `mqtt_username`, and `last_error` fields. `last_seen_at`
    is unused here — the green/grey dot uses
    `Dtu.producing_power?/1` directly, so the row reads
    correctly even if the device hasn't pushed in a while.
    """

  attr :expanded?, :boolean,
    default: false,
    doc: """
    True when this row's device is the one with its error
    expansion panel currently open. Drives the
    `aria-expanded` attribute on the clickable content area
    and the "Show/Hide error history" accessible label.
    """

  attr :id, :string,
    default: nil,
    doc: """
    The dom id for the row's root `<div>`. Defaults to
    `"devices-<device.id>"` (the form Phoenix's `stream/3`
    generates for a `%Dtu{id: <id>}` row), but can be
    overridden by the caller — the device list passes the
    stream's `dom_id` so LiveView can match the row to its
    server-side entry on stream refetch.
    """

  def device_row(assigns) do
    ~H"""
    <div
      id={@id || "devices-#{@device.id}"}
      class={
        [
          "flex items-center justify-between gap-4 px-4 py-3 transition",
          # Warning fill — distinct from a normal row so a misconfigured
          # DTU is unmissable. The rose-tinted background + thicker left
          # border mirror the delete-confirmation modal's warning style.
          if(@device.last_error,
            do: "bg-rose-50/60 dark:bg-rose-950/30 border-l-4 border-rose-500",
            else: "bg-white dark:bg-zinc-900"
          )
        ]
      }
    >
      <%!-- `producing_power?/1` (not `online?/1`) so the green dot
           here agrees with the dashboard's device-card pill and the
           current-power card. The dot flips to grey whenever the
           inverter hasn't published an AC-aggregate reading in the
           last two minutes — even if the MQTT session is alive. --%>
      <% online? = Dtu.producing_power?(@device) %>
      <%!-- Clickable content area: clicking anywhere here toggles
           the error expansion panel for this device (open if
           closed, close if open). Edit and Remove are nested
           elements with their own click handlers — those events
           route to the inner elements and don't reach this
           phx-click, so they don't accidentally toggle the panel.
           `cursor-pointer` + the `hover:bg-zinc-50` make the
           clickability discoverable to the user. The `role="button"`
           and `tabindex="0"` add keyboard / screen-reader
           support — pressing Enter / Space on a focused row toggles
           the panel via the JS hook, mirroring the click. --%>
      <div
        class="min-w-0 flex-1 cursor-pointer rounded-md hover:bg-zinc-50/60 dark:hover:bg-zinc-800/40 -my-1 py-1 px-1 -ml-1 transition"
        phx-click="toggle_expanded_errors"
        phx-value-id={@device.id}
        id={"device-row-content-#{@device.id}"}
        role="button"
        tabindex="0"
        aria-expanded={if(@expanded?, do: "true", else: "false")}
        aria-label={
          if(@expanded?,
            do: gettext("Hide error history for %{name}", name: @device.name),
            else: gettext("Show error history for %{name}", name: @device.name)
          )
        }
      >
        <div class="flex items-center gap-2">
          <span
            class={[
              "inline-block size-2 rounded-full",
              if(online?,
                do: "bg-emerald-500",
                else: "bg-zinc-300 dark:bg-zinc-600"
              )
            ]}
            title={
              if(online?,
                do: gettext("Online — this DTU has reported AC power within the last 2 minutes"),
                else:
                  gettext(
                    "Offline — no AC power reading has arrived in the last 2 minutes. The MQTT connection may still be alive."
                  )
              )
            }
          />
          <p class="truncate font-medium text-zinc-900 dark:text-zinc-100">
            {@device.name}
          </p>
        </div>
        <p class="mt-0.5 text-sm text-zinc-500">
          {@device.kind} · <code class="font-mono">{@device.mqtt_username}</code>
        </p>
        <%!-- Compact inline error message: only rendered for
             misconfigured devices. The full message is also carried on
             the title-attribute so a user can hover for the whole
             string when the truncated row doesn't fit it. --%>
        <%= if @device.last_error do %>
          <p
            class="mt-1 truncate text-xs text-rose-700 dark:text-rose-300"
            id={"dtu-error-message-#{@device.id}"}
            title={@device.last_error}
          >
            <.icon name="hero-exclamation-triangle" class="inline size-3 -mt-0.5 mr-0.5" />
            {@device.last_error}
          </p>
        <% end %>
      </div>
      <div class="flex shrink-0 items-center gap-3 text-sm">
        <%!-- "Details" navigates (not patches) to the device-details
             LiveView, which is a separate LV mounted on the same
             `live_session :current_scope`. `navigate` does a full
             LV lifecycle so the topic-tree subscription is wired
             fresh on the new page — patching in-place would
             collide with the Index's `:dtu_seen` subscription and
             the topic-tree subscription would leak across pages. --%>
        <.link
          navigate={~p"/devices/#{@device}/details"}
          class="font-medium text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100"
        >
          {gettext("Details")}
        </.link>
        <.link
          patch={~p"/devices/#{@device}/edit"}
          class="font-medium text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100"
        >
          {gettext("Edit")}
        </.link>
        <button
          phx-click="confirm_delete"
          phx-value-id={@device.id}
          id={"btn-delete-#{@device.id}"}
          class="font-medium text-rose-600 hover:text-rose-500 transition"
        >
          {gettext("Remove")}
        </button>
      </div>
    </div>
    """
  end
end
