defmodule DtuApp.Emails.ConnectionEmail do
  @moduledoc """
  Stub email body for `dtu_connection` events.

  Tasks 5 / 7 will replace this with the real template (inverter
  name, localized status word, dashboard CTA). For now it only
  needs to compile and return `{html, text}` so the dispatcher
  can be wired end-to-end without dragging the rich copy work
  forward.
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
