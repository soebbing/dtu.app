defmodule DtuApp.Emails.SunUpEmail do
  @moduledoc """
  Stub email body for `sun_up` events — the playful morning ping.

  Tasks 5 / 7 will replace this with the real template. For now it
  only needs to compile and return `{html, text}` so the dispatcher
  can be wired end-to-end.
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
