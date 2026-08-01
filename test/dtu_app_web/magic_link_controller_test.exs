defmodule DtuAppWeb.MagicLinkControllerTest do
  use DtuAppWeb.ConnCase, async: true
  import DtuApp.AccountsFixtures
  import Ecto.Query

  describe "GET /users/log-in/:token — magic link confirmation" do
    setup do
      %{user: user_fixture()}
    end

    test "redirects to /dashboard after successful magic-link login (the user's report)", %{
      user: user
    } do
      {encoded_token, _hashed} = generate_user_magic_link_token(user)

      conn = build_conn(:get, "/users/log-in/#{encoded_token}")
      conn = get(conn, "/users/log-in/#{encoded_token}")

      # The controller confirms the token, then redirects to ~p"/".
      # UserAuth.log_in_user/2 stores the user_token in the session and
      # responds with a 302 to /; the home controller then bounces to
      # /dashboard for authenticated users.
      assert redirected_to(conn) == ~p"/"

      # If the bug were present, the controller would set:
      #   flash: "Magic link is invalid or it has expired."
      # and redirect to ~p"/users/log-in". The redirect-to-/-assertion
      # above implicitly rejects that branch.
      refute Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Magic link is invalid or it has expired."
    end

    test "rejects a token that doesn't decode as base64url", %{user: _user} do
      # Real-world examples of malformed tokens that the controller
      # must reject: an email client that mangles the URL, a paste that
      # drops a character, an attacker trying random strings.
      for malformed_token <- [
            # too short
            "oops",
            # base64url charset but short
            "abc-DEF-ghi",
            # contains non-base64url chars
            "aaaaaaaaaaaa!bbbbbbbbbbbb",
            # valid chars but unknown
            "abc_def_ghi_jkl_mno_pqr_stu_vwx_yz0_1234"
          ] do
        conn = build_conn(:get, "/users/log-in/#{malformed_token}")
        conn = get(conn, "/users/log-in/#{malformed_token}")

        assert redirected_to(conn) == ~p"/users/log-in"

        assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
                 "Magic link is invalid or it has expired."
      end
    end

    test "rejects a token whose hash matches nothing in the DB", %{user: _user} do
      # A well-formed base64url token that has no DB row → "not found".
      # This simulates: the user clicked an old (already-consumed) link,
      # or one that was tampered with. The 32 random bytes here won't
      # collide with any real token.
      orphan_token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      conn = build_conn(:get, "/users/log-in/#{orphan_token}")
      conn = get(conn, "/users/log-in/#{orphan_token}")

      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Magic link is invalid or it has expired."
    end

    test "rejects a token whose hash matches but sent_to email was changed", %{user: user} do
      # Real-world scenario: user requests magic link on email A, then
      # updates to email B before clicking. The query's `token.sent_to
      # # == user.email` check rejects this — the token was issued for
      # email A, the user is now email B.
      {encoded_token, hashed_token} = generate_user_magic_link_token(user)

      # Simulate the email-change: update the user's email.
      new_email = "different-#{System.unique_integer([:positive])}@example.com"

      {:ok, _user} =
        user
        |> Ecto.Changeset.change(%{email: new_email})
        |> DtuApp.Repo.update()

      conn = build_conn(:get, "/users/log-in/#{encoded_token}")
      conn = get(conn, "/users/log-in/#{encoded_token}")

      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Magic link is invalid or it has expired."

      # Make sure we cleaned up the orphan token so the next test in
      # the same suite doesn't see a half-deleted user.
      _ =
        DtuApp.Repo.delete_all(
          from ut in DtuApp.Accounts.UserToken, where: ut.token == ^hashed_token
        )
    end

    test "rejects an expired token (older than 15 minutes)", %{user: user} do
      {encoded_token, hashed_token} = generate_user_magic_link_token(user)

      # Backdate the matching user_token by 16 minutes so the next verify
      # call sees it as expired. Ecto's typed-query builder doesn't accept
      # `set:` in the keyword list, and `DtuApp.Accounts.UserToken` doesn't
      # define a changeset — so we drop down to a raw UPDATE via the
      # underlying SQL adapter. This is the most portable backdating
      # technique without growing the UserToken schema.
      expired_at = DateTime.add(DateTime.utc_now(), -16 * 60, :second)

      _ =
        DtuApp.Repo.query(
          "UPDATE users_tokens SET inserted_at = $1 WHERE token = $2",
          [expired_at, hashed_token]
        )

      conn = build_conn(:get, "/users/log-in/#{encoded_token}")
      conn = get(conn, "/users/log-in/#{encoded_token}")

      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Magic link is invalid or it has expired."
    end

    test "URL-encoded safe characters in token decode correctly", %{user: user} do
      # Some email clients and URL formatters might double-encode the
      # token (`%` followed by hex). Phoenix decodes path params before
      # the controller sees them, so the `%` is stripped automatically.
      # The token we generate is already URL-safe (Base.url_encode64),
      # so this should round-trip without issue.
      {encoded_token, _} = generate_user_magic_link_token(user)

      # URL-encode the token in the path (some browsers / HTTP clients
      # do this for non-ASCII, even though the token is ASCII).
      url_encoded = URI.encode_www_form(encoded_token)
      conn = build_conn(:get, "/users/log-in/#{url_encoded}")
      conn = get(conn, "/users/log-in/#{url_encoded}")

      # Should still log the user in — the path param decoder strips
      # any %-encoding before the controller sees it.
      assert redirected_to(conn) == ~p"/"
    end
  end
end

defmodule DtuAppWeb.MagicLinkControllerEmailNoiseTest do
  use DtuAppWeb.ConnCase, async: true
  import DtuApp.AccountsFixtures

  describe "GET /users/log-in/:token — email round-trip noise" do
    setup do
      %{user: user_fixture()}
    end

    test "ACCEPTS a token with quoted-printable soft-line-break appended (=\\n) — the user's bug",
         %{user: user} do
      for suffix <- ["=\n", "=\r\n"] do
        {encoded_token, _} = generate_user_magic_link_token(user)
        wrapped = encoded_token <> suffix

        conn = build_conn(:get, "/users/log-in/#{wrapped}")
        conn = get(conn, "/users/log-in/#{wrapped}")

        assert redirected_to(conn) == ~p"/", "failed for #{inspect(wrapped)}"
        assert Phoenix.Flash.get(conn.assigns.flash, :error) == nil
      end
    end

    test "ACCEPTS a token with quoted-printable soft-line-break in the middle",
         %{user: user} do
      {encoded_token, _} = generate_user_magic_link_token(user)
      half = div(byte_size(encoded_token), 2)

      wrapped =
        binary_part(encoded_token, 0, half) <>
          "=\r\n" <> binary_part(encoded_token, half, byte_size(encoded_token) - half)

      conn = build_conn(:get, "/users/log-in/#{wrapped}")
      conn = get(conn, "/users/log-in/#{wrapped}")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == nil
    end

    test "ACCEPTS a token with trailing whitespace from copy-paste mistakes",
         %{user: user} do
      for wrap_fn <- [
            fn tok -> tok <> "\n" end,
            fn tok -> tok <> " " end,
            fn tok -> tok <> "\r\n" end,
            fn tok -> " " <> tok end,
            fn tok -> "\t" <> tok end,
            fn tok -> "  " <> tok <> "  " end
          ] do
        {encoded_token, _} = generate_user_magic_link_token(user)
        wrapped = wrap_fn.(encoded_token)

        conn = build_conn(:get, "/users/log-in/#{wrapped}")
        conn = get(conn, "/users/log-in/#{wrapped}")

        flash_error = Phoenix.Flash.get(conn.assigns.flash, :error)
        flash_info = Phoenix.Flash.get(conn.assigns.flash, :info)
        target = redirected_to(conn)

        assert target == ~p"/",
               "failed for #{inspect(wrapped)}: redirected_to=#{inspect(target)}, flash_error=#{inspect(flash_error)}, flash_info=#{inspect(flash_info)}"

        assert flash_error == nil
      end
    end

    test "ACCEPTS a token with trailing = padding that Outlook inserts",
         %{user: user} do
      {encoded_token, _} = generate_user_magic_link_token(user)

      conn = build_conn(:get, "/users/log-in/#{encoded_token}=")
      conn = get(conn, "/users/log-in/#{encoded_token}=")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == nil
    end

    test "ACCEPTS a token with full email-round-trip noise",
         %{user: user} do
      {encoded_token, _} = generate_user_magic_link_token(user)

      # Worst-case: leading space + middle QP wrap + trailing = + trailing
      # newline + trailing space — everything a real email client might
      # leave on the URL after a copy-paste.
      messy = " " <> encoded_token <> "=\n= "

      conn = build_conn(:get, "/users/log-in/#{messy}")
      conn = get(conn, "/users/log-in/#{messy}")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == nil
    end
  end
end
