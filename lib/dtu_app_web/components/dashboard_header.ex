defmodule DtuAppWeb.DashboardHeader do
  @moduledoc """
  The page header for the dashboard — a large title (`PV Power
  Dashboard`) plus a one-line subtitle (`Real-time and historic
  generation stats for your solar converter system.`). On the
  onboarding branch (no devices yet) the right side also gets a
  `Manage Devices` link button pointing at `/devices`; once the
  user has at least one device the same right side is empty so
  the user sees the title by itself (the manage-devices action
  is then reachable from the burger menu).

  Layout: a flex row that stacks vertically on small viewports
  (column layout when the right side is empty so the title
  stays centered) and lays out as a row on `md:` so the
  optional button sits flush-right on the same baseline as the
  title.

  The component takes only `@locale` (for `gettext/1` calls)
  and a `no_devices?` boolean — when `false`, the right-side
  wrapper and its conditional `Manage Devices` link render
  nothing at all so the header collapses to the title alone.

  Was the inline block in
  `DtuAppWeb.DashboardLive.html.heex` (formerly lines 76-106).
  Extracted so the dashboard template keeps just the outer
  spacing wrapper and the header itself has its own render-only
  test surface — important because the title / subtitle / CTA
  bundle is the highest-visibility content above the fold and
  gets tweaked far more often than the deeper chart internals.

  Sister to `DtuAppWeb.DeviceStatusCard` (PR #274),
  `DtuAppWeb.ConsumptionStatCards` (PR #275),
  `DtuAppWeb.NetFlowStatCards` (#276),
  `DtuAppWeb.ChartTitle` (#277),
  `DtuAppWeb.BarChartPanel` (#278),
  `DtuAppWeb.LineChartPanel` (#279),
  `DtuAppWeb.SharePanel` (#280), and
  `DtuAppWeb.OnboardingPanel` (#281).
  """

  use DtuAppWeb, :html

  attr :locale, :string,
    default: "en",
    doc: """
    BCP-47 locale passed through to `gettext/1` for the
    dashboard title, the subtitle paragraph, and the
    `Manage Devices` button label. Not used for number
    formatting — the header has no numeric output.
    """

  attr :no_devices?, :boolean,
    default: false,
    doc: """
    When `true`, renders the `Manage Devices` link button to
    the right of the title on `md:`+ viewports. The button
    navigates to `/devices` (not `/devices/new` — the welcome
    card's CTA is the primary "add your first" prompt; this
    CTA is for users who want to edit / inspect their existing
    setup but don't have one yet, so they're sent to the
    device-index page to read setup instructions before
    creating). When `false`, the right-hand wrapper renders
    nothing and the header collapses to title + subtitle.
    """

  def dashboard_header(assigns) do
    ~H"""
    <div class="flex flex-col md:flex-row md:items-center md:justify-between space-y-4 md:space-y-0">
      <div>
        <h1 class="text-3xl font-extrabold tracking-tight text-zinc-900 dark:text-white">
          {gettext("PV Power Dashboard")}
        </h1>
        <p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
          {gettext("Real-time and historic generation stats for your solar converter system.")}
        </p>
      </div>
      <%= if @no_devices? do %>
        <%!-- Promoted in the burger menu once a device exists. The
                 dashboard's main "Manage Devices" CTA only renders in
                 the onboarding state, so it doesn't compete with the
                 device cards below or the burger menu's link. --%>
        <div>
          <.link
            navigate={~p"/devices"}
            id="btn-manage-devices"
            class={[
              "inline-flex items-center px-4 py-2 border rounded-md shadow-sm text-sm font-medium transition",
              "border-zinc-300 dark:border-zinc-700 text-zinc-700 dark:text-zinc-200 bg-white dark:bg-zinc-800",
              "hover:bg-zinc-50 dark:hover:bg-zinc-700 focus:outline-none"
            ]}
          >
            <.icon name="hero-cog-6-tooth" class="-ml-1 mr-2 h-5 w-5 text-zinc-400" />
            {gettext("Manage Devices")}
          </.link>
        </div>
      <% end %>
    </div>
    """
  end
end
