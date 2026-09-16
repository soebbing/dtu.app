defmodule DtuApp.Emails.LayoutTest do
  @moduledoc """
  Tests for `DtuApp.Emails.Layout.render/1`.

  The layout module is a pure function — no DB, no GenServer, no
  process dictionary — so these tests run fast and asynchronously.
  We only assert on the user-visible contract:

    * `:lang` flows into the `<html lang="...">` attribute verbatim.
    * Default `:lang` is "en" when omitted (so callers that pre-date
      the i18n-coverage change still render sensibly).
    * Unknown languages pass through verbatim — gettext and screen
      readers fall back gracefully, and we don't want to silently
      mutate what the caller asked for.
    * The HTML body escapes user-controlled text (greeting, body,
      button label) so an email field with `<script>` in it can't
      inject markup into the rendered email.
  """

  use ExUnit.Case, async: true

  alias DtuApp.Emails.Layout

  @base_opts [
    title: "Test title",
    greeting: "Hi user@example.com,",
    body: ["First paragraph.", "Second paragraph."],
    button: %{label: "Click me", url: "https://example.com/confirm"},
    note: "If you didn't ask for this, ignore this email."
  ]

  describe "render/1 — :lang option" do
    test "default :lang is \"en\"" do
      {html, _text, _attachments} = Layout.render(@base_opts)
      assert html =~ ~s|<html lang="en">|
    end

    test "explicit :lang=\"de\" lands on the <html> tag" do
      {html, _text, _attachments} = Layout.render(Keyword.put(@base_opts, :lang, "de"))
      assert html =~ ~s|<html lang="de">|
    end

    test "explicit :lang=\"fr\" lands on the <html> tag" do
      {html, _text, _attachments} = Layout.render(Keyword.put(@base_opts, :lang, "fr"))
      assert html =~ ~s|<html lang="fr">|
    end

    test "unknown :lang passes through verbatim (no validation in the layout)" do
      # The layout doesn't know which languages gettext supports —
      # that's the caller's job (UserNotifier checks User.@supported_locales
      # before calling). The layout only forwards the attribute, so a
      # future locale added to the catalog just works.
      {html, _text, _attachments} = Layout.render(Keyword.put(@base_opts, :lang, "klingon"))
      assert html =~ ~s|<html lang="klingon">|
    end

    test ":lang=\"en\" survives when title/body contain user-controlled text" do
      # Sanity check: escaping the greeting/body doesn't accidentally
      # clobber the lang attribute.
      {html, _text, _attachments} =
        Layout.render(
          Keyword.put(@base_opts, :lang, "de")
          |> Keyword.put(:greeting, "Hi <script>alert(1)</script>,")
        )

      assert html =~ ~s|<html lang="de">|
      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    end
  end

  describe "render/1 — content pass-through" do
    test "subject-equivalent title appears in the rendered HTML" do
      {html, _text, _attachments} = Layout.render(@base_opts)
      assert html =~ "Test title"
    end

    test "text body includes the title, greeting, body, and button URL" do
      {_html, text, _attachments} = Layout.render(@base_opts)
      assert text =~ "Test title"
      assert text =~ "Hi user@example.com,"
      assert text =~ "First paragraph."
      assert text =~ "Second paragraph."
      assert text =~ "Click me"
      assert text =~ "https://example.com/confirm"
      assert text =~ "If you didn't ask for this, ignore this email."
    end

    test "body list is rendered as one paragraph per entry" do
      {html, _text, _attachments} = Layout.render(@base_opts)
      # Each body string is wrapped in its own <p>…</p>. Count
      # occurrences of the <p> wrapper the layout uses.
      assert html =~ ~s|<p style="margin:0 0 12px 0;">First paragraph.</p>|
      assert html =~ ~s|<p style="margin:0 0 12px 0;">Second paragraph.</p>|
    end
  end

  describe "render/1 — return shape and text_extra" do
    test "returns a triple {html, text, attachments} where attachments is always a list" do
      assert {_html, _text, attachments} = Layout.render(@base_opts)
      assert is_list(attachments)
      assert attachments == []
    end

    test ":text_extra strings land on the plain-text body (not the HTML)" do
      opts =
        @base_opts
        |> Keyword.put(:body, ["First paragraph.", "Second paragraph."])
        |> Keyword.put(:text_extra, ["Chart is attached.", "Open the dashboard."])

      {html, text, _attachments} = Layout.render(opts)

      # text_extra appears in the text body.
      assert text =~ "Chart is attached."
      assert text =~ "Open the dashboard."
      # but NOT in the HTML body (the whole point of text_extra is to
      # avoid dropping HTML markup into text/plain).
      refute html =~ "Chart is attached."
      refute html =~ "Open the dashboard."
    end

    test "when :text_extra is non-empty, raw <body_html> markup is NOT pulled into the text body" do
      # SunDownEmail passes body_html with an <img src="cid:..."> tag.
      # The old contract dumped body_html into the text body verbatim —
      # which is the exact bug that produced "raw <svg> markup in
      # text/plain" in the user's email. The text_extra keyword fixes
      # that: as soon as the caller asks for explicit text content,
      # body_html is no longer the text source.
      opts =
        @base_opts
        |> Keyword.delete(:body)
        |> Keyword.put(
          :body_html,
          ~s(<img src="cid:chart@sundo" alt="chart" />)
        )
        |> Keyword.put(:text_extra, ["See attached chart."])

      {_html, text, _attachments} = Layout.render(opts)

      refute text =~ "<img"
      refute text =~ "<svg"
      assert text =~ "See attached chart."
    end
  end
end
