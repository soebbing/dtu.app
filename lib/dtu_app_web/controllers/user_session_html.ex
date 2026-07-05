defmodule DtuAppWeb.UserSessionHTML do
  use DtuAppWeb, :html

  embed_templates "user_session_html/*"

  defp local_mail_adapter? do
    Application.get_env(:dtu_app, DtuApp.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
