defmodule DtuApp.Emails.SunUpEmailTest do
  @moduledoc """
  Tests for `DtuApp.Emails.SunUpEmail.render/2`.

  The sun-up email is the playful "first power of the day, here's to
  a sunny one!" ping. The producer (`Notifications.SunUp`)
  pre-localises the title and body inside its `Gettext.with_locale/2`
  block; this module is responsible for the **email-specific** strings
  (greeting, button — no note) and for stamping the `<html lang>`
  attribute from `user.locale`.

  The button label `"Go to Dashboard"` is a pre-existing translated
  msgid (see `priv/gettext/{de,fr}/LC_MESSAGES/default.po`) — the
  per-locale assertions below catch gettext drift: if the email
  module ever regresses to a different backend (or to a hard-coded
  English literal), the de/fr assertions diverge.
  """

  use DtuApp.DataCase, async: true

  alias DtuApp.Accounts.User
  alias DtuApp.Emails.SunUpEmail

  setup do
    user = %User{email: "u@example.com", locale: "en"}
    payload = %{
      title: "Sun is up — first power of the day",
      body: ["Your array just woke up at 06:14 local time. Here's to a sunny one."],
      event: "sun_up"
    }
    {:ok, user: user, payload: payload}
  end

  describe "render/2 — basic contract" do
    test "returns {html, text}", %{user: user, payload: p} do
      {html, text} = SunUpEmail.render(user, p)
      assert is_binary(html)
      assert is_binary(text)
    end

    test "html includes the title verbatim from the payload", %{user: user, payload: p} do
      {html, _} = SunUpEmail.render(user, p)
      assert html =~ "Sun is up — first power of the day"
    end

    test "html includes the body paragraphs verbatim", %{user: user, payload: p} do
      {html, _} = SunUpEmail.render(user, p)
      assert html =~ "Your array just woke up at 06:14 local time."
    end

    test "html includes the dashboard URL in the CTA", %{user: user, payload: p} do
      {html, _} = SunUpEmail.render(user, p)
      assert html =~ "/dashboard"
    end

    test "text body includes the title and body", %{user: user, payload: p} do
      {_html, text} = SunUpEmail.render(user, p)
      assert text =~ "Sun is up — first power of the day"
      assert text =~ "Your array just woke up at 06:14 local time."
    end
  end

  describe "render/2 — <html lang> attribute" do
    test "matches the user's locale", %{user: user, payload: p} do
      {html, _} = SunUpEmail.render(%{user | locale: "de"}, p)
      assert html =~ ~s(<html lang="de")
    end

    test "renders fr with lang=fr", %{payload: p} do
      user = %User{email: "u@example.com", locale: "fr"}
      {html, _} = SunUpEmail.render(user, p)
      assert html =~ ~s(<html lang="fr")
    end

    test "falls back to lang=en when user.locale is nil", %{payload: p} do
      user = %User{email: "u@example.com", locale: nil}
      {html, _} = SunUpEmail.render(user, p)
      assert html =~ ~s(<html lang="en")
    end
  end

  describe "render/2 — localised button label (gettext drift guard)" do
    test "renders the English button label for locale=en", %{user: user, payload: p} do
      {html, _} = SunUpEmail.render(user, p)
      assert html =~ "Go to Dashboard"
    end

    test "renders the German button label for locale=de", %{payload: p} do
      user = %User{email: "u@example.com", locale: "de"}
      {html, _} = SunUpEmail.render(user, p)
      assert html =~ "Zum Dashboard"
    end

    test "renders the French button label for locale=fr", %{payload: p} do
      user = %User{email: "u@example.com", locale: "fr"}
      {html, _} = SunUpEmail.render(user, p)
      assert html =~ "Aller au tableau de bord"
    end
  end
end