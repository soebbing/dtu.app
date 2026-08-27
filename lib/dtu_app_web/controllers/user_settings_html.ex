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
end
