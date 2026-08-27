defmodule DtuAppWeb.UserSettingsController do
  use DtuAppWeb, :controller

  alias DtuApp.Accounts
  alias DtuAppWeb.UserAuth

  import DtuAppWeb.UserAuth, only: [require_sudo_mode: 2]

  plug :require_sudo_mode
  plug :assign_email_and_password_changesets
  plug :assign_settings_changeset
  plug :assign_passkeys

  def edit(conn, _params) do
    render(conn, :edit)
  end

  def update(conn, %{"action" => "update_email"} = params) do
    %{"user" => user_params} = params
    user = conn.assigns.current_scope.user

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        conn
        |> put_flash(
          :info,
          gettext("A link to confirm your email change has been sent to the new address.")
        )
        |> redirect(to: ~p"/users/settings")

      changeset ->
        render(conn, :edit, email_changeset: %{changeset | action: :insert})
    end
  end

  def update(conn, %{"action" => "update_password"} = params) do
    %{"user" => user_params} = params
    user = conn.assigns.current_scope.user

    case Accounts.update_user_password(user, user_params) do
      {:ok, {user, _}} ->
        conn
        |> put_flash(:info, gettext("Password updated successfully."))
        |> put_session(:user_return_to, ~p"/users/settings")
        |> UserAuth.log_in_user(user)

      {:error, changeset} ->
        render(conn, :edit, password_changeset: changeset)
    end
  end

  def update(conn, %{"action" => "update_settings"} = params) do
    user = conn.assigns.current_scope.user

    case Accounts.update_user_settings(user, params) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, gettext("Settings updated successfully."))
        |> redirect(to: ~p"/users/settings")

      {:error, changeset} ->
        render(conn, :edit, settings_changeset: changeset)
    end
  end

  def confirm_email(conn, %{"token" => token}) do
    case Accounts.update_user_email(conn.assigns.current_scope.user, token) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, gettext("Email changed successfully."))
        |> redirect(to: ~p"/users/settings")

      {:error, _} ->
        conn
        |> put_flash(:error, gettext("Email change link is invalid or it has expired."))
        |> redirect(to: ~p"/users/settings")
    end
  end

  @doc """
  Removes a passkey owned by the current user. A passkey belonging to
  a different user (or one that no longer exists) is indistinguishable
  from a missing one: both render 404.

  POST `/users/settings/passkeys/:id/delete`
  """
  def delete_passkey(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user

    result =
      case Accounts.get_user_passkey(user, id) do
        nil -> {:error, :not_found}
        passkey -> Accounts.delete_passkey(user, passkey)
      end

    case result do
      :ok ->
        conn
        |> put_flash(:info, gettext("Passkey removed."))
        |> redirect(to: ~p"/users/settings")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(DtuAppWeb.ErrorHTML)
        |> put_root_layout(html: false)
        |> put_layout(html: false)
        |> render(:"404")
    end
  end

  defp assign_email_and_password_changesets(conn, _opts) do
    user = conn.assigns.current_scope.user

    conn
    |> assign(:email_changeset, Accounts.change_user_email(user))
    |> assign(:password_changeset, Accounts.change_user_password(user))
  end

  # Pre-build the settings changeset for the GET so the form can
  # redisplay on validation failure. The form posts `euros_per_kwh`
  # directly (not under the `user` key) because it's a single
  # top-level field rather than a User-schema shape; this matches
  # the existing email/password forms' top-level shapes.
  defp assign_settings_changeset(conn, _opts) do
    user = conn.assigns.current_scope.user

    conn
    |> assign(:settings_changeset, Accounts.change_user_settings(user))
  end

  # The passkey card lives on the same page as the email/password/settings
  # forms, and every `render(conn, :edit, ...)` path above (including the
  # validation-failure re-renders) needs the list. A plug keeps the assign
  # in one place instead of threading it through four call sites.
  defp assign_passkeys(conn, _opts) do
    assign(conn, :passkeys, Accounts.list_passkeys(conn.assigns.current_scope.user))
  end
end
