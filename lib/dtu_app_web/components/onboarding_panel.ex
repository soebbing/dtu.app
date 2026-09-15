defmodule DtuAppWeb.OnboardingPanel do
  @moduledoc """
  The first-visit onboarding panel rendered when a user has no
  DTUs yet (`@devices == []`). Replaces the stats / chart grid
  entirely (the grid is meaningless without telemetry to chart).

  Two stacked siblings, both always rendered together when this
  component renders:

    1. **Welcome card** — a centered bolt-icon badge, the
       `Welcome! Let's connect your first DTU` heading, the
       MQTT-explainer paragraph, and the primary `Add your
       first DTU` CTA linking to `/devices/new`. The CTA is
       the only interactive element in this block; everything
       else is prose + iconography.

    2. **"How it works" rail** — a quieter three-step promise
       below the welcome card. The welcome paragraph already
       explains MQTT and per-device credentials; the rail names
       the three beats (`Register` / `Connect` / `See live
       data`) without repeating the detail. Three numbered
       steps lay out in a single column on mobile and a
       three-up row on `md:` so the numbers + dividers read as
       a sequence instead of three isolated icons.

  The component takes only `@locale` (for the `gettext/1`
  calls); it has no dynamic assigns. The `if @devices == []`
  guard that gates rendering stays in the dashboard's outer
  template — this component always renders its full content
  when invoked.

  Was the inline block in
  `DtuAppWeb.DashboardLive.html.heex` (formerly lines 108-205).
  Extracted so the dashboard template keeps the `if @devices
  == []` guard but the onboarding UI has its own render-only
  test surface, and so future onboarding tweaks (a fourth
  step, a marketing screenshot, a video embed) don't pile more
  inline HTML onto a LiveView that's already extracted eleven
  sibling components.

  Sister to `DtuAppWeb.DeviceStatusCard` (PR #274),
  `DtuAppWeb.ConsumptionStatCards` (PR #275),
  `DtuAppWeb.NetFlowStatCards` (PR #276),
  `DtuAppWeb.ChartTitle` (PR #277),
  `DtuAppWeb.BarChartPanel` (PR #278),
  `DtuAppWeb.LineChartPanel` (PR #279), and
  `DtuAppWeb.SharePanel` (PR #280).
  """

  use DtuAppWeb, :html

  attr :locale, :string,
    default: "en",
    doc: """
    BCP-47 locale passed through to `gettext/1` for the welcome
    heading, the MQTT-explainer paragraph, the CTA label, and
    every string in the three-step rail. Not used for number
    formatting — the onboarding block has no numeric output.
    """

  def onboarding_panel(assigns) do
    ~H"""
    <!-- Onboarding: no DTUs yet. The whole stats/chart grid is meaningless
               without a device, so guide the user to create their first one. -->
    <div
      class="rounded-2xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-8 text-center"
      id="onboarding-empty"
    >
      <div class="mx-auto w-fit p-3 rounded-xl bg-emerald-50 dark:bg-emerald-950/30 text-emerald-600 dark:text-emerald-400">
        <.icon name="hero-bolt" class="h-8 w-8" />
      </div>
      <h2 class="mt-4 text-xl font-bold tracking-tight text-zinc-900 dark:text-white">
        {gettext("Welcome! Let's connect your first DTU")}
      </h2>
      <p class="mt-2 text-sm text-zinc-500 dark:text-zinc-400 max-w-md mx-auto">
        {gettext(
          "A DTU (Data Transfer Unit) reads your solar inverter and publishes live telemetry here over MQTT. Add yours to start seeing real-time generation — works with OpenDTU and AhoyDTU firmware."
        )}
      </p>
      <div class="mt-6">
        <.link
          navigate={~p"/devices/new"}
          id="btn-add-first-dtu"
          class="inline-flex items-center gap-1.5 rounded-lg bg-emerald-500 hover:bg-emerald-400 px-5 py-2.5 text-sm font-semibold text-zinc-950 shadow-sm transition"
        >
          <.icon name="hero-plus-mini" class="size-4" />
          {gettext("Add your first DTU")}
        </.link>
      </div>
    </div>

    <%!-- "How it works" rail: a quiet three-step promise below
               the welcome card. The welcome card's paragraph already
               explains MQTT and per-device credentials; the rail names
               the three beats without repeating the detail. Three
               numbered steps lay out in a single column on mobile and
               a three-up row on `md:` so the numbers + dividers read
               as a sequence instead of three isolated icons. --%>
    <div
      class="rounded-2xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-6 md:p-8"
      id="onboarding-how-it-works"
    >
      <h2 class="text-base font-semibold tracking-tight text-zinc-900 dark:text-white">
        {gettext("How it works")}
      </h2>
      <p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
        {gettext("Three steps from sign-up to a live chart. Each step takes about a minute.")}
      </p>
      <ol class="mt-5 grid grid-cols-1 gap-4 md:grid-cols-3 md:gap-0">
        <li class="flex md:flex-col items-start gap-3 md:gap-0 md:pr-6">
          <span
            class="shrink-0 inline-flex items-center justify-center size-7 rounded-full bg-emerald-50 dark:bg-emerald-950/40 text-emerald-700 dark:text-emerald-300 text-sm font-semibold"
            aria-hidden="true"
          >
            1
          </span>
          <div class="md:mt-3">
            <p class="text-sm font-semibold text-zinc-900 dark:text-white">
              {gettext("Register")}
            </p>
            <p class="mt-1 text-xs text-zinc-500 dark:text-zinc-400">
              {gettext("Add your DTU on the Devices page.")}
            </p>
          </div>
        </li>
        <li class="flex md:flex-col items-start gap-3 md:gap-0 md:px-6 md:border-x md:border-zinc-200 md:dark:border-zinc-800">
          <span
            class="shrink-0 inline-flex items-center justify-center size-7 rounded-full bg-emerald-50 dark:bg-emerald-950/40 text-emerald-700 dark:text-emerald-300 text-sm font-semibold"
            aria-hidden="true"
          >
            2
          </span>
          <div class="md:mt-3">
            <p class="text-sm font-semibold text-zinc-900 dark:text-white">
              {gettext("Connect")}
            </p>
            <p class="mt-1 text-xs text-zinc-500 dark:text-zinc-400">
              {gettext("Point your DTU at our broker with the credentials we show you.")}
            </p>
          </div>
        </li>
        <li class="flex md:flex-col items-start gap-3 md:gap-0 md:pl-6">
          <span
            class="shrink-0 inline-flex items-center justify-center size-7 rounded-full bg-emerald-50 dark:bg-emerald-950/40 text-emerald-700 dark:text-emerald-300 text-sm font-semibold"
            aria-hidden="true"
          >
            3
          </span>
          <div class="md:mt-3">
            <p class="text-sm font-semibold text-zinc-900 dark:text-white">
              {gettext("See live data")}
            </p>
            <p class="mt-1 text-xs text-zinc-500 dark:text-zinc-400">
              {gettext("Watch watts appear on this chart as soon as the sun is up.")}
            </p>
          </div>
        </li>
      </ol>
    </div>
    """
  end
end
