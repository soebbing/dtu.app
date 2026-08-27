defmodule DtuApp.Emails.ConnectionEmail do
  @moduledoc """
  Email body for `dtu_connection` events. Carries the inverter
  name, the status word, and the timestamp — same data the
  in-page notification shows, but plain-text-friendly with a
  dashboard CTA at the bottom and a small note explaining why the
  user is getting it.

  The producer (`DtuApp.Notifications.DtuConnection`) already
  pre-localises the title and body inside its own
  `Gettext.with_locale/2` block; this module is responsible for the
  email-specific strings (greeting, button, note) and for stamping
  the `<html lang>` attribute from `user.locale`. We wrap the whole
  `Layout.render/1` call in `Gettext.with_locale/2` so the
  email-specific `gettext/1` calls in this module resolve against the
  same backend catalog the producer used.
  """

  use Gettext, backend: DtuAppWeb.Gettext

  alias DtuApp.Emails.Layout

  def render(%{locale: locale}, payload) do
    Gettext.with_locale(DtuAppWeb.Gettext, locale || "en", fn ->
      Layout.render(
        title: payload.title,
        greeting: gettext("Hi,"),
        body: payload_body(payload),
        button: %{
          label: gettext("Go to Dashboard"),
          url: dashboard_url()
        },
        note:
          gettext("You're getting this email because you enabled inverter connection alerts."),
        lang: locale || "en"
      )
    end)
  end

  # `payload.body` is normally a list (e.g. `[ "Inverter Shed
  # stopped reporting at 14:23 UTC." ]`) but the producer may pass
  # a string for legacy reasons. Coerce defensively so the layout's
  # `:body` requirement (a list of paragraph strings) is met
  # either way.
  defp payload_body(%{body: body}) when is_list(body), do: body
  defp payload_body(%{body: body}) when is_binary(body), do: [body]
  defp payload_body(_), do: []

  defp dashboard_url do
    DtuAppWeb.Endpoint.url() <> "/dashboard"
  end
end
