defmodule DtuAppWeb.HealthController do
  @moduledoc """
  `GET /healthz` — public, dependency-checking health endpoint.

  Used by:
    * The Docker Compose `app` service healthcheck
      (`docker-compose.yml` — `wget --spider http://localhost:4000/healthz`).
    * Future readiness probes (e.g. k8s `readinessProbe`) for the same
      reason: the BEAM is up but a critical dependency (the database,
      the embedded MQTT broker) is down, so we should fail the probe
      and have the orchestrator hold traffic until things recover.

  ## Response shape

      {
        "status": "ok" | "degraded",
        "checks": {
          "database": "ok" | "error: <message>",
          "broker":   "ok" | "disabled" | "error: <message>"
        },
        "version": "<RELEASE_VERSION env or \"dev\">"
      }

  HTTP status:
    * `200 OK` when every required check returns `"ok"`. The broker
      check is *not* required (the app still serves HTTP with the
      broker disabled — e.g. CI environments where it's off because
      the Ecto sandbox would race the singleton broker).
    * `503 Service Unavailable` when any required check returns
      non-OK, including the DB going away mid-request.

  ## Auth

  No authentication, no CSRF token, no session — a healthcheck probe
  can't authenticate. The endpoint exposes only the fact that the
  dependencies are reachable, NOT any user data; that's enough for a
  load balancer / orchestrator and nothing more.

  ## Performance / abuse

  Each request runs `SELECT 1` against the Repo with a short timeout
  (see `check_database/0`). At ~1 ms on a warm connection, this is
  cheap enough to probe at the standard 5-10 s `interval` and not
  worth throttling — but if the endpoint ever needs a rate-limit
  (e.g. an exposed public port), the same `:rate_limit` plug used
  by the passkey flow can guard it.
  """

  use DtuAppWeb, :controller

  alias DtuApp.MqttBroker.Credentials
  alias DtuApp.Repo

  # Tight timeouts so a wedged DB doesn't keep the healthcheck
  # hanging on every probe interval. The orchestrator wants a
  # fast YES/NO, not a 30 s wait — `Repo.checkout/2` returns
  # `{:error, :timeout}` past this window and we report it as
  # `"error: timeout"`.
  @db_check_timeout_ms 1_000

  def show(conn, _params) do
    checks = %{
      database: check_database(),
      broker: check_broker()
    }

    healthy? = checks.database == "ok" and checks.broker in ["ok", "disabled"]

    body = %{
      status: if(healthy?, do: "ok", else: "degraded"),
      checks: checks,
      version: System.get_env("RELEASE_VERSION") || "dev"
    }

    # `put_status/2` must come BEFORE `json/2`: Phoenix's `json/2`
    # defaults to 200 OK and would clobber our 503 if we let it pick
    # the status. The content-type is set to JSON explicitly so a
    # `curl -i http://host:4000/healthz` from a shell shows the same
    # `Content-Type: application/json` a Docker healthcheck would
    # see when it parses the body via `wget --spider` (which does
    # follow `Content-Type` for `--content-on-error`).
    if healthy? do
      json(conn, body)
    else
      conn
      |> put_status(:service_unavailable)
      |> json(body)
    end
  end

  # `SELECT 1` is the cheapest possible roundtrip; it doesn't depend
  # on any application table existing (which matters during a
  # fresh-deploy healthcheck that runs before migrations land on a
  # not-yet-ready replica). The `timeout:` option bounds the worst
  # case — a hung DB connection returns `{:error, :timeout}` past
  # `db_check_timeout_ms` rather than blocking the whole probe.
  #
  # The `rescue` catches DB-driver exceptions that bypass the
  # error-tuple contract (e.g. `DBConnection.ConnectionError` raised
  # mid-checkout when the pool is exhausted). Without the rescue
  # the endpoint would 500 and the orchestrator would never see the
  # diagnostic JSON — exactly the failure mode the healthcheck
  # exists to prevent.
  defp check_database do
    case Repo.query("SELECT 1", [], timeout: @db_check_timeout_ms) do
      {:ok, _} -> "ok"
      {:error, reason} -> "error: #{inspect(reason)}"
    end
  rescue
    e -> "error: #{Exception.message(e)}"
  end

  # The MQTT broker (MqttX + ThousandIsland) does NOT register itself
  # under the supervisor's `id:` — `MqttX.Server.start_link/3` calls
  # `ThousandIsland.start_link/1` and that process has no registered
  # name. So `Process.whereis(DtuApp.MqttBroker.Broker)` would always
  # be `nil` even when the broker is healthy.
  #
  # What IS registered is `DtuApp.MqttBroker.Credentials` — a GenServer
  # started *alongside* the broker under the same `mqtt_broker_children/0`
  # gate. When the broker is enabled, Credentials is alive; when disabled,
  # Credentials isn't started either. Probing Credentials is therefore a
  # cheap, name-based liveness check that covers "did the supervision
  # subtree for MQTT come up at all?". We don't ping the actual TCP port
  # here — the orchestrator's job is to fail the container if the broker
  # died, and the container restart loop is what fixes it; we just need
  # a binary signal.
  defp check_broker do
    if mqtt_broker_enabled?() do
      if is_pid(Process.whereis(Credentials)) do
        "ok"
      else
        "error: broker credentials process not registered"
      end
    else
      "disabled"
    end
  end

  # The runtime config flips the broker on/off via
  # `Application.get_env(:dtu_app, :mqtt_broker)[:enabled]`. We
  # default to true (matching `DtuApp.Application`) so a misconfigured
  # deployment that forgot to set the key still expects the broker
  # to be up — surfacing that mismatch instead of silently reporting
  # "disabled".
  defp mqtt_broker_enabled? do
    case Application.get_env(:dtu_app, :mqtt_broker, [])[:enabled] do
      false -> false
      _ -> true
    end
  end
end
