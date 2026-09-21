defmodule DtuAppWeb.NetworkStatusIndicatorTest do
  @moduledoc """
  Render tests for `DtuAppWeb.NetworkStatusIndicator`.

  Covers:
    * the localized labels on the visible "Online" / "Offline" text
      and the aria-label on the colored dot
    * the detail-panel labels (Status:, Connection:, Updated:) and
      the "Just now" default for the timestamp span
    * the data-attribute hooks the JS hook (`NetworkStatus` in
      `assets/js/app.js`) reads and writes — those stay English
      (`online` / `offline`) because they're CSS-hook keys, not
      user-facing copy

  The component itself doesn't change text when network state flips
  — that's the JS hook's job (and a separate fix). The render-only
  tests pin the **initial** server-rendered labels so they survive
  catalog updates without re-pinning literal strings.

  All tests are async — the component is pure HTML.
  """

  use DtuAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DtuAppWeb.NetworkStatusIndicator

  defp render_it(assigns \\ %{}) do
    defaults = %{
      id: "network-status",
      show_text: true,
      show_detailed: false,
      class: ""
    }

    render_component(
      &NetworkStatusIndicator.network_status_indicator/1,
      Map.merge(defaults, assigns)
    )
  end

  describe "render/1 — visible status text" do
    test "renders the English 'Online' label by default" do
      html =
        Gettext.with_locale(DtuAppWeb.Gettext, "en", fn ->
          render_it()
        end)

      # The text node sits inside
      # `<span class="network-status-text ...">WHITESPACE Online WHITESPACE</span>`.
      # Pin the span open + the label + the span close; the exact
      # whitespace between them is fragile to HEEx formatter changes
      # so we anchor on the surrounding markup instead.
      assert html =~
               ~r|<span class="network-status-text[^"]*">\s*Online\s*</span>|
    end

    test "renders the German 'Online' label for a German catalog" do
      expected =
        Gettext.with_locale(DtuAppWeb.Gettext, "de", fn ->
          Gettext.gettext(DtuAppWeb.Gettext, "Online")
        end)

      html =
        Gettext.with_locale(DtuAppWeb.Gettext, "de", fn ->
          render_it()
        end)

      # German keeps "Online" as a loanword (technical term in DE
      # PV installer jargon); the catalog entry is intentionally
      # identical to EN. The render path is the same either way —
      # the catalog lookup is what we exercise here.
      assert html =~ expected
      assert html =~ ~r|<span class="network-status-text[^"]*"[^>]*>\s*Online\s*</span>|
    end

    test "renders the French 'Online' label for a French catalog" do
      expected =
        Gettext.with_locale(DtuAppWeb.Gettext, "fr", fn ->
          Gettext.gettext(DtuAppWeb.Gettext, "Online")
        end)

      html =
        Gettext.with_locale(DtuAppWeb.Gettext, "fr", fn ->
          render_it()
        end)

      # French translates "Online" → "En ligne". The render path is
      # the same — pin the localized text inside the status span so
      # a future regression to hardcoded "Online" is caught.
      assert html =~
               ~r|<span class="network-status-text[^"]*">\s*#{Regex.escape(expected)}\s*</span>|
    end
  end

  describe "render/1 — aria-label on the indicator dot" do
    test "uses the localized 'Network status indicator' aria-label" do
      html =
        Gettext.with_locale(DtuAppWeb.Gettext, "en", fn ->
          render_it()
        end)

      expected =
        Gettext.with_locale(DtuAppWeb.Gettext, "en", fn ->
          Gettext.gettext(DtuAppWeb.Gettext, "Network status indicator")
        end)

      assert html =~
               ~r|data-network-indicator[^>]*aria-label="#{Regex.escape(expected)}"|
    end

    test "renders the German aria-label when locale is German" do
      expected =
        Gettext.with_locale(DtuAppWeb.Gettext, "de", fn ->
          Gettext.gettext(DtuAppWeb.Gettext, "Network status indicator")
        end)

      assert expected != "Network status indicator",
             "expected a German translation for 'Network status indicator'"

      html =
        Gettext.with_locale(DtuAppWeb.Gettext, "de", fn ->
          render_it()
        end)

      assert html =~ ~r|aria-label="#{Regex.escape(expected)}"|
    end

    test "renders the French aria-label when locale is French" do
      expected =
        Gettext.with_locale(DtuAppWeb.Gettext, "fr", fn ->
          Gettext.gettext(DtuAppWeb.Gettext, "Network status indicator")
        end)

      assert expected != "Network status indicator",
             "expected a French translation for 'Network status indicator'"

      html =
        Gettext.with_locale(DtuAppWeb.Gettext, "fr", fn ->
          render_it()
        end)

      # HEEx HTML-escapes the apostrophe in "d'état" to `&#39;`, so
      # the literal catalog string (with `'`) won't byte-match the
      # rendered output. Match both forms.
      html_escaped = String.replace(expected, "'", "&#39;")

      assert html =~ expected or html =~ html_escaped,
             "expected French aria-label #{inspect(expected)} " <>
               "(or HTML-escaped form #{inspect(html_escaped)}) in: " <>
               html
    end
  end

  describe "render/1 — detail panel labels" do
    test "renders localized Status / Connection / Updated labels when show_detailed is true" do
      html =
        Gettext.with_locale(DtuAppWeb.Gettext, "en", fn ->
          render_it(%{show_detailed: true})
        end)

      for label_msgid <- ["Status", "Connection", "Updated", "Just now"] do
        localized =
          Gettext.with_locale(DtuAppWeb.Gettext, "en", fn ->
            Gettext.gettext(DtuAppWeb.Gettext, label_msgid)
          end)

        assert html =~ localized,
               "detail panel missing label for #{inspect(label_msgid)}; " <>
                 "got #{html}"
      end
    end
  end

  describe "render/1 — JS-hook data attributes stay stable" do
    # The JS hook in `assets/js/app.js` flips `data-network-status`
    # between "online" and "offline" and reads `[data-network-indicator]`
    # to find the dot. These MUST stay English — they are CSS / JS
    # selector hooks, not user-facing copy. If anyone refactors them
    # to gettext calls, this test fails.
    test "data-network-status reads 'online' on initial render" do
      html = render_it()
      assert html =~ ~s(data-network-status="online")
    end

    test "data-network-indicator selector is present on the dot" do
      html = render_it()
      assert html =~ ~s(data-network-indicator)
    end
  end
end
