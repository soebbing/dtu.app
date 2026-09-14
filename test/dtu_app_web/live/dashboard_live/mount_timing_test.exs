defmodule DtuAppWeb.DashboardLive.MountTimingTest do
  # `Application.put_env/3` is global; sibling `async: true` tests in
  # other files would observe the override if it leaked. Run serially
  # to match the rest of the dashboard cache / mount helper tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DtuAppWeb.DashboardLive.MountTiming

  # The production reader uses the 3-arg form with `false` default
  # (`enabled?/0` checks `Application.get_env(:dtu_app,
  # :dashboard_mount_timing_log, false) == true`), so the capture and
  # restore must agree on the same default. Capturing with the 2-arg
  # form would return `nil` for an unset key and `nil` would leak
  # into the production comparison, making the disable path crash on
  # `false == true`. See memory `dtu-app-async-env-leak-test-pattern`.
  defp with_mount_timing_log(value, fun) do
    original = Application.get_env(:dtu_app, :dashboard_mount_timing_log, false)

    Application.put_env(:dtu_app, :dashboard_mount_timing_log, value)

    try do
      fun.()
    after
      Application.put_env(:dtu_app, :dashboard_mount_timing_log, original)
    end
  end

  # The test env's logger level is `:warning` (`config/test.exs:79`),
  # which silently drops `Logger.info/2` calls. `ExUnit.CaptureLog`
  # captures whatever the Logger macros emit, and the macros
  # early-return below the configured level — so a `:info` line
  # never reaches the capture buffer unless we lower the level for
  # the test. Restore the prior level in `after` so a leaky failure
  # doesn't sink other suites that depend on the warning threshold.
  defp with_info_log_level(fun) do
    previous = Logger.level()

    Logger.configure(level: :info)

    try do
      fun.()
    after
      Logger.configure(level: previous)
    end
  end

  describe "enabled?/0" do
    test "defaults to false when the env var is unset" do
      Application.delete_env(:dtu_app, :dashboard_mount_timing_log)
      refute MountTiming.enabled?()
    end

    test "is true when the env var is explicitly set to true" do
      with_mount_timing_log(true, fn ->
        assert MountTiming.enabled?()
      end)
    end

    test "is false when the env var is set to anything else (defensive)" do
      with_mount_timing_log("yes", fn ->
        refute MountTiming.enabled?()
      end)
    end
  end

  describe "measure/3 (disabled)" do
    test "returns the stages list unchanged and still runs the function" do
      with_mount_timing_log(false, fn ->
        {stages, result} = MountTiming.measure(:mount_seed, [other: 123], fn -> :ran end)
        assert stages == [other: 123]
        assert result == :ran
      end)
    end
  end

  describe "measure/3 (enabled)" do
    test "appends a {name, us} tuple to the keyword and runs the function" do
      with_mount_timing_log(true, fn ->
        {stages, result} = MountTiming.measure(:mount_seed, [], fn -> :ran end)
        assert Keyword.has_key?(stages, :mount_seed)
        assert is_integer(stages[:mount_seed])
        assert stages[:mount_seed] >= 0
        assert result == :ran
      end)
    end

    test "preserves existing entries when adding a new stage" do
      with_mount_timing_log(true, fn ->
        {stages1, _} = MountTiming.measure(:first, [], fn -> :ok end)
        {stages2, _} = MountTiming.measure(:second, stages1, fn -> :ok end)
        assert stages2[:first] != nil
        assert stages2[:second] != nil
      end)
    end
  end

  describe "emit/3 (disabled)" do
    test "returns :disabled and emits no log line" do
      with_mount_timing_log(false, fn ->
        log =
          capture_log(fn ->
            assert MountTiming.emit(System.monotonic_time(:native), mount_seed: 1000) == :disabled
          end)

        refute log =~ "dashboard mount timing"
      end)
    end
  end

  describe "emit/3 (enabled)" do
    test "emits one log line with the expected metadata fields" do
      with_mount_timing_log(true, fn ->
        with_info_log_level(fn ->
          log =
            capture_log(fn ->
              assert :ok =
                       MountTiming.emit(
                         System.monotonic_time(:native),
                         [mount_seed: 1500, dashboard_data: 12_300],
                         user_id: 42
                       )
            end)

          assert log =~ "dashboard mount timing"
          assert log =~ "mount_wall_ms="
          assert log =~ "stages="
          assert log =~ "user_id=42"
        end)
      end)
    end

    test "uses user_id=:unset when the caller omits it" do
      with_mount_timing_log(true, fn ->
        with_info_log_level(fn ->
          log =
            capture_log(fn ->
              MountTiming.emit(System.monotonic_time(:native), [mount_seed: 1], [])
            end)

          assert log =~ "user_id=:unset"
        end)
      end)
    end
  end
end
