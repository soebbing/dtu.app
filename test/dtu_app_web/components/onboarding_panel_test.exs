defmodule DtuAppWeb.OnboardingPanelTest do
  @moduledoc """
  Render tests for `DtuAppWeb.OnboardingPanel`.

  Pure render-only tests, no LiveView, no DB. The component
  only takes `@locale` and runs no domain logic — both the
  welcome card and the "How it works" rail render their full
  content every time the component is invoked (the
  `if @devices == []` guard that gates the call lives in the
  dashboard's outer template).

  Covers the two always-rendered siblings:

    - Welcome card (`id="onboarding-empty"`): the centered
      bolt icon badge, the welcome heading, the MQTT-explainer
      paragraph, and the `Add your first DTU` CTA linking to
      `/devices/new`. The CTA is the only interactive
      element; the rest is prose + iconography.

    - "How it works" rail (`id="onboarding-how-it-works"`):
      the heading, the sub-paragraph, and the three numbered
      `<li>`s (`Register` / `Connect` / `See live data`).
      Each step gets the numbered emerald badge + a title +
      a one-line description.

  Sister to `DtuAppWeb.SharePanelTest` and
  `DtuAppWeb.LineChartPanelTest`.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DtuAppWeb.OnboardingPanel

  describe "welcome card" do
    test "renders the welcome card with the bolt icon badge" do
      html = render_component(&OnboardingPanel.onboarding_panel/1, %{locale: "en"})

      assert html =~ ~s(id="onboarding-empty")
      assert html =~ "rounded-2xl border border-zinc-200"
      assert html =~ "text-center"
      assert html =~ "hero-bolt"
      # Emerald icon-badge tint matches the rest of the chrome.
      assert html =~ "bg-emerald-50 dark:bg-emerald-950/30"
    end

    test "renders the welcome heading and the MQTT-explainer paragraph" do
      html = render_component(&OnboardingPanel.onboarding_panel/1, %{locale: "en"})

      # Phoenix HTML-escapes the apostrophe in text content as
      # `&#39;` (same encoding as the share panel toggle label).
      assert html =~ "Welcome! Let&#39;s connect your first DTU"
      assert html =~ "Data Transfer Unit"
      assert html =~ "OpenDTU and AhoyDTU firmware"
    end

    test "renders the Add-your-first-DTU CTA pointing at /devices/new" do
      html = render_component(&OnboardingPanel.onboarding_panel/1, %{locale: "en"})

      assert html =~ ~s(id="btn-add-first-dtu")
      assert html =~ "Add your first DTU"
      # `navigate={~p"/devices/new"}` resolves to the generated
      # /devices/new path via `DtuAppWeb.Router.Helpers.page_path/2`.
      assert html =~ ~s(href="/devices/new")
      # The emerald primary CTA tint.
      assert html =~ "bg-emerald-500 hover:bg-emerald-400"
      # The plus-mini icon glyph that sits inside the CTA.
      assert html =~ "hero-plus-mini"
    end
  end

  describe "How it works rail" do
    test "renders the rail container with the expected id and responsive padding" do
      html = render_component(&OnboardingPanel.onboarding_panel/1, %{locale: "en"})

      assert html =~ ~s(id="onboarding-how-it-works")
      assert html =~ "rounded-2xl border border-zinc-200"
      assert html =~ "p-6 md:p-8"
    end

    test "renders the rail heading and sub-paragraph" do
      html = render_component(&OnboardingPanel.onboarding_panel/1, %{locale: "en"})

      assert html =~ "How it works"
      assert html =~ "Three steps from sign-up to a live chart"
    end

    test "renders the three numbered steps in a single <ol> with three <li>s" do
      html = render_component(&OnboardingPanel.onboarding_panel/1, %{locale: "en"})

      # The ordered list lays out as one column on mobile and
      # three columns on md:.
      assert html =~ "<ol"
      assert html =~ "grid grid-cols-1"
      assert html =~ "md:grid-cols-3"
      # Three <li> entries — assert via the three emerald
      # badge spans (they share the same Tailwind class
      # cluster, so count those).
      badge_count =
        html
        |> String.split(
          "shrink-0 inline-flex items-center justify-center size-7 rounded-full bg-emerald-50"
        )
        |> length()
        |> Kernel.-(1)

      assert badge_count == 3
      # The badges carry `aria-hidden="true"` — proves the
      # number is decorative (the step title below carries
      # the actual readable label).
      assert html =~ ~s(aria-hidden="true">\n        1\n      </span>)
    end

    test "renders the step titles for Register, Connect, See live data" do
      html = render_component(&OnboardingPanel.onboarding_panel/1, %{locale: "en"})

      assert html =~ "Register"
      assert html =~ "Connect"
      assert html =~ "See live data"
    end

    test "renders the one-line step descriptions" do
      html = render_component(&OnboardingPanel.onboarding_panel/1, %{locale: "en"})

      assert html =~ "Add your DTU on the Devices page."
      assert html =~ "Point your DTU at our broker with the credentials we show you."
      assert html =~ "Watch watts appear on this chart as soon as the sun is up."
    end

    test "the middle step gets the divider-only border between siblings" do
      # On md: the middle step (`Connect`) gets `md:px-6` and
      # `md:border-x` so the three-up rail reads as a sequence
      # instead of three isolated columns. The first and last
      # steps intentionally omit `border-x`.
      html = render_component(&OnboardingPanel.onboarding_panel/1, %{locale: "en"})

      assert html =~ "md:px-6 md:border-x md:border-zinc-200 md:dark:border-zinc-800"
    end
  end

  describe "structure" do
    test "always renders BOTH the welcome card and the rail (no empty branches)" do
      # The component has no `@devices == []` guard internally —
      # that lives in the dashboard's outer template. Both
      # siblings render every time the component is invoked.
      html = render_component(&OnboardingPanel.onboarding_panel/1, %{locale: "en"})

      assert html =~ ~s(id="onboarding-empty")
      assert html =~ ~s(id="onboarding-how-it-works")
    end

    test "renders the default `en` locale when no locale attr is passed" do
      # `attr :locale, :string, default: "en"` means callers
      # can omit it entirely; we still get the same English
      # strings.
      html = render_component(&OnboardingPanel.onboarding_panel/1, %{})

      assert html =~ "How it works"
      assert html =~ "Register"
    end

    test "does NOT render any device-status, share-panel, or chart elements" do
      # The onboarding panel is the only thing rendered on
      # the no-devices dashboard path. It must not bleed into
      # the `else` branch (devices, charts, share, stat rows).
      html = render_component(&OnboardingPanel.onboarding_panel/1, %{locale: "en"})

      refute html =~ "id=\"share-panel\""
      refute html =~ "id=\"solar-chart-svg\""
      refute html =~ "id=\"device-status-grid\""
      refute html =~ "stat_card_row"
      refute html =~ "quick_range_switcher"
    end
  end
end
