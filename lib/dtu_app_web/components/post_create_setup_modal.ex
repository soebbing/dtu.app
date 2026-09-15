defmodule DtuAppWeb.PostCreateSetupModal do
  @moduledoc """
  The success modal that opens immediately after a user saves
  a new DTU. Walks them through configuring the physical device
  with the system-generated MQTT credentials.

  Bundles six layers:

    1. **Modal chrome** — fixed overlay (`fixed inset-0 z-50 ...`)
       with a backdrop blur and the max-width rounded card. The
       outer overlay carries `id="created-device-modal"` and
       the inner heading carries `id="created-device-modal-title"`
       so e2e selectors can target them precisely.

    2. **Success icon + heading** — emerald check-circle icon
       in a tinted tile + the "DTU Configured Successfully!" h3.
       The subtitle names the firmware kind ("OpenDTU", "AhoyDTU",
       "Shelly Plus 3EM (Gen3+)") so the user knows which
       hardware setup steps to follow.

    3. **Copy-to-clipboard grid** — five rows (broker host, port,
       username, password, base topic) where each value sits
       inside a tightly-bound `<span class="flex-1
       truncate">{value}</span>` and a copy button sits next to
       it. Critical: the value's span must be `>{value}</span>`
       with NO whitespace between `>` and the value — Chromium's
       double-click word-selection algorithm extends to whitespace
       inside an inline element, so a span rendered as
       `> mqtt_user </span>` would copy as ` mqtt_user ` instead
       of `mqtt_user`. The existing test
       `device_live_test.exs:105` pins this.

    4. **Colocated `.CopyToClipboard` JS hook** — the inline
       `<script :type={Phoenix.LiveView.ColocatedHook}>` block
       that defines the copy behaviour. Each copy button uses
       `phx-hook=".CopyToClipboard"` + `data-value="..."` and
       the hook calls `navigator.clipboard.writeText` + swaps
       the icon to a checkmark for 1.5 s on success.

    5. **Hardware setup instructions** — the four-bullet list
       ("Open your DTU's web interface", "Navigate to Settings
       → MQTT", "Fill in the server details", "Ensure MQTT is
       enabled, save and reboot") rendered as a numbered list.

    6. **Shelly-specific notes** (conditional on
       `device.kind == :shelly3em`) — extra paragraph explaining
       that Shelly publishes telemetry as a single JSON object
       and that Shelly's default MQTT prefix is the device ID.
       Rendered ONLY for `kind == :shelly3em`; other firmwares
       skip this block entirely.

    7. **"What happens next" footer** — the closing paragraph
       explaining that telemetry starts within ~1 minute of
       the DTU rebooting, plus a troubleshooting hint.

    8. **Dismiss button** — the only actionable element in the
       modal body. Triggers `phx-click="close_created_modal"`
       on the parent LV, which clears the `@created_device`
       assign so the modal unmounts.

  Was the inline block in
  `DtuAppWeb.DeviceLive.Index.html.heex` (formerly
  lines 396-627, ~230 lines). Extracted so the modal's
  per-field stable ids (`btn-copy-mqtt-host`, etc.), the
  copy-button + CopyToClipboard hook pairing, the
  Shelly-specific notes branch, and the
  `>value</span>` no-whitespace constraint get their own
  stable render-only test surface — important because the
  no-whitespace contract is invisible at a glance (a
  regression that adds whitespace between `>` and `{value}`
  silently breaks the user's double-click copy workflow).

  Sister to `DtuAppWeb.DeviceRow` (PR #287) and
  `DtuAppWeb.ErrorExpansionPanel` (PR #288).
  """

  use DtuAppWeb, :html

  attr :device, :map,
    required: true,
    doc: """
    The freshly-created DTU. The component reads `kind`,
    `mqtt_username`, `mqtt_password`, and `base_topic` —
    the four fields the user needs to type into their
    physical DTU. Other fields are not consumed.
    """

  attr :mqtt_host, :string,
    required: true,
    doc: """
    The MQTT broker hostname shown as the "MQTT Broker /
    Server" field. Set from
    `Application.get_env(:dtu_app, :mqtt_host)` with a
    fallback to the Phoenix endpoint's host (the LV's
    `mqtt_host/0` private helper).
    """

  def post_create_setup_modal(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-zinc-950/60 backdrop-blur-sm"
      id="created-device-modal"
    >
      <div class="bg-white dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-800 rounded-2xl max-w-lg w-full p-6 shadow-xl space-y-4">
        <div class="flex items-start gap-3">
          <div class="p-2 bg-emerald-50 dark:bg-emerald-950/30 text-emerald-600 dark:text-emerald-450 rounded-lg">
            <.icon name="hero-check-circle" class="h-6 w-6" />
          </div>
          <div class="flex-1 min-w-0">
            <h3
              class="text-lg font-bold text-zinc-900 dark:text-white"
              id="created-device-modal-title"
            >
              {gettext("DTU Configured Successfully!")}
            </h3>
            <p class="text-sm text-zinc-500 dark:text-zinc-400 mt-1">
              {gettext(
                "To start sending telemetry, configure your physical %{kind} hardware with the following MQTT settings:",
                kind: Atom.to_string(@device.kind) |> String.capitalize()
              )}
            </p>
          </div>
        </div>

        <div class="space-y-3 bg-zinc-50 dark:bg-zinc-800/40 p-4 rounded-xl border border-zinc-200/60 dark:border-zinc-700/60 text-sm">
          <%!-- Interpolation flush against tag: anything beyond the tags
              becomes part of the rendered text node, and Chromium's
              double-click word-selection algorithm then includes the
              surrounding whitespace when copying the value. --%>
          <div class="grid grid-cols-3 gap-2">
            <span class="text-zinc-500 font-medium self-center">{gettext("MQTT Broker / Server:")}</span>
            <div class="col-span-2 flex items-center gap-2 font-mono text-zinc-800 dark:text-zinc-200 select-all font-semibold min-w-0">
              <span class="flex-1 truncate">{@mqtt_host}</span>
              <button
                type="button"
                id="btn-copy-mqtt-host"
                phx-hook=".CopyToClipboard"
                data-value={@mqtt_host}
                class="shrink-0 inline-flex items-center justify-center rounded-md border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-800 p-1.5 text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 focus:outline-none focus:ring-2 focus:ring-emerald-500 transition"
                title={gettext("Copy to clipboard")}
                aria-label={gettext("Copy to clipboard")}
              >
                <.icon name="hero-clipboard-document" class="h-4 w-4" />
              </button>
            </div>

            <span class="text-zinc-500 font-medium self-center">{gettext("MQTT Port:")}</span>
            <div class="col-span-2 flex items-center gap-2 font-mono text-zinc-800 dark:text-zinc-200 select-all font-semibold min-w-0">
              <span class="flex-1 truncate">1883</span>
              <button
                type="button"
                id="btn-copy-mqtt-port"
                phx-hook=".CopyToClipboard"
                data-value="1883"
                class="shrink-0 inline-flex items-center justify-center rounded-md border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-800 p-1.5 text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 focus:outline-none focus:ring-2 focus:ring-emerald-500 transition"
                title={gettext("Copy to clipboard")}
                aria-label={gettext("Copy to clipboard")}
              >
                <.icon name="hero-clipboard-document" class="h-4 w-4" />
              </button>
            </div>

            <span class="text-zinc-500 font-medium self-center">{gettext("MQTT Username:")}</span>
            <div class="col-span-2 flex items-center gap-2 font-mono text-zinc-800 dark:text-zinc-200 select-all font-semibold min-w-0">
              <span class="flex-1 truncate">{@device.mqtt_username}</span>
              <button
                type="button"
                id="btn-copy-mqtt-username"
                phx-hook=".CopyToClipboard"
                data-value={@device.mqtt_username}
                class="shrink-0 inline-flex items-center justify-center rounded-md border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-800 p-1.5 text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 focus:outline-none focus:ring-2 focus:ring-emerald-500 transition"
                title={gettext("Copy to clipboard")}
                aria-label={gettext("Copy to clipboard")}
              >
                <.icon name="hero-clipboard-document" class="h-4 w-4" />
              </button>
            </div>

            <span class="text-zinc-500 font-medium self-center">{gettext("MQTT Password:")}</span>
            <div class="col-span-2 flex items-center gap-2 font-mono text-zinc-800 dark:text-zinc-200 select-all font-semibold min-w-0">
              <span class="flex-1 truncate">{@device.mqtt_password}</span>
              <button
                type="button"
                id="btn-copy-mqtt-password"
                phx-hook=".CopyToClipboard"
                data-value={@device.mqtt_password}
                class="shrink-0 inline-flex items-center justify-center rounded-md border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-800 p-1.5 text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 focus:outline-none focus:ring-2 focus:ring-emerald-500 transition"
                title={gettext("Copy to clipboard")}
                aria-label={gettext("Copy to clipboard")}
              >
                <.icon name="hero-clipboard-document" class="h-4 w-4" />
              </button>
            </div>

            <span class="text-zinc-500 font-medium self-center">{gettext("Base Topic:")}</span>
            <div class="col-span-2 flex items-center gap-2 font-mono text-zinc-800 dark:text-zinc-200 select-all font-semibold min-w-0">
              <span class="flex-1 truncate">{@device.base_topic}</span>
              <button
                type="button"
                id="btn-copy-base-topic"
                phx-hook=".CopyToClipboard"
                data-value={@device.base_topic}
                class="shrink-0 inline-flex items-center justify-center rounded-md border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-800 p-1.5 text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 focus:outline-none focus:ring-2 focus:ring-emerald-500 transition"
                title={gettext("Copy to clipboard")}
                aria-label={gettext("Copy to clipboard")}
              >
                <.icon name="hero-clipboard-document" class="h-4 w-4" />
              </button>
            </div>
          </div>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToClipboard">
          export default {
            mounted() {
              this.handler = (event) => {
                event.preventDefault()
                const text = this.el.dataset.value || ""
                navigator.clipboard.writeText(text).then(() => {
                  this.el.classList.add("copied")
                  const svg = this.el.querySelector("svg")

                  if (svg) {
                    svg.dataset.originalClass = svg.getAttribute("class") || ""
                    svg.setAttribute("class", "h-4 w-4 text-emerald-500")
                  }

                  clearTimeout(this._resetTimer)
                  this._resetTimer = setTimeout(() => {
                    this.el.classList.remove("copied")

                    if (svg) {
                      svg.setAttribute("class", svg.dataset.originalClass || "")
                    }
                  }, 1500)
                }).catch((err) => {
                  console.error("CopyToClipboard hook: copy failed", err)
                })
              }

              this.el.addEventListener("click", this.handler)
            },

            destroyed() {
              if (this.el && this.handler) {
                this.el.removeEventListener("click", this.handler)
              }

              clearTimeout(this._resetTimer)
            }
          }
        </script>

        <div class="border-t border-zinc-200 dark:border-zinc-800 pt-3">
          <h4 class="text-xs font-semibold text-zinc-700 dark:text-zinc-300 uppercase tracking-wider">
            {gettext("Hardware setup instructions:")}
          </h4>
          <ul class="mt-2 space-y-1 text-xs text-zinc-500 list-disc list-inside">
            <li>
              {gettext("Open your DTU's web interface in a browser.")}
            </li>
            <li>
              {gettext("Navigate to Settings -> MQTT.")}
            </li>
            <li>
              {gettext(
                "Fill in the server details, username, password, and base topic as shown above."
              )}
            </li>
            <li>
              {gettext("Ensure MQTT is enabled, save and reboot the DTU.")}
            </li>
          </ul>
        </div>

        <%!-- Shelly Plus 3EM (Gen3+) publishes telemetry on a single JSON
             topic rather than the per-field scalar topics OpenDTU and
             AhoyDTU use. Surface that here so users know what to expect
             in the broker's MQTT view, and remind them that Shelly's
             default MQTT prefix is the device ID, which usually doesn't
             match the Base Topic shown above. --%>
        <div
          :if={@device.kind == :shelly3em}
          class="border-t border-zinc-200 dark:border-zinc-800 pt-3 text-xs text-zinc-500 dark:text-zinc-400 space-y-1"
        >
          <p class="font-medium text-zinc-700 dark:text-zinc-300">
            {gettext("Shelly-specific notes:")}
          </p>
          <p>
            {gettext(
              "Telemetry is published as a single JSON object on the topic %{topic}. Shelly's default MQTT prefix is the device ID (e.g. shellyplus3em-XXXXXXXXXXXX), so set the device's prefix to %{custom_topic} to match the Base Topic shown above.",
              topic: "#{@device.base_topic}/status/em:0",
              custom_topic: @device.base_topic
            )}
          </p>
          <p>
            {gettext(
              "Once connected, the dashboard's consumption cards (\"Current Consumption\", \"Today's Consumption\") appear within a few seconds."
            )}
          </p>
        </div>

        <div class="border-t border-zinc-200 dark:border-zinc-800 pt-3 text-xs text-zinc-500 dark:text-zinc-400 space-y-1">
          <p class="font-medium text-zinc-700 dark:text-zinc-300">
            {gettext("What happens next")}
          </p>
          <p>
            {gettext(
              "After your DTU reboots, it will appear as online on your dashboard within about a minute, and live power data starts flowing within seconds."
            )}
          </p>
          <p>
            {gettext(
              "If it stays offline, double-check the username, password, and broker address above match exactly what's in your DTU's MQTT settings."
            )}
          </p>
        </div>

        <div class="flex justify-end pt-2">
          <button
            phx-click="close_created_modal"
            id="btn-close-created-modal"
            class="px-4 py-2 bg-zinc-900 hover:bg-zinc-700 dark:bg-zinc-100 dark:hover:bg-zinc-300 text-white dark:text-zinc-900 text-sm font-semibold rounded-lg transition shadow-sm"
          >
            {gettext("Dismiss")}
          </button>
        </div>
      </div>
    </div>
    """
  end
end
