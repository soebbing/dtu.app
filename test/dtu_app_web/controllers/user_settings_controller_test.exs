defmodule DtuAppWeb.UserSettingsControllerTest do
  use DtuAppWeb.ConnCase, async: true

  alias DtuApp.Accounts
  import DtuApp.AccountsFixtures

  setup :register_and_log_in_user

  describe "GET /users/settings" do
    test "renders settings page", %{conn: conn} do
      conn = get(conn, ~p"/users/settings")
      response = html_response(conn, 200)
      assert response =~ "Settings"
    end

    test "redirects if user is not logged in" do
      conn = build_conn()
      conn = get(conn, ~p"/users/settings")
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    @tag token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
    test "redirects if user is not in sudo mode", %{conn: conn} do
      conn = get(conn, ~p"/users/settings")
      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must re-authenticate to access this page."
    end
  end

  describe "PUT /users/settings (change password form)" do
    test "updates the user password and resets tokens", %{conn: conn, user: user} do
      new_password_conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_password",
          "user" => %{
            "password" => "new valid password",
            "password_confirmation" => "new valid password"
          }
        })

      assert redirected_to(new_password_conn) == ~p"/users/settings"

      assert get_session(new_password_conn, :user_token) != get_session(conn, :user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "does not update password on invalid data", %{conn: conn} do
      old_password_conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_password",
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      response = html_response(old_password_conn, 200)
      assert response =~ "Settings"
      assert response =~ "should be at least 12 character(s)"
      assert response =~ "does not match password"

      assert get_session(old_password_conn, :user_token) == get_session(conn, :user_token)
    end
  end

  describe "PUT /users/settings (change email form)" do
    @tag :capture_log
    test "updates the user email", %{conn: conn, user: user} do
      conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_email",
          "user" => %{"email" => unique_user_email()}
        })

      assert redirected_to(conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "A link to confirm your email"

      assert Accounts.get_user_by_email(user.email)
    end

    test "does not update email on invalid data", %{conn: conn} do
      conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_email",
          "user" => %{"email" => "with spaces"}
        })

      response = html_response(conn, 200)
      assert response =~ "Settings"
      assert response =~ "must have the @ sign and no spaces"
    end
  end

  describe "PUT /users/settings (energy rate form)" do
    # The energy-rate form on `/users/settings` posts a top-level
    # `euros_per_kwh` value (no `user` wrapper). The form is converted
    # to whole cents and stored in `users.cents_per_kwh`. The bug
    # we're guarding against: an empty form submission previously
    # surfaced the Ecto default `is invalid` error and the user saw
    # "invalid value" on every blank submit. The fix maps empty /
    # non-numeric input to `nil` so the field is silently cleared and
    # the user gets the success flash.

    test "persists a valid €/kWh value and redirects to settings", %{conn: conn, user: user} do
      conn =
        put(conn, ~p"/users/settings", %{"action" => "update_settings", "euros_per_kwh" => "0.32"})

      assert redirected_to(conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "Settings updated successfully"

      reloaded = Accounts.get_user!(user.id)
      assert reloaded.cents_per_kwh == 32
    end

    test "blank form clears the rate and does not show 'is invalid'", %{conn: conn, user: user} do
      # Set a rate first.
      {:ok, _} = Accounts.update_user_settings(user, %{"euros_per_kwh" => "0.45"})
      assert Accounts.get_user!(user.id).cents_per_kwh == 45

      # Submitting a blank form should clear the field, NOT surface
      # the cast-time "is invalid" error.
      conn =
        put(conn, ~p"/users/settings", %{"action" => "update_settings", "euros_per_kwh" => ""})

      assert redirected_to(conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "Settings updated successfully"

      reloaded = Accounts.get_user!(user.id)
      assert is_nil(reloaded.cents_per_kwh)
    end

    test "out-of-range value shows the friendly range error and keeps the rate", %{
      conn: conn,
      user: user
    } do
      # Sub-cent rates round to 0, which the changeset rejects with
      # the friendly range error rather than the Ecto default "is
      # invalid" message.
      conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_settings",
          "euros_per_kwh" => "0.001"
        })

      response = html_response(conn, 200)
      assert response =~ "Settings"
      assert response =~ "must be between €0.01 and €100"
      refute response =~ "is invalid"

      # The original rate (or nil) must be preserved.
      assert Accounts.get_user!(user.id).cents_per_kwh == user.cents_per_kwh
    end
  end

  describe "GET /users/settings/confirm-email/:token" do
    setup %{user: user} do
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{token: token, email: email}
    end

    test "updates the user email once", %{conn: conn, user: user, token: token, email: email} do
      conn = get(conn, ~p"/users/settings/confirm-email/#{token}")
      assert redirected_to(conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "Email changed successfully"

      refute Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(email)

      conn = get(conn, ~p"/users/settings/confirm-email/#{token}")

      assert redirected_to(conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "Email change link is invalid or it has expired"
    end

    test "does not update email with invalid token", %{conn: conn, user: user} do
      conn = get(conn, ~p"/users/settings/confirm-email/oops")
      assert redirected_to(conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "Email change link is invalid or it has expired"

      assert Accounts.get_user_by_email(user.email)
    end

    test "redirects if user is not logged in", %{token: token} do
      conn = build_conn()
      conn = get(conn, ~p"/users/settings/confirm-email/#{token}")
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end
end
