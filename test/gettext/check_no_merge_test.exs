defmodule DtuApp.Gettext.CheckNoMergeTest do
  @moduledoc """
  Unit tests for `priv/gettext/scripts/check-no-merge.sh`.

  The script is a bash CI guard; we test it by invoking it on
  purpose-built .po fixtures and asserting on its exit code and
  output. The fixtures are constructed in `/tmp/<random>/...` so
  the test doesn't pollute the working tree.

  We can't shell out to bash from `mix test` (cross-platform), so
  the test runs `bash` directly — fine on Linux/macOS CI runners.
  """
  use ExUnit.Case, async: true

  @script_path Path.expand("../../priv/gettext/scripts/check-no-merge.sh", __DIR__)

  setup do
    workdir =
      Path.join(
        System.tmp_dir!(),
        "gettext-merge-guard-test-#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(workdir)
    on_exit(fn -> File.rm_rf!(workdir) end)

    # Build a tiny fake git repo with a baseline commit so the script
    # can compute a diff against HEAD~1.
    System.cmd("git", ["init", "-q", workdir])
    System.cmd("git", ["-C", workdir, "config", "user.email", "test@test.com"])
    System.cmd("git", ["-C", workdir, "config", "user.name", "Test"])

    gettext_root = Path.join([workdir, "priv", "gettext"])
    en_dir = Path.join([gettext_root, "en", "LC_MESSAGES"])
    de_dir = Path.join([gettext_root, "de", "LC_MESSAGES"])
    File.mkdir_p!(en_dir)
    File.mkdir_p!(de_dir)

    File.write!(Path.join(gettext_root, "default.pot"), """
    msgid ""
    msgstr ""

    #: lib/foo.ex:1
    msgid "hello"
    msgstr ""

    #: lib/foo.ex:2
    msgid "world"
    msgstr ""
    """)

    File.write!(Path.join(en_dir, "default.po"), """
    msgid ""
    msgstr "Content-Type: text/plain; charset=UTF-8\\n"

    msgid "hello"
    msgstr "hello"

    msgid "world"
    msgstr "world"
    """)

    File.write!(Path.join(de_dir, "default.po"), """
    msgid ""
    msgstr "Content-Type: text/plain; charset=UTF-8\\n"

    msgid "hello"
    msgstr "hallo"

    msgid "world"
    msgstr "welt"
    """)

    System.cmd("git", ["-C", workdir, "add", "priv"])
    System.cmd("git", ["-C", workdir, "commit", "-q", "-m", "baseline"])

    %{workdir: workdir, gettext_root: gettext_root, de_dir: de_dir, en_dir: en_dir}
  end

  defp run_script(workdir) do
    {output, exit_code} =
      System.cmd("bash", [@script_path], cd: workdir, env: [{"GITHUB_BASE_REF", ""}])

    {output, exit_code}
  end

  test "passes when only .pot is touched (extract, no merge)", %{
    workdir: workdir,
    gettext_root: root
  } do
    pot_path = Path.join(root, "default.pot")
    existing = File.read!(pot_path)
    File.write!(pot_path, existing <> "\n#: lib/foo.ex:3\nmsgid \"another\"\nmsgstr \"\"\n")

    System.cmd("git", ["-C", workdir, "add", "priv"])
    System.cmd("git", ["-C", workdir, "commit", "-q", "-m", "extract new msgid"])

    {output, exit_code} = run_script(workdir)
    assert exit_code == 0
    assert output =~ "no .po files changed"
  end

  test "passes on a hand-appended msgid (the discipline)", %{workdir: workdir, de_dir: de_dir} do
    po_path = Path.join(de_dir, "default.po")

    File.write!(
      po_path,
      File.read!(po_path) <> "\nmsgid \"new_string\"\nmsgstr \"neuer_string\"\n"
    )

    System.cmd("git", ["-C", workdir, "add", "priv"])
    System.cmd("git", ["-C", workdir, "commit", "-q", "-m", "hand-append"])

    {output, exit_code} = run_script(workdir)
    assert exit_code == 0, "expected pass, got: #{output}"
    assert output =~ "msgid ordering matches"
  end

  test "fails on merge-style reordering", %{workdir: workdir, de_dir: de_dir} do
    # Reorder hello/world (should be hello then world per .pot) to
    # world then hello — the signature of merge-style sorting.
    File.write!(de_dir |> Path.join("default.po"), """
    msgid ""
    msgstr "Content-Type: text/plain; charset=UTF-8\\n"

    msgid "world"
    msgstr "welt"

    msgid "hello"
    msgstr "hallo"
    """)

    System.cmd("git", ["-C", workdir, "add", "priv"])
    System.cmd("git", ["-C", workdir, "commit", "-q", "-m", "reorder"])

    {output, exit_code} = run_script(workdir)
    assert exit_code == 1
    assert output =~ "msgid ordering diverges"
    assert output =~ "Hand-append new msgids"
  end

  test "passes on a msgid dropped in correct-order position (out of contract)", %{
    workdir: workdir,
    de_dir: de_dir
  } do
    # The script's contract is detecting reordering, not dropped or
    # fuzzy-flagged content. A msgid dropped in correct-order position
    # preserves the common-set projection's ordering — the script
    # passes. Dropped msgids are caught by the test suite (a missing
    # translation breaks rendering); this test documents that the
    # guard is intentionally narrower.
    File.write!(de_dir |> Path.join("default.po"), """
    msgid ""
    msgstr "Content-Type: text/plain; charset=UTF-8\\n"

    msgid "hello"
    msgstr "hallo"
    """)

    System.cmd("git", ["-C", workdir, "add", "priv"])
    System.cmd("git", ["-C", workdir, "commit", "-q", "-m", "drop msgid"])

    {output, exit_code} = run_script(workdir)
    assert exit_code == 0, "expected pass (drop in correct position), got: #{output}"
    assert output =~ "msgid ordering matches"
  end
end
