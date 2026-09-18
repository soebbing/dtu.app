defmodule DtuApp.Emails.SunDownEmailResendPayloadTest do
  @moduledoc """
  Regression test that pins the JSON shape `Swoosh.Adapters.Resend`
  sends to `api.resend.com` for the SunDown chart-attachment path.

  The two layered tests under `sun_down_email_e2e_test.exs` already
  cover the rendered MIME shape (HTML + text + one inline attachment
  on a `Swoosh.Email` struct) and `sun_down_email_test.exs` covers the
  classifier. This test plugs the gap *between* Swoosh and Resend:
  if a future Swoosh upgrade breaks the JSON envelope (drops
  `content_id`, double-base64-encodes the body, etc.) we want the
  test to fire here, not from a "Gmail shows blank" bug report.

  Mechanism: install a fake `:swoosh, :api_client` that captures the
  POST body, switch the Mailer adapter to `Swoosh.Adapters.Resend`
  for the duration of the test, and assert on the decoded body.
  """

  # async: false — we mutate global Swoosh / Mailer config in setup.
  use DtuApp.DataCase, async: false

  alias DtuApp.Accounts.User
  alias DtuApp.Emails.SunDownEmail
  alias DtuApp.Mailer

  # Capturing fake — implements the `Swoosh.ApiClient` behaviour so
  # `Swoosh.Adapters.Resend.deliver/2` thinks it talked to api.resend.com.
  # We forward `{url, headers, body}` to the test process so the test
  # process (not the adapter) can deserialize and assert.
  defmodule Capture do
    @behaviour Swoosh.ApiClient

    @impl true
    def init, do: :ok

    @impl true
    def post(url, headers, body, _email) do
      send(self(), {:swoosh_post, url, headers, body})
      {:ok, 200, [], ~s({"id":"capture-id"})}
    end
  end

  # The classifier in `chart_attachment/1` only checks three things:
  #
  #   1. PNG signature `89 50 4E 47 0D 0A 1A 0A` at offset 0,
  #   2. byte_size > @min_png_byte_size (1024),
  #   3. trailing 12-byte IEND chunk `00 00 00 00 49 45 4E 44 AE 42 60 82`.
  #
  # The IDAT contents are not validated — so we use a 1 KB zero-padded
  # body between the signature and the IEND chunk. This keeps the
  # fixture stable (no hardcoded CRC bytes that drift across runs)
  # and decoupled from the actual `rsvg-convert` output.
  @png_signature <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
  @png_iend_chunk <<0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82>>

  setup do
    # Save the env-supplied config so we can restore on_exit. The
    # test profile sets adapter=Swoosh.Adapters.Test + api_client=false;
    # we override here so the Resend adapter runs end-to-end against
    # our capture client.
    original_adapter = Application.get_env(:dtu_app, DtuApp.Mailer) || []
    original_api_client = Application.get_env(:swoosh, :api_client)

    Application.put_env(
      :dtu_app,
      DtuApp.Mailer,
      adapter: Swoosh.Adapters.Resend,
      api_key: "capture-key"
    )

    Application.put_env(:swoosh, :api_client, Capture)

    on_exit(fn ->
      Application.put_env(:dtu_app, DtuApp.Mailer, original_adapter)
      Application.put_env(:swoosh, :api_client, original_api_client)
    end)

    fake =
      Path.join(
        System.tmp_dir!(),
        "rsvg-convert-fake-resend-#{System.unique_integer([:positive])}.sh"
      )

    # Construct the fixture PNG: 8-byte signature + 1000 zero padding
    # bytes + 12-byte IEND chunk = 1020 bytes total. That clears the
    # > 1024 floor... actually 1020 < 1024, so bump the padding.
    padded_bytes =
      @png_signature <> :binary.copy(<<0>>, 1004) <> @png_iend_chunk

    octal =
      padded_bytes
      |> :binary.bin_to_list()
      |> Enum.map(&("\\" <> Integer.to_string(&1, 8)))
      |> Enum.join()

    script =
      "#!/bin/sh\n" <>
        "# fake rsvg-convert for the Swoosh→Resend payload test\n" <>
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

  describe "Resend JSON envelope — chart attachment round-trip" do
    test "the POST body has exactly one inline attachment whose base64 decodes to the chart bytes",
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

      # Drive the same path the prod `:web_push`-style release uses:
      # `Swoosh.Mailer.deliver/2` → configured adapter → configured api_client.
      assert {:ok, %{id: "capture-id"}} = Mailer.deliver(email)

      assert_receive {:swoosh_post, url, headers, body}, 1_000

      # URL/headers — the Resend adapter posts to https://api.resend.com/emails
      # with a Bearer auth header and JSON content-type. These two
      # assertions exist to catch a future Swoosh change that retargets
      # the adapter (e.g. swaps to a different endpoint).
      assert url == ["https://api.resend.com", "/emails"]
      assert {"Authorization", "Bearer capture-key"} in headers
      assert {"Content-Type", "application/json"} in headers

      decoded = Jason.decode!(body)

      # Inline-attachment contract — exactly one image/png attachment,
      # bound to the HTML body via `content_id` matching `cid:chart@sundo`.
      # If Swoosh stops emitting `content_id`, Gmail renders a broken
      # image icon (the regression we just spent two PRs fixing).
      assert [
               %{
                 "filename" => "chart.png",
                 "content_id" => "chart@sundo",
                 "content" => content_b64
               }
             ] = decoded["attachments"]

      # Byte-perfect base64 round-trip. If Swoosh ever double-encodes
      # (or stops base64-encoding at all), Gmail receives a malformed
      # image/png part — the "Body empty in Show Original" failure
      # mode we already saw twice.
      assert is_binary(content_b64)
      assert Base.decode64!(content_b64) == png_bytes

      # HTML body must reference the same cid so Gmail binds the parts.
      assert decoded["html"] =~ ~s(<img src="cid:chart@sundo")
    end
  end
end
