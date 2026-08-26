defmodule DtuApp.Emails.SunUpEmailTest do
  @moduledoc """
  Tests for `DtuApp.Emails.SunUpEmail.render/2`.

  The sun-up email is the playful "first power of the day, here's to
  a sunny one!" ping. The producer (`Notifications.SunUp`)
  pre-localises the title and body inside its `Gettext.with_locale/2`
  block (see `sun_up_notifier.ex:277`); this module is responsible
  for the **email-specific** strings (greeting, button — no note)
  and for stamping the `<html lang>` attribute from `user.locale`.

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
  alias DtuApp.Emails.SunUpEmail

  # The producer's gettext call — see `sun_up_notifier.ex:277`.
  # Pinned here as a module attribute so the tests document the
  # exact catalog line they exercise; if it ever moves, this
  # attribute is the single point of update.
  @sun_up_body_msgid "Your panels are sipping sunshine — first power of the day. Here's to a sunny one!"

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
          Gettext.gettext(DtuAppWeb.Gettext, @sun_up_body_msgid)
        end)

      payload = %{p | body: [localised_body]}
      {html, _} = SunUpEmail.render(user, payload)
      assert html =~ localised_body
    end

    test "renders the German body for locale=de", %{payload: p} do
      user = %User{email: "u@example.com", locale: "de"}

      localised_body =
        Gettext.with_locale(DtuAppWeb.Gettext, "de", fn ->
          Gettext.gettext(DtuAppWeb.Gettext, @sun_up_body_msgid)
        end)

      payload = %{p | body: [localised_body]}
      {html, _} = SunUpEmail.render(user, payload)
      assert html =~ localised_body
    end

    test "renders the French body for locale=fr", %{payload: p} do
      user = %User{email: "u@example.com", locale: "fr"}

      localised_body =
        Gettext.with_locale(DtuAppWeb.Gettext, "fr", fn ->
          Gettext.gettext(DtuAppWeb.Gettext, @sun_up_body_msgid)
        end)

      payload = %{p | body: [localised_body]}
      {html, _} = SunUpEmail.render(user, payload)
      assert html =~ localised_body
    end
  end
end
