defmodule DtuAppWeb.NotificationPreferencesFormTest do
  @moduledoc """
  Render tests for `DtuAppWeb.NotificationPreferencesForm`.

  Pure render-only — no LV, no DB. Builds a
  `DtuApp.Accounts.User{}` struct in-memory, runs the
  `notification_settings_changeset/2` cast over the test attrs
  (no DB write), then wraps the changeset in a Phoenix
  `to_form/2` so we can hand the form to the component.

  Covers:

    - Form chrome: `<form id="notifications-form">` + `phx-submit="save"`.
    - Each of the four event toggles renders its label copy +
      description copy.
    - The "Deliver via" radio group renders three radios with
      values `push` / `email` / `both`; the one matching
      `form[:notification_channel].value` carries `checked="checked"`.
    - The email-not-confirmed warning is shown only when channel
      is `email` or `both` AND `confirmed?` is `false`.
    - The Save button has `phx-disable-with="Saving…"`.
  """

  # Pure render — the changeset cast doesn't need a DB connection
  # and `to_form/2` is purely in-memory. ExUnit.Case is enough.
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias DtuApp.Accounts.User
  alias DtuAppWeb.NotificationPreferencesForm

  # Build a changeset wrapped in a Phoenix.HTML.Form so we can
  # render the component without spinning up a LV socket. The
  # changeset cast doesn't write to the DB; `to_form/2` is purely
  # a struct transformation.
  defp build_form(attrs) do
    %User{}
    |> User.notification_settings_changeset(attrs)
    |> to_form(as: :user)
  end

  defp render_form(attrs, confirmed?) do
    render_component(
      &NotificationPreferencesForm.notification_preferences_form/1,
      %{form: build_form(attrs), confirmed?: confirmed?}
    )
  end

  describe "form chrome" do
    test "renders id=notifications-form + phx-submit=save" do
      html = render_form(%{}, true)

      assert html =~ ~s(id="notifications-form")
      assert html =~ ~s(phx-submit="save")
    end
  end

  describe "four event toggles" do
    test "renders the inverter-connection toggle" do
      html = render_form(%{}, true)

      assert html =~ "Inverter connection state"
      assert html =~ "A notification whenever an inverter goes offline"
    end

    test "renders the sun-down summary toggle" do
      html = render_form(%{}, true)

      assert html =~ "End-of-day summary"
      assert html =~ "When the sun goes down"
    end

    test "renders the sun-up ping toggle" do
      html = render_form(%{}, true)

      assert html =~ "Morning sun-up ping"
      assert html =~ "when your panels start producing"
    end

    test "renders the yield-anomaly toggle" do
      html = render_form(%{}, true)

      assert html =~ "Mid-day yield collapse"
      assert html =~ "stops producing for over 1 hour"
    end

    test "renders all four event-toggle form field names" do
      html = render_form(%{}, true)

      # The `<.input field={...}>` helper writes the field name
      # into `name="user[notify_dtu_connection]"` (etc.) — exercise
      # all four so a future refactor that renames the cast list
      # in `notification_settings_changeset/2` is caught here.
      for field <- [
            "notify_dtu_connection",
            "notify_sun_down",
            "notify_sun_up",
            "notify_yield_anomaly"
          ] do
        assert html =~ ~s(name="user[#{field}]"),
               "expected form field user[#{field}] to be rendered"
      end
    end
  end

  describe "channel radio group" do
    test "renders three radios with values push, email, both" do
      html = render_form(%{"notification_channel" => "push"}, true)

      assert html =~ ~s(value="push")
      assert html =~ ~s(value="email")
      assert html =~ ~s(value="both")
      assert html =~ "Notification"
      assert html =~ "Email"
      assert html =~ "Both"
    end

    test "the radio matching form[:notification_channel].value carries checked=checked" do
      html = render_form(%{"notification_channel" => "email"}, true)

      # `checked` attribute on the radio element should be present
      # exactly once, on the value="email" input.
      assert html =~ ~s(value="email" checked)
      refute html =~ ~s(value="push" checked)
      refute html =~ ~s(value="both" checked)
    end

    test "channel=push leaves email + both unchecked" do
      html = render_form(%{"notification_channel" => "push"}, true)

      assert html =~ ~s(value="push" checked)
      refute html =~ ~s(value="email" checked)
      refute html =~ ~s(value="both" checked)
    end
  end

  describe "email-not-confirmed warning" do
    test "shown when channel=email AND confirmed?=false" do
      html = render_form(%{"notification_channel" => "email"}, false)

      # `'` is HTML-escaped to `&#39;` in the rendered output, so
      # match on the rendered form rather than the raw gettext string.
      assert html =~ "your email address isn&#39;t confirmed"
    end

    test "shown when channel=both AND confirmed?=false" do
      html = render_form(%{"notification_channel" => "both"}, false)

      assert html =~ "your email address isn&#39;t confirmed"
    end

    test "hidden when channel=push AND confirmed?=false (push is independent of email)" do
      html = render_form(%{"notification_channel" => "push"}, false)

      refute html =~ "your email address isn&#39;t confirmed"
    end

    test "hidden when channel=email AND confirmed?=true" do
      html = render_form(%{"notification_channel" => "email"}, true)

      refute html =~ "your email address isn&#39;t confirmed"
    end

    test "hidden when channel=both AND confirmed?=true" do
      html = render_form(%{"notification_channel" => "both"}, true)

      refute html =~ "your email address isn&#39;t confirmed"
    end
  end

  describe "Save button" do
    test "renders the Save preferences button with phx-disable-with" do
      html = render_form(%{}, true)

      assert html =~ "Save preferences"
      assert html =~ ~s(phx-disable-with="Saving…")
    end
  end
end
