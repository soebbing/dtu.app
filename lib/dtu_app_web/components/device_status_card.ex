defmodule DtuAppWeb.DeviceStatusCard do
  @moduledoc """
  Per-device status card rendered in the dashboard's device-status grid.

  Shows three things about a device in one card:

    1. **Three-state pill** — `online + producing` (green), `online +
       nighttime` (amber moon), or `offline` (zinc). The MQTT-liveness
       signal (`Dtu.online?/1`) drives online/offline so a DTU whose
       inverter goes quiet at night no longer flips to "offline" while
       the broker is still forwarding status frames. `Dtu.nighttime?/1`
       disambiguates the "MQTT alive but no power data" state for
       firmware that suppresses telemetry at sunset.

    2. **Sink badge** — identifies a `mqtt_ro_sink` device so the user
       understands this card represents a passive subscriber — it
       never publishes, so it never contributes to the production /
       consumption / net rows above. The violet palette matches nothing
       else on the dashboard; sinks are their own kind, neither inverter
       nor consumption meter.

    3. **Last-seen line** — human-friendly relative time ("3 minutes
       ago", "2 hours ago") for fresh readings; an absolute
       `YYYY-MM-DD HH:MM UTC` string for timestamps older than a week;
       `"never"` when the device has never reported. Falls through
       `DtuAppWeb.DashboardLive.TimeHelpers.relative_time_label/2`.

    Optional **error badge** pinned to the card's top-right corner
    when `@error_count > 0`. Shows the *distinct* error-message
    count so a Shelly spamming the same `unknown_topic` 50× in a
    minute shows "1" rather than "50".

  The entire card is a `<.link>` to `/devices?expand=<id>` so
  clicking anywhere surfaces the deep-link to the devices page.
  The error badge sits OUTSIDE the link (`pointer-events-none`) so
  the hover state on the card doesn't flicker when the cursor
  passes over the badge.

  Was an inline `<%= for device <- @devices do %>` block in
  `DtuAppWeb.DashboardLive.html.heex` (lines 2027-2181). Extracted
  so the dashboard template stays focused on page-level layout
  and so the per-device card has a stable unit-test surface
  (the render-only behaviour — pill classes, sink badge, error
  badge overflow at 99+ — is now testable in isolation).
  """

  use DtuAppWeb, :html

  alias DtuApp.Devices.Dtu
  alias DtuAppWeb.DashboardLive.DtuKinds
  alias DtuAppWeb.DashboardLive.TimeHelpers

  attr :device, :map,
    required: true,
    doc: "The Dtu struct (or a test-shaped map with :id, :name, :last_seen_at)."

  attr :error_count, :integer,
    default: 0,
    doc: "Distinct error-message count for the error badge."

  def device_status_card(assigns) do
    # `Dtu.online?/1` and `Dtu.nighttime?/1` are the same predicates
    # the original inline block called. They use `last_seen_at` (MQTT
    # liveness) and `last_ac_power_at` (inverter AC telemetry) on the
    # Dtu row respectively; a test fixture that omits those columns
    # falls through to "offline" / "not nighttime" — the conservative
    # answer that matches the dashboard's pre-extraction behaviour.
    assigns =
      assigns
      |> assign(:online?, Dtu.online?(assigns.device))
      |> assign(:nighttime?, Dtu.nighttime?(assigns.device))

    ~H"""
    <div class="relative">
      <.link
        navigate={~p"/devices?expand=#{@device.id}"}
        aria-label={
          if(@error_count > 0,
            do: gettext("%{count} errors, view details", count: @error_count),
            else: gettext("Manage device")
          )
        }
        class={[
          "block border rounded-lg p-5 h-full flex flex-col justify-between transition hover:shadow-md focus:outline-none focus:ring-2 focus:ring-emerald-500",
          if(@error_count > 0,
            do: "border-rose-300 dark:border-rose-700",
            else: "border-zinc-200 dark:border-zinc-700"
          )
        ]}
        id={"device-card-#{@device.id}"}
      >
        <div>
          <div class="flex items-center justify-between gap-2">
            <div class="flex items-center gap-2 min-w-0">
              <h3 class="text-md font-semibold text-zinc-900 dark:text-white truncate">
                {@device.name}
              </h3>
              <%= if DtuKinds.ro_sink_kind?(@device) do %>
                <span
                  class="inline-flex shrink-0 items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-semibold bg-violet-100 text-violet-800 dark:bg-violet-900/30 dark:text-violet-300"
                  id={"dtu-sink-badge-#{@device.id}"}
                  title={
                    gettext(
                      "Read-only MQTT sink — receives a real-time feed of this account's other devices"
                    )
                  }
                >
                  <.icon name="hero-arrow-down-on-square-stack" class="size-3" />
                  {gettext("sink")}
                </span>
              <% end %>
            </div>
            <span
              class={[
                "inline-flex shrink-0 items-center px-2 py-0.5 rounded text-xs font-medium",
                cond do
                  @online? and not @nighttime? ->
                    "bg-emerald-100 text-emerald-800 dark:bg-emerald-900/30 dark:text-emerald-400"

                  @online? ->
                    "bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-300"

                  true ->
                    "bg-zinc-100 text-zinc-800 dark:bg-zinc-800 dark:text-zinc-400"
                end
              ]}
              title={
                cond do
                  @online? and not @nighttime? ->
                    gettext("Online — this DTU has reported AC power within the last 2 minutes")

                  @online? ->
                    gettext(
                      "Nighttime — MQTT is alive but no AC power reading has arrived. The inverter has stopped emitting telemetry, e.g. after sunset."
                    )

                  true ->
                    gettext("Offline — no MQTT activity in the last 5 minutes")
                end
              }
            >
              {cond do
                @online? and not @nighttime? -> gettext("online")
                @online? -> gettext("nighttime")
                true -> gettext("offline")
              end}
            </span>
          </div>
          <div class="mt-2 space-y-1 text-sm text-zinc-550 dark:text-zinc-400">
            <p>
              <span class="font-medium text-zinc-700 dark:text-zinc-300">{gettext("Last seen:")}</span>
              <span title={
                case @device.last_seen_at do
                  nil -> nil
                  dt -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
                end
              }>{case @device.last_seen_at do
                nil -> gettext("never")
                dt -> TimeHelpers.relative_time_label(dt)
              end}</span>
            </p>
          </div>
        </div>
      </.link>
      <%= if @error_count > 0 do %>
        <span
          class={[
            "absolute -top-2 -right-2 inline-flex items-center justify-center size-7 rounded-full bg-rose-500 text-white text-xs font-semibold shadow-md ring-2 ring-white dark:ring-zinc-800 pointer-events-none",
            if(@error_count > 99, do: "size-8 text-[10px]")
          ]}
          id={"dtu-error-edge-badge-#{@device.id}"}
          aria-label={gettext("%{count} distinct errors", count: @error_count)}
          title={gettext("%{count} distinct error message — click to view", count: @error_count)}
        >
          {if @error_count > 99, do: "99+", else: @error_count}
        </span>
      <% end %>
    </div>
    """
  end
end
