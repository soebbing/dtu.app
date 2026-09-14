defmodule DtuAppWeb.HealthControllerTest do
  @moduledoc """
  Tests for `GET /healthz`.

  Three contracts exercised here:

    * **Healthy path** — DB reachable, broker either enabled
      (Credentials GenServer alive) or disabled → 200 OK with
      `"status": "ok"`.
    * **Public-route guard** — anonymous callers reach the
      endpoint without a redirect to log-in. The endpoint is on
      the bare `:api` pipeline with no auth, so the docker-compose
      healthcheck (an unauthenticated HTTP probe) must work.
    * **Content-negotiation guard** — `Accept: */*` (the
      `wget --spider` default) and no Accept header at all both
      reach the controller. Phoenix's `Plug.Accepts` falls back
      to the first declared format when the header is missing,
      and `:api` declares `["json"]`, so both probes succeed.

  ## What's NOT tested here

  * **DB-down path** — would need to break the test DB connection
    mid-suite, which would cascade into every other test that
    uses `DtuApp.DataCase.setup_sandbox/1`. The project has no
    Mox/meck (see `dispatcher_test.exs`'s `@moduledoc` for the
    same constraint), so we don't simulate Repo errors here.
    The 503 path is verifiable by `docker compose stop db` in
    a real environment, which is what the docker-compose
    healthcheck is for.
  * **Broker-enabled-but-Credentials-not-alive** — would require
    a supervisor subtree in a half-broken state, which the test
    scaffolding doesn't expose. The production check is
    `Process.whereis/1` — there is no logic to misroute.

  CSRF: not relevant — the endpoint is on the bare `:api` pipeline
  with no session / CSRF plug. The controller test uses an
  anonymous `build_conn/0` to assert the route is public.
  """

  use DtuAppWeb.ConnCase, async: false

  alias DtuApp.MqttBroker.Credentials

  setup do
    # Default to broker-enabled, matching what the application tree
    # boots with in `:dev`/`:prod`. The :test config disables the
    # broker (so the singleton producers don't race the SQL
    # sandbox — see `DtuApp.Application.mqtt_broker_children/0`),
    # so the test-specific override here is what enables it.
    # Save and restore so env-state doesn't bleed between tests.
    prev = Application.get_env(:dtu_app, :mqtt_broker, [])
    Application.put_env(:dtu_app, :mqtt_broker, Keyword.put(prev, :enabled, true))
    on_exit(fn -> Application.put_env(:dtu_app, :mqtt_broker, prev) end)
    :ok
  end

  describe "GET /healthz (healthy path)" do
    test "returns 200 OK with status:ok when DB is reachable and broker is enabled" do
      # Force the broker enabled AND start Credentials so
      # `check_broker/0` returns "ok" — the shape of a healthy
      # production environment. The anonymous conn (no
      # `register_and_log_in_user` setup) is what the docker-compose
      # healthcheck sends; it's also what an external load balancer
      # or k8s readiness probe would send.
      Application.put_env(:dtu_app, :mqtt_broker, enabled: true)
      start_supervised!(Credentials)
      conn = build_conn()

      conn = get(conn, ~p"/healthz")
      assert json = json_response(conn, 200)
      assert json["status"] == "ok"
      assert json["checks"]["database"] == "ok"
      assert json["checks"]["broker"] == "ok"
      assert is_binary(json["version"])
    end

    test "returns 200 OK with broker:disabled when broker is configured off" do
      # The app can serve HTTP without the MQTT broker — a
      # web-only deployment (e.g. staging without DTUs) is
      # legitimate. The endpoint must NOT 503 in that case;
      # "disabled" is a third terminal state distinct from
      # "ok" and "error: ...".
      Application.put_env(:dtu_app, :mqtt_broker, enabled: false)
      conn = build_conn()

      conn = get(conn, ~p"/healthz")
      assert json = json_response(conn, 200)
      assert json["status"] == "ok"
      assert json["checks"]["broker"] == "disabled"
      assert json["checks"]["database"] == "ok"
    end

    test "returns 503 when broker is enabled but the Credentials GenServer is not alive" do
      # The supervisor either failed to start the broker children
      # or the Credentials GenServer crashed mid-flight. Either
      # way, `Process.whereis(DtuApp.MqttBroker.Credentials)` is
      # `nil`, and `check_broker/0` returns `"error: ..."`. With
      # a healthy DB the overall status is still `"degraded"` and
      # the HTTP status is 503 — failing the healthcheck is the
      # right move: the operator needs to know the MQTT subtree
      # didn't come up.
      Application.put_env(:dtu_app, :mqtt_broker, enabled: true)
      # Crucially, we do NOT start_supervised!(Credentials).
      conn = build_conn()

      conn = get(conn, ~p"/healthz")
      assert json = json_response(conn, 503)
      assert json["status"] == "degraded"
      assert json["checks"]["database"] == "ok"
      assert json["checks"]["broker"] =~ "error:"
    end
  end

  describe "GET /healthz (auth + content negotiation)" do
    test "is reachable without authentication" do
      # Build a fresh anonymous conn — NO session cookie. The
      # route is on the public `:api` pipeline, so this must
      # succeed. Regression guard: if someone moves /healthz
      # behind `:require_authenticated_user` the docker-compose
      # healthcheck would 302/redirect-loop and the container
      # would never come up healthy.
      #
      # We disable the broker for this test so the response is
      # 200 OK deterministically — auth/content-negotiation are
      # orthogonal to which subsystems are healthy, and we don't
      # want this test to flip to 503 because some unrelated
      # supervision quirk left Credentials down.
      Application.put_env(:dtu_app, :mqtt_broker, enabled: false)
      conn = build_conn() |> get(~p"/healthz")
      assert json = json_response(conn, 200)
      assert json["status"] == "ok"
    end

    test "responds to Accept: */* (the wget --spider default)" do
      # `wget --spider` (the docker-compose healthcheck) doesn't
      # send an Accept header at all, and `curl -i` defaults to
      # `*/*`. The :api pipeline accepts ["json"]; Phoenix's
      # `handle_header_accept/2` falls back to the first declared
      # format when the header is missing or `*/*`, so the route
      # must succeed. Without this guarantee the docker-compose
      # healthcheck would 406 and the container would never reach
      # the `healthy` state.
      Application.put_env(:dtu_app, :mqtt_broker, enabled: false)

      conn =
        build_conn()
        |> put_req_header("accept", "*/*")
        |> get(~p"/healthz")

      assert json = json_response(conn, 200)
      assert json["status"] == "ok"
    end

    test "responds with no Accept header at all" do
      # Same as above but `wget --spider` literally does not
      # send an Accept header. Belt-and-suspenders against the
      # Phoenix version in case the */* handling changes.
      Application.put_env(:dtu_app, :mqtt_broker, enabled: false)
      conn = build_conn() |> get(~p"/healthz")
      assert json = json_response(conn, 200)
      assert json["status"] == "ok"
    end
  end
end
