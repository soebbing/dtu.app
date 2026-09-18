defmodule DtuApp.Emails.SunDownEmailSmtpPayloadTest do
  @moduledoc """
  Pairs with `sun_down_email_resend_payload_test.exs`. That test pins
  the JSON shape Swoosh hands to `api.resend.com`; this one pins the
  raw MIME bytes Swoosh's SMTP adapter would put on the wire when the
  Mailer is configured to talk to Resend's SMTP endpoint
  (`smtp.resend.com:587`).

  **Why this test exists:** on the JSON path, Resend reconstructs the
  MIME from our `attachments[].content` + `content_id`, and the
  reconstructed `image/png` part arrives at Gmail with all the right
  headers (`Content-ID: <chart@sundo>`, `Content-Disposition: inline`,
  `Content-Transfer-Encoding: base64`) but an **empty body**. The PNG
  bytes that Swoosh shipped in `attachments[0].content` are gone by
  the time the email lands in the inbox, and Gmail renders a flat
  grey rectangle in the chart slot. Switching to SMTP bypasses that
  reconstruction — Resend forwards the raw multipart/related we build
  on the wire, so the inline image body is preserved.

  This test calls `Swoosh.Adapters.SMTP.Helpers.body/2` directly (it's
  `@doc false` but `def`) with the SMTP adapter's own config shape so
  we can assert on the bytes *without* opening a real TCP connection
  to `smtp.resend.com`. If a future Swoosh change ever drops inline
  attachment content from the wire MIME, this test fails — and the
  same bug won't show up as a "Gmail shows blank" report three weeks
  later.
  """

  use DtuApp.DataCase, async: true

  alias DtuApp.Accounts.User
  alias DtuApp.Emails.SunDownEmail

  # The classifier in `chart_attachment/1` only checks three things:
  #
  #   1. PNG signature `89 50 4E 47 0D 0A 1A 0A` at offset 0,
  #   2. byte_size > @min_png_byte_size (1024),
  #   3. trailing 12-byte IEND chunk `00 00 00 00 49 45 4E 44 AE 42 60 82`.
  #
  # IDAT contents are not validated — so a 1 KB zero-padded body
  # between the signature and the IEND chunk is enough.
  @png_signature <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
  @png_iend_chunk <<0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82>>

  setup do
    fake =
      Path.join(
        System.tmp_dir!(),
        "rsvg-convert-fake-smtp-#{System.unique_integer([:positive])}.sh"
      )

    # 8-byte signature + 1004 zero-padding + 12-byte IEND = 1024 bytes
    # — clears the > 1024 floor (`@min_png_byte_size`).
    padded_bytes =
      @png_signature <> :binary.copy(<<0>>, 1004) <> @png_iend_chunk

    octal =
      padded_bytes
      |> :binary.bin_to_list()
      |> Enum.map(&("\\" <> Integer.to_string(&1, 8)))
      |> Enum.join()

    script =
      "#!/bin/sh\n" <>
        "# fake rsvg-convert for the Swoosh SMTP payload test\n" <>
        "OUT=\"\"\n" <>
        "INPUT=\"\"\n" <>
        "while [ $# -gt 0 ]; do\n" <>
        "  case \"$1\" in\n" <>
        "    -o) OUT=\"$2\"; shift 2;;\n" <>
        "    *) [ -z \"$INPUT\" ] && [ -f \"$1\" ] && INPUT=\"$1\"; shift;;\n" <>
        "  esac\n" <>
        "done\n" <>
        "printf '" <> octal <> "' > \"$OUT\"\n"

    File.write!(fake, script)
    File.chmod!(fake, 0o755)

    on_exit(fn -> File.rm(fake) end)

    {:ok, fake_cli: fake, png_bytes: padded_bytes}
  end

  defp build_email(user, payload, fake_cli) do
    Application.put_env(:dtu_app, :swoosh_email_chart_cli, fake_cli)
    {html, text, attachments} = SunDownEmail.render(user, payload)

    email =
      Swoosh.Email.new()
      |> Swoosh.Email.to({"Recipient", user.email})
      |> Swoosh.Email.from({"dtu.app", "noreply@localhost"})
      |> Swoosh.Email.subject(payload.title)
      |> Swoosh.Email.html_body(html)
      |> Swoosh.Email.text_body(text)

    Enum.reduce(attachments, email, fn att, acc -> Swoosh.Email.attachment(acc, att) end)
  end

  describe "SMTP wire MIME — chart attachment round-trip" do
    test "the SMTP adapter's body includes the chart attachment bytes (not just headers)",
         %{fake_cli: fake_cli, png_bytes: png_bytes} do
      user = %User{email: "u@example.com", locale: "en"}

      payload = %{
        title: "Sun down",
        body: ["Today: 12.4 kWh, peak 3,250 W."],
        event: "sun_down",
        today_yield_kwh: 12.4,
        yesterday_yield_kwh: 10.1,
        peak_power_w: 3250,
        peak_yesterday_w: 2840,
        chart_svg: ~s(<svg viewBox="0 0 800 280"></svg>),
        dashboard_path: "/dashboard"
      }

      email = build_email(user, payload, fake_cli)

      # The SMTP adapter accepts a config that mirrors the runtime
      # values from `config/runtime.exs` (relay, port, auth, etc.).
      # We don't talk to the network — we only invoke the body
      # builder, which assembles the multipart/related bytes from the
      # Swoosh.Email struct + attachments.
      smtp_config = [
        relay: "smtp.resend.com",
        port: 587,
        username: "resend",
        password: "test-key",
        tls: :always,
        auth: :always,
        domain: "resend.dev",
        retries: 2
      ]

      body = Swoosh.Adapters.SMTP.Helpers.body(email, smtp_config)
      assert is_binary(body)

      # The wire MIME must reference the cid we wired into the
      # `<img src>` tag and into the attachment's `cid:` field. If
      # Swoosh ever drops either side, Gmail's broken-image icon
      # reappears. The HTML part goes through quoted-printable
      # encoding (`=` -> `=3D`, line-wraps at 76 chars with `=\r\n`)
      # so the `<img src="cid:chart@sundo">` substring may be split
      # across a line break. The `cid:chart@sundo` token itself
      # contains no `=` so it survives unchanged — match just that.
      assert body =~ "cid:chart@sundo"
      assert body =~ ~s(Content-Id: <chart@sundo>)
      assert body =~ "Content-Disposition: inline"
      assert body =~ "Content-Transfer-Encoding: base64"

      # **The actual fix.** The base64-encoded PNG must be in the
      # wire body — that's the difference between the SMTP path
      # (where we ship our own MIME) and the JSON path (where Resend
      # reconstructs it and loses the body). The PNG signature
      # appears as the first 8 bytes of the decoded attachment, so
      # the base64 in the wire body must start with `iVBORw0K` (the
      # base64 of `89 50 4E 47 0D 0A 1A 0A`). The base64 part is
      # the raw attachment body, not quoted-printable-encoded, so
      # `iVBORw0K` is searchable verbatim.
      assert body =~ "iVBORw0K"

      # Round-trip: extract the base64 body for `chart.png`, decode,
      # and confirm we get back the exact bytes `chart_attachment/1`
      # produced. If this drifts (e.g. Swoosh starts base64-encoding
      # twice, or truncates the body for very large attachments),
      # the test fails here, not from a Gmail bug report.
      #
      # MIME uses CRLF (`\r\n`) per RFC 5322, and the base64 part is
      # line-wrapped at 76 chars — so the body spans multiple lines
      # separated by `\r\n`. We grab everything between the
      # attachment's blank separator line and the next MIME
      # boundary, then strip the whitespace.
      [_headers, b64_block] =
        Regex.run(
          ~r/Content-Id: <chart@sundo>.*?\r\n\r\n([A-Za-z0-9+\/=\r\n]+?)\r\n--/s,
          body
        ) ||
          flunk("no base64 body found for chart@sundo attachment")

      decoded = b64_block |> String.replace(~r/\s/, "") |> Base.decode64!()

      assert decoded == png_bytes,
             "expected #{byte_size(png_bytes)} bytes, got #{byte_size(decoded)}"
    end
  end
end
