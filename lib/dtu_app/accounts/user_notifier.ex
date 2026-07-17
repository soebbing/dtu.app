defmodule DtuApp.Accounts.UserNotifier do
  @moduledoc """
  Delivers transactional emails (magic-link login, account confirmation,
  email change). Each email has both an HTML body rendered by
  `DtuApp.Emails.Layout` and a plain-text fallback.
  """

  import Swoosh.Email

  alias DtuApp.Emails.Layout
  alias DtuApp.Mailer
  alias DtuApp.Accounts.User

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions",
      title: "Update your email",
      greeting: "Hi #{user.email},",
      body: [
        "You can change your email address by clicking the button below. This link expires shortly.",
        "If the button doesn't work, copy and paste this link into your browser:"
      ],
      button: %{label: "Update email", url: url},
      note: "If you didn't request this change, you can safely ignore this email."
    )
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Log in to dtu.app",
      title: "Log in",
      greeting: "Hi #{user.email},",
      body: [
        "Click the button below to log in to your account. This link can only be used once and expires shortly.",
        "If the button doesn't work, copy and paste this link into your browser:"
      ],
      button: %{label: "Log in", url: url},
      note: "If you didn't try to log in, you can safely ignore this email — no one else can access your account without this link."
    )
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirm your dtu.app account",
      title: "Confirm your account",
      greeting: "Hi #{user.email},",
      body: [
        "Welcome to dtu.app! Confirm your email address to activate your account by clicking the button below.",
        "If the button doesn't work, copy and paste this link into your browser:"
      ],
      button: %{label: "Confirm account", url: url},
      note: "If you didn't create an account with us, you can safely ignore this email."
    )
  end

  # Delivers the email using the application mailer. `opts` describe the content
  # (see DtuApp.Emails.render/1); both an HTML and a plain-text body are set.
  defp deliver(recipient, subject, opts) do
    {html, text} = Layout.render(opts)

    email =
      new()
      |> to(recipient)
      |> from(mail_from())
      |> subject(subject)
      |> html_body(html)
      |> text_body(text)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  # Sender address, configured via MAIL_FROM (see config/runtime.exs). Must be
  # on a domain verified by the transactional provider (Resend). Accepts a
  # plain address ("a@b.com") or a named form ("Name <a@b.com>"); the latter is
  # parsed into the {"Name", "a@b.com"} tuple Swoosh's from/1 expects.
  defp mail_from do
    mail_from = Application.get_env(:dtu_app, :mail_from, "DtuApp <noreply@localhost>")

    case Regex.run(~r/^\s*(.*?)\s*<([^>]+)>\s*$/, mail_from, capture: :all_but_first) do
      [name, address] -> {name, address}
      _ -> mail_from
    end
  end
end