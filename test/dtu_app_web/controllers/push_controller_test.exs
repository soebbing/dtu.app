defmodule DtuAppWeb.PushControllerTest do
  @moduledoc """
  Tests for the Web Push (VAPID) HTTP endpoints.

  Three contracts exercised here:

    * `GET  /push/vapid/public_key` returns the configured public key
      as JSON, or 503 when VAPID isn't configured.
    * `POST /push/subscribe` upserts a `PushSubscription` row from the
      browser's `PushSubscription#toJSON()` payload. Idempotent on
      re-subscribe; rejects malformed payloads.
    * `POST /push/unsubscribe` deletes by endpoint. Idempotent (returns
      200 even when no row matched).

  All three require an authenticated session — `redirect_if_user_is_authenticated`
  is wired into the `:require_authenticated_user` plug.

  CSRF: the test conn includes a CSRF token, so the controller's
  `protect_from_forgery` plug doesn't reject the POST. Real
  browser callers send `X-CSRF-Token` from the `<meta name="csrf-token">`
  element; the `PushSubscribe` JS hook handles that.
  """
  use DtuAppWeb.ConnCase, async: false

  alias DtuApp.PushSubscriptions
  alias DtuApp.PushSubscriptions.PushSubscription

  setup :register_and_log_in_user

  setup do
    # Snap VAPID on so the controller has *something* to return and
    # any test can override with `Application.delete_env/1` if it
    # wants to exercise the "no VAPID" 503 path. We don't reset on
    # teardown — the next test's setup will overwrite.
    Application.put_env(:web_push, :vapid, %{
      public_key: "BTestPublicKey",
      private_key: "irrelevant",
      subject: "mailto:test@localhost"
    })

    :ok
  end

  describe "GET /push/vapid/public_key" do
    test "returns the configured public key", %{conn: conn} do
      # The shape is what the browser cares about — URL-safe base64,
      # 65-byte P-256 point — not the actual key value (which is
      # fake-by-design to keep test runs hermetic).
      conn = get(conn, ~p"/push/vapid/public_key")
      assert json = json_response(conn, 200)
      assert json["public_key"] == "BTestPublicKey"
    end

    test "returns 503 when VAPID isn't configured", %{conn: conn} do
      # A misconfigured deployment (operator hasn't provisioned keys
      # yet) shouldn't 500 the dashboard. The JS hook treats 503 as
      # "skip native push, keep in-page notifications" — see
      # `assets/js/push_subscribe.js#tryAutoSubscribe`.
      Application.delete_env(:web_push, :vapid)

      conn = get(conn, ~p"/push/vapid/public_key")
      assert json_response(conn, 503) == %{"error" => "vapid_not_configured"}
    end

    test "redirects to log-in if unauthenticated" do
      conn = build_conn() |> get(~p"/push/vapid/public_key")
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "returns 200 (not 406) when the client sends Accept: application/json", %{conn: conn} do
      # Regression guard for the 406 bug: when the push routes were on
      # the `:browser` pipeline (`accepts: ["html"]`), Phoenix's
      # `Plug.Accepts` content-negotiated against the HTML mime type
      # and rejected the JS hook's `Accept: application/json` header
      # with **406 Not Acceptable**. The `:push_api` pipeline is now
      # used (`:accepts: ["json"]`) so the JS hook's fetch lands on
      # 200 + JSON. Without this guard, the next refactor that moves
      # the route back to `:browser` would silently break native push.
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/push/vapid/public_key")

      assert json = json_response(conn, 200)
      assert json["public_key"] == "BTestPublicKey"
    end
  end

  describe "POST /push/subscribe" do
    test "persists a brand-new subscription", %{conn: conn, user: user} do
      assert PushSubscriptions.list_for_user(user) == []

      conn = post(conn, ~p"/push/subscribe", valid_payload())
      assert json_response(conn, 200)["ok"] == true

      assert [%{endpoint: endpoint}] = PushSubscriptions.list_for_user(user)
      assert endpoint == "https://push.example/test-endpoint"
    end

    test "upserts an existing subscription (same endpoint, second POST)", %{
      conn: conn,
      user: user
    } do
      # First POST inserts.
      assert %{"ok" => true} =
               post(conn, ~p"/push/subscribe", valid_payload()) |> json_response(200)

      assert [%PushSubscription{endpoint: "https://push.example/test-endpoint"}] =
               PushSubscriptions.list_for_user(user)

      # Second POST with the same endpoint must update, not insert
      # (still exactly one row). The `user_agent` field is captured
      # server-side from the `User-Agent` header so we verify the
      # upsert by row-count and the persistence by row-fields.
      assert %{"ok" => true} =
               post(conn, ~p"/push/subscribe", valid_payload()) |> json_response(200)

      assert [%PushSubscription{}] = PushSubscriptions.list_for_user(user)
    end

    test "rejects a payload missing the endpoint", %{conn: conn} do
      # The browser's PushSubscription#toJSON() should always include
      # `endpoint`, but defensive 400s keep a misbehaving client from
      # creating a half-formed row.
      bad_payload = %{
        "keys" => %{"p256dh" => "Bp256dh", "auth" => "AAuth"}
      }

      conn = post(conn, ~p"/push/subscribe", bad_payload)
      assert json_response(conn, 400)["error"] == "invalid_subscription_payload"
    end

    test "rejects a payload missing the keys", %{conn: conn} do
      bad_payload = %{"endpoint" => "https://push.example/no-keys"}

      conn = post(conn, ~p"/push/subscribe", bad_payload)
      assert json_response(conn, 400)["error"] == "invalid_subscription_payload"
    end

    test "redirects to log-in if unauthenticated" do
      conn = build_conn() |> post(~p"/push/subscribe", valid_payload())
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "POST /push/unsubscribe" do
    setup %{user: user} do
      {:ok, _sub} =
        PushSubscriptions.upsert(user, %{
          "endpoint" => "https://push.example/to-delete",
          "p256dh" => "Bp256dh",
          "auth" => "AAuth",
          "user_agent" => "test-agent"
        })

      :ok
    end

    test "deletes a subscription owned by the caller", %{conn: conn, user: user} do
      assert length(PushSubscriptions.list_for_user(user)) == 1

      conn =
        post(conn, ~p"/push/unsubscribe", %{
          "endpoint" => "https://push.example/to-delete"
        })

      assert json_response(conn, 200)["ok"] == true
      assert PushSubscriptions.list_for_user(user) == []
    end

    test "is idempotent: deleting a non-existent endpoint still returns 200", %{conn: conn} do
      conn =
        post(conn, ~p"/push/unsubscribe", %{
          "endpoint" => "https://push.example/never-existed"
        })

      # The hook treats "ok: true" as success regardless of whether a
      # row was deleted; pre-fix this surfaced a 404 to the user on
      # every "Disable notifications" click.
      assert json_response(conn, 200)["ok"] == true
    end

    test "rejects a payload missing the endpoint", %{conn: conn} do
      conn = post(conn, ~p"/push/unsubscribe", %{})
      assert json_response(conn, 400)["error"] == "missing_endpoint"
    end

    test "redirects to log-in if unauthenticated" do
      conn =
        build_conn()
        |> post(~p"/push/unsubscribe", %{"endpoint" => "https://push.example/x"})

      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  ## Helpers

  defp valid_payload do
    %{
      "endpoint" => "https://push.example/test-endpoint",
      "keys" => %{
        "p256dh" => "Bp256dhEncodedKey",
        "auth" => "AAuthEncodedSecret"
      },
      "user_agent" => "test-agent/1.0"
    }
  end
end
