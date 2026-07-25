defmodule DtuApp.Emails.Layout do
  @moduledoc """
  Site-styled, email-client-safe HTML for transactional emails.

  Email HTML is not web HTML: Gmail strips `<head>` `<style>` blocks, Outlook
  ignores most CSS, and many clients block images by default. So this layout
  uses table-based structure, fully inline styles, a web-safe font stack, and a
  text fallback for every link. The palette mirrors the marketing site —
  zinc-950 canvas, emerald-500 primary action, an emerald→amber gradient on the
  wordmark — so the emails read as one product.
  """

  # Brand palette (kept in sync with the Tailwind classes on the site).
  # zinc-950
  @canvas "#09090b"
  # zinc-900
  @card "#18181b"
  # zinc-800
  @card_border "#27272a"
  # zinc-400
  @muted "#a1a1aa"
  # zinc-50
  @text "#fafafa"
  # emerald-500
  @primary "#10b981"
  # emerald-600 (button bottom gradient / border)
  @primary_dark "#059669"
  # amber-300
  @amber "#fcd34d"

  @doc """
  Render a transactional email.

  ## Options

    * `:title`       — bold header line above the greeting (required)
    * `:greeting`    — e.g. "Hi user@example.com," (required)
    * `:body`        — list of `<p>` paragraphs (strings). Required.
    * `:button`      — `%{label: String.t(), url: String.t()}` CTA, or `nil`
    * `:note`        — small muted footer paragraph (e.g. security note), or `nil`

  Returns `{html_body, text_body}`.
  """
  def render(opts) do
    title = Keyword.fetch!(opts, :title)
    greeting = Keyword.fetch!(opts, :greeting)
    body = Keyword.fetch!(opts, :body)
    button = Keyword.get(opts, :button)
    note = Keyword.get(opts, :note)

    html = html(title, greeting, body, button, note)
    text = text_body(title, greeting, body, button, note)

    {html, text}
  end

  defp html(title, greeting, body, button, note) do
    ~s"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
        <title>#{escape(title)}</title>
      </head>
      <body style="margin:0;padding:0;background-color:#{@canvas};">
        <!-- Outer canvas -->
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#{@canvas};">
          <tr>
            <td align="center" style="padding:32px 16px;">

              <!-- Card -->
              <table role="presentation" width="560" cellpadding="0" cellspacing="0" border="0" style="width:560px;max-width:100%;background-color:#{@card};border:1px solid #{@card_border};border-radius:16px;">
                <!-- Brand header -->
                <tr>
                  <td style="padding:32px 40px 0 40px;">
                    <span style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:22px;font-weight:800;letter-spacing:-0.02em;color:#{@text};">
                      dtu<span style="color:#{@primary};">.</span>app
                    </span>
                  </td>
                </tr>
                <!-- Accent rule -->
                <tr>
                  <td style="padding:20px 40px 0 40px;">
                    <div style="height:3px;width:48px;border-radius:9999px;background:linear-gradient(90deg, #{@primary}, #{@amber});font-size:0;line-height:0;">&nbsp;</div>
                  </td>
                </tr>
                <!-- Title -->
                <tr>
                  <td style="padding:20px 40px 0 40px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:24px;font-weight:800;letter-spacing:-0.02em;line-height:1.2;color:#{@text};">
                    #{escape(title)}
                  </td>
                </tr>
                <!-- Greeting + body -->
                <tr>
                  <td style="padding:12px 40px 0 40px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:16px;line-height:1.6;color:#{@muted};">
                    <p style="margin:0 0 12px 0;">#{escape(greeting)}</p>
                    #{paragraphs(body)}
                  </td>
                </tr>
                #{button_row(button)}
                #{note_row(note)}
                <tr><td style="height:16px;line-height:16px;font-size:0;">&nbsp;</td></tr>
              </table>

              <!-- Footer -->
              <table role="presentation" width="560" cellpadding="0" cellspacing="0" border="0" style="width:560px;max-width:100%;">
                <tr>
                  <td align="center" style="padding:20px 40px 0 40px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:12px;line-height:1.5;color:#52525b;">
                    dtu.app &middot; solar telemetry
                  </td>
                </tr>
              </table>

            </td>
          </tr>
        </table>
      </body>
    </html>
    """
  end

  defp paragraphs(body) do
    body
    |> List.wrap()
    |> Enum.map(fn p ->
      ~s|<p style="margin:0 0 12px 0;">#{escape(p)}</p>|
    end)
    |> Enum.join("\n")
  end

  defp button_row(nil), do: ""

  defp button_row(%{label: label, url: url}) do
    ~s"""
        <!-- CTA -->
        <tr>
          <td style="padding:8px 40px 0 40px;">
            <table role="presentation" cellpadding="0" cellspacing="0" border="0">
              <tr>
                <td bgcolor="#{to_string(@primary)}" style="border-radius:10px;background-image:linear-gradient(180deg, #{@primary}, #{@primary_dark});">
                  <a href="#{escape(url)}" target="_blank" style="display:inline-block;padding:14px 28px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#09090b;text-decoration:none;border-radius:10px;">
                    #{escape(label)}
                  </a>
                </td>
              </tr>
            </table>
          </td>
        </tr>
    """
  end

  defp note_row(nil), do: ""

  defp note_row(note) do
    ~s"""
        <!-- Note -->
        <tr>
          <td style="padding:16px 40px 0 40px;">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#101012;border:1px solid #{@card_border};border-radius:12px;">
              <tr>
                <td style="padding:14px 16px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:13px;line-height:1.55;color:#71717a;">
                  #{escape(note)}
                </td>
              </tr>
            </table>
          </td>
        </tr>
    """
  end

  defp text_body(title, greeting, body, button, note) do
    parts =
      [title, "", greeting, ""] ++
        List.wrap(body) ++
        text_button(button) ++
        text_note(note)

    parts
    |> Enum.join("\n")
    |> String.trim()
  end

  defp text_button(nil), do: []
  defp text_button(%{label: label, url: url}), do: ["", "#{label}:", url]

  defp text_note(nil), do: []
  defp text_note(note), do: ["", note]

  defp escape(nil), do: ""
  defp escape(string) when is_binary(string), do: escape_impl(string)

  defp escape_impl(string) do
    string
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
