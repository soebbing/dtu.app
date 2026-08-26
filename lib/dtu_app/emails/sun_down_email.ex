defmodule DtuApp.Emails.SunDownEmail do
  @moduledoc """
  Stub email body for `sun_down` events — the rich end-of-day summary.

  Tasks 6 / 7 will replace this with the full template (4 stat
  panels, inline SVG chart, dashboard CTA). For now it only needs
  to compile and return `{html, text}` so the dispatcher can be
  wired end-to-end.
  """

  alias DtuApp.Emails.Layout

  def render(user, payload) do
    Layout.render(
      title: payload.title,
      greeting: "Hi,",
      body: List.wrap(payload[:body] || payload["body"] || []),
      button: nil,
      note: nil,
      lang: user.locale || "en"
    )
  end
end
