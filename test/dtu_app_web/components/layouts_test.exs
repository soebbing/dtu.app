defmodule DtuAppWeb.LayoutsTest do
  @moduledoc """
  Pins the footer-version-to-GitHub-URL mapping so a future refactor
  of the release-tag format (or the repo URL) doesn't silently 404
  the link in the site footer.
  """

  use ExUnit.Case, async: true

  alias DtuAppWeb.Layouts

  describe "release_href/1 — Calver release tag" do
    test "current production tag points at its release page" do
      assert Layouts.release_href("2026-08-28-9") ==
               "https://github.com/soebbing/dtu.app/releases/tag/2026-08-28-9"
    end

    test "earlier tags use the same shape" do
      assert Layouts.release_href("2026-07-26-1") ==
               "https://github.com/soebbing/dtu.app/releases/tag/2026-07-26-1"
    end
  end

  describe "release_href/1 — branch name" do
    test "main goes to the tree view" do
      assert Layouts.release_href("main") ==
               "https://github.com/soebbing/dtu.app/tree/main"
    end

    test "nested branch with a slash is preserved" do
      assert Layouts.release_href("fix/passkey-runtime-env") ==
               "https://github.com/soebbing/dtu.app/tree/fix/passkey-runtime-env"
    end
  end

  describe "release_href/1 — fallback (dev, SemVer)" do
    test "dev falls back to the repo root" do
      assert Layouts.release_href("dev") ==
               "https://github.com/soebbing/dtu.app"
    end

    test "SemVer Mix.Project fallback also points at the repo root" do
      assert Layouts.release_href("0.1.0") ==
               "https://github.com/soebbing/dtu.app"
    end
  end

  describe "release_href/1 — defensive fallback (non-binary)" do
    # The `@version` assign is a string in every supported environment,
    # but a stale `Application.put_env` or a future config-shape change
    # could surface a non-binary value at render time. The function
    # must not crash the request — point at the repo root instead.
    test "nil falls back to the repo root" do
      assert Layouts.release_href(nil) ==
               "https://github.com/soebbing/dtu.app"
    end

    test "true (the leaked :version symptom from async test races) falls back" do
      assert Layouts.release_href(true) ==
               "https://github.com/soebbing/dtu.app"
    end

    test "an integer falls back" do
      assert Layouts.release_href(0) ==
               "https://github.com/soebbing/dtu.app"
    end

    test "an atom other than `dev` falls back" do
      assert Layouts.release_href(:something) ==
               "https://github.com/soebbing/dtu.app"
    end
  end
end
