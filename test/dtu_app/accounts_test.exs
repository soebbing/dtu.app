defmodule DtuApp.AccountsTest do
  use DtuApp.DataCase

  alias DtuApp.Accounts

  import DtuApp.AccountsFixtures
  alias DtuApp.Accounts.{User, UserToken}

  describe "get_user_by_email/1" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email("unknown@example.com")
    end

    test "returns the user if the email exists" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user_by_email(user.email)
    end
  end

  describe "get_user_by_email_and_password/2" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email_and_password("unknown@example.com", "hello world!")
    end

    test "does not return the user if the password is not valid" do
      user = user_fixture() |> set_password()
      refute Accounts.get_user_by_email_and_password(user.email, "invalid")
    end

    test "returns the user if the email and password are valid" do
      %{id: id} = user = user_fixture() |> set_password()

      assert %User{id: ^id} =
               Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end
  end

  describe "get_user!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!(-1)
      end
    end

    test "returns the user with the given id" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user!(user.id)
    end
  end

  describe "register_user/1" do
    test "requires email to be set" do
      {:error, changeset} = Accounts.register_user(%{})

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates email when given" do
      {:error, changeset} = Accounts.register_user(%{email: "not valid"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "validates maximum values for email for security" do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Accounts.register_user(%{email: too_long})
      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "validates email uniqueness" do
      %{email: email} = user_fixture()
      {:error, changeset} = Accounts.register_user(%{email: email})
      assert "has already been taken" in errors_on(changeset).email

      # Now try with the uppercased email too, to check that email case is ignored.
      {:error, changeset} = Accounts.register_user(%{email: String.upcase(email)})
      assert "has already been taken" in errors_on(changeset).email
    end

    test "registers users without password" do
      email = unique_user_email()
      {:ok, user} = Accounts.register_user(valid_user_attributes(email: email))
      assert user.email == email
      assert is_nil(user.hashed_password)
      assert is_nil(user.confirmed_at)
      assert is_nil(user.password)
    end
  end

  describe "sudo_mode?/2" do
    test "validates the authenticated_at time" do
      now = DateTime.utc_now()

      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.utc_now()})
      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -19, :minute)})
      refute Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -21, :minute)})

      # minute override
      refute Accounts.sudo_mode?(
               %User{authenticated_at: DateTime.add(now, -11, :minute)},
               -10
             )

      # not authenticated
      refute Accounts.sudo_mode?(%User{})
    end
  end

  describe "change_user_email/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_email(%User{})
      assert changeset.required == [:email]
    end
  end

  describe "deliver_user_update_email_instructions/3" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(user, "current@example.com", url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "change:current@example.com"
    end
  end

  describe "update_user_email/2" do
    setup do
      user = unconfirmed_user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{user: user, token: token, email: email}
    end

    test "updates the email with a valid token", %{user: user, token: token, email: email} do
      assert {:ok, %{email: ^email}} = Accounts.update_user_email(user, token)
      changed_user = Repo.get!(User, user.id)
      assert changed_user.email != user.email
      assert changed_user.email == email
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email with invalid token", %{user: user} do
      assert Accounts.update_user_email(user, "oops") ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if user email changed", %{user: user, token: token} do
      assert Accounts.update_user_email(%{user | email: "current@example.com"}, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      assert Accounts.update_user_email(user, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "change_user_password/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_password(%User{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_user_password(
          %User{},
          %{
            "password" => "new valid password"
          },
          hash_password: false
        )

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_user_password/2" do
    setup do
      %{user: user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_password(user, %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{user: user} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.update_user_password(user, %{password: too_long})

      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{user: user} do
      {:ok, {user, expired_tokens}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      assert expired_tokens == []
      assert is_nil(user.password)
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Accounts.generate_user_session_token(user)

      {:ok, {_, _}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      refute Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "generate_user_session_token/1" do
    setup do
      %{user: user_fixture()}
    end

    test "generates a token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.context == "session"
      assert user_token.authenticated_at != nil

      # Creating the same token for another user should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%UserToken{
          token: user_token.token,
          user_id: user_fixture().id,
          context: "session"
        })
      end
    end

    test "duplicates the authenticated_at of given user in new token", %{user: user} do
      user = %{user | authenticated_at: DateTime.add(DateTime.utc_now(:second), -3600)}
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.authenticated_at == user.authenticated_at
      assert DateTime.compare(user_token.inserted_at, user.authenticated_at) == :gt
    end
  end

  describe "get_user_by_session_token/1" do
    setup do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      %{user: user, token: token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert {session_user, token_inserted_at} = Accounts.get_user_by_session_token(token)
      assert session_user.id == user.id
      assert session_user.authenticated_at != nil
      assert token_inserted_at != nil
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_session_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      dt = ~N[2020-01-01 00:00:00]
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: dt, authenticated_at: dt])
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "get_user_by_magic_link_token/1" do
    setup do
      user = user_fixture()
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      %{user: user, token: encoded_token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert session_user = Accounts.get_user_by_magic_link_token(token)
      assert session_user.id == user.id
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_magic_link_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      refute Accounts.get_user_by_magic_link_token(token)
    end
  end

  describe "login_user_by_magic_link/1" do
    test "confirms user and expires tokens" do
      user = unconfirmed_user_fixture()
      refute user.confirmed_at
      {encoded_token, hashed_token} = generate_user_magic_link_token(user)

      assert {:ok, {user, [%{token: ^hashed_token}]}} =
               Accounts.login_user_by_magic_link(encoded_token)

      assert user.confirmed_at
    end

    test "returns user and (deleted) token for confirmed user" do
      user = user_fixture()
      assert user.confirmed_at
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      assert {:ok, {^user, []}} = Accounts.login_user_by_magic_link(encoded_token)
      # one time use only
      assert {:error, :not_found} = Accounts.login_user_by_magic_link(encoded_token)
    end

    test "raises when unconfirmed user has password set" do
      user = unconfirmed_user_fixture()
      {1, nil} = Repo.update_all(User, set: [hashed_password: "hashed"])
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)

      assert_raise RuntimeError, ~r/magic link log in is not allowed/, fn ->
        Accounts.login_user_by_magic_link(encoded_token)
      end
    end
  end

  describe "delete_user_session_token/1" do
    test "deletes the token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert Accounts.delete_user_session_token(token) == :ok
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "deliver_login_instructions/2" do
    setup do
      %{user: unconfirmed_user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "login"
    end
  end

  describe "sanitize_magic_link_token/1" do
    # Real email round-trips append garbage to the magic-link token:
    # quoted-printable soft-line-breaks, trailing `=` padding that some
    # clients add when they confuse base64url with standard base64, and
    # plain whitespace from copy-paste. The verifier has to decode all
    # of these as the same token — that's the user's report.

    setup do
      user = user_fixture()
      {encoded_token, _user_token} = generate_user_magic_link_token(user)
      %{token: encoded_token}
    end

    test "round-trips a clean token unchanged", %{token: token} do
      assert {:ok, decoded} = UserToken.sanitize_magic_link_token(token)
      assert {:ok, decoded} == Base.url_decode64(token, padding: false)
    end

    test "strips quoted-printable soft-line-break at the end (=\\n)", %{token: token} do
      # When the email body wraps a long URL at column 76, quoted-printable
      # appends `=\r\n` (or just `=\n`) at the wrap point. The receiver
      # is supposed to collapse it back to nothing, but a copy-pasted
      # link can carry the artifact verbatim.
      assert {:ok, decoded} = UserToken.sanitize_magic_link_token(token <> "=\n")
      assert {:ok, decoded} == Base.url_decode64(token, padding: false)
    end

    test "strips quoted-printable soft-line-break in the middle", %{token: token} do
      half = div(byte_size(token), 2)

      wrapped =
        binary_part(token, 0, half) <>
          "=\r\n" <> binary_part(token, half, byte_size(token) - half)

      assert {:ok, decoded} = UserToken.sanitize_magic_link_token(wrapped)
      assert {:ok, decoded} == Base.url_decode64(token, padding: false)
    end

    test "strips trailing = padding that some email clients add", %{token: token} do
      # E.g. Outlook inserts a single trailing `=` when the URL crosses
      # the line wrap boundary and gets re-encoded as standard base64.
      assert {:ok, decoded} = UserToken.sanitize_magic_link_token(token <> "=")
      assert {:ok, decoded} == Base.url_decode64(token, padding: false)
    end

    test "strips trailing whitespace (newline / space) that the email client left behind", %{
      token: token
    } do
      assert {:ok, decoded} = UserToken.sanitize_magic_link_token(token <> "\n")
      assert {:ok, decoded} == UserToken.sanitize_magic_link_token(token <> " ")
      assert {:ok, decoded} == UserToken.sanitize_magic_link_token(token <> "\r\n")
      assert {:ok, decoded} == Base.url_decode64(token, padding: false)
    end

    test "strips leading whitespace", %{token: token} do
      assert {:ok, decoded} = UserToken.sanitize_magic_link_token(" \t" <> token)
      assert {:ok, decoded} == Base.url_decode64(token, padding: false)
    end

    test "still rejects a token that is genuinely too short", %{token: _token} do
      assert :error = UserToken.sanitize_magic_link_token("abc")
      assert :error = UserToken.sanitize_magic_link_token("")
      assert :error = UserToken.sanitize_magic_link_token(nil)
    end

    test "still rejects a token with non-base64url characters", %{token: _token} do
      # `!` is not in the base64url alphabet — if a token comes through
      # with this, it's been tampered with, not just mangled by an
      # email client.
      assert :error = UserToken.sanitize_magic_link_token("abc!def")
    end

    test "round-trip with full email-simulated URL noise", %{token: token} do
      # The worst case: copy-pasted from an email client that has done
      # the lot — quoted-printable soft-line-breaks, trailing whitespace,
      # trailing `=` padding, AND the user typed a leading space.
      noisy =
        " " <> String.replace(token, "abc", "=\r\nabc=\n") <> " =  \r\n"

      assert {:ok, decoded} = UserToken.sanitize_magic_link_token(noisy)
      assert {:ok, decoded} == Base.url_decode64(token, padding: false)
    end
  end

  describe "UserToken inserted_at uses the database clock (db-clock refactor)" do
    # The DB-clock refactor exists because every other timestamp in the app
    # is rounded to the same time source — the database. Without explicit
    # `inserted_at: DtuApp.Time.utc_now()` in `build_*_token/1`, Ecto's
    # `timestamps(type: :utc_datetime, updated_at: false)` macro auto-fills
    # `inserted_at` from `DateTime.utc_now()` on the app container. That
    # reintroduces app↔DB clock drift in the verify query and mis-classifies
    # freshly-issued magic links as "expired" when the app clock runs ahead
    # of (or behind) the DB clock. See `DtuApp.Time` and the
    # `set_db_clock_defaults_for_time_columns` migration for the rationale.

    setup do
      %{user: user_fixture()}
    end

    test "build_email_token/2 pre-fills inserted_at from DtuApp.Time.utc_now()", %{user: user} do
      # Capture the DB clock immediately around the build call so the
      # assertion tolerates the round-trip's microsecond drift (DtuApp.Time
      # truncates to whole seconds, but the call still races a clock tick
      # between build and verify).
      before = DtuApp.Time.utc_now()
      {_encoded, user_token} = UserToken.build_email_token(user, "login")
      after_ = DtuApp.Time.utc_now()

      # The pre-filled value must come from the DB clock helper, not from
      # `DateTime.utc_now()`. In tests both clocks agree, so the bound is
      # `before <= inserted_at <= after_` — exactly what `DtuApp.Time.utc_now()`
      # would return.
      assert user_token.inserted_at != nil
      assert DateTime.compare(user_token.inserted_at, before) in [:gt, :eq]
      assert DateTime.compare(user_token.inserted_at, after_) in [:lt, :eq]
    end

    test "build_session_token/1 pre-fills inserted_at from DtuApp.Time.utc_now()", %{user: user} do
      before = DtuApp.Time.utc_now()
      {_token, user_token} = UserToken.build_session_token(user)
      after_ = DtuApp.Time.utc_now()

      assert user_token.inserted_at != nil
      assert DateTime.compare(user_token.inserted_at, before) in [:gt, :eq]
      assert DateTime.compare(user_token.inserted_at, after_) in [:lt, :eq]
    end

    test "a token written via the app helper round-trips through verify_magic_link_token_query/1",
         %{user: user} do
      # End-to-end regression: build, insert, verify. With the fix in
      # place, `inserted_at` is set from `DtuApp.Time.utc_now()` on the
      # write side, so the verify query's `DtuApp.Time.utc_now() - 15min`
      # cutoff compares two values from the same clock and the token is
      # found. Without the fix, Ecto's autogenerate would write
      # `DateTime.utc_now()` from the app container, and any drift between
      # the app and DB clocks would mis-classify a fresh link as expired.
      {encoded_token, user_token} = UserToken.build_email_token(user, "login")

      # Sanity check: the helper stamped `inserted_at` from the DB clock.
      # If this assertion ever fails, the bug is back.
      db_now = DtuApp.Time.utc_now()

      assert DateTime.compare(user_token.inserted_at, db_now) in [:gt, :eq],
             "build_email_token/2 should pre-fill inserted_at from DtuApp.Time.utc_now(); " <>
               "got #{inspect(user_token.inserted_at)} but DtuApp.Time.utc_now()=#{inspect(db_now)}"

      # Now insert and verify — the round trip should succeed because the
      # stored `inserted_at` is consistent with the DB clock used by the
      # verify query, regardless of any drift between the host's wall
      # clock and the DB server's wall clock.
      Repo.insert!(user_token)

      assert %User{} = Accounts.get_user_by_magic_link_token(encoded_token)
    end
  end

  describe "inspect/2 for the User module" do
    test "does not include password" do
      refute inspect(%User{password: "123456"}) =~ "password: \"123456\""
    end
  end

  describe "notification_settings_changeset/2 and update_notification_settings/2" do
    # Notification preferences are written by the `/notifications`
    # LiveView via `Accounts.update_notification_settings/2`. The
    # changeset only needs to cast the two flags; there's no other
    # validation because the user can save with both flags off (i.e.
    # "no notifications at all") and that's a valid state.
    alias DtuApp.Accounts.User, as: AccountsUser

    test "casts the two notification flags" do
      user = user_fixture()

      changeset = AccountsUser.notification_settings_changeset(user, %{})

      assert changeset.valid?
      refute get_field(changeset, :notify_dtu_connection)
      refute get_field(changeset, :notify_sun_down)
    end

    test "accepts and persists both flags" do
      user = user_fixture()

      assert {:ok, updated} =
               Accounts.update_notification_settings(user, %{
                 notify_dtu_connection: true,
                 notify_sun_down: true
               })

      assert updated.notify_dtu_connection
      assert updated.notify_sun_down

      # Round-trip: a fresh read from the DB sees the new values.
      reloaded = Repo.get!(User, user.id)
      assert reloaded.notify_dtu_connection
      assert reloaded.notify_sun_down
    end

    test "accepts and persists one flag off" do
      user = user_fixture()

      assert {:ok, updated} =
               Accounts.update_notification_settings(user, %{
                 notify_dtu_connection: true,
                 notify_sun_down: false
               })

      assert updated.notify_dtu_connection
      refute updated.notify_sun_down
    end

    test "ignores other keys" do
      # The settings page only sends the two boolean keys; everything
      # else (e.g. the user's email, password) must be silently
      # ignored by the changeset. This is a regression guard against
      # the changeset being made too permissive.
      user = user_fixture()

      assert {:ok, updated} =
               Accounts.update_notification_settings(user, %{
                 notify_dtu_connection: true,
                 email: "malicious@example.com"
               })

      assert updated.notify_dtu_connection
      assert updated.email == user.email
    end
  end

  describe "settings_changeset/2 and update_user_settings/2" do
    # The `settings_changeset/2` parses a decimal €/kWh string from the
    # `/users/settings` form, converts it to whole cents, and validates
    # the range. The bug fixed in this commit: an empty string (or any
    # unparseable text) used to fall through to the `:invalid` atom and
    # then `cast/3` rejected it on the integer field with Ecto's
    # default "is invalid" message — the user saw "invalid value" on
    # every blank submit. The fix maps all non-numeric / out-of-range
    # inputs to `nil`, so the form clears the field silently and the
    # dashboard hides the savings card.

    test "converts a valid €/kWh value to whole cents" do
      changeset = User.settings_changeset(%User{}, %{"euros_per_kwh" => "0.32"})

      assert changeset.valid?
      assert get_change(changeset, :cents_per_kwh) == 32
    end

    test "treats an empty string as clearing the field (no 'is invalid' error)" do
      # Regression: blank form submission previously added the Ecto
      # default `{"is invalid", [type: :integer, validation: :cast]}`
      # error to the changeset. The fix maps empty input to nil so the
      # field is silently cleared.
      changeset = User.settings_changeset(%User{}, %{"euros_per_kwh" => ""})

      assert changeset.valid?
      assert get_change(changeset, :cents_per_kwh) == nil
    end

    test "treats whitespace-only input as clearing the field" do
      # The form trim()s whitespace before parsing; "   " becomes ""
      # after String.trim/1 and must yield the same nil result as the
      # empty-string case.
      changeset = User.settings_changeset(%User{}, %{"euros_per_kwh" => "   "})

      assert changeset.valid?
      assert get_change(changeset, :cents_per_kwh) == nil
    end

    test "treats zero as clearing the field" do
      # The user may type "0" or "0.00" expecting "no rate" — both
      # parse to `{+0.0, _}` and must round to nil, not 0 cents (which
      # would otherwise produce a misleading "€0.00 saved" on the
      # dashboard).
      for input <- ["0", "0.00", "0.0"] do
        changeset = User.settings_changeset(%User{}, %{"euros_per_kwh" => input})
        assert changeset.valid?, "input #{inspect(input)} should be valid"

        assert get_change(changeset, :cents_per_kwh) == nil,
               "input #{inspect(input)} should clear the field"
      end
    end

    test "treats non-numeric input as clearing the field" do
      # A pasted garbage value (e.g. "abc") must not surface the Ecto
      # "is invalid" error — it should silently clear the field so
      # the user can retype.
      changeset = User.settings_changeset(%User{}, %{"euros_per_kwh" => "abc"})

      assert changeset.valid?
      assert get_change(changeset, :cents_per_kwh) == nil
    end

    test "reports a friendly range error for sub-cent precision" do
      # "0.001" parses to 0.001, which rounds to 0 cents. The
      # changeset detects this and declines with the friendly range
      # error instead of silently storing 0.
      {:error, changeset} =
        Accounts.update_user_settings(user_fixture(), %{"euros_per_kwh" => "0.001"})

      assert errors_on(changeset).cents_per_kwh == ["must be between €0.01 and €100"]
    end

    test "persists a valid rate and clears it on a subsequent empty submit" do
      user = user_fixture()

      {:ok, %{cents_per_kwh: 25}} =
        Accounts.update_user_settings(user, %{"euros_per_kwh" => "0.25"})

      reloaded = Repo.get!(User, user.id)
      assert reloaded.cents_per_kwh == 25

      {:ok, %{cents_per_kwh: nil}} =
        Accounts.update_user_settings(reloaded, %{"euros_per_kwh" => ""})

      empty = Repo.get!(User, user.id)
      assert empty.cents_per_kwh == nil
    end

    test "ignores other keys" do
      # The settings page only sends `euros_per_kwh`; everything else
      # (e.g. the user's email, password) must be silently ignored.
      user = user_fixture()

      assert {:ok, updated} =
               Accounts.update_user_settings(user, %{
                 "euros_per_kwh" => "0.30",
                 "email" => "malicious@example.com"
               })

      assert updated.cents_per_kwh == 30
      assert updated.email == user.email
    end
  end

  describe "locale validation (settings_changeset/2)" do
    # The /users/settings form posts a `locale` string from the
    # dropdown. User.@supported_locales is the source of truth for
    # allowed values (`"en"`, `"de"`, `"fr"`). Anything else must be
    # rejected with the inclusion error so a malformed payload (or
    # future addition) can't smuggle an unknown code into the DB.
    # The Plug.Locale priority chain reads from the same list, so
    # a locale we don't ship a .po catalog for would otherwise fall
    # through to a gettext locale code that doesn't exist.

    test "accepts each supported locale" do
      for locale <- ~w(en de fr) do
        # Start from a User with a different locale so the changeset
        # records the change (otherwise `get_change/2` returns nil for
        # a no-op write). `get_field/2` returns the value the
        # changeset would persist — the post-cast result — and works
        # in both cases.
        changeset = User.settings_changeset(%User{locale: "en"}, %{"locale" => locale})
        assert changeset.valid?, "expected locale #{inspect(locale)} to be valid"
        assert get_field(changeset, :locale) == locale
      end
    end

    test "rejects an unsupported locale with the inclusion error" do
      changeset = User.settings_changeset(%User{}, %{"locale" => "klingon"})
      refute changeset.valid?

      assert errors_on(changeset).locale == ["must be one of: en, de, fr"]
    end

    test "preserves the user's existing locale when no locale is posted" do
      # The rate form posts only `euros_per_kwh` — the locale field
      # is omitted on the same submission. The changeset must keep
      # the user's stored locale instead of clobbering it with nil.
      user = %User{locale: "de"}
      changeset = User.settings_changeset(user, %{"euros_per_kwh" => "0.32"})

      assert changeset.valid?
      # `get_field/2` returns the value the changeset would write —
      # for unchanged fields, that's the original (the user's stored
      # locale), not nil.
      assert get_field(changeset, :locale) == "de"
    end

    test "persists a locale change end-to-end" do
      user = user_fixture()

      {:ok, updated} =
        Accounts.update_user_settings(user, %{"locale" => "fr"})

      assert updated.locale == "fr"

      reloaded = Repo.get!(User, user.id)
      assert reloaded.locale == "fr"
    end

    test "a locale change combined with a rate change persists both" do
      # The form posts both fields in one PUT; the changeset must
      # accept them together.
      user = user_fixture()

      {:ok, updated} =
        Accounts.update_user_settings(user, %{
          "euros_per_kwh" => "0.40",
          "locale" => "de"
        })

      assert updated.cents_per_kwh == 40
      assert updated.locale == "de"
    end
  end
end
