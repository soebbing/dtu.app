defmodule DtuApp.MqttBroker.Telemetry do
  @moduledoc """
  Coordinator GenServer for MQTT-driven DTU telemetry.

  Subscribes to three PubSub topics the embedded MqttX broker
  publishes on (`dtu:uplink` for parsed readings, `dtu:presence`
  for CONNECT/DISCONNECT broadcasts, `dtu:ro_fanout` for the
  account-scoped read-only-sink fan-out). For every uplink we:

    1. Touch `dtus.last_seen_at` so the dashboard's online badge
       flips from offline → online within one publish interval
       (independent of which parser branch runs below).
    2. Clear any stale `dtus.last_error` from a previous build,
       so the manage-device error panel only shows live errors.
    3. Dispatch to one of three parsers, by `device_info.kind`:
         `:opendtu`     → `DtuApp.MqttBroker.Telemetry.OpenDtu.handle/6`
         `:ahoydtu`     → `DtuApp.MqttBroker.Telemetry.AhoyDtu.handle/6`
         `:shelly3em`   → `DtuApp.MqttBroker.Telemetry.Shelly.handle/6`
         `:mqtt_ro_sink`→ no-op (the fan-out broadcast above
                            already covers downstream sinks)

  ## Layout

  This module owns the **GenServer lifecycle** (start_link, init,
  the `:uplink` / `:dtu_connected` / `:dtu_disconnected` /
  `:EXIT` dispatch) and the **cross-cutting helpers**
  (`touch_last_seen/1`, `clear_stale_error/1`, `safe_db_call/1`,
  `record_dtu_error/2`). The parser-specific code lives in
  sibling modules under `telemetry/` (one per device kind) so each
  parser is small enough to hold in your head and the file isn't
  1400+ lines.

  ## Test surface

  `MqttBrokerTest` exercises the full pipeline by calling
  `Telemetry.handle_info/2` directly with synthetic uplink
  messages and asserting on the DB rows that result. Public
  callbacks on the parser modules are not called from tests —
  we test through `handle_info/2` because that's the contract
  every production caller uses.

  ## State

  `state.buffers` is a `%{{dtu_id, {serial, channel}} => row_map}`
  cache shared across calls. The parser modules own the buffer
  update logic (per-MPPT field accumulation) but the state map
  itself lives here in `Telemetry` so the buffers survive across
  device kinds.
  """

  require Logger
  use GenServer

  alias DtuApp.MqttBroker.Broker
  alias DtuApp.Devices.Dtu
  alias DtuApp.MqttBroker.Telemetry.AhoyDtu
  alias DtuApp.MqttBroker.Telemetry.OpenDtu
  alias DtuApp.MqttBroker.Telemetry.Shelly

  @reading_topic "dtu:reading"
  @status_topic "dtu:status"
  @ro_fanout_topic "dtu:ro_fanout"

  @doc "The PubSub topic parsed readings are broadcast on."
  def reading_topic, do: @reading_topic

  @doc "The PubSub topic DTU status changes are broadcast on."
  def status_topic, do: @status_topic

  @doc "Subscribe the calling process to parsed readings."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(DtuApp.PubSub, @reading_topic)

  @doc "Subscribe the calling process to DTU status changes."
  @spec subscribe_status() :: :ok | {:error, term()}
  def subscribe_status, do: Phoenix.PubSub.subscribe(DtuApp.PubSub, @status_topic)

  @doc "Subscribe the calling process to account-scoped read-only sink fan-out."
  @spec subscribe_ro_fanout() :: :ok | {:error, term()}
  def subscribe_ro_fanout, do: Phoenix.PubSub.subscribe(DtuApp.PubSub, @ro_fanout_topic)

  @doc """
  Record a `dtu_errors` row for `device_id` with `message`.

  Public so the parser sub-modules (`OpenDtu`, `AhoyDtu`, `Shelly`)
  can surface parser failures without each module re-implementing
  the Ecto write. Trims `message` first (an all-whitespace
  message would otherwise persist a useless empty-bubble
  indicator on the device). On success broadcasts `:dtu_error`
  on `dtu:status` so the dashboard bubble and manage-device
  LiveView's `handle_info/2` both refresh.

  Failure modes:

    * `:not_found` from `DtuApp.Devices.record_dtu_error/2` —
      device row was deleted between the uplink landing and
      our write. Silent no-op; the next inbound message will
      short-circuit at the `is_nil(device_info)` check upstream.
    * any other `{:error, reason}` — logged at warn, swallowed.
      The broker keeps running; the next successful uplink will
      clear the stale `last_error` via `clear_stale_error/1`.
    * raised exception (sandbox-teardown race in :test, Ecto
      cast failure on a malformed payload in :dev/:prod) —
      rescued and logged at warn.

  Always returns `:ok`. The parser callers don't branch on the
  result; they emit a Logger.debug line and move on regardless.
  """
  @spec record_dtu_error(integer() | nil, String.t()) :: :ok
  def record_dtu_error(device_id, message) when is_integer(device_id) and is_binary(message) do
    trimmed = String.trim(message)

    if trimmed == "" do
      :ok
    else
      try do
        case DtuApp.Devices.record_dtu_error(device_id, trimmed) do
          :ok ->
            Phoenix.PubSub.broadcast(
              DtuApp.PubSub,
              @status_topic,
              {:dtu_error, device_id}
            )

          {:error, :not_found} ->
            # Device was deleted between the uplink arriving and our
            # write — silent no-op, the next inbound message will
            # notice and short-circuit earlier.
            :ok

          {:error, reason} ->
            Logger.warning(
              "[Telemetry] record_dtu_error(#{device_id}) DB write failed: #{inspect(reason)}"
            )

            :ok
        end
      rescue
        e ->
          Logger.warning("[Telemetry] record_dtu_error(#{device_id}) raised: #{inspect(e)}")

          :ok
      end
    end
  end

  def record_dtu_error(_device_id, _message), do: :ok

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  # Read at REQUEST time via `Application.get_env/3`, NOT compile-time —
  # the value is set in `config/test.exs` and any future per-env override
  # in `runtime.exs` would otherwise hit the same OTP 26 `validate_compile_env`
  # trap as the WebAuthn RP ID (see the parallel note in
  # `DtuAppWeb.PasskeyController`). Default `true` matches production.
  defp subscribers_enabled? do
    Application.get_env(:dtu_app, :mqtt_broker_subscribers, [])[:enabled] != false
  end

  # --- GenServer --------------------------------------------------------------

  @impl true
  def init(:ok) do
    # Trap exits so a sandbox-teardown race during tests (where the
    # long-lived GenServer's in-flight `Repo.*` call lands after the
    # SQL.Sandbox owner has been stopped) doesn't kill the GenServer
    # via the linked DBConnection process's `DBConnection.ConnectionError`
    # exit signal. The `safe_db_call/1` rescue catches the matching
    # raise inside the GenServer's own code path; this trap covers the
    # orthogonal case where the underlying connection process dies
    # while a query is in flight and propagates its exit reason to
    # every linked caller. We forward all `:EXIT` signals to
    # `handle_info/2` and ignore them there.
    Process.flag(:trap_exit, true)
    # Subscribing to PubSub is gated on the `:mqtt_broker_subscribers`
    # config flag. In `:test` the broker is off and no real uplink
    # traffic exists, but `MqttBrokerTest` calls `Broker.handle_publish/4`
    # directly — that broadcasts on `dtu:uplink`, which the long-lived
    # GenServer would receive async and process via `Repo`, racing the
    # SQL sandbox owner of the next test. Disabling the subscribe here
    # means the only way `handle_info({:uplink, ...})` is exercised in
    # :test is via a direct call from the test process (synchronous,
    # connection already owned by the test). Production / dev keep the
    # default (`enabled: true`) — see `config/runtime.exs` and
    # `config/dev.exs` for the explicit defaults, and
    # `config/test.exs` for the override.
    if subscribers_enabled?() do
      Broker.subscribe_uplink()
      Broker.subscribe_presence()
      Broker.subscribe_ro_fanout()
      Logger.info("[Telemetry] subscribed to DTU uplinks and presence")
    else
      Logger.info("[Telemetry] PubSub subscriptions skipped (mqtt_broker_subscribers disabled)")
    end

    {:ok, %{buffers: %{}}}
  end

  @impl true
  def handle_info({:uplink, client_id, device_info, topic_str, payload}, state) do
    if is_nil(device_info) do
      # Ignore unauthenticated uplinks
      {:noreply, state}
    else
      # Touch `last_seen_at` first so the dashboard's online badge can
      # flip from offline → online within one publish interval of the
      # DTU waking up — independent of which parser branch (or no
      # branch at all, e.g. an unknown topic) runs below.
      touch_last_seen(device_info.id)

      # Clear any stale `dtus.last_error` written by a previous parser
      # build. The current parser may *not* overwrite the cached
      # column on every successful parse (the AhoyDTU numeric per-
      # field path, for example, only writes a `dtu_errors` row when
      # the parser returns an `:error` or a malformed-payload reason).
      # Calling clear_stale_error/1 here means: any cached error is
      # cleared as soon as the device successfully publishes *any*
      # topic, even if the new parse doesn't surface a fresh error.
      # If the parse *does* surface a new error, `record_dtu_error/2`
      # (called from the per-kind handler) overwrites the cleared
      # value with the new message — the order is:
      # touch_last_seen → clear_stale_error → parse → maybe_record_error.
      # The helper is a no-op on a healthy device (`update_all` is
      # gated on `not is_nil(d.last_error)`), so the per-uplink cost
      # is a single PK lookup.
      clear_stale_error(device_info.id)

      if device_info.kind != :mqtt_ro_sink do
        Phoenix.PubSub.broadcast(
          DtuApp.PubSub,
          @ro_fanout_topic,
          {:ro_uplink, device_info, topic_str, payload}
        )
      end

      # Dispatch by device kind. Each parser owns the full
      # uplink → DB-row pipeline for its kind: parse the topic,
      # buffer/flush per-MPPT fields, write through `safe_db_call/1`,
      # broadcast on `@reading_topic` when a reading lands. Passing
      # `&safe_db_call/1` as a closure keeps the parser modules pure
      # (no compile-time cycle back through `Telemetry`) while still
      # routing every DB call through the sandbox-safe rescue.
      case device_info.kind do
        :opendtu ->
          OpenDtu.handle(client_id, device_info, topic_str, payload, state, &safe_db_call/1)

        :ahoydtu ->
          AhoyDtu.handle(client_id, device_info, topic_str, payload, state, &safe_db_call/1)

        :shelly3em ->
          Shelly.handle(client_id, device_info, topic_str, payload, state, &safe_db_call/1)

        :mqtt_ro_sink ->
          {:noreply, state}
      end
    end
  end

  # Handle presence tracking for DTUs. CONNECT / DISCONNECT both touch
  # `last_seen_at` so the derived `Dtu.online?/2` flips accordingly;
  # we no longer carry a stored `online` boolean.
  @impl true
  def handle_info({:dtu_connected, _client_id, device_id}, state) do
    if device_id, do: touch_last_seen(device_id)
    {:noreply, state}
  end

  @impl true
  def handle_info({:dtu_disconnected, _client_id, device_id}, state) do
    if device_id, do: touch_last_seen(device_id)
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    # Ignore EXIT signals from linked processes. The most common
    # source is a DBConnection process shutting down because the
    # SQL.Sandbox owner has been torn down mid-query — the
    # GenServer is long-lived (started in the application supervisor)
    # and outlasts any single test's sandbox, so we must not die
    # with the connection process. The actual `Repo.*` raise is
    # caught by `safe_db_call/1`'s rescue clause.
    {:noreply, state}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  # --- Ingestion & DB helpers -------------------------------------------------

  # Update `dtus.last_seen_at` for `device_id` to the DB clock. Used
  # on every MQTT activity (uplink, CONNECT, DISCONNECT) so the
  # derived `Dtu.online?/2` reflects real-time liveness. Broadcasts
  # `:dtu_seen` on `dtu:status` so subscribed LiveViews can refresh
  # their device list and the badge flips within one publish interval.
  #
  # `last_seen_at` is typed `:utc_datetime_usec`, so we use the
  # microsecond-precision `utc_now_usec/0` (otherwise Ecto would
  # reject the write with `:utc_datetime_usec expects microsecond
  # precision`).
  #
  # The whole function is wrapped in `safe_db_call/1` so a
  # sandbox-teardown race during tests (where the long-lived
  # GenServer's DB call lands after the SQL.Sandbox owner has been
  # stopped) can't crash the GenServer and corrupt the shared sandbox
  # for every subsequent test. The worst case in production is a
  # missed badge flip on the next render, and the next uplink will
  # retry anyway.
  defp touch_last_seen(device_id) do
    safe_db_call(fn ->
      case DtuApp.Repo.get(Dtu, device_id) do
        nil ->
          :ok

        dtu ->
          dtu
          |> Ecto.Changeset.change(%{last_seen_at: DtuApp.Time.utc_now_usec()})
          |> DtuApp.Repo.update()

          Phoenix.PubSub.broadcast(
            DtuApp.PubSub,
            @status_topic,
            {:dtu_seen, device_id}
          )

          :ok
      end
    end)
  end

  # Clear any stale `dtus.last_error` written by a previous parser
  # version (e.g. an old build that wrote `:ignored_topic` errors for
  # `inverter/total/MaxPower` uplinks). The current parser drops the
  # `{base}/total/{Metric}` topic on purpose (no `_fleet` row persisted
  # — see the `[binary_base, "total", _metric]` clause in
  # `AhoyDtu.parse/3`), but it still routes through the AhoyDTU
  # handler and returns `{:error, :ignored_topic}` instead of
  # `record_dtu_error/2`, so the cached `last_error` column would
  # otherwise never be overwritten. Without this helper, a device
  # that publishes a fleet-total numeric would still show its old
  # `AhoyDTU uplink rejected (:ignored_topic on topic
  # "inverter/total/MaxPower")` bubble, even though no `dtu_errors`
  # row exists in the recency window.
  #
  # Called from every parser success path (OpenDTU, AhoyDTU, Shelly).
  # Idempotent: a no-op for devices that have never errored or whose
  # `last_error` was already cleared by an earlier uplink. Wrapped in
  # `safe_db_call/1` for symmetry with `touch_last_seen/1` — the
  # underlying `clear_stale_dtu_error/1` already swallows its own DB
  # errors, but if Ecto is unreachable before the call dispatches the
  # outer rescue still catches it.
  defp clear_stale_error(device_id) do
    safe_db_call(fn ->
      DtuApp.Devices.clear_stale_dtu_error(device_id)
    end)
  end

  # Run a DB call from a `handle_info/2` clause and degrade gracefully
  # if the SQL.Sandbox owner has been torn down before the call returns.
  # The long-lived `DtuApp.MqttBroker.Telemetry` GenServer keeps
  # subscribing to PubSub across every test in the suite, so an
  # in-flight `Repo.*` call can race the per-test `stop_owner/1` at
  # the end of a test. When that race fires, Ecto raises either a
  # `MatchError` ("could not lookup Ecto repo DtuApp.Repo because it
  # was not started or it does not exist") or a
  # `DBConnection.ConnectionError`; the unchecked exception crashes
  # the GenServer and corrupts the shared sandbox for every
  # subsequent test, producing cascading setup_sandbox failures.
  #
  # In production this rescue never fires: the GenServer is never
  # torn down outside test teardown, so the only "errors" that reach
  # here are validation / cast failures (`Ecto.Query.CastError`)
  # caused by malformed payloads, which the parser should already be
  # sanitising before they reach the DB layer.
  #
  # Returns `:ok` on rescued failure and the wrapped function's value
  # on success. Callers should treat `:ok` as a sentinel meaning
  # "drop this uplink" only when the wrapped function's normal
  # return set is strictly `{:ok, _} | {:error, _}` (which is the
  # case for every `DtuApp.Devices.*` helper used here).
  #
  # Exposed via the closure passed to each parser module's `handle/6`
  # so they can route every DB write through the same sandbox-safe
  # rescue without each parser duplicating the try/rescue/catch
  # boilerplate.
  def safe_db_call(fun) do
    try do
      fun.()
    rescue
      MatchError -> :ok
      DBConnection.ConnectionError -> :ok
      Ecto.Query.CastError -> :ok
    catch
      # DBConnection.Holder.checkout raises an `:exit` (not a `raise`)
      # when the SQL.Sandbox owner has been torn down mid-query:
      # `exit({:shutdown, %DBConnection.ConnectionError{...}})`. The
      # `:rescue` clauses above cover a `raise` with the same exception
      # type, but the exit-form is distinct enough that we need an
      # explicit `catch :exit` clause as well. Without it the exit
      # propagates past the try and kills the GenServer, defeating the
      # whole point of the helper. Production never reaches this catch
      # for the same reason the rescue clauses don't fire in :dev/:prod.
      :exit, _ -> :ok
    end
  end
end
