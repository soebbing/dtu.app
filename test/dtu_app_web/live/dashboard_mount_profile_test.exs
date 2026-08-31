defmodule DtuAppWeb.DashboardMountProfileTest do
  @moduledoc """
  One-shot profiling harness for the dashboard mount path. Not a
  behavioural test — its only assertion is that the page renders.
  The point is to capture per-query Ecto telemetry + the wall-clock
  cost of the first `live(conn, ~p"/dashboard")` call with a setup
  that mirrors production (3 inverters + 1 Shelly + 1 day's worth
  of 5-minute bucket rows).

  Run with:

      mix test test/dtu_app_web/live/dashboard_mount_profile_test.exs

  The captured timings print to stdout via `IO.puts`. Use them to
  decide which of Perf #4 / #5 / #6 has the highest leverage for
  the 30s-on-prod complaint. We can delete this file once the
  perf triage is done.
  """
  use DtuAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import DtuApp.DevicesFixtures

  alias DtuApp.Repo

  setup :register_and_log_in_user

  test "measure mount cost: 3 inverters + 1 Shelly, today's buckets", %{
    conn: conn,
    user: user
  } do
    # Attach Ecto telemetry handler before mount so every Repo
    # call inside `mount/3` + `assign_dashboard_data/5` is captured.
    test_pid = self()
    handler_id = "dashboard-profile-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:dtu_app, :repo, :query]
      ],
      fn _event, measurements, %{query: query_src}, _config ->
        total_us = Map.get(measurements, :total_time, 0)
        query_us = Map.get(measurements, :query_time, 0)
        queue_us = Map.get(measurements, :queue_time, 0)

        send(
          test_pid,
          {:query_timing, total_us, query_us, queue_us, query_src}
        )
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # Production-shaped fleet: 3 OpenDTU inverters + 1 Shelly Plus 3EM.
    inv1 = device_fixture(user, %{kind: :opendtu, mqtt_username: "prof-inv1"})
    inv2 = device_fixture(user, %{kind: :opendtu, mqtt_username: "prof-inv2"})
    inv3 = device_fixture(user, %{kind: :opendtu, mqtt_username: "prof-inv3"})
    shelly = device_fixture(user, %{kind: :shelly3em, mqtt_username: "prof-shelly"})

    # Seed today's 5-minute buckets for all four devices, plus the
    # matching per-MPPT DC rows. Production sees ~288 buckets per
    # device per day (12 per hour × 24 hours). Each OpenDTU gets
    # two MPPTs (ch0 AC + ch1 DC).
    seed_today_buckets(inv1, "INV-1")
    seed_today_buckets(inv2, "INV-2")
    seed_today_buckets(inv3, "INV-3")
    seed_shelly_buckets(shelly)

    # Drain any messages that arrived during seeding so the
    # post-mount timings are clean.
    flush_messages()

    # Run the mount 3 times back-to-back. A real user reloads the
    # page or opens the dashboard in multiple tabs — the per-user
    # caches (Perf #4's `TodayDataCache`, plus #7/#8) absorb the
    # repeated fetches after the first mount. The 15s TTL is wide
    # enough that mounts 2 and 3 land fully in cache.
    n_mounts = 3
    wall_total_us = 0
    timings_all = []

    {wall_total_us, timings_all, last_html} =
      Enum.reduce(1..n_mounts, {0, [], nil}, fn mount_idx, {wall_acc, timings_acc, _prev} ->
        flush_messages()

        {wall_us, result} =
          :timer.tc(fn ->
            live(conn, ~p"/dashboard")
          end)

        {:ok, _view, html} = result
        # Drain a final time so any telemetry that landed after the
        # mount call but before the next iteration is included.
        Process.sleep(20)
        mount_timings = collect_query_timings()

        IO.puts(
          "\n--- Mount #{mount_idx}: #{format_us(wall_us)} wall, " <>
            "#{length(mount_timings)} queries ---"
        )

        {wall_acc + wall_us, timings_acc ++ [mount_timings], html}
      end)

    timings = List.flatten(timings_all)

    IO.puts("\n========= DASHBOARD MOUNT PROFILE =========")
    IO.puts("Setup: 3 inverters + 1 Shelly, today's 5-min buckets seeded")
    IO.puts("Mounts run: #{n_mounts}")
    IO.puts("Wall-clock total: #{format_us(wall_total_us)}")
    IO.puts("Queries observed: #{length(timings)}")
    IO.puts("")

    totals = Enum.map(timings, fn {t, _, _, _} -> t end)

    IO.puts("Total DB time: #{format_us(Enum.sum(totals))}")
    IO.puts("Max single-query: #{format_us(Enum.max(totals, fn -> 0 end))}")
    IO.puts("Mean per-query:   #{format_us(div(Enum.sum(totals), max(length(timings), 1)))}")

    # Group by query fingerprint so we can see which queries are
    # being called multiple times. The fingerprint is the first
    # ~80 chars of the query text + the param signatures collapsed
    # to placeholders.
    grouped =
      timings
      |> Enum.group_by(fn {_, _, _, src} -> query_fingerprint(src) end)
      |> Enum.map(fn {fp, calls} ->
        sum = calls |> Enum.map(fn {t, _, _, _} -> t end) |> Enum.sum()
        max = calls |> Enum.map(fn {t, _, _, _} -> t end) |> Enum.max()
        {fp, length(calls), sum, max}
      end)
      |> Enum.sort_by(fn {_, _, sum, _} -> sum end, :desc)

    IO.puts("")
    IO.puts("--- Grouped by query fingerprint (sorted by total time desc) ---")

    Enum.each(grouped, fn {fp, count, sum, max_t} ->
      IO.puts("[x#{count}] total=#{format_us(sum)} max=#{format_us(max_t)} :: #{fp}")
    end)

    IO.puts("===========================================\n")

    # Sanity: page must render the dashboard heading. Anything else
    # here is a side-effect of the seeding step, not a real check.
    assert last_html =~ "PV Power Dashboard"
  end

  # Seed today's 5-min bucket for an OpenDTU inverter. Uses the
  # `readings_5m` cagg path so the dashboard's today-query hits
  # the aggregate, mirroring production.
  defp seed_today_buckets(dtu, serial) do
    now = DateTime.utc_now()

    # 5-minute buckets for the past 23 hours, all strictly behind
    # the now-5min live-tail cutoff so they survive the cagg filter.
    for hour <- 0..22 do
      bucket =
        now
        |> DateTime.add(-hour * 3600, :second)
        |> DateTime.truncate(:second)
        # Floor to the bucket's 5-minute slot.
        |> floor_to_5min()

      Repo.query!(
        """
        INSERT INTO readings_5m
          (bucket, dtu_id, avg_ac_power, max_ac_power, yield_day, yield_total,
           inverter_serial, mppt_index, inverter_name)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        """,
        [
          bucket,
          dtu.id,
          # Production-typical morning/afternoon curve.
          150.0 + hour * 30.0,
          200.0 + hour * 30.0,
          (23 - hour) * 100.0,
          5000.0 + hour * 10.0,
          serial,
          0,
          serial
        ]
      )
    end
  end

  defp seed_shelly_buckets(dtu) do
    now = DateTime.utc_now()

    for hour <- 0..22 do
      bucket =
        now
        |> DateTime.add(-hour * 3600, :second)
        |> DateTime.truncate(:second)
        |> floor_to_5min()

      Repo.query!(
        """
        INSERT INTO readings
          (dtu_id, inverter_serial, mppt_index, inverter_name, power_type,
           ac_power, yield_day, yield_total, frequency, producing,
           reachable, inserted_at)
        VALUES ($1, $2, 0, $3, 'consumption', $4, $5, $6, 50.0, true, true, $7)
        """,
        [
          dtu.id,
          "SHELLY-1",
          "SHELLY-1",
          300.0 + rem(hour, 6) * 50.0,
          hour * 50.0,
          10_000.0,
          bucket
        ]
      )
    end
  end

  defp floor_to_5min(dt) do
    %{dt | minute: div(dt.minute, 5) * 5, second: 0, microsecond: {0, 0}}
  end

  defp collect_query_timings do
    do_collect([])
  end

  defp do_collect(acc) do
    receive do
      {:query_timing, total, query, queue, src} ->
        do_collect([{total, query, queue, src} | acc])
    after
      50 -> acc
    end
  end

  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      20 -> :ok
    end
  end

  defp format_us(us) when is_integer(us) do
    cond do
      us >= 1_000_000 -> "#{Float.round(us / 1_000_000, 2)} s"
      us >= 1_000 -> "#{Float.round(us / 1_000, 2)} ms"
      true -> "#{us} µs"
    end
  end

  defp summarise_query(src) when is_binary(src) do
    src
    |> String.trim()
    |> String.split("\n", trim: true)
    |> List.first()
    |> String.slice(0, 120)
  end

  # Collapse whitespace + slice first 80 chars so identical queries
  # group together regardless of how Ecto formatted them.
  defp query_fingerprint(src) when is_binary(src) do
    src
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 80)
  end

  defp summarise_query(_), do: "<unknown>"
end
