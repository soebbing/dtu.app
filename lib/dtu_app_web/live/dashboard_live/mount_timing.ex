defmodule DtuAppWeb.DashboardLive.MountTiming do
  @moduledoc """
  Optional per-mount timing probe for `DashboardLive.mount/3`.

  Disabled by default. Enable with the `DASHBOARD_MOUNT_TIMING_LOG=true`
  runtime env (picked up by `config/runtime.exs`). When enabled, the
  dashboard emits one structured `Logger.info` line per cold mount
  with the total wall-clock and a keyword list of named stages
  (`mount_seed`, `dashboard_data`, `line_chart_data`,
  `assign_devices`).

  Volume is low (one line per cold mount, gated to opt-in installs),
  and the format is grep-able from prod logs:

      [info] dashboard mount timing mount_wall_ms=... stages=[…]

  ## Why this exists

  When the 30s-on-prod cold-mount complaint landed (closed as Perf
  #1–#5 + #7–#9, last commit `4ffce52`), the mount went 30s → 375 ms.
  A separate user later reported 12 s on a 6-inverter + Shelly
  install after the fixes shipped. CI's
  `dashboard_mount_profile_test.exs` only captures Repo query
  timings, which were not the bottleneck — the gap lived somewhere
  in `mount/3` itself. Stage-level wall-clock on prod is the only
  place that signal exists.

  ## Why telemetry events aren't used

  `:telemetry.execute/3` would emit multiples of the same event per
  stage and need a reporter. A `Logger.info` line with `:metadata`
  is simpler, parseable, and gives the user a single grep target in
  prod logs without infra work. Opt-in via env.

  ## Usage from `DashboardLive.mount/3`

      mount_start = System.monotonic_time(:native)
      stages = []
      {stages, seed} =
        MountTiming.measure(:mount_seed, stages, fn -> mount_seed(socket, user) end)
      {stages, dashboard_data} =
        MountTiming.measure(:dashboard_data, stages, fn -> assign_dashboard_data(...) end)
      MountTiming.emit(mount_start, stages, user_id: user.id)
  """

  require Logger

  @doc """
  Whether the mount-stage timing probe is enabled.

  Reads `:dtu_app, :dashboard_mount_timing_log` (set by
  `config/runtime.exs` from the `DASHBOARD_MOUNT_TIMING_LOG`
  environment variable). Defaults to `false`.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:dtu_app, :dashboard_mount_timing_log, false) == true
  end

  @doc """
  Run `fun` and return `{stages_keyword, result}`.

  When enabled, the returned keyword is `stages` with one
  `{name, duration_us}` entry appended; when disabled, the keyword
  is returned unchanged (so a fully-disabled mount logs an empty
  `stages` list, which is fine — `emit/3` skips the line entirely
  in that case). `result` is whatever `fun` returned in either
  case.

  Callers thread the returned keyword through subsequent
  `measure/3` calls and pass the final list to `emit/3`.

  Zero overhead in the disabled path beyond a single `Application
  .get_env/3` lookup.
  """
  @spec measure(atom(), keyword(), (-> term())) :: {keyword(), term()}
  def measure(name, stages, fun) when is_function(fun, 0) and is_list(stages) do
    if enabled?() do
      start_native = System.monotonic_time(:native)
      result = fun.()

      us =
        System.convert_time_unit(
          System.monotonic_time(:native) - start_native,
          :native,
          :microsecond
        )

      {Keyword.put(stages, name, us), result}
    else
      {stages, fun.()}
    end
  end

  @doc """
  Emit one log line with the cold-mount wall-clock and the
  accumulated stages. Skips silently when `enabled?/0` is false.

  `mount_start_native` is the `System.monotonic_time(:native)`
  value captured at the top of `mount/3` (so total wall-clock
  measures from the same point the user perceived latency).

  `stages` is a keyword list of `{stage_name, microseconds}` pairs
  collected via `measure/3`.

  `opts` may include `:user_id` (greppable across users).

  The key/value pairs are embedded in the message text (not just
  shipped as `metadata:`) so the default console log format shows
  them without needing a structured-log shipping pipeline. The
  metadata is also attached for any downstream consumer that
  parses JSON logs.
  """
  @spec emit(integer(), keyword(), keyword()) :: :ok | :disabled
  def emit(mount_start_native, stages, opts \\ [])
      when is_integer(mount_start_native) and is_list(stages) and is_list(opts) do
    if enabled?() do
      mount_us =
        System.convert_time_unit(
          System.monotonic_time(:native) - mount_start_native,
          :native,
          :microsecond
        )

      mount_ms = div(mount_us, 1000)
      user_id = Keyword.get(opts, :user_id, :unset)

      Logger.info(
        "dashboard mount timing user_id=#{inspect(user_id)} mount_wall_ms=#{mount_ms} stages=#{inspect(stages)}",
        metadata: [
          mount_timing: true,
          user_id: user_id,
          mount_wall_ms: mount_ms,
          stages: stages
        ]
      )

      :ok
    else
      :disabled
    end
  end
end
