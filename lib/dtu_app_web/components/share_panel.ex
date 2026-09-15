defmodule DtuAppWeb.SharePanel do
  @moduledoc """
  The anonymous current-day dashboard share panel. Lives below
  the chart rather than in the toolbar so the URL row never has
  to compete for horizontal space with the quick-range / period
  stepper.

  Owns:

    * The toggle row (icon + label + checkbox-styled-as-pill).
    * The dynamic inner row, which renders one of three states
      keyed off `@share_loading?` / `@share_active?` / `@share_url`
      — they share the same outer chrome and only swap their
      inner row (spinner, URL input + copy button + hint, or
      static hint text) so the layout doesn't jump when the
      toggle flips. `aria-live="polite"` on the dynamic inner
      row announces state changes to screen readers without
      stealing focus.
    * Two colocated JS hooks the share row needs —
      `.CopyToClipboardWithHint` (the dedicated copy button's
      optimistic "Copied!" with a 1.5 s reset) and `.SelectOnFocus`
      (auto-select on focus / click / pointerdown so Cmd-C copies
      without a triple-click). Both are colocated because they're
      only used by this panel.

  The toggle fires `phx-click="toggle_share"` with
  `phx-value-enabled=<not @share_active?>`; the dashboard's
  `handle_event/3` does the actual mint/revoke. The component
  does not own any of the share token state — it just renders
  it.

  Was the inline block in
  `DtuAppWeb.DashboardLive.html.heex` (formerly lines 381-500 +
  the colocated `.CopyToClipboardWithHint` / `.SelectOnFocus`
  hook scripts at lines 521-739). Extracted so the dashboard
  template keeps just one `<.share_panel ...>` invocation and
  the share-row state machine has its own render-only test
  surface.

  Sister to `DtuAppWeb.DeviceStatusCard` (PR #274),
  `DtuAppWeb.ConsumptionStatCards` (PR #275),
  `DtuAppWeb.NetFlowStatCards` (PR #276),
  `DtuAppWeb.ChartTitle` (PR #277),
  `DtuAppWeb.BarChartPanel` (PR #278), and
  `DtuAppWeb.LineChartPanel` (PR #279).
  """

  use DtuAppWeb, :html

  attr :share_loading?, :boolean,
    default: false,
    doc: """
    `true` while a server-side `toggle_share` round-trip is in
    flight. Hides the pill cursor (becomes `cursor-wait`) and
    dims the pill (`opacity-70`); disables the checkbox; and
    swaps the inner row for the inline spinner + "Generating
    link…" text.
    """

  attr :share_active?, :boolean,
    default: false,
    doc: """
    `true` when a share link exists. Drives the pill's
    `peer-checked:` on-colour (via the checkbox `checked=` attr),
    the `phx-value-enabled` so a click flips the server-side
    state, and the inner row's `URL row + copy button` branch
    when `@share_url` is also set.
    """

  attr :share_url, :string,
    default: nil,
    doc: """
    The current share URL when `@share_active?` is `true` and
    the token has been minted yet (typically `nil` while
    `@share_loading?` is `true`, then populated by
    `handle_info({:share_link_minted, _, _}, _)`). Powers the
    URL `<input value=>`, the copy button's `data-value=`,
    and the `.CopyToClipboardWithHint` / `.SelectOnFocus` hook
    data attributes.
    """

  attr :locale, :string,
    default: "en",
    doc: """
    BCP-47 locale passed through to `gettext/1` for the toggle
    label, the loading text, the copy-button aria/title, and the
    static hint paragraph. Not used for number formatting —
    the share row has no numeric output.
    """

  def share_panel(assigns) do
    ~H"""
    <div
      id="share-panel"
      class="mt-4 border-t border-zinc-200 dark:border-zinc-700 pt-4"
    >
      <label
        id="share-toggle-label"
        for="share-toggle"
        class={[
          "flex items-center gap-3 select-none",
          unless(@share_loading?, do: "cursor-pointer", else: "cursor-wait opacity-70")
        ]}
        title={gettext("Share today's dashboard read-only")}
      >
        <.icon name="hero-share" class="size-5 text-zinc-500 dark:text-zinc-400" />
        <span class="text-sm font-semibold text-zinc-700 dark:text-zinc-200">
          {gettext("Share today's dashboard read-only")}
        </span>
        <%!-- The visible switch: a checkbox styled as a pill
               with a sliding dot. `peer-checked:` Tailwind
               variants flip the on-colors without a separate
               state class. The pill itself goes translucent
               while a server call is in flight so it's
               visually clear the click has been registered. --%>
        <span class="relative inline-flex items-center">
          <input
            type="checkbox"
            id="share-toggle"
            phx-click="toggle_share"
            phx-value-enabled={to_string(!@share_active?)}
            checked={@share_active?}
            disabled={@share_loading?}
            class="peer sr-only"
          />
          <span class="w-9 h-5 rounded-full bg-zinc-300 dark:bg-zinc-600 peer-checked:bg-emerald-500 peer-disabled:opacity-50 transition-colors"></span>
          <span class="absolute left-0.5 top-0.5 size-4 rounded-full bg-white shadow transition-transform peer-checked:translate-x-4"></span>
        </span>
      </label>

      <div
        id="share-row"
        class="mt-3 min-h-[2.25rem] flex items-center"
        aria-live="polite"
      >
        <%= cond do %>
          <% @share_loading? -> %>
            <%!-- Inline spinner shown while the token is
                   being minted (see `toggle_share` +
                   `handle_info({:share_link_minted, _, _}, _)`).
                   A pure-CSS border-spinner so it doesn't
                   depend on any icon glyph being available. --%>
            <div
              id="share-loading-row"
              class="flex items-center gap-2 text-sm text-zinc-500 dark:text-zinc-400"
              data-testid="share-loading"
            >
              <span
                class="inline-block size-4 rounded-full border-2 border-emerald-500 border-t-transparent animate-spin"
                aria-hidden="true"
              ></span>
              <span>{gettext("Generating link…")}</span>
            </div>
          <% @share_active? and @share_url -> %>
            <div
              id="share-url-row"
              class="flex items-center gap-2 w-full"
            >
              <input
                type="text"
                id="share-url-input"
                readonly
                value={@share_url}
                class="flex-1 min-w-0 px-3 py-2 text-sm font-mono rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-800 text-zinc-800 dark:text-zinc-100 focus:outline-none focus:ring-1 focus:ring-emerald-500"
                data-value={@share_url}
                phx-hook=".SelectOnFocus"
                aria-label={gettext("Shareable URL")}
                data-testid="share-url-input"
              />
              <button
                type="button"
                id="btn-share-copy"
                title={gettext("Copy URL")}
                aria-label={gettext("Copy URL")}
                class="shrink-0 p-2 rounded-lg text-zinc-600 hover:text-zinc-900 dark:text-zinc-300 dark:hover:text-white hover:bg-zinc-200/50 dark:hover:bg-zinc-700/50 transition"
                data-value={@share_url}
                phx-hook=".CopyToClipboardWithHint"
                data-testid="btn-share-copy"
              >
                <.icon name="hero-clipboard-document" class="size-5" />
              </button>
              <span
                id="share-copy-hint"
                class="text-sm font-semibold text-emerald-600 dark:text-emerald-400 opacity-0 transition-opacity"
                aria-live="polite"
                data-testid="share-copy-hint"
              >
                {gettext("Copied!")}
              </span>
            </div>
          <% true -> %>
            <p
              id="share-hint-text"
              class="text-xs text-zinc-500 dark:text-zinc-400"
            >
              {gettext(
                "Anyone with this link can view today's dashboard. The link stays valid until you turn sharing off."
              )}
            </p>
        <% end %>
      </div>
    </div>

    <%!-- Colocated JS hook for the share-cluster copy button. The
         dashboard uses `CopyToClipboard` for the URL input (a small
         green flash on the icon is enough context) and
         `CopyToClipboardWithHint` for the dedicated copy button —
         the latter reveals a "Copied!" label next to the button for
         1.5 s so the affordance is visible without having to hover
         the icon. We don't extend the existing `CopyToClipboard`
         hook because the device-settings page intentionally keeps
         its own quieter visual feedback, and merging the two would
         force every other call-site to carry the label element. --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToClipboardWithHint">
      export default {
        mounted() {
          this.hint = document.getElementById("share-copy-hint")

          this.handler = (event) => {
            event.preventDefault()
            const text = this.el.dataset.value || ""

            // Show "Copied!" feedback *immediately* on click — the
            // user needs to know the click registered, even if the
            // clipboard write below takes a beat (or hangs, in
            // some headless / iframe / permission-denied setups).
            // If the write later turns out to have failed, we
            // downgrade the visual feedback to "Copy failed" so
            // the optimistic state doesn't lie to the user.
            this.showFeedback(true)

            // `navigator.clipboard.writeText` is only available in
            // secure contexts (HTTPS, or `localhost` on most
            // browsers). On plain-HTTP LAN IPs (e.g. staging on a
            // Raspberry Pi) it returns `undefined` — and even when
            // defined, it can throw on browsers that prompt for
            // permission and the user clicks "Block". Fall back to
            // the legacy `document.execCommand("copy")` path via a
            // temporary textarea so the copy still works in those
            // environments. The legacy path is deprecated but still
            // works on every browser we care about.
            const write = async () => {
              if (
                typeof navigator !== "undefined" &&
                navigator.clipboard &&
                typeof navigator.clipboard.writeText === "function"
              ) {
                try {
                  await navigator.clipboard.writeText(text)
                  return true
                } catch (_err) {
                  // Fall through to the textarea path.
                }
              }

              try {
                const ta = document.createElement("textarea")
                ta.value = text
                ta.setAttribute("readonly", "")
                ta.style.position = "fixed"
                ta.style.top = "0"
                ta.style.left = "0"
                ta.style.opacity = "0"
                document.body.appendChild(ta)
                ta.focus()
                ta.select()
                const ok = document.execCommand && document.execCommand("copy")
                document.body.removeChild(ta)
                return !!ok
              } catch (_err) {
                return false
              }
            }

            write().then((ok) => {
              if (!ok) {
                console.error(
                  "CopyToClipboardWithHint hook: copy failed (both clipboard API and execCommand fallback returned false)"
                )
                // Downgrade the optimistic "Copied!" to "Copy
                // failed" — same timer, just an amber tint so the
                // user notices something went wrong.
                if (this.hint) {
                  this.hint.textContent = "Copy failed"
                  this.hint.classList.add(
                    "text-amber-600",
                    "dark:text-amber-400"
                  )
                  this.hint.classList.remove(
                    "text-emerald-600",
                    "dark:text-emerald-400"
                  )
                }
              }
            })
          }

          this.showFeedback = (success) => {
            if (this.hint) {
              this.hint.textContent = success ? "Copied!" : "Copy failed"
              this.hint.classList.add("opacity-100")
              this.hint.classList.remove("opacity-0")
              if (!success) {
                this.hint.classList.add("text-amber-600", "dark:text-amber-400")
                this.hint.classList.remove("text-emerald-600", "dark:text-emerald-400")
              }
            }

            this.el.classList.add("copied")
            const svg = this.el.querySelector("svg")

            if (svg) {
              svg.dataset.originalClass = svg.getAttribute("class") || ""
              svg.setAttribute(
                "class",
                success
                  ? "size-5 text-emerald-500"
                  : "size-5 text-amber-500"
              )
            }

            clearTimeout(this._resetTimer)
            this._resetTimer = setTimeout(() => {
              if (this.hint) {
                this.hint.classList.add("opacity-0")
                this.hint.classList.remove("opacity-100")
                this.hint.classList.remove(
                  "text-amber-600",
                  "dark:text-amber-400"
                )
                this.hint.classList.add(
                  "text-emerald-600",
                  "dark:text-emerald-400"
                )
                this.hint.textContent = "Copied!"
              }

              this.el.classList.remove("copied")

              if (svg) {
                svg.setAttribute("class", svg.dataset.originalClass || "")
              }
            }, 1500)
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

    <%!-- SelectOnFocus: selects the full URL on the first user
         gesture so Cmd-C / Ctrl-C copies it without an extra
         triple-click. We listen on three events:

           * `focus`    — desktop keyboard navigation (Tab into the
                          field)
           * `click`    — desktop mouse click into the field
           * `pointerdown` — mobile / touch tap (where the browser
                          may or may not fire `focus` reliably; some
                          WebKit builds don't focus on tap without
                          `touch-action: manipulation`)

         We deliberately don't use the inline `onfocus="this.select()"`
         attribute — it works on desktop clicks but tap-into-input on
         iOS Safari doesn't fire `focus` for readonly inputs in some
         builds, so the URL stays unselected. The hook guarantees the
         selection on every gesture.

         The select() call is deferred via `setTimeout(..., 0)`
         — a macrotask — so it runs AFTER both the click event
         listeners AND the browser's default-action cursor
         placement for the click. (Microtasks drain BEFORE the
         click default action in some Chrome builds, which lets
         the cursor land at the click position; a macrotask
         always fires after both, so our selection wins.) --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SelectOnFocus">
      export default {
        mounted() {
          this.select = () => {
            // `setTimeout(..., 0)` schedules a macrotask —
            // these always run AFTER microtasks drain AND after
            // the browser's default-action cursor placement.
            // That's what we need to win over the click's
            // default.
            setTimeout(() => {
              if (typeof this.el.select === "function") {
                this.el.focus({ preventScroll: true })
                this.el.select()
                if (typeof this.el.setSelectionRange === "function") {
                  try {
                    this.el.setSelectionRange(0, this.el.value.length)
                  } catch (_err) {
                    // Some input types (e.g. email) reject setSelectionRange.
                    // `select()` already covered the common case.
                  }
                }
              }
            }, 0)
          }

          this.el.addEventListener("focus", this.select)
          this.el.addEventListener("click", this.select)
          this.el.addEventListener("pointerdown", this.select)
        },

        destroyed() {
          if (!this.el || !this.select) return
          this.el.removeEventListener("focus", this.select)
          this.el.removeEventListener("click", this.select)
          this.el.removeEventListener("pointerdown", this.select)
        }
      }
    </script>
    """
  end
end
