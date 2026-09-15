defmodule DtuAppWeb.SharePanelTest do
  @moduledoc """
  Render tests for `DtuAppWeb.SharePanel`.

  Pure render-only tests, no LiveView, no DB. We construct the
  attribute map by hand because the component only reads four
  top-level keys (`share_loading?`, `share_active?`, `share_url`,
  `locale`) and runs no domain logic; the share-state values come
  straight from the dashboard's `handle_event/3` and
  `handle_info({:share_link_minted, _, _}, _)` calls that the
  dashboard regression suite covers.

  Covers the three-state inner row:

    - Loading: `share_loading? == true` renders the inline
      spinner + "Generating link…" text. The URL row and the
      static hint paragraph are NOT rendered.

    - URL row: `share_active? == true` AND `share_url` is set
      renders the URL `<input>` (with the FQN
      `phx-hook="DtuAppWeb.SharePanel.SelectOnFocus"`), the copy
      button (with the FQN
      `phx-hook="DtuAppWeb.SharePanel.CopyToClipboardWithHint"`),
      and the "Copied!" hint. The spinner and the static hint
      paragraph are NOT rendered. Both hook names resolve to
      their fully-qualified Phoenix LiveView colocated-hook
      module paths under `DtuAppWeb.SharePanel`.

    - Hint: any other combination (the dashboard's normal
      "off" state) renders the static hint paragraph. The
      spinner, URL row, and copy button are NOT rendered.

  Also covers the toggle chrome (label + icon + pill) that
  always renders regardless of which inner-row state is active:
  the `phx-click="toggle_share"` event name, the
  `phx-value-enabled` flip that mirrors `share_active?`, and
  the `disabled` attr that mirrors `share_loading?`.

  Sister to `DtuAppWeb.BarChartPanelTest` and
  `DtuAppWeb.LineChartPanelTest`.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DtuAppWeb.SharePanel

  defp base_share(overrides \\ %{}) do
    Map.merge(
      %{
        share_loading?: false,
        share_active?: false,
        share_url: nil,
        locale: "en"
      },
      overrides
    )
  end

  describe "toggle chrome (renders in every state)" do
    test "renders the wrapper div with the expected id and border separator" do
      html = render_component(&SharePanel.share_panel/1, base_share())

      assert html =~ ~s(id="share-panel")
      assert html =~ "mt-4 border-t border-zinc-200 dark:border-zinc-700 pt-4"
    end

    test "renders the checkbox pill with phx-click toggle_share" do
      html = render_component(&SharePanel.share_panel/1, base_share())

      assert html =~ ~s(id="share-toggle")
      assert html =~ ~s(phx-click="toggle_share")
      # share_active? is false → a click would enable, so
      # phx-value-enabled flips to "true".
      assert html =~ ~s(phx-value-enabled="true")
      # The `checked` attribute is ABSENT (note the leading
      # space — the Tailwind `peer-checked:` variants contain
      # the substring `checked:`, which we don't want to
      # match against).
      refute html =~ " checked"
    end

    test "phx-value-enabled flips to false when share_active? is true" do
      html =
        render_component(&SharePanel.share_panel/1,
          share_loading?: false,
          share_active?: true,
          share_url: "https://example.com/share/abc",
          locale: "en"
        )

      # Active state: clicking would DISABLE sharing.
      assert html =~ ~s(phx-value-enabled="false")
      assert html =~ "checked"
    end

    test "applies cursor-wait and disables the pill while loading" do
      html =
        render_component(&SharePanel.share_panel/1,
          share_loading?: true,
          share_active?: false,
          share_url: nil,
          locale: "en"
        )

      assert html =~ "cursor-wait opacity-70"
      assert html =~ ~s(<input type="checkbox" id="share-toggle")
      assert html =~ "disabled"
    end

    test "stays cursor-pointer when not loading" do
      html =
        render_component(&SharePanel.share_panel/1,
          share_loading?: false,
          share_active?: true,
          share_url: "https://example.com/share/abc",
          locale: "en"
        )

      assert html =~ "cursor-pointer"
    end
  end

  describe "loading inner row (share_loading? == true)" do
    test "renders the inline spinner and Generating link text" do
      html =
        render_component(&SharePanel.share_panel/1,
          share_loading?: true,
          share_active?: false,
          share_url: nil,
          locale: "en"
        )

      # The pure-CSS border-spinner (no icon glyph dependency).
      assert html =~ "id=\"share-loading-row\""
      assert html =~ "border-2 border-emerald-500 border-t-transparent animate-spin"
      assert html =~ "data-testid=\"share-loading\""

      # Spinner's parent carries the localized loading text.
      assert html =~ ~s(>Generating link…<)
    end

    test "does NOT render the URL row when only share_loading? is true" do
      html =
        render_component(&SharePanel.share_panel/1,
          share_loading?: true,
          share_active?: false,
          share_url: nil,
          locale: "en"
        )

      refute html =~ "share-url-row"
      refute html =~ "share-url-input"
      refute html =~ "btn-share-copy"
      refute html =~ "share-copy-hint"
    end

    test "does NOT render the static hint paragraph while loading" do
      html =
        render_component(&SharePanel.share_panel/1,
          share_loading?: true,
          share_active?: false,
          share_url: nil,
          locale: "en"
        )

      refute html =~ "share-hint-text"
    end
  end

  describe "URL row (share_active? == true AND share_url set)" do
    test "renders the URL input pre-filled with share_url" do
      url = "https://example.com/share/abc-def"

      html =
        render_component(&SharePanel.share_panel/1,
          share_loading?: false,
          share_active?: true,
          share_url: url,
          locale: "en"
        )

      assert html =~ "id=\"share-url-row\""
      assert html =~ "id=\"share-url-input\""
      assert html =~ "readonly"
      # value= appears twice — once as the visible input value,
      # once in data-value (consumed by the JS hooks).
      assert html =~ "value=\"#{url}\""
      assert html =~ "data-value=\"#{url}\""
    end

    test "wires the URL input to the fully-qualified SelectOnFocus hook" do
      html =
        render_component(&SharePanel.share_panel/1,
          share_loading?: false,
          share_active?: true,
          share_url: "https://example.com/share/abc",
          locale: "en"
        )

      # Phoenix LiveView expands colocated hook names to their
      # fully qualified module path. The `.SelectOnFocus`
      # shorthand in the template resolves to
      # `phx-hook="DtuAppWeb.SharePanel.SelectOnFocus"`.
      assert html =~ ~s(phx-hook="DtuAppWeb.SharePanel.SelectOnFocus")
    end

    test "renders the copy button wired to the CopyToClipboardWithHint hook" do
      url = "https://example.com/share/abc-def"

      html =
        render_component(&SharePanel.share_panel/1,
          share_loading?: false,
          share_active?: true,
          share_url: url,
          locale: "en"
        )

      assert html =~ "id=\"btn-share-copy\""
      assert html =~ "type=\"button\""
      assert html =~ "data-testid=\"btn-share-copy\""
      # The copy icon used as the button's visible affordance.
      assert html =~ "hero-clipboard-document"
      # data-value lets the hook read the URL off the dataset.
      assert html =~ "data-value=\"#{url}\""

      # Fully qualified colocated hook name (PR #280).
      assert html =~ ~s(phx-hook="DtuAppWeb.SharePanel.CopyToClipboardWithHint")
    end

    test "renders the Copied hint span with opacity-0 starting state and aria-live" do
      html =
        render_component(&SharePanel.share_panel/1,
          share_loading?: false,
          share_active?: true,
          share_url: "https://example.com/share/abc",
          locale: "en"
        )

      assert html =~ "id=\"share-copy-hint\""
      assert html =~ "opacity-0 transition-opacity"
      assert html =~ "aria-live=\"polite\""
      assert html =~ "data-testid=\"share-copy-hint\""
      assert html =~ "Copied!"
    end

    test "does NOT render the spinner or the static hint when the URL row is showing" do
      html =
        render_component(&SharePanel.share_panel/1,
          share_loading?: false,
          share_active?: true,
          share_url: "https://example.com/share/abc",
          locale: "en"
        )

      refute html =~ "share-loading-row"
      refute html =~ "share-hint-text"
    end
  end

  describe "static hint (default off state)" do
    test "renders the hint paragraph when neither loading nor active" do
      html =
        render_component(&SharePanel.share_panel/1,
          share_loading?: false,
          share_active?: false,
          share_url: nil,
          locale: "en"
        )

      assert html =~ "id=\"share-hint-text\""
      assert html =~ ~s(Anyone with this link can view today&#39;s dashboard)
    end

    test "does NOT render the URL row or loading spinner in the off state" do
      html =
        render_component(&SharePanel.share_panel/1,
          share_loading?: false,
          share_active?: false,
          share_url: nil,
          locale: "en"
        )

      refute html =~ "share-url-row"
      refute html =~ "share-loading-row"
      refute html =~ "share-copy-hint"
    end

    test "falls back to the hint even when share_active? is true but share_url is still nil" do
      # Mid-race condition: the user has enabled sharing, the
      # server is still minting the token, and @share_url is
      # not yet set on the assigns. We render the static hint
      # because the inner row's `cond` only matches the URL
      # row when BOTH flags hold.
      html =
        render_component(&SharePanel.share_panel/1,
          share_loading?: false,
          share_active?: true,
          share_url: nil,
          locale: "en"
        )

      assert html =~ "share-hint-text"
      refute html =~ "share-url-row"
    end

    test "falls back to the hint while loading takes precedence over share_active?" do
      # share_active? is true but share_loading? is also true →
      # loading wins (the spinner stays visible until the URL
      # arrives). The conditional evaluates loading first.
      html =
        render_component(&SharePanel.share_panel/1,
          share_loading?: true,
          share_active?: true,
          share_url: "https://example.com/share/abc",
          locale: "en"
        )

      assert html =~ "share-loading-row"
      refute html =~ "share-url-row"
      refute html =~ "share-hint-text"
    end
  end

  describe "container attributes" do
    test "the inner row has aria-live=polite and the min-height the layout relies on" do
      html = render_component(&SharePanel.share_panel/1, base_share())

      assert html =~ "id=\"share-row\""
      assert html =~ "aria-live=\"polite\""
      # min-h-[2.25rem] prevents the layout from jumping when
      # the inner row swaps from spinner → URL row.
      assert html =~ "min-h-[2.25rem]"
    end
  end
end
