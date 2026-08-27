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

    test "prefills the €/kWh input with the user's stored rate", %{conn: conn, user: user} do
      # Set a rate via the public API, then GET the page. The input
      # must render with the stored value (e.g. "0.32" for 32 cents).
      # The previous template only matched `{:changes, _}`, which is
      # never populated on a fresh GET — so the field rendered empty
      # every time, making the user wonder if their saved value had
      # actually stuck.
      {:ok, _} = Accounts.update_user_settings(user, %{"euros_per_kwh" => "0.32"})

      conn = get(conn, ~p"/users/settings")
      response = html_response(conn, 200)

      # The exact regex is `<input ... value="0.32" ...>` (the
      # template uses `:erlang.float_to_binary/2` with `decimals: 2`
      # for stable formatting). Match the input by id and check its
      # rendered value attribute.
      assert response =~ ~r/<input[^>]*\bid="euros_per_kwh"[^>]*\bvalue="0\.32"/
    end

    test "leaves the €/kWh input empty when the user has no stored rate", %{conn: conn} do
      # The seed/fixture user has cents_per_kwh == nil. The GET must
      # render an input with an empty `value=""` attribute (the
      # placeholder "0.32" stays visible, but no actual stored value
      # is shown).
      conn = get(conn, ~p"/users/settings")
      response = html_response(conn, 200)

      assert response =~ ~r/<input[^>]*\bid="euros_per_kwh"[^>]*\bvalue=""/,
             "expected the empty-value input attribute when user has no rate"
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

  describe "PUT /users/settings (language dropdown)" do
    # The locale `<.input type="select">` posts a top-level `locale`
    # value alongside `euros_per_kwh` (or on its own). The
    # `settings_changeset/2` reads `attrs["locale"]` directly, casts
    # it against `@supported_locales`, and persists via the standard
    # update path. This shape mirrors the energy-rate test above:
    # one form, two optional fields, same routing.

    test "persists the chosen locale and prefills it on subsequent GETs", %{
      conn: conn,
      user: user
    } do
      # The fixture user starts with locale "en" (the column default).
      assert user.locale == "en"

      conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_settings",
          "locale" => "de"
        })

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Settings updated successfully"

      assert Accounts.get_user!(user.id).locale == "de"

      # Re-fetch the page — the dropdown must reflect the new value
      # so the user can see their choice persisted (and re-submit to
      # change it back without losing context).
      conn = get(conn, ~p"/users/settings")
      response = html_response(conn, 200)

      # Phoenix's <.input type="select"> renders the active option
      # as `<option selected value="de">Deutsch</option>` (note:
      # attribute order is `selected` before `value`, no space
      # before the closing `>`). We assert the right option is
      # marked selected — the user-visible labels are gettext strings
      # whose rendered form depends on the current process locale
      # (the test fixture's user is "de" by the time this assertion
      # runs, so the labels render in German), so we don't pin them.
      assert response =~ ~r|<option\s+selected\s+value="de">[^<]*</option>|

      # And the other two options are NOT selected.
      refute response =~ ~r|<option\s+selected\s+value="en">|
      refute response =~ ~r|<option\s+selected\s+value="fr">|
    end

    test "submitting a rate and a locale together persists both", %{conn: conn, user: user} do
      conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_settings",
          "euros_per_kwh" => "0.30",
          "locale" => "fr"
        })

      assert redirected_to(conn) == ~p"/users/settings"

      reloaded = Accounts.get_user!(user.id)
      assert reloaded.cents_per_kwh == 30
      assert reloaded.locale == "fr"
    end

    test "submitting an unsupported locale redisplayes the form with the inclusion error", %{
      conn: conn,
      user: user
    } do
      # The select dropdown only offers supported locales, but a
      # hand-crafted curl POST (or a future addition to the dropdown
      # that wasn't validated upstream) must still hit the changeset
      # guard. The user keeps their stored locale and sees the
      # friendly error.
      conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_settings",
          "locale" => "klingon"
        })

      response = html_response(conn, 200)
      assert response =~ "must be one of: en, de, fr"

      # Locale unchanged — the failed cast must NOT have written
      # anything to the row.
      assert Accounts.get_user!(user.id).locale == user.locale
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

  describe "POST /users/settings/passkeys/:id/delete" do
    test "deletes the passkey and redirects with a flash", %{conn: conn, user: user} do
      pk = passkey_fixture(user, %{})

      conn = post(conn, ~p"/users/settings/passkeys/#{pk.id}/delete")

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Passkey removed"
      refute DtuApp.Repo.get(DtuApp.Accounts.Passkey, pk.id)
    end

    test "404s and keeps the row when the passkey belongs to another user", %{conn: conn} do
      other_pk = passkey_fixture(user_fixture(), %{})

      conn = post(conn, ~p"/users/settings/passkeys/#{other_pk.id}/delete")

      assert conn.status == 404
      assert DtuApp.Repo.get(DtuApp.Accounts.Passkey, other_pk.id)
    end

    test "404s when the passkey does not exist", %{conn: conn} do
      conn = post(conn, ~p"/users/settings/passkeys/#{Ecto.UUID.generate()}/delete")
      assert conn.status == 404
    end

    test "404s on a non-UUID id instead of raising", %{conn: conn} do
      conn = post(conn, ~p"/users/settings/passkeys/not-a-uuid/delete")
      assert conn.status == 404
    end

    test "redirects if the user is not logged in" do
      conn = post(build_conn(), ~p"/users/settings/passkeys/#{Ecto.UUID.generate()}/delete")
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end
end
