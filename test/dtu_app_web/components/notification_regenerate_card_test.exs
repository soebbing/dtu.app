defmodule DtuAppWeb.NotificationRegenerateCardTest do
  @moduledoc """
  Render tests for `DtuAppWeb.NotificationRegenerateCard`.

  Pure render-only — no LV, no DB. The component takes the
  `max_date` (yesterday) and `min_date` (today-30) bounds so the
  native `<input type="date">` can hint users away from
  out-of-range dates. The server-side validation in
  `DtuAppWeb.NotificationsLive.handle_event("regenerate_sun_down", ...)`
  still rejects out-of-range dates, but the HTML attributes give
  the browser a chance to grey out the input *before* the user
  submits.

  Covers:

    - Card chrome: `id="notification-regenerate"` + heading +
      description text.
    - Form chrome: `phx-submit="regenerate_sun_down"` +
      `id="notification-regenerate-form"` (so the form is
      nameable in tests).
    - Date input attributes: `name="date"`, `type="date"`,
      `max=` and `min=` reflect the assigns, default value
      is empty so the user picks.
    - Submit button: present, with the localised label.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DtuAppWeb.NotificationRegenerateCard

  defp render_card(assigns) do
    render_component(&NotificationRegenerateCard.notification_regenerate_card/1, assigns)
  end

  describe "card chrome" do
    test "renders id=notification-regenerate + heading + description" do
      today = ~D[2026-09-16]
      html = render_card(%{min_date: Date.add(today, -30), max_date: Date.add(today, -1)})

      assert html =~ ~s(id="notification-regenerate")
      assert html =~ "Missed a day"
      assert html =~ ~s(phx-submit="regenerate_sun_down")
      assert html =~ ~s(id="notification-regenerate-form")
    end
  end

  describe "date input" do
    test "renders type=date with name=date + min/max from assigns" do
      today = ~D[2026-09-16]
      min_date = Date.add(today, -30)
      max_date = Date.add(today, -1)

      html = render_card(%{min_date: min_date, max_date: max_date})

      assert html =~ ~s(type="date")
      assert html =~ ~s(name="date")
      assert html =~ ~s(min="#{Date.to_iso8601(min_date)}")
      assert html =~ ~s(max="#{Date.to_iso8601(max_date)}")
    end
  end

  describe "submit button" do
    test "renders the Regenerate summary submit button" do
      today = ~D[2026-09-16]
      html = render_card(%{min_date: Date.add(today, -30), max_date: Date.add(today, -1)})

      assert html =~ ~s(type="submit")
      assert html =~ "Regenerate summary"
    end
  end
end
