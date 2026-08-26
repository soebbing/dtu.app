defmodule DtuApp.Emails.ConnectionEmailTest do
  @moduledoc """
  Tests for `DtuApp.Emails.ConnectionEmail.render/2`.

  The connection email carries three pieces of data — the
  inverter name, the localised status word, and the timestamp —
  plus a dashboard CTA. The producer (`Notifications.DtuConnection`)
  pre-localises the title and body inside its `Gettext.with_locale/2`
  block; this module is responsible for the **email-specific**
  strings (greeting, button, note) and for stamping the `<html lang>`
  attribute from `user.locale`.

  The button label `"Go to Dashboard"` is a pre-existing translated
  msgid (see `priv/gettext/{de,fr}/LC_MESSAGES/default.po`) — the
  per-locale assertions below catch gettext drift: if the email
  module ever regresses to a different backend (or to a hard-coded
  English literal), the de/fr assertions diverge.
  """

  use DtuApp.DataCase, async: true

  alias DtuApp.Accounts.User
  alias DtuApp.Emails.ConnectionEmail

  setup do
    user = %User{email: "u@example.com", locale: "en"}
    payload = %{
      title: "Shed went offline",
      body: ["Inverter Shed stopped reporting at 14:23 UTC."],
      event: "dtu_connection",
      dtu_name: "Shed",
      status: "offline",
      since: ~U[2026-08-27 14:23:00Z]
    }
    {:ok, user: user, payload: payload}
  end

  describe "render/2 — basic contract" do
    test "returns {html, text} where html starts with <html and text contains the inverter name",
         %{user: user, payload: p} do
      {html, text} = ConnectionEmail.render(user, p)
      assert is_binary(html)
      assert html =~ "<html"
      assert is_binary(text)
      assert text =~ "Shed"
    end

    test "html includes the inverter name from the payload body", %{user: user, payload: p} do
      {html, _} = ConnectionEmail.render(user, p)
      assert html =~ "Shed"
    end

    test "html includes the title from the payload", %{user: user, payload: p} do
      {html, _} = ConnectionEmail.render(user, p)
      assert html =~ "Shed went offline"
    end

    test "html includes the dashboard URL in the CTA", %{user: user, payload: p} do
      {html, _} = ConnectionEmail.render(user, p)
      assert html =~ "/dashboard"
    end

    test "text body includes the inverter name", %{user: user, payload: p} do
      {_html, text} = ConnectionEmail.render(user, p)
      assert text =~ "Shed"
      assert text =~ "Shed went offline"
    end
  end

  describe "render/2 — <html lang> attribute" do
    test "matches the user's locale", %{user: user, payload: p} do
      {html, _} = ConnectionEmail.render(%{user | locale: "fr"}, p)
      assert html =~ ~s(<html lang="fr")
    end

    test "renders de with lang=de", %{payload: p} do
      user = %User{email: "u@example.com", locale: "de"}
      {html, _} = ConnectionEmail.render(user, p)
      assert html =~ ~s(<html lang="de")
    end

    test "falls back to lang=en when user.locale is nil", %{payload: p} do
      user = %User{email: "u@example.com", locale: nil}
      {html, _} = ConnectionEmail.render(user, p)
      assert html =~ ~s(<html lang="en")
    end
  end

  describe "render/2 — localised button label (gettext drift guard)" do
    test "renders the English button label for locale=en", %{user: user, payload: p} do
      {html, _} = ConnectionEmail.render(user, p)
      assert html =~ "Go to Dashboard"
    end

    test "renders the German button label for locale=de", %{payload: p} do
      user = %User{email: "u@example.com", locale: "de"}
      {html, _} = ConnectionEmail.render(user, p)
      assert html =~ "Zum Dashboard"
    end

    test "renders the French button label for locale=fr", %{payload: p} do
      user = %User{email: "u@example.com", locale: "fr"}
      {html, _} = ConnectionEmail.render(user, p)
      assert html =~ "Aller au tableau de bord"
    end
  end
end