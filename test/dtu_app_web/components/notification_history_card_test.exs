defmodule DtuAppWeb.NotificationHistoryCardTest do
  @moduledoc """
  Render tests for `DtuAppWeb.NotificationHistoryCard`.

  Pure render-only — no LV, no DB. The component takes the
  current page's `items`, the cross-page `total`, the
  pagination `total_pages` + `page`, the active `event_filter`,
  and the chip-row `filters` (a list of `{value, label}`
  tuples). Each item carries a pre-formatted `delivered_label`
  string (the LV formats it via
  `FormatHelpers.format_relative_time/1` before handing the
  item in — that helper bottoms out in `DtuApp.Time.utc_now/0`
  which is DB-backed, so pushing the call to the LV keeps the
  component sandbox-free).

  Covers:

    - Card chrome: `id="notification-history"` + heading +
      conditional Clear-all button visibility.
    - Chip row: one button per filter, `aria-pressed="true"`
      on the active filter, `data-event-filter` attribute
      carrying the value.
    - Empty state (total == 0): "all" copy vs any-other copy.
    - Notification rows (total > 0): per-row `id` contract,
      title / event chip / body / delete button.
    - Pagination bar: hidden when `total_pages <= 1`,
      Previous disabled on page 1, Next disabled on last page.
  """

  # Pure render — no DB. The LV pre-formats `delivered_label`
  # before passing items in, so the component itself never
  # touches `DtuApp.Time.utc_now/0` (which would require a
  # SQL.Sandbox checkout). `async: true` is safe.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DtuAppWeb.NotificationHistoryCard

  @default_filters [
    {"all", "All"},
    {"dtu_connection", "Connection"},
    {"sun_down", "Sun down"},
    {"sun_up", "Sun up"},
    {"yield_anomaly", "Yield anomaly"},
    {"test", "Test"}
  ]

  defp item(attrs) do
    Map.merge(
      %{
        id: 1,
        event: "dtu_connection",
        title: "Inverter went offline",
        body: "Living Room Inverter disconnected at 14:23.",
        # Pinned to a fixed UTC instant so the row's `title`
        # attribute (rendered via `Calendar.strftime(n.delivered_at, ...)`)
        # is deterministic across runs. Tests that care about the
        # exact title string override this via `Map.put`.
        delivered_at: ~U[2026-09-16 14:30:45Z],
        delivered_label: "5 minutes ago"
      },
      Map.new(attrs)
    )
  end

  defp render_history(assigns) do
    render_component(&NotificationHistoryCard.notification_history_card/1, assigns)
  end

  describe "card chrome" do
    test "renders id=notification-history" do
      html =
        render_history(%{
          items: [],
          total: 0,
          total_pages: 1,
          page: 1,
          event_filter: "all",
          filters: @default_filters
        })

      assert html =~ ~s(id="notification-history")
      assert html =~ "Recent notifications"
    end

    test "Clear-all button is hidden when total == 0" do
      html =
        render_history(%{
          items: [],
          total: 0,
          total_pages: 1,
          page: 1,
          event_filter: "all",
          filters: @default_filters
        })

      refute html =~ "Clear all"
      refute html =~ ~s(phx-click="clear_all_notifications")
    end

    test "Clear-all button is shown when total > 0" do
      html =
        render_history(%{
          items: [item([])],
          total: 1,
          total_pages: 1,
          page: 1,
          event_filter: "all",
          filters: @default_filters
        })

      assert html =~ "Clear all"
      assert html =~ ~s(phx-click="clear_all_notifications")
    end
  end

  describe "chip row" do
    test "renders one button per filter with data-event-filter and label" do
      html =
        render_history(%{
          items: [],
          total: 0,
          total_pages: 1,
          page: 1,
          event_filter: "all",
          filters: @default_filters
        })

      for {value, label} <- @default_filters do
        assert html =~ ~s(data-event-filter="#{value}"),
               "expected chip with data-event-filter=#{value}"

        assert html =~ ~s(>#{label}</button>) or html =~ ~s(phx-value-event="#{value}")
        assert html =~ ~s(phx-value-event="#{value}")
      end
    end

    test "active filter carries aria-pressed=true, others aria-pressed=false" do
      html =
        render_history(%{
          items: [],
          total: 0,
          total_pages: 1,
          page: 1,
          event_filter: "dtu_connection",
          filters: @default_filters
        })

      # The active chip's button opener includes `aria-pressed="true"`.
      active_block =
        case Regex.run(
               ~r/<button[^>]*data-event-filter="dtu_connection"[^>]*>/,
               html
             ) do
          [block] -> block
          _ -> flunk("dtu_connection chip not found in chip row")
        end

      assert active_block =~ ~s(aria-pressed="true")

      # Every other chip carries `aria-pressed="false"`.
      for {value, _label} <- @default_filters, value != "dtu_connection" do
        block =
          case Regex.run(
                 ~r/<button[^>]*data-event-filter="#{value}"[^>]*>/,
                 html
               ) do
            [b] -> b
            _ -> flunk("chip #{value} not found in chip row")
          end

        assert block =~ ~s(aria-pressed="false"),
               "non-active chip #{value} should have aria-pressed=false"
      end
    end
  end

  describe "empty state" do
    test "shows the 'all' copy when event_filter is 'all' and total == 0" do
      html =
        render_history(%{
          items: [],
          total: 0,
          total_pages: 1,
          page: 1,
          event_filter: "all",
          filters: @default_filters
        })

      assert html =~ "No notifications yet"
    end

    test "shows the 'filtered' copy when event_filter is non-'all' and total == 0" do
      html =
        render_history(%{
          items: [],
          total: 0,
          total_pages: 1,
          page: 1,
          event_filter: "sun_down",
          filters: @default_filters
        })

      assert html =~ "No notifications in this filter yet"
      refute html =~ "No notifications yet"
    end
  end

  describe "notification rows" do
    test "each row carries id=notification-row-<id> + title + event chip + delete button" do
      html =
        render_history(%{
          items: [
            item(%{id: 1, title: "First", event: "dtu_connection"}),
            item(%{id: 2, title: "Second", event: "sun_down"})
          ],
          total: 2,
          total_pages: 1,
          page: 1,
          event_filter: "all",
          filters: @default_filters
        })

      assert html =~ ~s(id="notification-row-1")
      assert html =~ ~s(id="notification-row-2")
      assert html =~ "First"
      assert html =~ "Second"
      # Each row also renders its pre-formatted relative-time label.
      assert html =~ "5 minutes ago"
      # Event chips render the event value verbatim (the value sits
      # inside the chip's `<span>` with surrounding whitespace from
      # HEEx indentation, so we regex on a permissive slice).
      assert html =~ ~r/>\s*dtu_connection\s*</
      assert html =~ ~r/>\s*sun_down\s*</
      # Each row carries a delete button.
      assert html =~ ~s(phx-value-id="1")
      assert html =~ ~s(phx-value-id="2")
      assert html =~ ~s(phx-click="delete_notification")
    end

    # The visible `delivered_label` ("5 minutes ago") loses
    # precision past a day and can't disambiguate between two
    # notifications that landed close together. The browser's
    # native `title` tooltip exposes the exact `delivered_at`
    # as UTC ISO so a user hovering the row sees the timestamp
    # they actually need for triage.
    test "each row carries a title attribute with the exact UTC delivered_at" do
      html =
        render_history(%{
          items: [
            item(%{
              id: 1,
              delivered_at: ~U[2026-09-16 14:30:45Z]
            }),
            item(%{
              id: 2,
              delivered_at: ~U[2026-09-15 09:00:00Z]
            })
          ],
          total: 2,
          total_pages: 1,
          page: 1,
          event_filter: "all",
          filters: @default_filters
        })

      # Pin the per-row markup: `<li id="notification-row-N" ...>`
      # followed by a `title="..."` carrying the UTC timestamp.
      # The exact date string mirrors `device_status_card`'s
      # `Calendar.strftime(.., "%Y-%m-%d %H:%M:%S UTC")` format so
      # the user gets one consistent timestamp style across the app.
      assert html =~
               ~r{<li id="notification-row-1"\s+class="[^"]*"[^>]*title="2026-09-16 14:30:45 UTC"}

      assert html =~
               ~r{<li id="notification-row-2"\s+class="[^"]*"[^>]*title="2026-09-15 09:00:00 UTC"}
    end
  end

  describe "pagination bar" do
    test "hidden when total_pages <= 1" do
      html =
        render_history(%{
          items: [item([])],
          total: 1,
          total_pages: 1,
          page: 1,
          event_filter: "all",
          filters: @default_filters
        })

      refute html =~ "Page 1 of 1"
      refute html =~ ~s(phx-value-page="0")
    end

    test "shown when total_pages > 1" do
      html =
        render_history(%{
          items: [item([])],
          total: 25,
          total_pages: 3,
          page: 2,
          event_filter: "all",
          filters: @default_filters
        })

      assert html =~ "Page 2 of 3"
      assert html =~ ~s(phx-value-page="1")
      assert html =~ ~s(phx-value-page="3")
    end

    test "Previous button is disabled on page 1" do
      html =
        render_history(%{
          items: [item([])],
          total: 25,
          total_pages: 3,
          page: 1,
          event_filter: "all",
          filters: @default_filters
        })

      prev_block =
        case Regex.run(
               ~r/<button[^>]*phx-value-page="0"[^>]*>.*?<\/button>/s,
               html
             ) do
          [b] -> b
          _ -> flunk("Previous button (phx-value-page=0) not found")
        end

      assert prev_block =~ ~r/\bdisabled\b/
    end

    test "Next button is disabled on the last page" do
      html =
        render_history(%{
          items: [item([])],
          total: 25,
          total_pages: 3,
          page: 3,
          event_filter: "all",
          filters: @default_filters
        })

      next_block =
        case Regex.run(
               ~r/<button[^>]*phx-value-page="4"[^>]*>.*?<\/button>/s,
               html
             ) do
          [b] -> b
          _ -> flunk("Next button (phx-value-page=4) not found")
        end

      assert next_block =~ ~r/\bdisabled\b/
    end

    test "neither button is disabled on a middle page" do
      html =
        render_history(%{
          items: [item([])],
          total: 25,
          total_pages: 3,
          page: 2,
          event_filter: "all",
          filters: @default_filters
        })

      refute html =~ ~s(phx-value-page="1" disabled)
      refute html =~ ~s(phx-value-page="3" disabled)
    end
  end
end
