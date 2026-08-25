defmodule DtuAppWeb.GettextCatalogTest do
  @moduledoc """
  Regression test for the user-facing i18n bug fixed in PR #158:
  every `gettext/1` call on the dashboard, device-details page,
  notifications, sun-up/sun-down emails, and the locale switcher
  used to fall back to the English msgid under the de / fr locales,
  because the corresponding `msgstr` entries in the German and
  French .po files were empty.

  This test reads each locale's .po file directly and asserts the
  msgstr is non-empty for every msgid that was leaking. We assert
  on the catalog directly (not via `Gettext.gettext/2`) because
  some leaked strings — `YTD`, `Français`, `Deutsch` — are valid
  self-translations (`msgstr == msgid`), and the only way to
  distinguish "translator deliberately left msgstr = msgid" from
  "empty msgstr → runtime fallback to msgid" is to inspect the
  catalog.

  It's also a guard against anyone stripping translations again
  (e.g. by running `mix gettext.extract` without `--merge` after
  the source file regenerates the .pot).
  """

  use ExUnit.Case, async: true

  @catalog_path "priv/gettext"

  # The 59 msgids that were empty in both de and fr at the time this
  # test was written. Verified manually against
  # `priv/gettext/{de,fr}/LC_MESSAGES/default.po` before being
  # committed. Keep this list in sync with the catalog — if you add
  # a new gettext() call, either translate it everywhere or extend
  # this list and provide translations.
  @leaked_msgids [
    # Device details page (PR #102, #104, #107)
    "%{distinct} distinct, %{occurrences} total",
    "%{n} topic(s)",
    "Back to devices",
    "Copied!",
    "Copy as JSON",
    "Copy failed",
    "Copy the live topic tree as JSON",
    "Details",
    "DTU details — %{name}",
    "Errors",
    "Live MQTT topics",
    "Waiting for live data…",
    "none in the last 48 hours",
    "payload",
    "payload (%{n} chars)",
    "topic:",
    "Topics appear here as soon as the device publishes.",

    # Dashboard quick-range + 5-up stat card row (PR #154)
    "1D",
    "30D",
    "7D",
    "Custom",
    "Daily Yields — Last 30 days (kWh)",
    "Daily Yields — Last 7 days (kWh)",
    "Last 30 days",
    "Last 7 days",
    "Peak Time",
    "Selected day",
    "Selected month",
    "Selected week",
    "Selected year",
    "YTD",
    "Year to date",
    "Yield",

    # Dashboard yesterday ghost (PR #153)
    "Yesterday",
    "Yesterday (day-over-day comparison)",

    # Sun-down notifier (PR #144)
    " (same as yesterday)",
    " (%{sign}%{diff} W vs yesterday)",
    " (%{sign}%{diff} kWh vs yesterday)",
    "Sun's down — daily summary",

    # Sun-up notifier (PR #144)
    "Morning sun-up ping",
    "sink",

    # Email templates (lib/dtu_app/accounts/user_notifier.ex)
    "A cheerful one-off when your panels start producing for the day. Fires once per day, in your local timezone, the moment your fleet wakes up.",
    "Click the button below to log in to your account. This link can only be used once and expires shortly.",
    "Click the button below; your browser will ask whether to allow notifications for this site. Desktop browsers do not require a PWA install — you can install later for background (closed-tab) delivery if you want it.",
    "Hi %{email},",
    "If the button doesn't work, copy and paste this link into your browser:",
    "If you didn't create an account with us, you can safely ignore this email.",
    "If you didn't request this change, you can safely ignore this email.",
    "If you didn't try to log in, you can safely ignore this email — no one else can access your account without this link.",
    "Keep this tab open to receive notifications. For background delivery when the tab is closed, install this site as a PWA.",
    "Read-only MQTT sink — receives a real-time feed of this account's other devices",
    "Today: %{today_kwh} kWh%{yield_diff}, peak %{peak_w} W%{peak_diff}.",
    "Update email instructions",
    "Welcome to dtu.app! Confirm your email address to activate your account by clicking the button below.",
    "You can change your email address by clicking the button below. This link expires shortly.",

    # Auth/session flash + offline banner
    "You must log in to access this page.",
    "You must re-authenticate to access this page.",
    "You're offline. Showing the latest data we have.",

    # Locale switcher labels
    "Deutsch",
    "Français"
  ]

  describe "de catalog has a non-empty msgstr for every previously-leaked msgid" do
    for {msgid, idx} <- Enum.with_index(@leaked_msgids) do
      test "DE ##{idx}" do
        msgstr = lookup_msgstr!("de", unquote(msgid))

        refute msgstr == "",
               "DE catalog has empty msgstr for #{inspect(unquote(msgid))} — runtime would fall back to English"
      end
    end
  end

  describe "fr catalog has a non-empty msgstr for every previously-leaked msgid" do
    for {msgid, idx} <- Enum.with_index(@leaked_msgids) do
      test "FR ##{idx}" do
        msgstr = lookup_msgstr!("fr", unquote(msgid))

        refute msgstr == "",
               "FR catalog has empty msgstr for #{inspect(unquote(msgid))} — runtime would fall back to English"
      end
    end
  end

  describe "runtime lookups for a sample of previously-leaked strings" do
    # The catalog-level checks above already cover every leaked
    # msgid; these runtime checks confirm Gettext loads the
    # catalogs and substitutes translations into a few high-traffic
    # UI strings — the strings users reported as leaking.
    for {msgid, expected_de, expected_fr} <- [
          {"Yield", "Ertrag", "Rendement"},
          {"Peak Time", "Spitzenzeit", "Heure de pointe"},
          {"1D", "1T", "1J"},
          {"Custom", "Eigen", "Personnalisé"},
          {"Last 7 days", "Letzte 7 Tage", "7 derniers jours"},
          {"Year to date", "Jahr bis heute", "Année en cours"},
          {"Yesterday", "Gestern", "Hier"}
        ] do
      test "DE/FR: #{msgid}" do
        Gettext.put_locale(DtuAppWeb.Gettext, "de")
        assert Gettext.gettext(DtuAppWeb.Gettext, unquote(msgid)) == unquote(expected_de)
        Gettext.put_locale(DtuAppWeb.Gettext, "fr")
        assert Gettext.gettext(DtuAppWeb.Gettext, unquote(msgid)) == unquote(expected_fr)
      end
    end
  end

  describe "en locale still returns the English msgid" do
    for msgid <- [
          "Yield",
          "Peak Time",
          "1D",
          "Custom",
          "Yesterday",
          "Sun's down — daily summary"
        ] do
      test "EN: #{msgid}" do
        Gettext.put_locale(DtuAppWeb.Gettext, "en")
        assert Gettext.gettext(DtuAppWeb.Gettext, unquote(msgid)) == unquote(msgid)
      end
    end
  end

  # Reads priv/gettext/<locale>/LC_MESSAGES/default.po and returns
  # the msgstr for the given msgid. Raises on missing entries so
  # the test fails with a clear "msgid vanished" message rather than
  # silently passing on the wrong file.
  defp lookup_msgstr!(locale, target_msgid) do
    path = Path.join([@catalog_path, locale, "LC_MESSAGES", "default.po"])
    content = File.read!(path)

    case find_entry(content, target_msgid) do
      nil ->
        raise "msgid #{inspect(target_msgid)} not found in #{path} — the catalog has drifted; update @leaked_msgids or restore the missing entry"

      msgstr ->
        msgstr
    end
  end

  defp find_entry(content, target_msgid) do
    content
    # Split on msgid "..." boundaries so each chunk is one entry.
    # The header entry starts at line 1 and has empty msgid; we
    # drop it by checking for non-empty msgid.
    |> String.split(~r/^msgid /m, trim: true)
    |> Enum.find_value(fn chunk ->
      [msgid_raw, msgstr_raw | _] = String.split(chunk, ["\nmsgstr "], parts: 2)

      msgid = unquote_string(msgid_raw)

      if msgid == target_msgid do
        # msgstr_raw may end with `\n\n#: next entry...`. Trim to
        # the first newline so we keep only the actual msgstr.
        msgstr = msgstr_raw |> String.split("\n", parts: 2) |> List.first() |> unquote_string()
        msgstr
      else
        nil
      end
    end)
  end

  defp unquote_string(quoted) do
    # Strip the outer double quotes and unescape per .po conventions.
    # Input looks like: `"foo \"bar\""` or `"foo\nbar"`.
    case quoted do
      <<"\"", rest::binary>> ->
        case String.split(rest, "\"", parts: 2) do
          [inner, _after] ->
            inner
            |> String.replace(~s{\\}, "\\")
            |> String.replace(~s{\"}, "\"")
            |> String.replace(~s{\n}, "\n")

          _ ->
            # Unterminated — return raw for diagnostics.
            rest
        end

      _ ->
        quoted
    end
  end
end
