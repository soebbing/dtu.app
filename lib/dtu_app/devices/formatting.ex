defmodule DtuApp.Devices.Formatting do
  @moduledoc """
  Number / savings / locale formatting.

  Pure-data helpers, no DB access. Three clusters:

    * `compute_savings/2` — kWh × cents/kWh → integer cents.
    * `format_savings/1`, `format_savings/2` — integer cents →
      `"1.234,56 €"` (locale-aware: `,` decimal + `.` thousand
      for `de`, NBSP thousand + `,` decimal for `fr`, default
      `,` thousand + `.` decimal for everything else).
    * `format_number/1..3` — number → fixed-decimal string, same
      locale rules as `format_savings`.

  The `fr` thousand separator is a non-breaking space (U+00A0) so
  line-breaks don't split the digits in middle of a number.

  Re-exported through `DtuApp.Devices` via `defdelegate` so
  existing call sites continue to work unchanged.
  """

  alias Gettext

  @doc """
  Compute the euro-cent savings for a given yield in kWh at a given
  rate. `cents_per_kwh` is the integer-cent rate stored on the
  `User` schema; `kwh` is the period's total yield (already rounded
  to one decimal by the per-period `compute_*_period_stats`
  functions). The product is the euro-cent savings as an integer
  (e.g. `250.0 kWh × 32 c/kWh = 8000 c = €80.00`):

      compute_savings(250.0, 32)  # 250 kWh at €0.32/kWh
      # => 8000                     # 8000 euro-cents (€80.00)

  Pure data shaping, no DB access. `nil` rate (user hasn't set one
  on `/users/settings`) propagates as `nil` so the dashboard can
  hide the savings card rather than show "€0.00 saved".

  Note: this function deliberately does NOT divide by 100 — the
  product `kwh × cents_per_kwh` is already in euro cents (e.g.
  `0.32 €/kWh × 250 kWh = 80 € = 8000 cents`), and `format_savings/1`
  performs the cents→euros split when it formats the value for the
  dashboard. Dividing here as well would shrink every card value by
  100× and collapse typical residential daily yields (single-digit
  kWh at €0.32/kWh) to a rounded 0 — see the
  `compute_savings/2 + format_savings/1` describe block in
  `test/dtu_app/devices_test.exs`.
  """
  @spec compute_savings(float() | nil, pos_integer() | nil) :: pos_integer() | nil
  def compute_savings(nil, _cents), do: nil
  def compute_savings(_kwh, nil), do: nil

  def compute_savings(kwh, cents) when is_number(kwh) and is_integer(cents) and cents > 0 do
    round(kwh * cents)
  end

  @doc """
  Format a euro-cent integer as a `€X.XX` string for display in the
  dashboard. Mirrors the precision contract of the
  `compute_*_period_stats` family (two decimal places, no
  thousands separator — a self-hosted solar app rarely shows four-
  digit-savings totals, and the dashboard's "Saved this month"
  card is already in a compact stat-card layout). Returns "€0.00"
  for `nil` so the template can render a stable placeholder.

  `format_savings/1` reads the current Gettext locale and uses the
  matching number-formatting convention (English `1,234.56 €`,
  German `1.234,56 €`, French `1 234,56 €`). The dashboard calls
  `format_savings/1` from a locale-aware context, so the appropriate
  number format is selected automatically. `format_savings/2` is
  the explicit-locale form for tests and any future caller that
  needs to format for a locale other than the current request.

  ## Locales

  | locale | format           | example 1234.56 |
  | ------ | ---------------- | --------------- |
  | `en`   | `1,234.56 €`     | English         |
  | `de`   | `1.234,56 €`     | German          |
  | `fr`   | `1 234,56 €`     | French (NBSP)   |
  | _other_| falls back to `en` | —               |

  Returns "€0.00" / locale equivalent for `nil`.
  """
  @spec format_savings(pos_integer() | nil) :: String.t()
  def format_savings(cents), do: format_savings(cents, Gettext.get_locale(DtuAppWeb.Gettext))

  @spec format_savings(pos_integer() | nil, String.t()) :: String.t()
  def format_savings(nil, _locale), do: format_savings(0, "en")

  def format_savings(cents, locale) when is_integer(cents) and cents >= 0 do
    # Build the whole and fractional parts separately. Doing it via a
    # single `:erlang.float_to_binary(cents/100)` would lose the
    # magnitude (e.g. 12_345/100 → "123.45" — there's no way to
    # recover that 12345 cents came from 5 digits, so a thousands
    # separator becomes impossible to add).
    whole = Integer.to_string(div(cents, 100))
    frac = cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")

    formatted =
      case locale do
        # German: dot as thousand separator, comma as decimal, symbol after.
        "de" -> "#{insert_thousands_separator(whole, ".")},#{frac} €"
        # French: non-breaking space (U+00A0) as thousand separator per
        # French/European typographic convention (DIN 5008 / AFNOR).
        "fr" -> "#{insert_thousands_separator(whole, " ")},#{frac} €"
        # English: comma as thousand separator, dot as decimal.
        "en" -> "#{insert_thousands_separator(whole, ",")}.#{frac} €"
        _ -> "#{insert_thousands_separator(whole, ",")}.#{frac} €"
      end

    formatted
  end

  # Insert a thousands separator every three digits from the right.
  # The separator is passed as a UTF-8 binary ("," "." or NBSP) so a
  # multibyte separator like U+00A0 round-trips correctly through the
  # recursion — `<<sep, last_three::binary>>` would only append the
  # first byte. We split out the separator's byte length and glue
  # the result back together with explicit byte-counts instead.
  defp insert_thousands_separator(whole, _sep) when byte_size(whole) <= 3, do: whole

  defp insert_thousands_separator(whole, sep) do
    {head, last_three} = String.split_at(whole, -3)
    head = insert_thousands_separator(head, sep)

    sep_bytes = byte_size(sep)
    head_bytes = byte_size(head)
    <<head::binary-size(head_bytes), sep::binary-size(sep_bytes), last_three::binary>>
  end

  @doc """
  Format a unit-less number for display in the dashboard. The
  dashboard's stat cards (`Current Power`, `Today's Total Yield`,
  `Peak Power`, etc.) and chart Y-axis labels need a locale-aware
  number without a trailing unit — `format_savings/1` doesn't fit
  because it always appends ` €`. The convention is the same as
  `format_savings/1`:

  | locale | format           | example 1234.5 |
  | ------ | ---------------- | --------------- |
  | `en`   | `1,234.5`        | English         |
  | `de`   | `1.234,5`        | German          |
  | `fr`   | `1 234,5`        | French (NBSP)   |
  | _other_| falls back to `en` | —               |

  `decimals` controls precision (default `1` to match the kWh stat
  cards, which read better as `1.3 kWh` than `1 kWh`). Pass
  `decimals: 0` for integer-only output — the W (watts) stat cards
  use this so `350.0 W` reads as `350 W` (the underlying value is
  already rounded to one decimal upstream; rendering the trailing
  `.0` would just be visual noise).

  Returns `"—"` (em-dash) for `nil` so the template can render a
  stable placeholder without a conditional.

  `format_number/1` and `format_number/2` read the current Gettext
  locale — the dashboard calls them from a request-scoped LiveView
  process, so the user's selected language is picked up automatically.
  `format_number/3` is the explicit-locale form for tests and any
  future caller that needs to format for a locale other than the
  current request.
  """
  @spec format_number(number() | nil) :: String.t()
  def format_number(value), do: format_number(value, 1, Gettext.get_locale(DtuAppWeb.Gettext))

  @spec format_number(number() | nil, non_neg_integer()) :: String.t()
  def format_number(value, decimals),
    do: format_number(value, decimals, Gettext.get_locale(DtuAppWeb.Gettext))

  @spec format_number(number() | nil, non_neg_integer(), String.t()) :: String.t()
  def format_number(nil, _decimals, _locale), do: "—"

  def format_number(value, decimals, locale)
      when is_number(value) and is_integer(decimals) and decimals >= 0 do
    {whole_int, frac_str, sign} = split_value(value, decimals)
    {sep_t, sep_d} = locale_separators(locale)
    formatted_whole = insert_thousands_separator(Integer.to_string(whole_int), sep_t)

    case decimals do
      0 -> "#{sign}#{formatted_whole}"
      _ -> "#{sign}#{formatted_whole}#{sep_d}#{frac_str}"
    end
  end

  # Round to `decimals` digits after the point, then split into
  # (whole, fractional-string, sign). `Integer.to_string(whole)` is
  # later fed into `insert_thousands_separator/2` so the locale-aware
  # separator can be inserted.
  @spec split_value(number(), non_neg_integer()) :: {integer(), String.t(), String.t()}
  defp split_value(value, decimals) do
    sign = if value < 0, do: "-", else: ""
    rounded = Float.round(abs(value) * 1.0, decimals)
    scaled = round(rounded * :math.pow(10, decimals))
    scale = round(:math.pow(10, decimals))
    whole = div(scaled, scale)
    frac = rem(scaled, scale) |> Integer.to_string() |> String.pad_leading(decimals, "0")
    {whole, frac, sign}
  end

  # Per-locale {thousands_separator, decimal_separator} tuple. Falls
  # back to English for any unknown locale so a stale Gettext backend
  # (e.g. a new language without a project-side translation yet) still
  # produces a readable, machine-parseable number rather than `?`.
  @spec locale_separators(String.t()) :: {String.t(), String.t()}
  defp locale_separators("de"), do: {".", ","}
  # French typography (DIN 5008 / AFNOR): non-breaking space (U+00A0)
  # as thousands separator. A regular space would let a line break
  # split the number — the NBSP keeps the digits glued together.
  defp locale_separators("fr"), do: {"\u00A0", ","}
  defp locale_separators(_), do: {",", "."}
end
