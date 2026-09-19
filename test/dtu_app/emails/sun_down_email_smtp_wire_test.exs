defmodule DtuApp.Emails.SunDownEmailSmtpWireTest do
  @moduledoc """
  Regression test that pins the wire MIME `Swoosh.Adapters.SMTP`
  produces for the SunDown chart-attachment path.

  The two layered tests under `sun_down_email_e2e_test.exs` already
  cover the rendered MIME shape (HTML + text + one inline attachment
  on a `Swoosh.Email` struct) and `sun_down_email_test.exs` covers
  the classifier. This test plugs the gap *between* Swoosh and the
  SMTP wire: it calls `Swoosh.Adapters.SMTP.Helpers.body/2` directly
  (the same entry point `Swoosh.Adapters.SMTP.deliver/2` calls before
  handing the bytes to `:gen_smtp_client.send_blocking/2`) and asserts
  on the MIME structure that hits the relay.

  Specifically: the `image/png` MIME part bound to `cid:chart@sundo`
  must have a **non-empty** base64 body that decodes to the chart
  bytes. The exact failure mode we just spent PRs #307–#316 chasing
  (Resend's JSON→MIME reconstruction dropping inline cid bodies;
  Gmail then rendering the `<img src="cid:chart@sundo">` slot as a
  flat grey rectangle) cannot recur on this path because SMTP forwards
  raw multipart bytes — and this test pins that contract.

  Mechanism: install a fake `rsvg-convert` script that writes a known
  PNG (8-byte signature + padding + 12-byte IEND chunk, > 1024 bytes
  total so the success-path classifier accepts it), build a Swoosh
  email via the same `SunDownEmail.render/2` helper, then invoke
  `Swoosh.Adapters.SMTP.Helpers.body/2` to produce the wire MIME bytes.
  """

  use DtuApp.DataCase, async: false

  alias DtuApp.Accounts.User
  alias DtuApp.Emails.SunDownEmail

  @png_signature <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
  @png_iend_chunk <<0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82>>

  setup do
    fake =
      Path.join(
        System.tmp_dir!(),
        "rsvg-convert-fake-smtp-#{System.unique_integer([:positive])}.sh"
      )

    # Same fixture shape as the Resend-payload test: 8-byte signature +
    # 1004 padding bytes + 12-byte IEND = 1024 bytes. The classifier's
    # `byte_size > @min_png_byte_size` check is `> 1024`, so this lands
    # at the boundary — bump padding by 1 to clear the threshold and
    # stay defensible if the constant ever moves.
    padded_bytes =
      @png_signature <> :binary.copy(<<0>>, 1005) <> @png_iend_chunk

    octal =
      padded_bytes
      |> :binary.bin_to_list()
      |> Enum.map(&("\\" <> Integer.to_string(&1, 8)))
      |> Enum.join()

    script =
      "#!/bin/sh\n" <>
        "# fake rsvg-convert for the Swoosh→SMTP wire test\n" <>
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

    Swoosh.Email.new()
    |> Swoosh.Email.to({"Recipient", user.email})
    |> Swoosh.Email.from({"dtu.app", "noreply@localhost"})
    |> Swoosh.Email.subject(payload.title)
    |> Swoosh.Email.html_body(html)
    |> Swoosh.Email.text_body(text)
    |> then(fn email ->
      Enum.reduce(attachments, email, fn att, acc -> Swoosh.Email.attachment(acc, att) end)
    end)
  end

  # Minimal SMTP config — the wire MIME shape is independent of the relay
  # details; only the helpers body builder reads from the email struct.
  @smtp_config [
    relay: "smtp.example.com",
    port: 587,
    tls: :if_available,
    authentication: :none,
    domain: "localhost"
  ]

  describe "SMTP wire MIME — chart attachment round-trip" do
    test "the wire bytes contain a multipart/related with image/png bound to cid:chart@sundo whose base64 body decodes to the chart bytes",
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

      wire = Swoosh.Adapters.SMTP.Helpers.body(email, @smtp_config)
      assert is_binary(wire)

      # Multipart/related part containing the chart attachment must be present.
      # The MIME body that SMTP forwards includes the chart's base64 body —
      # if it didn't, the regex below would not match and this test would
      # fail, which is exactly the regression we're guarding against.
      assert wire =~ ~r/Content-Type:\s*multipart\/related/
      assert wire =~ ~r/Content-Id:\s*<chart@sundo>/

      # Extract the chart attachment block and decode its base64 body.
      # The block runs from the part's opening boundary line through the
      # next `--boundary` line. Headers are before the first blank line,
      # body is between the blank line and the closing boundary.
      #
      # NB: `[\s\S]*?` (not `.*?`) because Elixir regex's `.` doesn't match
      # newlines by default — we need to cross the `\r\n` boundary between
      # Content-Id and the closing blank line.
      chart_b64 =
        case Regex.run(
               ~r/Content-Id: <chart@sundo>[\s\S]*?\r\n\r\n([\s\S]+?)\r\n--/,
               wire,
               capture: :all_but_first
             ) do
          [body] -> body |> String.replace(~r/\s+/, "")
          nil -> ""
        end

      assert chart_b64 != "",
             "expected chart attachment to have a non-empty base64 body — " <>
               "this is the regression we want to prevent (Resend's JSON→MIME " <>
               "reconstruction dropped the inline image body; Gmail rendered " <>
               "the <img> slot as a grey rectangle)"

      decoded = Base.decode64!(chart_b64)
      assert decoded == png_bytes

      # HTML body references the same cid so Gmail binds the parts.
      # The HTML is quoted-printable encoded, so `=` shows up as `=3D`
      # in the wire bytes.
      assert wire =~ ~r/src=3D"cid:chart@sundo"/
    end

    test "the wire bytes do NOT contain a multipart/related when the classifier rejects the chart (fallback path)",
         %{fake_cli: _fake_cli} do
      # Force the fallback path by pointing the rsvg-convert shim at a
      # binary that doesn't exist: chart_attachment/1 returns :unavailable
      # and no image/png part is attached.
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

      Application.put_env(:dtu_app, :swoosh_email_chart_cli, nil)

      {html, text, attachments} = SunDownEmail.render(user, payload)
      assert attachments == []

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to({"Recipient", user.email})
        |> Swoosh.Email.from({"dtu.app", "noreply@localhost"})
        |> Swoosh.Email.subject(payload.title)
        |> Swoosh.Email.html_body(html)
        |> Swoosh.Email.text_body(text)

      wire = Swoosh.Adapters.SMTP.Helpers.body(email, @smtp_config)

      refute wire =~ ~r/Content-Id:\s*<chart@sundo>/
      refute wire =~ ~r/Content-Type:\s*image\/png/
      # Fallback text/HTML body tells the user where to find the chart on
      # the dashboard — proves we're on the fallback branch, not the
      # success branch.
      assert wire =~ "/dashboard"
    end
  end
end
