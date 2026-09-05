defmodule DtuAppWeb.GettextCatalogTest do
  @moduledoc """
  Guards against user-facing i18n leaks: a `gettext/1` call whose
  `msgstr` is empty in a translated locale silently falls back to
  the English msgid at runtime, so the string ships untranslated
  with no compile-time or test-time signal.

  Originally (PR #158) this was a hardcoded list of the 59 msgids
  known to be leaking on the dashboard, device-details page,
  notifications and emails. That list could only catch regressions
  in strings someone had already noticed by hand — it went stale
  the moment a feature added new `gettext/1` calls, which is
  exactly what happened with the passkeys, location/weather and
  empty-state work (40 de / 39 fr strings leaked past it).

  It is now a blanket check: **every** entry in every translated
  locale's catalog must have a non-empty msgstr. Adding a new
  `gettext/1` call and running `mix gettext.extract --merge`
  therefore fails this test until the string is actually
  translated in de and fr.

  Two things this deliberately does *not* flag:

    * `msgstr == msgid` — a legitimate self-translation. "Passkeys",
      "YTD", "Deutsch", "online" and "0 W" are correct as-is in
      German, and the runtime cannot distinguish these from a
      fallback, which is why we assert on the catalog rather than
      via `Gettext.gettext/2`.

    * `fuzzy`-flagged entries — `mix gettext.merge` sets this when
      it auto-matches a translation to a changed msgid. Elixir's
      Gettext still serves the translation at runtime (verified:
      "Peak power" -> "Spitzenleistung" under a fuzzy flag), so
      these render translated. They mean "a human should review
      this", not "this is missing".
  """

  use ExUnit.Case, async: true

  @catalog_path "priv/gettext"

  # Locales we ship translations for. "en" is the source locale —
  # its msgstrs are empty by design and fall back to the msgid,
  # which *is* the English text. Mirrors `@supported_locales` in
  # `DtuAppWeb.Plugs.Locale` minus "en".
  @translated_locales ~w(de fr)

  # Gettext domains, one .po per (locale, domain).
  @domains ~w(default errors)

  describe "catalog completeness" do
    for locale <- @translated_locales, domain <- @domains do
      test "#{locale}/#{domain}.po has a non-empty msgstr for every entry" do
        locale = unquote(locale)
        domain = unquote(domain)
        path = po_path(locale, domain)

        untranslated =
          path
          |> parse_po!()
          |> Enum.filter(&untranslated?/1)
          |> Enum.map(& &1.msgid)

        assert untranslated == [],
               """
               #{length(untranslated)} untranslated msgid(s) in #{path}.

               An empty msgstr makes Gettext fall back to the English msgid at
               runtime, so these ship untranslated to #{locale} users:

               #{Enum.map_join(untranslated, "\n", &"  - #{inspect(&1)}")}

               Translate them in #{path}. If a string is genuinely identical in
               #{locale} (a product name, a unit like "0 W"), set msgstr to the
               same text as msgid rather than leaving it empty.
               """
      end
    end
  end

  describe "runtime lookups for a sample of previously-leaked strings" do
    # The catalog check above proves no msgstr is empty; these
    # confirm Gettext actually loads the catalogs and substitutes
    # translations into high-traffic UI strings — covering the
    # wiring (backend config, locale switching) that a pure
    # file-parsing test cannot.
    for {msgid, expected_de, expected_fr} <- [
          {"Yield", "Ertrag", "Rendement"},
          {"Peak Time", "Spitzenzeit", "Heure de pointe"},
          {"1D", "1T", "1J"},
          {"Custom", "Eigen", "Personnalisé"},
          {"Last 7 days", "Letzte 7 Tage", "7 derniers jours"},
          {"Year to date", "Jahr bis heute", "Année en cours"},
          {"Yesterday", "Gestern", "Hier"},
          # Location / weather + passkeys — the features whose
          # strings the old hardcoded list could not have caught.
          {"Cloud cover", "Bewölkung", "Couverture nuageuse"},
          {"partly cloudy", "teilweise bewölkt", "partiellement nuageux"},
          {"Share location", "Standort freigeben", "Partager la position"},
          {"Use a passkey", "Passkey verwenden", "Utiliser une clé d'accès"},
          {"Never used", "Nie verwendet", "Jamais utilisée"}
        ] do
      test "DE/FR: #{msgid}" do
        Gettext.put_locale(DtuAppWeb.Gettext, "de")
        assert Gettext.gettext(DtuAppWeb.Gettext, unquote(msgid)) == unquote(expected_de)
        Gettext.put_locale(DtuAppWeb.Gettext, "fr")
        assert Gettext.gettext(DtuAppWeb.Gettext, unquote(msgid)) == unquote(expected_fr)
      end
    end
  end

  describe "interpolation placeholders survive translation" do
    # A translation that drops or renames a %{binding} raises
    # Gettext.Error (or renders a stray literal) only when that
    # exact branch runs in production. Assert here instead.
    for {locale, expected} <- [{"de", "vor 5 Stunden"}, {"fr", "il y a 5 heures"}] do
      test "#{locale} keeps %{hours}" do
        Gettext.put_locale(DtuAppWeb.Gettext, unquote(locale))

        assert Gettext.gettext(DtuAppWeb.Gettext, "%{hours} hours ago", hours: 5) ==
                 unquote(expected)
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

  defp po_path(locale, domain),
    do: Path.join([@catalog_path, locale, "LC_MESSAGES", "#{domain}.po"])

  # An entry is untranslated when any of its msgstr forms is empty.
  # Plural entries (errors.po carries 9) have msgstr[0], msgstr[1],
  # …; a half-filled plural set is just as broken as an empty
  # singular, so we require all of them.
  defp untranslated?(%{msgstrs: msgstrs}), do: Enum.any?(msgstrs, &(&1 == ""))

  # Minimal .po parser. Entries are separated by blank lines; the
  # first entry (empty msgid) is the header and is dropped. Handles
  # the two shapes present in this catalog that a naive
  # line-at-a-time reader gets wrong:
  #
  #   * multi-line values, where a `msgid`/`msgstr` is continued by
  #     bare quoted lines beneath it (errors.po has these)
  #   * plural forms, `msgid_plural` + indexed `msgstr[N]`
  #
  # Obsolete entries (`#~`) are skipped along with all other
  # comments — they are not live translations.
  defp parse_po!(path) do
    path
    |> File.read!()
    |> String.split(~r/\n[ \t]*\n/, trim: true)
    |> Enum.map(&parse_entry/1)
    |> Enum.reject(&(&1 == nil or &1.msgid == ""))
  end

  defp parse_entry(block) do
    fields =
      block
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "#"))
      |> Enum.reduce({%{}, nil}, &collect_line/2)
      |> elem(0)

    case fields do
      %{msgid: msgid} ->
        msgstrs =
          fields
          |> Enum.filter(fn {k, _} -> match?({:msgstr, _}, k) end)
          |> Enum.sort_by(fn {{:msgstr, n}, _} -> n end)
          |> Enum.map(fn {_, v} -> v end)

        %{msgid: msgid, msgstrs: msgstrs}

      _ ->
        nil
    end
  end

  defp collect_line(line, {acc, current}) do
    cond do
      String.starts_with?(line, "msgid_plural ") ->
        put_field(acc, :msgid_plural, value_of(line, "msgid_plural "))

      String.starts_with?(line, "msgid ") ->
        put_field(acc, :msgid, value_of(line, "msgid "))

      captures = Regex.run(~r/^msgstr\[(\d+)\] /, line) ->
        [prefix, n] = captures
        put_field(acc, {:msgstr, String.to_integer(n)}, value_of(line, prefix))

      String.starts_with?(line, "msgstr ") ->
        put_field(acc, {:msgstr, 0}, value_of(line, "msgstr "))

      # Continuation of whichever key we saw last.
      String.starts_with?(line, "\"") and current != nil ->
        {Map.update!(acc, current, &(&1 <> unquote_po(line))), current}

      true ->
        {acc, current}
    end
  end

  defp put_field(acc, key, value), do: {Map.put(acc, key, value), key}

  defp value_of(line, prefix),
    do: line |> String.replace_prefix(prefix, "") |> unquote_po()

  # Strips the surrounding quotes and unescapes .po escape
  # sequences in one pass, so `\\n` and `\\"` do not corrupt the
  # emptiness check or the failure message.
  defp unquote_po(<<?", rest::binary>>) do
    rest
    |> String.replace_suffix("\"", "")
    |> unescape()
  end

  defp unquote_po(other), do: other

  defp unescape(string) do
    Regex.replace(~r/\\(.)/, string, fn _full, char ->
      case char do
        "n" -> "\n"
        "t" -> "\t"
        "r" -> "\r"
        other -> other
      end
    end)
  end
end
