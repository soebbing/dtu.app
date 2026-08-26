defmodule DtuApp.Emails.SunUpEmail do
  @moduledoc """
  Email body for `sun_up` events — the playful morning ping. Same
  cheerful tone as the in-page notification, but the email is
  mostly a "first power of the day, here's to a sunny one!" line
  with a dashboard CTA so users who only get email still have a
  fast path to the live data.

  The producer (`DtuApp.Notifications.SunUp`) already pre-localises
  the title and body inside its own `Gettext.with_locale/2` block;
  this module is responsible for the email-specific strings
  (greeting, button — no note) and for stamping the `<html lang>`
  attribute from `user.locale`. We wrap the whole `Layout.render/1`
  call in `Gettext.with_locale/2` so the email-specific `gettext/1`
  calls resolve against the same backend catalog the producer
  used.
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
        note: nil,
        lang: locale || "en"
      )
    end)
  end

  # `payload.body` is normally a list (e.g.
  # `[ "Your array just woke up at 06:14 local time. …" ]`) but the
  # producer may pass a string for legacy reasons. Coerce
  # defensively so the layout's `:body` requirement (a list of
  # paragraph strings) is met either way.
  defp payload_body(%{body: body}) when is_list(body), do: body
  defp payload_body(%{body: body}) when is_binary(body), do: [body]
  defp payload_body(_), do: []

  defp dashboard_url do
    DtuAppWeb.Endpoint.url() <> "/dashboard"
  end
end