defmodule DtuApp.Emails.ConnectionEmailTest do
  @moduledoc """
  Tests for `DtuApp.Emails.ConnectionEmail.render/2`.

  The connection email carries three pieces of data — the
  inverter name, the localised status word, and the timestamp —
  plus a dashboard CTA. The producer (`Notifications.DtuConnection`)
  pre-localises the title and body inside its `Gettext.with_locale/2`
  block (see `dtu_connection_notifier.ex:462`); this module is
  responsible for the **email-specific** strings (greeting, button,
  note) and for stamping the `<html lang>` attribute from
  `user.locale`.

  The drift-guard describe block below anchors on the
  *producer-localised body* (the data path the email carries),
  not on the email module's own button decoration. We build the
  expected body via `Gettext.with_locale/2` +
  `Gettext.gettext/3` against the same catalog line the producer
  uses, so a translation update flows through automatically without
  re-pinning literal strings. If the email's rendering path ever
  drops the payload body or escapes it incorrectly, the per-locale
  assertion catches that.
  """

  use DtuApp.DataCase, async: true

  alias DtuApp.Accounts.User
  alias DtuApp.Emails.ConnectionEmail

  # The producer's gettext call — see `dtu_connection_notifier.ex:462`.
  # Pinned here as a module attribute so the tests document the
  # exact catalog line they exercise; if it ever moves, this
  # attribute is the single point of update.
  @offline_msgid "Your inverter %{name} has gone offline."

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

  describe "render/2 — localised body (producer-data gettext drift guard)" do
    # Anchored on the producer-localised body content (the data
    # path the email carries) rather than on the email module's
    # button decoration. The brief's example was the localised
    # status word; we use the catalog-translated body instead so
    # drift detection exercises the actual payload data, not a UI
    # string the email module owns. The English catalog has no
    # translations, so the en case asserts the source-string path;
    # the de/fr cases assert the catalog-translated paths. If the
    # catalog line ever moves or the email's render path ever
    # drops/escapes the body, these tests fail.
    test "renders the English (source) body verbatim for locale=en", %{user: user, payload: p} do
      localised_body =
        Gettext.with_locale(DtuAppWeb.Gettext, "en", fn ->
          Gettext.gettext(DtuAppWeb.Gettext, @offline_msgid, name: "Shed")
        end)

      payload = %{p | body: [localised_body]}
      {html, _} = ConnectionEmail.render(user, payload)
      assert html =~ localised_body
    end

    test "renders the German body for locale=de", %{payload: p} do
      user = %User{email: "u@example.com", locale: "de"}

      localised_body =
        Gettext.with_locale(DtuAppWeb.Gettext, "de", fn ->
          Gettext.gettext(DtuAppWeb.Gettext, @offline_msgid, name: "Shed")
        end)

      payload = %{p | body: [localised_body]}
      {html, _} = ConnectionEmail.render(user, payload)
      assert html =~ localised_body
    end

    test "renders the French body for locale=fr", %{payload: p} do
      user = %User{email: "u@example.com", locale: "fr"}

      localised_body =
        Gettext.with_locale(DtuAppWeb.Gettext, "fr", fn ->
          Gettext.gettext(DtuAppWeb.Gettext, @offline_msgid, name: "Shed")
        end)

      payload = %{p | body: [localised_body]}
      {html, _} = ConnectionEmail.render(user, payload)
      assert html =~ localised_body
    end
  end
end
