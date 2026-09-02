defmodule DtuAppWeb.UserSettingsHTML do
  use DtuAppWeb, :html

  embed_templates "user_settings_html/*"

  # Human-readable "when was this passkey last used" label. Lives here
  # rather than on the controller because `edit.html.heex` is compiled
  # into this module, which is what makes the bare call in the template
  # resolve.
  defp last_used_label(%{last_used_at: nil}), do: gettext("Never used")

  defp last_used_label(%{last_used_at: ts}) do
    ago = DateTime.diff(DateTime.utc_now(), ts, :second)

    cond do
      ago < 60 -> gettext("Just now")
      ago < 3600 -> gettext("%{minutes} minutes ago", minutes: div(ago, 60))
      ago < 86_400 -> gettext("%{hours} hours ago", hours: div(ago, 3600))
      true -> Calendar.strftime(ts, "%Y-%m-%d")
    end
  end

  # Formats the user's stored lat/lon as a one-line human-readable
  # display string for the Location section on `/users/settings`.
  # Returns `:unset` when either coord is missing so the template can
  # switch on the atom instead of a sentinel string.
  #
  # 4 decimal places ≈ 11 m of precision at the equator — enough to
  # identify a city block, and the same precision consumer GPS chips
  # and most browser geolocation APIs report. Going wider is
  # misleading (the source data isn't that accurate), going narrower
  # hides the hemisphere detail users actually want to see.
  @spec format_location(DtuApp.Accounts.User.t()) :: {:set, String.t()} | :unset
  def format_location(%DtuApp.Accounts.User{latitude: nil}), do: :unset
  def format_location(%DtuApp.Accounts.User{longitude: nil}), do: :unset

  def format_location(%DtuApp.Accounts.User{
        latitude: %Decimal{} = lat,
        longitude: %Decimal{} = lon
      }) do
    lat_f = Decimal.to_float(lat)
    lon_f = Decimal.to_float(lon)

    {:set, "#{format_coord(lat_f, :lat)}, #{format_coord(lon_f, :lon)}"}
  end

  defp format_coord(value, :lat) do
    hemisphere = if value >= 0, do: "N", else: "S"
    "#{Float.round(abs(value), 4)}° #{hemisphere}"
  end

  defp format_coord(value, :lon) do
    hemisphere = if value >= 0, do: "E", else: "W"
    "#{Float.round(abs(value), 4)}° #{hemisphere}"
  end

  # Humanises the Ecto field atom from the failed location changeset
  # so the user sees "Latitude: must be between -90 and 90" instead
  # of ":latitude: must be between -90 and 90". Keep this list
  # closed — the location changeset only casts `:latitude` /
  # `:longitude`, so anything else is a programmer error and should
  # surface the raw atom (debugging-friendly) rather than a
  # silent empty string.
  defp humanize_field(:latitude), do: gettext("Latitude")
  defp humanize_field(:longitude), do: gettext("Longitude")
  defp humanize_field(other), do: other |> Atom.to_string() |> String.capitalize()
end
