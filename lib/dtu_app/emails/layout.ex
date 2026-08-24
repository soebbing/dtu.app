defmodule DtuApp.Emails.Layout do
  @moduledoc """
  Site-styled, email-client-safe HTML for transactional emails.

  Email HTML is not web HTML: Gmail strips `<head>` `<style>` blocks, Outlook
  ignores most CSS, and many clients block images by default. So this layout
  uses table-based structure, fully inline styles, a web-safe font stack, and
  a text fallback for every link.

  **Theme.** The brand palette (emerald primary, emerald→amber wordmark
  gradient) is the same in both light and dark modes — only the canvas /
  card / text colors swap. We default to the **light** palette (Gmail,
  Outlook, and most webmail strip `<style>` so they won't see the dark
  variant) and override to dark only inside an in-body `<style>` block
  via `@media (prefers-color-scheme: dark)`. Apple Mail, iOS Mail, and
  Thunderbird honour that media query and render dark for users with the
  system in dark mode. Other clients keep the light default.

  Earlier versions hard-coded the dark palette which made the email
  appear dark on light-mode devices (and inverted/illegible on some
  clients with auto-dark schemes), hence this rewrite.
  """

  # ── Light theme (default — what Gmail / Outlook render) ──────────────────
  # zinc-100 outer background
  @canvas_light "#f4f4f5"
  # card surface
  @card_light "#ffffff"
  # zinc-200 border
  @card_border_light "#e4e4e7"
  # zinc-900 primary text
  @text_light "#18181b"
  # zinc-600 secondary text
  @muted_light "#52525b"
  # zinc-50 inner note card
  @note_bg_light "#fafafa"
  # zinc-200 note border
  @note_border_light "#e4e4e7"
  # zinc-500 note text
  @note_text_light "#71717a"
  # zinc-400 footer text
  @footer_text_light "#a1a1aa"

  # ── Dark theme (active when prefers-color-scheme: dark) ──────────────────
  # zinc-950 outer background
  @canvas_dark "#09090b"
  # zinc-900 card surface
  @card_dark "#18181b"
  # zinc-800 border
  @card_border_dark "#27272a"
  # zinc-50 primary text
  @text_dark "#fafafa"
  # zinc-400 secondary text
  @muted_dark "#a1a1aa"
  # near-black inner note card
  @note_bg_dark "#101012"
  # zinc-800 note border
  @note_border_dark "#27272a"
  # zinc-500 note text
  @note_text_dark "#71717a"
  # zinc-500 footer text
  @footer_text_dark "#71717a"

  # ── Brand (same in both themes) ─────────────────────────────────────────
  # emerald-500
  @primary "#10b981"
  # emerald-600 (button bottom gradient)
  @primary_dark "#059669"
  # zinc-950 — readable on emerald
  @primary_text_on_color "#09090b"
  # amber-300 (gradient end)
  @amber "#fcd34d"

  @doc """
  Render a transactional email.

  ## Options

    * `:title`       — bold header line above the greeting (required)
    * `:greeting`    — e.g. "Hi user@example.com," (required)
    * `:body`        — list of `<p>` paragraphs (strings). Required.
    * `:button`      — `%{label: String.t(), url: String.t()}` CTA, or `nil`
    * `:note`        — small muted footer paragraph (e.g. security note), or `nil`
    * `:lang`        — BCP-47 short code (`"en"`, `"de"`, `"fr"`) used for the
                       `<html lang="...">` attribute. Defaults to `"en"`. The
                       title / greeting / body / button / note strings are
                       expected to ALREADY be translated by the caller (this
                       module does no translation itself) — only the
                       attribute is set here.

  Returns `{html_body, text_body}`.
  """
  def render(opts) do
    title = Keyword.fetch!(opts, :title)
    greeting = Keyword.fetch!(opts, :greeting)
    body = Keyword.fetch!(opts, :body)
    button = Keyword.get(opts, :button)
    note = Keyword.get(opts, :note)
    # Default to "en" so a caller that forgets the option (or pre-dates
    # the i18n-coverage change) still renders sensibly. The set of
    # supported values is the same as `Plugs.Locale.@supported_locales`
    # and `User.@supported_locales`; an unknown code is passed through
    # verbatim — gettext / screen readers fall back gracefully.
    lang = Keyword.get(opts, :lang, "en")

    html = html(title, greeting, body, button, note, lang)
    text = text_body(title, greeting, body, button, note)

    {html, text}
  end

  defp html(title, greeting, body, button, note, lang) do
    # Inline styles set the LIGHT theme defaults so clients that strip <style>
    # (Gmail web, Outlook desktop) at least render something sensible. The
    # <style> block at the top of <body> overrides these with dark colors
    # when prefers-color-scheme: dark matches.
    #
    # Colour-scheme: light/dark also tells the browser to render form
    # controls and scrollbars in the matching palette.
    ~s"""
    <!DOCTYPE html>
    <html lang="#{lang}">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
        <meta name="color-scheme" content="light dark" />
        <meta name="supported-color-schemes" content="light dark" />
        <title>#{escape(title)}</title>
      </head>
      <body style="margin:0;padding:0;background-color:#{@canvas_light};color:#{@text_light};color-scheme:light dark;">
        <style>
          :root { color-scheme: light dark; supported-color-schemes: light dark; }
          @media (prefers-color-scheme: dark) {
            .email-canvas     { background-color: #{@canvas_dark} !important; }
            .email-card       { background-color: #{@card_dark} !important; border-color: #{@card_border_dark} !important; }
            .email-text       { color: #{@text_dark} !important; }
            .email-muted      { color: #{@muted_dark} !important; }
            .email-note-bg    { background-color: #{@note_bg_dark} !important; border-color: #{@note_border_dark} !important; }
            .email-note-text  { color: #{@note_text_dark} !important; }
            .email-footer     { color: #{@footer_text_dark} !important; }
          }
        </style>
        <!-- Outer canvas -->
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" class="email-canvas" style="background-color:#{@canvas_light};">
          <tr>
            <td align="center" style="padding:32px 16px;">

              <!-- Card -->
              <table role="presentation" width="560" cellpadding="0" cellspacing="0" border="0" class="email-card" style="width:560px;max-width:100%;background-color:#{@card_light};border:1px solid #{@card_border_light};border-radius:16px;">
                <!-- Brand header -->
                <tr>
                  <td style="padding:32px 40px 0 40px;">
                    <span style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:22px;font-weight:800;letter-spacing:-0.02em;color:#{@text_light};" class="email-text">
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
                  <td style="padding:20px 40px 0 40px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:24px;font-weight:800;letter-spacing:-0.02em;line-height:1.2;color:#{@text_light};" class="email-text">
                    #{escape(title)}
                  </td>
                </tr>
                <!-- Greeting + body -->
                <tr>
                  <td style="padding:12px 40px 0 40px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:16px;line-height:1.6;color:#{@muted_light};" class="email-muted">
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
                  <td align="center" style="padding:20px 40px 0 40px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:12px;line-height:1.5;color:#{@footer_text_light};" class="email-footer">
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
                  <a href="#{escape(url)}" target="_blank" style="display:inline-block;padding:14px 28px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#{@primary_text_on_color};text-decoration:none;border-radius:10px;">
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
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" class="email-note-bg" style="background-color:#{@note_bg_light};border:1px solid #{@note_border_light};border-radius:12px;">
              <tr>
                <td style="padding:14px 16px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:13px;line-height:1.55;color:#{@note_text_light};" class="email-note-text">
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
