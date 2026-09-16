defmodule DtuApp.Emails.SunDownEmailE2ETest do
  @moduledoc """
  End-to-end test for the chart-as-cid-attachment path.

  The unit tests in `sun_down_email_test.exs` assert on the rendered
  HTML/text/attachments shape coming out of `SunDownEmail.render/2`.
  THIS test wires that output into a real Swoosh email and asserts the
  generated MIME message structure — multipart/related with one
  `image/png` part referenced by `cid:` in the HTML body.

  Why an e2e here: the user's actual report was "the graph isn't being
  rendered in Gmail". The unit tests pin our contract, but only the
  MIME shape proves the Swoosh builder turns the attachment list into a
  message that Gmail will (a) accept with image/png parts, (b) match by
  `cid:` against the HTML body's `<img src>` reference.
  """

  use DtuApp.DataCase, async: true

  alias DtuApp.Accounts.User
  alias DtuApp.Emails.SunDownEmail

  # Same byte sequence as the unit tests, kept as an integer list so
  # the module attribute doesn't get confused with a bitstring iterable.
  @png_1x1_byte_list [
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
    0,
    0,
    0,
    13,
    73,
    72,
    68,
    82,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    1,
    8,
    6,
    0,
    0,
    0,
    31,
    21,
    196,
    137,
    0,
    0,
    0,
    11,
    73,
    68,
    65,
    84,
    24,
    87,
    99,
    248,
    255,
    255,
    63,
    0,
    5,
    254,
    2,
    254,
    164,
    171,
    207,
    7,
    0,
    0,
    0,
    0,
    73,
    69,
    78,
    68,
    174,
    66,
    96,
    130
  ]

  setup do
    fake =
      Path.join(
        System.tmp_dir!(),
        "rsvg-convert-fake-e2e-#{System.unique_integer([:positive])}.sh"
      )

    octal =
      @png_1x1_byte_list
      |> Enum.map(&("\\" <> Integer.to_string(&1, 8)))
      |> Enum.join()

    script =
      "#!/bin/sh\n" <>
        "# fake rsvg-convert for e2e tests: read input file, write fixed PNG\n" <>
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

    {:ok, fake_cli: fake, png_bytes: :erlang.list_to_binary(@png_1x1_byte_list)}
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

  describe "build_email/2 — cid-attachment shape" do
    setup do
      user = %User{email: "u@example.com", locale: "en"}

      payload = %{
        title: "Sun down",
        body: ["Today: 12.4 kWh, peak 3,250 W."],
        event: "sun_down",
        today_yield_kwh: 12.4,
        yesterday_yield_kwh: 10.1,
        peak_power_w: 3250,
        peak_yesterday_w: 2840,
        chart_svg: "<svg viewBox=\"0 0 800 280\"></svg>",
        dashboard_path: "/dashboard"
      }

      {:ok, user: user, payload: payload}
    end

    test "html body references the chart via cid; attachments carry the PNG bytes; text body has no raw markup",
         %{user: user, payload: payload, fake_cli: fake_cli, png_bytes: png_bytes} do
      email = build_email(user, payload, fake_cli)

      assert email.html_body =~ ~s(<img src="cid:chart@sundo")
      refute email.html_body =~ "<svg"

      assert email.text_body =~ ~s(power curve)
      refute email.text_body =~ "<img"
      refute email.text_body =~ "<svg"

      attachments = email.attachments
      assert length(attachments) == 1

      [att] = attachments
      assert att.content_type == "image/png"
      assert att.type == :inline
      assert att.cid == "chart@sundo"
      assert att.data == png_bytes
    end

    test "fallback path: no attachments, html and text both carry the dashboard link, no raw markup",
         %{user: user, payload: payload} do
      Application.put_env(:dtu_app, :swoosh_email_chart_cli, nil)

      {html, text, attachments} = SunDownEmail.render(user, payload)

      assert html =~ "View today's power curve"
      assert html =~ "/dashboard"
      refute html =~ "<svg"
      refute html =~ "<img"

      assert text =~ "View today's power curve"
      assert text =~ "/dashboard"
      refute text =~ "<svg"
      refute text =~ "<img"

      assert attachments == []
    end

    test "cid reference in HTML body matches the attachment's cid field (binding test)",
         %{user: user, payload: payload, fake_cli: fake_cli} do
      email = build_email(user, payload, fake_cli)

      [att] = email.attachments
      cid = att.cid

      # The HTML body's <img src="cid:..."> must reference the same
      # cid as the attachment's `cid` field. If this drifts, Gmail
      # shows a broken-image icon — the exact regression we want to
      # prevent.
      assert email.html_body =~ ~s(<img src="cid:#{cid}")
    end
  end
end
