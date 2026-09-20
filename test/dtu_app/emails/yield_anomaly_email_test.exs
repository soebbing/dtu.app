defmodule DtuApp.Emails.YieldAnomalyEmailTest do
  @moduledoc """
  Tests for `DtuApp.Emails.YieldAnomalyEmail.render/2`.

  The producer (`Notifications.YieldAnomaly`) pre-localises
  the title and body inside its `Gettext.with_locale/2` block
  (see `yield_anomaly_notifier.ex:469`); this module is
  responsible for the **email-specific** strings (greeting,
  button, note) and for stamping the `<html lang>` attribute
  from `user.locale`.

  The drift-guard describe block below anchors on the
  *producer-localised body* (the data path the email carries),
  not on the email module's own button decoration. We build
  the expected body via `Gettext.with_locale/2` +
  `Gettext.gettext/3` against the same catalog line the
  producer uses, so a translation update flows through
  automatically without re-pinning literal strings.

  Post-PR-#325 the body carries the diagnostic paragraph
  inline (the collapse window + threshold). The "diagnostic
  paragraphs" describe block guards that the email renders
  that diagnostic data — a future refactor of
  `YieldAnomalyEmail.render/2` that drops the body list down
  to a single string fails the suite.
  """

  use DtuApp.DataCase, async: true

  alias DtuApp.Accounts.User
  alias DtuApp.Emails.YieldAnomalyEmail
  alias DtuApp.Notifications.YieldAnomaly.Payload, as: YieldAnomalyPayload

  # The producer's gettext body — see
  # `DtuApp.Notifications.YieldAnomaly.Payload.body/2`. Pinned
  # here as a module attribute so the tests document the exact
  # catalog line they exercise; if it ever moves, this
  # attribute is the single point of update.
  @body_msgid "Your panels stopped producing for %{duration} while the sun was up — the fleet sum stayed below %{threshold} even though no inverter reported an outage. Worth a look at the array."

  setup do
    user = %User{email: "u@example.com", locale: "en"}

    payload = %{
      title: "⚠️ Production has stalled",
      body: [
        "Your panels stopped producing for 1 hour while the sun was up — the fleet sum stayed below 15 W even though no inverter reported an outage. Worth a look at the array."
      ],
      event: "yield_anomaly",
      tag: "yield_anomaly:2026-09-20",
      since: ~U[2026-09-20 14:23:00Z]
    }

    {:ok, user: user, payload: payload}
  end

  describe "render/2 — basic contract" do
    test "returns {html, text, attachments} where html starts with <html", %{
      user: user,
      payload: p
    } do
      {html, text, attachments} = YieldAnomalyEmail.render(user, p)
      assert is_binary(html)
      assert html =~ "<html"
      assert is_binary(text)
      assert is_list(attachments)
      assert attachments == []
    end

    test "html includes the title from the payload", %{user: user, payload: p} do
      {html, _, _} = YieldAnomalyEmail.render(user, p)
      assert html =~ "Production has stalled"
    end

    test "html includes the body verbatim", %{user: user, payload: p} do
      {html, _, _} = YieldAnomalyEmail.render(user, p)

      assert html =~
               "Your panels stopped producing for 1 hour while the sun was up"
    end

    test "html includes the dashboard URL in the CTA", %{user: user, payload: p} do
      {html, _, _} = YieldAnomalyEmail.render(user, p)
      assert html =~ "/dashboard"
    end

    test "text body includes the title and the body", %{user: user, payload: p} do
      {_html, text, _} = YieldAnomalyEmail.render(user, p)
      assert text =~ "Production has stalled"
      assert text =~ "panels stopped producing"
    end
  end

  describe "render/2 — <html lang> attribute" do
    test "matches the user's locale", %{user: user, payload: p} do
      {html, _, _} = YieldAnomalyEmail.render(%{user | locale: "fr"}, p)
      assert html =~ ~s(<html lang="fr")
    end

    test "renders de with lang=de", %{payload: p} do
      user = %User{email: "u@example.com", locale: "de"}
      {html, _, _} = YieldAnomalyEmail.render(user, p)
      assert html =~ ~s(<html lang="de")
    end

    test "falls back to lang=en when user.locale is nil", %{payload: p} do
      user = %User{email: "u@example.com", locale: nil}
      {html, _, _} = YieldAnomalyEmail.render(user, p)
      assert html =~ ~s(<html lang="en")
    end
  end

  describe "render/2 — diagnostic body (post-PR-#325 collapse)" do
    # The producer builds the body inline (single paragraph) with
    # `%{duration}` + `%{threshold}` interpolation. The diagnostic
    # data must reach the email body — coalescing the list, dropping
    # interpolation args, or rendering the catalog line verbatim
    # instead of with the substituted values all fail here.

    # End-to-end: build the payload the way the producer does
    # (via `YieldAnomaly.Payload.build/4`), then hand it to
    # `YieldAnomalyEmail.render/2`. A change to the payload shape
    # that breaks the email contract is caught here — without
    # this test, the diagnostic data could silently drop between
    # producer and email and the per-locale assertions below
    # would still pass (they construct the body by hand).

    test "renders the diagnostic body built by YieldAnomaly.Payload.build/4",
         %{user: user} do
      now = ~U[2026-09-20 14:23:00.000000Z]
      tag_date = ~D[2026-09-20]

      payload = YieldAnomalyPayload.build(now, 60, 15.0, tag_date)

      {html, text, _} = YieldAnomalyEmail.render(user, payload)

      # Producer built a 1-paragraph body carrying the
      # collapse window + threshold — both must reach the email.
      assert is_list(payload.body)
      assert length(payload.body) == 1
      assert html =~ "Your panels stopped producing for"
      assert html =~ "1 hour"
      assert html =~ "15 W"
      assert html =~ "fleet sum stayed below"
      assert text =~ "1 hour"
      assert text =~ "15 W"
    end

    test "renders a multi-hour collapse duration in the diagnostic body",
         %{user: user} do
      now = ~U[2026-09-20 17:23:00.000000Z]
      tag_date = ~D[2026-09-20]

      # 90-minute collapse should render as "1 hour 30 minutes"
      # via the format_minutes helper in the Payload module.
      payload = YieldAnomalyPayload.build(now, 90, 15.0, tag_date)

      {html, _, _} = YieldAnomalyEmail.render(user, payload)

      assert html =~ "1 hours 30 minutes" or html =~ "1 hour 30 minutes"
    end

    setup %{payload: p} do
      localised_body =
        Gettext.with_locale(DtuAppWeb.Gettext, "en", fn ->
          Gettext.gettext(DtuAppWeb.Gettext, @body_msgid,
            duration: "1 hour",
            threshold: "15 W"
          )
        end)

      payload_with_localised_body = %{p | body: [localised_body]}

      {:ok,
       localised_body: localised_body, payload_with_localised_body: payload_with_localised_body}
    end

    test "renders the diagnostic duration in the html body",
         %{user: user, localised_body: body, payload_with_localised_body: payload} do
      {html, _, _} = YieldAnomalyEmail.render(user, payload)

      # The full localised body — interpolation and all — must
      # reach the rendered HTML. A refactor that drops
      # `payload.body` to a string instead of rendering the list,
      # or one that escapes the `%{...}` markers, fails here.
      assert html =~ body
      assert html =~ "1 hour"
      assert html =~ "15 W"
    end

    test "renders the diagnostic duration in the plain-text mirror",
         %{user: user, localised_body: body, payload_with_localised_body: payload} do
      {_html, text, _} = YieldAnomalyEmail.render(user, payload)

      assert text =~ body
      assert text =~ "1 hour"
      assert text =~ "15 W"
    end
  end

  describe "render/2 — localised body (producer-data gettext drift guard)" do
    test "renders the English (source) body verbatim for locale=en", %{user: user, payload: p} do
      localised_body =
        Gettext.with_locale(DtuAppWeb.Gettext, "en", fn ->
          Gettext.gettext(DtuAppWeb.Gettext, @body_msgid,
            duration: "1 hour",
            threshold: "15 W"
          )
        end)

      payload = %{p | body: [localised_body]}
      {html, _, _} = YieldAnomalyEmail.render(user, payload)
      assert html =~ localised_body
    end

    test "renders the German body for locale=de", %{payload: p} do
      user = %User{email: "u@example.com", locale: "de"}

      localised_body =
        Gettext.with_locale(DtuAppWeb.Gettext, "de", fn ->
          Gettext.gettext(DtuAppWeb.Gettext, @body_msgid,
            duration: "1 Stunde",
            threshold: "15 W"
          )
        end)

      payload = %{p | body: [localised_body]}
      {html, _, _} = YieldAnomalyEmail.render(user, payload)
      assert html =~ localised_body
    end

    test "renders the French body for locale=fr", %{payload: p} do
      user = %User{email: "u@example.com", locale: "fr"}

      localised_body =
        Gettext.with_locale(DtuAppWeb.Gettext, "fr", fn ->
          Gettext.gettext(DtuAppWeb.Gettext, @body_msgid,
            duration: "1 heure",
            threshold: "15 W"
          )
        end)

      payload = %{p | body: [localised_body]}
      {html, _, _} = YieldAnomalyEmail.render(user, payload)
      assert html =~ localised_body
    end
  end
end
