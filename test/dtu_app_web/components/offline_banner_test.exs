defmodule DtuAppWeb.OfflineBannerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DtuAppWeb.OfflineBanner

  describe "offline_banner/1" do
    test "renders a banner with the offline hook and hidden by default" do
      html = render_component(&OfflineBanner.offline_banner/1, %{})

      assert html =~ ~s(id="offline-banner")
      assert html =~ ~s(phx-hook="OfflineBanner")
      assert html =~ ~s(data-offline="false")
    end

    test "advertises the offline message in the dom for screen readers" do
      html = render_component(&OfflineBanner.offline_banner/1, %{})

      assert html =~ ~s(role="status")
      assert html =~ ~s(aria-live="polite")
      # gettext HTML-escapes the apostrophe; assert on a substring that
      # doesn't contain one so the test isn't encoding-sensitive.
      assert html =~ "offline. Showing the latest data we have."
    end

    test "respects a custom id" do
      html = render_component(&OfflineBanner.offline_banner/1, %{id: "my-offline"})

      assert html =~ ~s(id="my-offline")
      refute html =~ ~s(id="offline-banner")
    end
  end
end
