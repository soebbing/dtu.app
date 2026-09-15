defmodule DtuAppWeb.DashboardToolbar do
  @moduledoc """
  The dashboard toolbar — the cluster of switches above the stat
  cards and chart that drives both *which DTU is shown* and *which
  time window is being viewed*. The bundle is a stack:

    1. **DTU switcher** (`<.dtu_switcher>`) — one button per DTU,
       plus a `Total` button for the aggregate view. Hidden
       entirely when the user has 0 or 1 devices (the switcher
       self-suppresses when it's not meaningful).
    2. **Quick-range switcher** (`<.quick_range_switcher>`) —
       fixed 1D / 7D / 30D / YTD / Custom row; the active preset
       is highlighted.
    3. **Historical stepper** (`<.historical_stepper>`) — only
       appears inline beside the quick-range row when the user
       picks the `Custom` preset. Pre-bucketed selectable date
       lists (`selectable_dates` / `selectable_days` /
       `selectable_weeks` / `selectable_months` /
       `selectable_years`) drive the granularity dropdowns;
       `granularity` plus `selected_period` hold the current
       anchor.

  Layout: vertical stack on narrow viewports, single column on
  `md:`+ that wraps the quick-range row + stepper onto a shared
  `flex flex-wrap items-center gap-4` row so they read as one
  toolbar instead of two stacked clusters.

  The `:live` flag is forwarded straight from the LiveView mount
  (`@live`) so the historical stepper can hide its "No
  historical data" caption in the live-view mode.

  Was the inline block in
  `DtuAppWeb.DashboardLive.html.heex` (formerly lines 87-124).
  Extracted so the dashboard template keeps just the outer
  spacing wrapper and the toolbar trio has its own render-only
  test surface — important because the toolbar wires together
  three sibling components whose conditional rendering (the
  stepper only in `custom` mode) is the easiest place for a
  regression to hide.

  Sister to `DtuAppWeb.DeviceStatusCard` (PR #274),
  `DtuAppWeb.ConsumptionStatCards` (PR #275),
  `DtuAppWeb.NetFlowStatCards` (#276),
  `DtuAppWeb.ChartTitle` (#277),
  `DtuAppWeb.BarChartPanel` (#278),
  `DtuAppWeb.LineChartPanel` (#279),
  `DtuAppWeb.SharePanel` (#280),
  `DtuAppWeb.OnboardingPanel` (#281), and
  `DtuAppWeb.DashboardHeader` (#282).
  """

  use DtuAppWeb, :html

  import DtuAppWeb.DashboardLive.Components,
    only: [
      dtu_switcher: 1,
      quick_range_switcher: 1,
      historical_stepper: 1
    ]

  attr :devices, :list,
    default: [],
    doc: """
    The user's DTU list, forwarded to `<.dtu_switcher>`. The
    switcher self-suppresses when the list is empty or has a
    single device — that's the switcher's own decision, not
    the toolbar's, so the toolbar still receives the list as
    given.
    """

  attr :selected_dtu_id, :any,
    default: nil,
    doc: """
    Currently selected DTU id, or `nil` for the aggregate
    `Total (All DTUs)` view. Forwarded to `<.dtu_switcher>`
    so the matching button gets the emerald highlight.
    """

  attr :range_preset, :string,
    default: "1d",
    doc: """
    Currently selected quick-range preset — one of `"1d"`,
    `"7d"`, `"30d"`, `"ytd"`, `"custom"`. Forwarded to
    `<.quick_range_switcher>` so the matching button is
    highlighted; also gates the inline `<.historical_stepper>`
    (the stepper only renders when the preset is `"custom"` —
    the 1D/7D/30D/YTD presets already encode their own window
    and don't need the stepper UI).
    """

  attr :granularity, :string,
    default: "day",
    doc: """
    Currently selected historical granularity, one of `"day"`,
    `"week"`, `"month"`, `"year"`. Only consumed by
    `<.historical_stepper>`, so it's only meaningful when
    `range_preset == "custom"`. Default `"day"` keeps the
    toolbar renderable for tests / fragments that don't pick
    a granularity yet.
    """

  attr :selected_period, :any,
    default: nil,
    doc: """
    Currently selected historical period anchor — `Date` for
    day/week/month granularity, integer year for year
    granularity. Only consumed by `<.historical_stepper>`,
    so only meaningful when `range_preset == "custom"`.
    """

  attr :selectable_dates, :list,
    default: [],
    doc: """
    Full list of dates with data for the day-granularity
    selector, forwarded straight to `<.historical_stepper>`.
    Empty in the live view (the stepper self-suppresses the
    "No data" caption when `@live` is true).
    """

  attr :selectable_days, :list,
    default: [],
    doc: """
    Pre-bucketed day list from
    `DtuAppWeb.DashboardLive.PeriodSelectable.build_selectable_days/1`,
    forwarded to `<.historical_stepper>`.
    """

  attr :selectable_weeks, :list,
    default: [],
    doc: """
    Pre-bucketed week list, forwarded to
    `<.historical_stepper>`.
    """

  attr :selectable_months, :list,
    default: [],
    doc: """
    Pre-bucketed month list, forwarded to
    `<.historical_stepper>`.
    """

  attr :selectable_years, :list,
    default: [],
    doc: """
    Pre-bucketed year list, forwarded to
    `<.historical_stepper>`.
    """

  attr :live, :boolean,
    default: false,
    doc: """
    True when the dashboard is in the live view. Forwarded
    straight to `<.historical_stepper>` so the stepper can
    hide its "No historical data for this period" caption —
    the live view simply doesn't have a historical period to
    caption.
    """

  def dashboard_toolbar(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <%!-- DTU Switcher (self-suppresses when device list is empty
           or single — see <.dtu_switcher>). --%>
      <.dtu_switcher devices={@devices} selected_dtu_id={@selected_dtu_id} />

      <%!-- Quick-range row + (conditional) historical stepper share
           this row so the toolbar reads as one toolbar instead of
           two stacked controls. The wrapping <div> uses
           `flex flex-wrap items-center gap-4` so the two clusters
           stay side by side on desktop and wrap below each other
           on narrow viewports. --%>
      <div class="flex flex-wrap items-center gap-4">
        <.quick_range_switcher range_preset={@range_preset} />

        <%!-- Historical stepper: ‹ [Granularity ▾] [Date ▾] › —
             only rendered when the user picked the `custom`
             preset; the 1D/7D/30D/YTD presets already encode
             their own window and don't need the stepper UI. --%>
        <%= if @range_preset == "custom" do %>
          <.historical_stepper
            granularity={@granularity}
            selected_period={@selected_period}
            selectable_dates={@selectable_dates}
            selectable_days={@selectable_days}
            selectable_weeks={@selectable_weeks}
            selectable_months={@selectable_months}
            selectable_years={@selectable_years}
            live={@live}
          />
        <% end %>
      </div>
    </div>
    """
  end
end
