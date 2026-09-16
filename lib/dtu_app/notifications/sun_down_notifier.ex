defmodule DtuApp.Notifications.SunDown do
  @moduledoc """
  Server-side producer for `event: "sun_down"` notifications.

  Watches every parsed reading on `dtu:reading`, maintains a per-user
  fleet-power state (`%{user_id => %{devices: %{device_id =>
  %{power_w: float, last_reading_at: DateTime.t()}},
  zero_since: ts | nil, fire_timer: ref | nil}}`), and — once the
  *active* fleet sum (devices whose last AC reading is fresher than
  `@fleet_reading_stale_seconds`, default 5 min) has been at 0 W for
  `:sun_down_idle_seconds` (default 15 min) — fires
  `DtuApp.Notifications.broadcast/2` with the day's totals (today +
  yesterday, both as kWh and peak W). The receiver side (in-page JS
  hook + native Web Push) does the user-visible work; this module is
  the producer that lives **outside** the LiveView so the summary
  also fires when the user has no tab open.

  Why a timer instead of "fire on every reading at 0 W"? When the sun
  is fully down, no more readings arrive. The only reliable trigger
  is a timer set the moment the fleet first hits 0 W (active fleet
  sum) and not reset until either the fleet wakes up again or the
  timer fires.

  Why "active" fleet sum? Some inverter firmwares stop emitting AC
  readings at night but keep their MQTT session alive with status
  frames and keepalives. Without the staleness filter, the cached
  `power_w` would hold the day's last value forever and `fleet_w ==
  0.0` would never trip — the user would never see a daily summary.
  Filtering out devices whose last reading is older than
  `@fleet_reading_stale_seconds` makes "silent" equivalent to
  "producing 0 W" for the purposes of the idle-window check.

  Why an idle threshold? A cloud passing over the array can drop
  fleet power to 0 W for a few minutes mid-day; without a threshold,
  every such blip would fire a false sun-down. 15 min matches the
  "sun is actually down" heuristic; the JS hook's `tag` and the
  receiver's `dedupKey` would coalesce repeats even without the
  threshold, but the idle check keeps the OS-level banner frequency
  sensible.

  Reading-payload tolerance: production broadcasts a full
  `DtuApp.Devices.Reading` struct (`telemetry.ex` fans the inserted
  row out). Some tests broadcast a stripped-down map (`%{dtu_id: id}`)
  — we treat the absent `:ac_power` as a 0-W reading, which is the
  correct semantics for a synthetic disconnect test.

  ## Preference gate (producer-level)

  The producer itself checks `User.notify_sun_down` before doing
  anything visible — same UX contract as `SunUp` and `DtuConnection`.
  When the toggle is off, the producer skips the entire broadcast
  (no in-page event, no native push, no history row, no
  `sun_down_fires` insert). The previous behaviour kept the in-page
  broadcast unconditional and only gated the VAPID fan-out; the
  history page therefore received a row even when the user had
  disabled the notification, which was inconsistent with the
  user-facing "off = silent" semantics the user explicitly asked
  for.

  ## Silent-day explanation row (silent-drop guard)

  When `build_payload/2` returns `nil` because the user owns
  devices but none of them have reported readings today (e.g.
  the inverter is silent / offline / the MQTT session never
  came up), the producer used to do nothing — no broadcast, no
  history row, no `sun_down_fires` insert — leaving the user
  wondering why "today's summary" never arrived when their
  account toggle is on. The producer now writes an explanatory
  `notifications` history row so the silent day is no longer
  invisible to the user (they see it on the history page, and
  can troubleshoot their devices without having to ask).

  Three callsites deliberately skip this:

    * `sun_down_fires` dedup row — NOT inserted (the day
      stays open for a later sweep that might find real
      readings; PR #255's invariant).
    * PubSub broadcast — not emitted (no real signal to
      deliver, no in-page banner would feel right for "your
      devices are silent").
    * Push / email — not fanned out (same reason; the
      dispatcher's `push_enabled?` gate would also block
      this path).

  Suppressed when the user owns zero devices (`dtu_ids == []`):
  a daily "you have no devices" reminder would be noise — the
  default state for that user is "no summary". Only the
  warning log line carries the operator signal in that case.

  ## Dedup persistence

  Once-per-day dedup state lives in the `sun_down_fires` table
  (one row per user per local date). On every fire the producer
  attempts to insert today's `(user_id, fired_on)`; the unique
  constraint makes the insert idempotent — a second fire on the
  same day raises `Ecto.ConstraintError`, which we swallow. This
  protects against duplicate fires racing through the producer
  after a GenServer restart (the previous in-memory `state.users`
  cache was wiped on every restart).

  Test override: `Application.put_env(:dtu_app, :sun_down_idle_seconds,
  N)` makes the GenServer arm a N-second timer instead of the 15-min
  default. The notification_test.exs suite uses this to drive an
  immediate fire.
  """

  use GenServer

  require Logger

  use Gettext, backend: DtuAppWeb.Gettext

  import Ecto.Query

  alias DtuApp.Accounts.User
  alias DtuApp.Devices
  alias DtuApp.Devices.Dtu
  alias DtuApp.Devices.Reading
  alias DtuApp.Notifications
  alias DtuApp.Notifications.SunDown.Payload
  alias DtuApp.Notifications.Dispatcher
  alias DtuApp.Notifications.SunDownFire
  alias DtuApp.Repo
  alias DtuApp.Time

  # Pure helpers moved to sibling modules under
  # `DtuApp.Notifications.SunDown.*`. Re-exported here so the
  # notifier's call sites stay unchanged and the existing test
  # surface (e.g. `SunDown.build_payload/2`, `SunDown.reading_topic/0`)
  # continues to work without edits.
  defdelegate build_payload(user, date, tz_offset_seconds), to: __MODULE__.Payload
  defdelegate reading_dtu_id(reading), to: __MODULE__.Detection
  defdelegate reading_ac_power(reading), to: __MODULE__.Detection
  defdelegate active_fleet_w(devices, now), to: __MODULE__.Detection
  defdelegate all_devices_silent?(user_state, now), to: __MODULE__.Detection
  defdelegate past_sunset?(user_id, now), to: __MODULE__.Detection
  defdelegate read_now(), to: __MODULE__.Detection

  @doc """
  Compute the user's local `Date` for `now_utc`.

  Subtracts the user's `tz_offset_seconds` from the UTC instant
  and takes the resulting calendar date. A user with
  `tz_offset_seconds: 7200` (CEST = UTC+2) at 2026-09-15T22:00Z
  gets `2026-09-16` (their local tomorrow). Mirrors
  `DtuApp.Notifications.SunUp.local_date/2` so the two producers
  agree on offset semantics; exposed publicly for the test suite
  and any other caller that needs the same shift.
  """
  @spec local_date(DateTime.t(), integer()) :: Date.t()
  def local_date(%DateTime{} = now_utc, offset_seconds) when is_integer(offset_seconds) do
    shifted = DateTime.add(now_utc, offset_seconds, :second)
    DateTime.to_date(shifted)
  end

  # Resolve the user's "today" with the test override applied.
  # `Application.put_env(:dtu_app, :sun_down_offset_seconds, N)` makes
  # the producer pretend every user has offset N (useful for the
  # date-rollover tests). `nil` clears it. Mirrors
  # `DtuApp.Notifications.SunUp.user_today/1` so the two producers
  # share a single test-override env-key convention (one per
  # producer, to keep test isolation between them — SunDown tests
  # don't have to know about the SunUp env-key).
  defp user_today(%User{tz_offset_seconds: stored_offset}) do
    offset =
      case Application.get_env(:dtu_app, :sun_down_offset_seconds, :__unset__) do
        :__unset__ -> stored_offset || 0
        nil -> 0
        n when is_integer(n) -> n
      end

    local_date(DateTime.utc_now(), offset)
  end

  @reading_topic "dtu:reading"

  # Lazy-resolved on every timer arm so tests can swap the value at
  # runtime via `Application.put_env` without recompiling.
  @default_idle_seconds 15 * 60

  # How often the producer re-walks every user's cached fleet-power
  # state. The default reactive arming (driven by `:reading` events)
  # only fires `maybe_arm_timer/2` when a fresh uplink arrives — so a
  # user whose inverter stops emitting AC readings at sunset never
  # triggers the idle window, and never sees the daily summary. The
  # sweep re-runs the arming check on a timer so the
  # `fleet_w == 0.0` / `all_devices_silent?` condition is detected
  # even without new readings.
  #
  # 5 minutes = worst-case 5 min extra delay on top of the 15-min
  # idle window. Trivially cheap (in-memory walk over `state.users`).
  # Overridable via `Application.put_env(:dtu_app,
  # :sun_down_sweep_interval_ms, N)` for tests.
  @default_sweep_interval_ms 5 * 60 * 1000

  # How far back the seed query looks for the "latest AC reading
  # per device" when bootstrapping `state.users` at `init/1`. Bounds
  # the bootstrap scan so a multi-year install's hypertable isn't
  # scanned at every restart. 24 hours covers a sunset-to-sunset
  # window with margin for slow / sporadic inverters.
  @seed_window_seconds 24 * 60 * 60

  # A device's `power_w` is considered stale — and therefore excluded
  # from the active fleet sum — when no AC-aggregate reading has
  # arrived in the last `@fleet_reading_stale_seconds`. Matches the
  # `@online_threshold_seconds` on `Dtu.online?/2`: if the broker
  # hasn't seen the device for 5 min, the device is MQTT-silent and
  # its cached power is treated as "not contributing". This is the
  # missing piece for users whose inverters stop emitting AC readings
  # at night but keep their MQTT session alive with status frames —
  # the cached `power_w` would otherwise hold yesterday's last value
  # forever and `fleet_w == 0.0` would never trip.
  # The actual attribute lives on `DtuApp.Notifications.SunDown.Detection`
  # — the detection helpers (active_fleet_w/2, all_devices_silent?/2)
  # are the only consumers.

  @doc "The PubSub topic this producer subscribes to. Exposed for tests."
  def reading_topic, do: @reading_topic

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    Phoenix.PubSub.subscribe(DtuApp.PubSub, @reading_topic)
    Logger.info("[Notifications.SunDown] subscribed to #{@reading_topic}")

    # Seed the per-user fleet-power cache from the most recent AC
    # readings in the DB. Recovers state lost on the previous
    # process exit — without this, a restart at night leaves
    # `state.users` empty and the periodic sweep has nothing to
    # arm. See `seed_users_from_db/0` for the bounded query.
    users = seed_users_from_db()
    device_to_user = build_device_to_user(users)

    # Schedule the first periodic sweep. The sweep itself re-arms
    # itself (see `handle_sweep/1`), so this is the only explicit
    # `schedule_sweep/0` call.
    schedule_sweep()

    {:ok, %{users: users, device_to_user: device_to_user}}
  end

  @impl true
  def handle_info({:reading, _client_id, reading}, state) do
    device_id = reading_dtu_id(reading)
    power_w = reading_ac_power(reading)

    cond do
      is_nil(device_id) ->
        {:noreply, state}

      power_w == :ignore ->
        # Per-MPPT row — only the AC aggregate row carries `ac_power`.
        # We don't update fleet state from these; the aggregate row
        # (mppt_index = 0) always arrives alongside (or just before)
        # them and carries the truth.
        {:noreply, state}

      true ->
        state = update_user_power(state, device_id, power_w)
        {:noreply, maybe_arm_timer(state, device_id)}
    end
  end

  def handle_info({:fire_sun_down, user_id}, state) when is_integer(user_id) do
    state = fire_for_user(state, user_id)
    {:noreply, state}
  end

  def handle_info(:sun_down_sweep, state) do
    # Re-walk every user's cached state. See `handle_sweep/1` for
    # why this exists — without it, an inverter that stops emitting
    # AC readings at sunset never triggers the idle window.
    {:noreply, handle_sweep(state)}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # Update the per-user fleet-power state with this device's latest
  # AC-aggregate reading. Per-device state is
  # `%{power_w: float, last_reading_at: DateTime.t()}` — the timestamp
  # is what lets `active_fleet_w/2` exclude stale entries, so a DTU
  # whose inverter stops emitting AC readings at night is treated as
  # "not generating" rather than as "still generating the last value
  # it ever published". Cache miss on the device → user mapping is
  # resolved via the DB (the `Device.user_id` FK lookup); cache hits
  # are O(1).
  defp update_user_power(state, device_id, power_w) do
    user_id = resolve_user_id(state, device_id)

    if is_nil(user_id) do
      state
    else
      now = Time.utc_now()

      users =
        Map.update(state.users, user_id, %{devices: %{}, zero_since: nil, timer: nil}, fn u ->
          devices = Map.put(u.devices, device_id, %{power_w: power_w, last_reading_at: now})
          %{u | devices: devices}
        end)

      %{state | users: users, device_to_user: Map.put(state.device_to_user, device_id, user_id)}
    end
  end

  # Active fleet power: sum of `power_w` for devices whose last AC
  # reading landed within `@fleet_reading_stale_seconds`. A device
  # that has gone silent (its inverter stopped emitting AC readings)
  # contributes 0 — which is what we want for "is the fleet currently
  # generating?". Without this filter, the cached `power_w` from a
  # daytime reading would keep the fleet sum > 0 forever, and the
  # idle-window timer would never arm.

  defp resolve_user_id(state, device_id) do
    case Map.get(state.device_to_user, device_id) do
      nil -> fetch_user_id_from_db(device_id)
      uid -> uid
    end
  end

  defp fetch_user_id_from_db(device_id) do
    try do
      case Repo.get(DtuApp.Devices.Dtu, device_id) do
        nil -> nil
        %{user_id: uid} -> uid
      end
    rescue
      _ -> nil
    end
  end

  # Defensive user lookup. The producer's job is to fire on the
  # idle transition; a brief DB hiccup must not crash the GenServer.
  # The `Detection` module has a private twin for the sunset-gate
  # path; both wrap the lookup in `:rescue` so the producer stays
  # best-effort.
  defp safe_get_user(user_id) do
    try do
      Repo.get(User, user_id)
    rescue
      _ -> nil
    end
  end

  defp maybe_arm_timer(state, device_id) do
    # The reactive arming path: a fresh `:reading` event arrived for
    # `device_id`, look up the owning user, and re-run the arming
    # check. The sweep (`handle_info(:sun_down_sweep, ...)`) calls
    # `arm_if_idle/2` directly with the user_id since it doesn't have
    # a device event.
    user_id = Map.get(state.device_to_user, device_id)
    if is_nil(user_id), do: state, else: arm_if_idle(state, user_id)
  end

  # Sunset gate: returns `true` iff the user's fleet should be
  # considered idle AND the current instant is past today's
  # sunset for the user's geographic position. The user
  # explicitly asked for "sun_down" to fire only after sunset —
  # a daily summary fired at noon (under cloud cover) is the
  # wrong signal (that's `YieldAnomaly`'s job).
  #
  # The gate now lives in `DtuApp.Notifications.SunDown.Detection`
  # (see `SunDown.past_sunset?/2`); only the call site stays here.

  defp arm_if_idle(state, user_id) do
    case Map.get(state.users, user_id) do
      nil ->
        state

      %{devices: devices, zero_since: zero_since, timer: timer} = user_state ->
        now = read_now()
        fleet_w = active_fleet_w(devices, now)
        silent? = all_devices_silent?(user_state, now)

        cond do
          # Fleet is producing power and a timer is running — cancel it.
          fleet_w > 0.0 and timer != nil ->
            Process.cancel_timer(timer)
            put_in(state.users[user_id], %{user_state | zero_since: nil, timer: nil})

          # Fleet is producing power, no timer running — reset `zero_since`.
          fleet_w > 0.0 ->
            put_in(state.users[user_id], %{user_state | zero_since: nil})

          # Fleet is at 0 W (active fleet sum) and we haven't started the
          # countdown yet — arm the idle timer. Also covers the case
          # where the entire fleet has gone silent (no fresh AC readings
          # in the last @fleet_reading_stale_seconds); we still want a
          # summary at the end of a silent day.
          #
          # Sunset gate: a daily summary at noon is meaningless — the
          # user explicitly asked for "sun_down", which only fires
          # once the sun is actually down. Look up the user to read
          # their coordinates; the DB hit is only charged on the
          # rare idle-transition path, never on the hot reactive
          # path (the cond branches above return state unchanged
          # for the producing-power cases). Users without
          # coordinates fall back to the legacy behaviour
          # (fire regardless) — `past_sunset?/2` returns `true` for
          # them — so adding the gate is a strict upgrade, not a
          # regression for users who never set their location.
          (fleet_w == 0.0 or silent?) and zero_since == nil and past_sunset?(user_id, now) ->
            zero_since = Time.utc_now()

            idle_seconds = idle_seconds()
            ref = Process.send_after(self(), {:fire_sun_down, user_id}, idle_seconds * 1000)

            put_in(state.users[user_id], %{user_state | zero_since: zero_since, timer: ref})

          true ->
            # Fleet is at 0 W and a timer is already running — leave it.
            state
        end
    end
  end

  # Re-walk every cached user's fleet-power state on a timer. Without
  # this, the producer is purely reactive — a user whose inverter
  # stops emitting AC readings at sunset never triggers the
  # reactive arming path (no `:reading` event arrives), so the idle
  # timer never arms and the daily summary never fires. The sweep
  # is the only mechanism that re-checks `fleet_w` and
  # `all_devices_silent?` for users already in `state.users`.
  #
  # For users NOT in `state.users` (e.g. after a deploy at night
  # wiped the in-memory cache), the seed in `init/1` is what gets
  # them into the cache so this sweep can find them — see
  # `seed_users_from_db/0` below.
  #
  # Walks `state.users` in a `reduce` so a `Map.put` on one user's
  # state is visible to the next user's check (state is the
  # accumulator). The walk is O(N users), all in-memory — no DB.
  defp handle_sweep(state) do
    state =
      Enum.reduce(state.users, state, fn {user_id, _user_state}, acc ->
        arm_if_idle(acc, user_id)
      end)

    schedule_sweep()
    state
  end

  defp schedule_sweep do
    Process.send_after(self(), :sun_down_sweep, sweep_interval_ms())
  end

  defp sweep_interval_ms do
    Application.get_env(
      :dtu_app,
      :sun_down_sweep_interval_ms,
      @default_sweep_interval_ms
    )
  end

  @doc """
  Rebuild the per-user / per-device fleet-power cache from the most
  recent AC-aggregate reading in the database.

  Used by `init/1` to recover state lost on the previous process
  exit (deploy, OOM, host swap). After a restart at night the
  producer's `state.users` is empty — without the seed, the
  periodic sweep would have nothing to arm and the user would miss
  today's daily summary.

  Scoped to `mppt_index = 0` rows (AC aggregate only — per-MPPT
  rows carry `dc_power`, not `ac_power`, and the in-page arming
  path ignores them via `reading_ac_power/1`) and to readings newer
  than `@seed_window_seconds` (bounds the bootstrap scan on
  multi-year installs).

  Exposed publicly so the seed query can be tested in isolation
  without restarting the GenServer.
  """
  @spec seed_users_from_db() :: map()
  def seed_users_from_db do
    cutoff = DateTime.add(Time.utc_now(), -@seed_window_seconds, :second)

    rows =
      Repo.all(
        from r in Reading,
          join: d in Dtu,
          on: d.id == r.dtu_id,
          where: r.mppt_index == 0 and r.inserted_at >= ^cutoff,
          order_by: [asc: r.dtu_id, desc: r.inserted_at],
          distinct: [asc: r.dtu_id],
          select: %{
            user_id: d.user_id,
            dtu_id: r.dtu_id,
            ac_power: r.ac_power,
            inserted_at: r.inserted_at
          }
      )

    Enum.reduce(rows, %{}, fn row, acc ->
      user_state =
        Map.get(acc, row.user_id, %{devices: %{}, zero_since: nil, timer: nil})

      devices =
        Map.put(user_state.devices, row.dtu_id, %{
          power_w: (row.ac_power || 0) * 1.0,
          last_reading_at: row.inserted_at
        })

      Map.put(acc, row.user_id, %{user_state | devices: devices})
    end)
  end

  defp build_device_to_user(users) do
    Enum.reduce(users, %{}, fn {user_id, user_state}, acc ->
      Enum.reduce(user_state.devices, acc, fn {device_id, _}, acc2 ->
        Map.put(acc2, device_id, user_id)
      end)
    end)
  end

  defp fire_for_user(state, user_id) do
    case Map.get(state.users, user_id) do
      nil ->
        state

      %{devices: devices, zero_since: ts} = user_state ->
        now = Time.utc_now()
        fleet_w = active_fleet_w(devices, now)
        silent? = all_devices_silent?(user_state, now)

        # Race window: a non-zero reading may have arrived between the
        # timer being armed and it firing. Re-check before broadcasting.
        # Same active-fleet semantics as `maybe_arm_timer/2`: the timer
        # also fires when every device has gone silent (cached power is
        # ignored, fleet sum is 0 by construction).
        if (fleet_w == 0.0 or silent?) and not is_nil(ts) do
          case safe_get_user(user_id) do
            nil ->
              clear_user_state(state, user_id)

            user ->
              # Producer-level preference gate. SunDown used to
              # always publish + record history (only the native-push
              # path was gated inside `Notifications.broadcast/2`),
              # which meant a user who'd turned the toggle off still
              # received an in-page banner and a history row. Same
              # rationale as `SunUp` — the user explicitly asked for
              # "off = silent everywhere" — so the producer now
              # honours the toggle at the source. `try_fire/2` also
              # writes the `sun_down_fires` dedup row, so an opt-out
              # user is never charged an insert at all.
              if user.notify_sun_down == true do
                try_fire(user)
              end

              clear_user_state(state, user_id)
          end
        else
          clear_user_state(state, user_id)
        end
    end
  end

  # Insert into `sun_down_fires`. The unique `(user_id, fired_on)`
  # constraint makes a duplicate insert a no-op for our purposes
  # (any second fire on the same day raises `Ecto.ConstraintError`,
  # which we swallow). The actual `fire/1` call happens *only* when
  # the insert succeeded — that prevents a race where two idle
  # windows fire in close succession and both compute `today` before
  # either insert has been committed.
  defp try_fire(%User{} = user) do
    # Resolve the user's local "today" from `User.tz_offset_seconds`
    # rather than `Date.utc_today()`. For CEST (UTC+2) users this
    # matters when the producer fires at UTC times that land on a
    # different local date — e.g. UTC 23:30 on Sep 15 is already
    # local Sep 16 in CEST. Without this shift, the dedup row,
    # history tag, and stats query all key off the wrong day.
    # Mirrors the `user_today/1` pattern in
    # `DtuApp.Notifications.SunUp` so the two producers agree on
    # offset semantics.
    today = user_today(user)

    # The SunDown producer runs as a long-lived GenServer
    # without a request context, so `gettext/1` would default to
    # whatever Gettext was initialized with (≈ "en") regardless
    # of the user's preference. Wrap the build_payload +
    # dispatch pair in the user's locale so the title/body
    # strings are generated in the right language — both the
    # in-page PubSub broadcast and the dispatcher's email
    # rendering (handled inside `Dispatcher.fire/3` via its own
    # `Gettext.with_locale/2` wrapper) carry that locale.
    #
    # Order matters: `build_payload/3` runs FIRST so the dedup
    # `sun_down_fires` row is only written when there is
    # something to dispatch. A user with devices but no
    # readings inside today's date range (silent-inverter
    # overnight / post-deploy-at-night seed scenario) makes
    # `build_payload/3` return `nil` — writing the dedup row
    # before that check would silently swallow the day's
    # notification AND lock out any later retry (the row's
    # unique constraint blocks every subsequent fire attempt
    # until tomorrow).
    Gettext.with_locale(DtuAppWeb.Gettext, user.locale || "en", fn ->
      case build_payload(user, today, user.tz_offset_seconds || 0) do
        nil ->
          # No payload — log a warning so an operator can spot
          # silent-inverter installs in production logs. The
          # `sun_down_fires` dedup row is intentionally NOT
          # written here so the day stays open for a later
          # sweep that might find real readings (PR #255's
          # invariant — preserved exactly).
          #
          # What we DO write: a single `notifications` history
          # row explaining why no summary was sent. Without it,
          # a fleet that's been silent all day is
          # indistinguishable from "the toggle is off" — the
          # user has zero feedback that the producer even ran
          # for them today. The row is suppressed for users
          # with no devices at all (`dtu_ids == []`); a daily
          # "you have no devices" entry is noise, not signal.
          # No PubSub broadcast, no push, no email — there's
          # no real summary to deliver, just a status note.
          Logger.warning(
            "[sun_down] no payload user=#{user.id} fired_on=#{Date.to_iso8601(today)} reason=no_today_readings"
          )

          write_no_payload_history(user, today)
          :ok

        payload ->
          case insert_fire(user.id, today) do
            :ok ->
              # Augment the payload with the email-specific keys via
              # the shared `Payload.decorate_for_dispatch/3` helper
              # so the producer and the regenerate handler stay in
              # lockstep — any future email-renderer shape change
              # happens in one place. `build_payload/3` retains the
              # in-page JS shape (`today_yield_yesterday_kwh` /
              # `peak_power_yesterday_w`) for the JS hook's
              # `formatPayload` consumer; the helper renames them
              # for `SunDownEmail`, attaches the inline chart + the
              # dashboard CTA, and wraps `body` in a list to match
              # the dispatcher's email / layout contract.
              full = Payload.decorate_for_dispatch(payload, user, today)

              # In-page PubSub broadcast for the dashboard LiveView
              # hook (`Notifications.subscribe(user.id)` →
              # `handle_info({:notification, payload}, ...)`). The
              # dispatcher fan-out below handles push + email +
              # history. Keeping both call sites preserves the
              # existing in-page + native-push + email + history
              # contract; the producer is the single fan-out
              # decision point.
              Phoenix.PubSub.broadcast(
                DtuApp.PubSub,
                Notifications.user_topic(user.id),
                {:notification, full}
              )

              Dispatcher.fire(user, "sun_down", full)

            {:error, :duplicate} ->
              # Another idle window for the same user fired
              # between our `build_payload/2` and
              # `insert_fire/2` calls and beat us to the row.
              # The other fire already broadcast + dispatched —
              # nothing to do.
              :ok
          end
      end
    end)
  end

  defp insert_fire(user_id, %Date{} = fired_on) do
    %SunDownFire{}
    |> SunDownFire.changeset(%{user_id: user_id, fired_on: fired_on})
    # Source-of-truth constraint is the composite PK on
    # `(user_id, fired_on)` — set up in the migration.
    #
    # Why `on_conflict: :raise` instead of `on_conflict: :nothing`?
    # Because the schema declares `primary_key: false`, Ecto omits
    # `RETURNING` from the INSERT — and with no `RETURNING`, there's
    # no row for Ecto to return. The `:nothing` path silently returns
    # `{:ok, %SunDownFire{}}` for both an actual insert AND a
    # swallowed conflict (the struct is built from the changeset,
    # not the DB), which would let every timer expiry fire. Raising
    # and catching the `Ecto.ConstraintError` gives a clean duplicate
    # signal. Same rationale as `SunUp.insert_fire/2`.
    |> Repo.insert(on_conflict: :raise)
    |> case do
      {:ok, %SunDownFire{}} -> :ok
      {:error, _changeset} -> {:error, :duplicate}
    end
  catch
    :error, %Ecto.ConstraintError{} -> {:error, :duplicate}
  end

  # Persist an explanatory `notifications` history row when
  # `build_payload/2` returns nil (user has devices but no
  # readings today). See the "Silent-day explanation row"
  # section of the moduledoc for the why / what-is-skipped
  # policy. Implementation notes:
  #
  #   * `body` is a single string (column is `:string`),
  #     matching the existing normal-fire history rows. The
  #     locale is honoured via `Gettext.with_locale/2` upstream
  #     of `try_fire/1`.
  #   * Wrapped in `try/rescue` so a DB hiccup can't break
  #     the producer — the producer's job is to fire, not
  #     to log status notes infallibly.
  defp write_no_payload_history(%User{} = user, %Date{} = today) do
    if owned_dtu_ids(user) == [] do
      :ok
    else
      payload = %{
        event: "sun_down",
        title: gettext("No end-of-day summary"),
        body:
          gettext(
            "Your devices haven't reported any readings today, so there's no daily summary to send. If readings arrive, we'll fire the summary automatically."
          ),
        tag: "sun_down:no_readings:#{Date.to_iso8601(today)}"
      }

      try do
        case Notifications.record(user, payload) do
          {:ok, _} ->
            :ok

          {:error, changeset} ->
            Logger.warning(
              "[sun_down] no-payload history insert failed user=#{user.id} errors=#{inspect(changeset.errors)}"
            )

            :ok
        end
      rescue
        e ->
          Logger.warning(
            "[sun_down] no-payload history insert raised user=#{user.id} reason=#{Exception.message(e)}"
          )

          :ok
      end
    end
  end

  # Tiny wrapper so the helper above stays close to the
  # `dtu_ids == []` predicate that `build_payload/2` uses to
  # decide between "user has devices but no readings today"
  # and "user has no devices at all". Mirrors the
  # `DtuApp.Devices.owned_dtu_ids/2` contract; delegates to the
  # user-scoped lookup (`nil` dtu_id branch) so we only count
  # the user's own devices.
  defp owned_dtu_ids(%User{} = user) do
    Devices.owned_dtu_ids(user, nil)
  end

  defp clear_user_state(state, user_id) do
    case Map.get(state.users, user_id) do
      nil -> state
      %{timer: timer} when not is_nil(timer) -> Process.cancel_timer(timer)
      _ -> :ok
    end

    %{state | users: Map.delete(state.users, user_id)}
  end

  defp idle_seconds do
    Application.get_env(:dtu_app, :sun_down_idle_seconds, @default_idle_seconds)
  end
end
