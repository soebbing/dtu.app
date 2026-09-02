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

  # The Location section on `/users/settings` posts top-level
  # `latitude` / `longitude` strings (rendered as a `<form
  # action="update_location">` with hidden inputs the inline JS
  # populates from `navigator.geolocation.getCurrentPosition`).
  # We route them through the existing `Accounts.update_user_location/2`
  # rather than re-implementing validation here — that function
  # already enforces the WGS84 -90..90 / -180..180 bounds and
  # atomically nils both fields when either arrives nil, so a
  # corrupted payload can't leave a half-position in the DB.
  #
  # On `:error` we re-render `:edit` with the settings_changeset so
  # the form shows the friendly range error (the existing
  # `settings_changeset/2` already passes through any
  # `:latitude` / `:longitude` errors from the underlying validator).
  # We re-build that changeset from the user so the rest of the
  # page (€/kWh, locale) is in its initial state.
  def update(conn, %{"action" => "update_location"} = params) do
    user = conn.assigns.current_scope.user

    # The JS payload sends raw floats (`pos.coords.latitude` is a JS
    # Number → JSON number → Elixir float). Coerce to float here so
    # the validator doesn't have to deal with stringly-typed input
    # (which it would silently reject via the `is_number` guard).
    lat =
      case Map.get(params, "latitude") do
        nil ->
          nil

        v when is_number(v) ->
          v

        v ->
          case Float.parse(to_string(v)) do
            {f, _} -> f
            :error -> nil
          end
      end

    lon =
      case Map.get(params, "longitude") do
        nil ->
          nil

        v when is_number(v) ->
          v

        v ->
          case Float.parse(to_string(v)) do
            {f, _} -> f
            :error -> nil
          end
      end

    case Accounts.update_user_location(user, %{latitude: lat, longitude: lon}) do
      :ok ->
        conn
        |> put_flash(:info, gettext("Location updated successfully."))
        |> redirect(to: ~p"/users/settings")

      {:error, %Ecto.Changeset{} = location_changeset} ->
        # The failed changeset has `:latitude` / `:longitude` errors
        # we want the template to surface. We pass it through as a
        # separate `location_changeset` assign so the €/kWh / locale
        # `settings_changeset` stays in its initial state — they're
        # independent forms with independent validation lifecycles.
        conn = assign(conn, :location_changeset, location_changeset)

        render(conn, :edit, settings_changeset: Accounts.change_user_settings(user))
    end
  end

  # The "Clear" link posts empty coords through the same pipeline —
  # `Accounts.update_user_location/2` already handles the
  # nil-through case (drops both fields atomically), so we just
  # forward without the float-coercion dance.
  def update(conn, %{"action" => "clear_location"}) do
    user = conn.assigns.current_scope.user

    case Accounts.update_user_location(user, %{latitude: nil, longitude: nil}) do
      :ok ->
        conn
        |> put_flash(:info, gettext("Location cleared."))
        |> redirect(to: ~p"/users/settings")

      {:error, %Ecto.Changeset{} = location_changeset} ->
        # Clearing shouldn't fail (nil is always in range), but if a
        # concurrent write corrupted the row we re-render so the user
        # sees something rather than a 500.
        conn = assign(conn, :location_changeset, location_changeset)

        render(conn, :edit, settings_changeset: Accounts.change_user_settings(user))
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
    # The Location section has its own validation lifecycle
    # (the `update_location` / `clear_location` actions feed
    # `Accounts.update_user_location/2`, whose changesets are NOT
    # the same as `settings_changeset/2`). We default the assign
    # to `nil` on every GET / re-render so the template can render
    # without `if @location_changeset do ... end` exploding on a
    # fresh page load — the failed-update paths in `update/2`
    # overwrite the nil with the actual failed changeset.
    |> assign(:location_changeset, nil)
  end

  # The passkey card lives on the same page as the email/password/settings
  # forms, and every `render(conn, :edit, ...)` path above (including the
  # validation-failure re-renders) needs the list. A plug keeps the assign
  # in one place instead of threading it through four call sites.
  defp assign_passkeys(conn, _opts) do
    assign(conn, :passkeys, Accounts.list_passkeys(conn.assigns.current_scope.user))
  end
end
