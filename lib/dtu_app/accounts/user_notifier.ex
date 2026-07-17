defmodule DtuApp.Accounts.UserNotifier do
  import Swoosh.Email

  alias DtuApp.Mailer
  alias DtuApp.Accounts.User

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(mail_from())
      |> subject(subject)
      |> text_body(body)

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

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
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
    deliver(user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end
end
