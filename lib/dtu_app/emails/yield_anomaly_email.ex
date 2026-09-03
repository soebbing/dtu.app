defmodule DtuApp.Emails.YieldAnomalyEmail do
  @moduledoc """
  Email body for `yield_anomaly` events — the mid-day
  production-collapse alert.

  Tone is intentionally alert (not playful): the email is the
  user's heads-up that something's off in their array, distinct
  from the cheerful tones of `SunUpEmail` (`☀️ The sun's
  awake!`) and the per-day-summary tone of `SunDownEmail`. The
  email points the user straight at the dashboard where the
  live chart will show the flatlined production curve.

  The producer (`DtuApp.Notifications.YieldAnomaly`) pre-localises
  the title and body inside its own `Gettext.with_locale/2`
  block; this module is responsible for the email-specific
  strings (greeting, button — no note) and for stamping the
  `<html lang>` attribute from `user.locale`. We wrap the
  whole `Layout.render/1` call in `Gettext.with_locale/2` so
  the email-specific `gettext/1` calls resolve against the
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
          label: gettext("Open dashboard"),
          url: dashboard_url()
        },
        # No trailing "note" line — the in-app LiveView is the
        # right surface for a follow-on. Email is for the heads-up.
        note: nil,
        lang: locale || "en"
      )
    end)
  end

  # `payload.body` is normally a list (e.g.
  # `[ "Your panels stopped producing for over 15 minutes…" ]`).
  # The producer may pass a string for legacy reasons. Coerce
  # defensively so the layout's `:body` requirement (a list of
  # paragraph strings) is met either way.
  defp payload_body(%{body: body}) when is_list(body), do: body
  defp payload_body(%{body: body}) when is_binary(body), do: [body]
  defp payload_body(_), do: []

  defp dashboard_url do
    DtuAppWeb.Endpoint.url() <> "/dashboard"
  end
end
