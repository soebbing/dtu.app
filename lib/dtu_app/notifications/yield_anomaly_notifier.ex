defmodule DtuApp.Notifications.YieldAnomaly do
  @moduledoc """
  Server-side producer for `event: "yield_anomaly"` notifications.

  Fires once per user per local day when the user's fleet
  output collapses mid-day for longer than `@collapse_seconds`
  (default 15 min) AND the collapse happens *between local
  sunrise and local sunset* — i.e. the "panels stopped producing
  while the sun is up, but no inverter went offline to explain it"
  case the three existing producers (`SunUp`, `SunDown`,
  `DtuConnection`) cannot catch by design.

  Why a new producer instead of extending `SunDown`?
    * `SunDown` arms its idle timer without consulting the sun
      window — a normal night-time fleet-zero event is exactly
      what it exists for. Folding the mid-day check into
      `SunDown` would couple two contradictory semantics
      ("fire on idle" + "skip idle when it's night") in the
      same timer's arming logic.
    * The mid-day collapse and the end-of-day summary have
      different dedup rates (per local day vs once at sunset)
      and different histories from the user's perspective
      ("end of summary" vs "alert, something is wrong").

  Why a timer rather than firing on the first sub-threshold
  reading? A cloud passing over the array can drop fleet power
  to 0 W for a few minutes mid-day; without a `@collapse_seconds`
  threshold, every such blip would fire a false alert. The
  threshold matches `SunDown`'s `@default_idle_seconds`; the
  receiver-side `tag` would coalesce repeats even without it,
  but the threshold keeps the banner frequency sensible.

  Reading-payload tolerance: production broadcasts a full
  `DtuApp.Devices.Reading` struct; some tests broadcast a
  stripped-down map (`%{dtu_id: id}`). Stripped maps without
  `mppt_index` or `ac_power` are treated as 0 W, which is the
  correct semantics for a synthetic "fleet went dark" test.

  ## Sun-window check

  We compute sunrise / sunset for the user's saved
  geographic position (`User.latitude` / `User.longitude`)
  via `DtuApp.SunCalc.sunrise_sunset_utc/3`. When either
  coord is missing, the window check is conservative — we
  skip the fire. Skipping (rather than firing) is the safer
  default: a user without captured coords has shown no
  preference, and a fired mid-day alert for someone whose
  day-night cycle we can't model is worse than no alert.

  Polar edge cases (`:polar_night`, `:polar_day`) return
  nil for the corresponding side. For `:polar_day` the
  window is "always in sun" — we use the user's local
  midnight → next local midnight as a stand-in so the
  arming check stays well-defined. For `:polar_night`
  the window is "always dark" — we skip the fire.

  ## Preference gate (producer-level)

  The producer itself checks `User.notify_yield_anomaly`
  before doing anything visible — same UX contract as
  `SunUp` (a low-value per-day greeting where
  "off = silent" is the right answer). When the toggle is
  off, the producer skips the entire broadcast (no in-page
  event, no native push, no history row, no
  `yield_anomaly_fires` insert).

  ## Dedup persistence

  Once-per-day dedup state lives in the
  `yield_anomaly_fires` table (one row per user per local
  date). On every fire the producer attempts to insert
  today's `(user_id, fired_on)`; the unique constraint
  makes the insert idempotent — a second fire on the same
  day raises `Ecto.ConstraintError`, which we swallow.

  Test override:
  `Application.put_env(:dtu_app, :yield_anomaly_collapse_seconds,
  N)` makes the GenServer arm a N-second timer instead of the
  15-min default. The notification_test.exs suite uses this to
  drive an immediate fire without `Process.sleep`.
  """

  use GenServer

  use Gettext, backend: DtuAppWeb.Gettext

  require Logger

  alias DtuApp.Accounts.User
  alias DtuApp.Notifications
  alias DtuApp.Notifications.Dispatcher
  alias DtuApp.Notifications.YieldAnomalyFire
  alias DtuApp.Repo
  alias DtuApp.SunCalc
  alias DtuApp.Time

  @reading_topic "dtu:reading"

  @doc "The PubSub topic this producer subscribes to. Exposed for tests."
  def reading_topic, do: @reading_topic

  # Lazy-resolved on every timer arm so tests can swap the value
  # at runtime via `Application.put_env/3` without recompiling.
  # 15 minutes (in milliseconds — `Process.send_after/3` is
  # millisecond-native) matches `SunDown`'s
  # `@default_idle_seconds` so a user reading the code can carry
  # the same mental model across both producers.
  @default_collapse_ms 15 * 60 * 1000

  # The yield threshold below which we consider the fleet
  # "collapsed". 5 W absorbs inverter self-consumption noise
  # (most OpenDTU/AhoyDTU firmwares keep the gateway itself
  # sipping a couple of watts even when the panels are dark)
  # without tripping on a real low-yield setup (a small
  # string at dawn / dusk can sit at 1–3 W for a few minutes).
  @collapse_threshold_w 5.0

  # Staleness cap for the per-device reading cache. Matches
  # `SunDown`'s `@fleet_reading_stale_seconds`. Devices that
  # have gone silent for longer than this contribute 0 W to
  # the fleet sum — the cached value is treated as if the
  # inverter had stopped emitting. Without this filter a
  # single daytime reading would haunt the cache forever.
  @fleet_reading_stale_seconds 300

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    Phoenix.PubSub.subscribe(DtuApp.PubSub, @reading_topic)
    Logger.info("[Notifications.YieldAnomaly] subscribed to #{@reading_topic}")
    {:ok, %{users: %{}, device_to_user: %{}}}
  end

  @impl true
  def handle_info({:reading, _client_id, reading}, state) do
    device_id = reading_dtu_id(reading)
    power_w = reading_ac_power(reading)

    cond do
      is_nil(device_id) ->
        {:noreply, state}

      power_w == :ignore ->
        # Per-MPPT row — only the AC aggregate row carries
        # `ac_power`. We don't update fleet state from these.
        {:noreply, state}

      true ->
        state = update_user_power(state, device_id, power_w)
        {:noreply, maybe_arm_timer(state, device_id)}
    end
  end

  def handle_info({:fire_yield_anomaly, user_id}, state) when is_integer(user_id) do
    state = fire_for_user(state, user_id)
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # Extract `dtu_id` from a Reading struct or a stripped test map.
  defp reading_dtu_id(%{dtu_id: id}) when is_integer(id), do: id
  defp reading_dtu_id(%{dtu_id: id}) when not is_nil(id), do: id
  defp reading_dtu_id(_), do: nil

  # AC power: only valid on the AC-aggregate row (mppt_index = 0).
  # Per-MPPT rows (mppt_index >= 1) carry `dc_power`, not
  # `ac_power`, so we explicitly ignore them. A nil `ac_power`
  # is treated as 0 W.
  defp reading_ac_power(%{mppt_index: 0, ac_power: w}) when is_number(w), do: w * 1.0
  defp reading_ac_power(%{mppt_index: 0, ac_power: nil}), do: 0.0
  defp reading_ac_power(%{ac_power: _}), do: :ignore
  defp reading_ac_power(_), do: :ignore

  # Per-device state:
  #   * `power_w` — the latest AC reading we observed
  #   * `last_reading_at` — wall-clock UTC of that reading
  # The timestamp lets `active_fleet_w/2` exclude stale entries
  # so a DTU whose inverter stops emitting AC readings is treated
  # as "not generating" rather than as "still generating the last
  # value".
  defp update_user_power(state, device_id, power_w) do
    user_id = resolve_user_id(state, device_id)

    if is_nil(user_id) do
      state
    else
      now = Time.utc_now()

      users =
        state.users
        # `Map.put_new/3` seeds a default user-state only when the
        # key is missing — the lambda form of `Map.update/4`
        # silently returns the default verbatim on a miss
        # (dropping the very first reading for any user the
        # process has never seen before). Same lesson as
        # `SunUp.update_user_power/3`.
        |> Map.put_new(user_id, %{devices: %{}, collapse_since: nil, timer: nil})
        |> Map.update!(user_id, fn u ->
          %{u | devices: Map.put(u.devices, device_id, %{power_w: power_w, last_reading_at: now})}
        end)

      %{state | users: users, device_to_user: Map.put(state.device_to_user, device_id, user_id)}
    end
  end

  # Active fleet power: sum of `power_w` for devices whose last AC
  # reading landed within `@fleet_reading_stale_seconds`. Mirrors
  # `SunDown`'s filter — without it, the cached daytime value
  # would keep the fleet sum > 0 forever and the
  # collapse-window timer would never arm.
  defp active_fleet_w(devices, now) do
    devices
    |> Map.values()
    |> Enum.filter(fn %{last_reading_at: last} ->
      DateTime.diff(now, last, :second) < @fleet_reading_stale_seconds
    end)
    |> Enum.map(& &1.power_w)
    |> Enum.sum()
  end

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

  # Decide whether to arm / disarm the collapse-window timer:
  #
  #   * Fleet > @collapse_threshold_w → clear any pending timer
  #     and reset `collapse_since`. The fleet is producing, not
  #     collapsed.
  #
  #   * Fleet <= threshold AND we're in the sun-up window AND
  #     no timer pending AND we can resolve the user → arm a
  #     `@default_collapse_seconds` timer. Fires
  #     `{:fire_yield_anomaly, user_id}` when it expires.
  #
  #   * Fleet <= threshold AND we're NOT in the sun-up window
  #     AND no timer pending → no-op. A 0 W fleet at night is
  #     `SunDown`'s domain, not ours.
  #
  #   * Already pending timer → no-op. We let the existing
  #     timer run; the next non-zero reading will clear it.
  #
  # The in-sun-window check at arming time avoids arming a
  # timer at 14:00 that fires at 14:15 — the in-window check
  # at fire time below catches the flipped case (armed before
  # sunset, fires after sunset), so both edges need to hold.
  defp maybe_arm_timer(state, device_id) do
    user_id = Map.get(state.device_to_user, device_id)

    if is_nil(user_id) do
      state
    else
      case Map.get(state.users, user_id) do
        nil ->
          state

        %{timer: timer} = user_state when not is_nil(timer) ->
          # Timer already armed. If the fleet is producing
          # again, cancel the pending timer — we don't want a
          # transient blip to fire a false alert. Otherwise
          # the timer runs to completion; the fire-time
          # sun-window check (`fire_for_user/2`) catches
          # the "armed before sunset, fires after sunset" edge.
          now = read_now()

          if active_fleet_w(user_state.devices, now) > @collapse_threshold_w do
            new_user_state = cancel_timer(user_state)
            put_in(state, [:users, user_id], %{new_user_state | collapse_since: nil})
          else
            state
          end

        %{devices: devices} = user_state ->
          # Wall-clock now — or the test-override value (mirrors
          # the date-override path inside `user_today/1`).
          now = read_now()

          fleet_w = active_fleet_w(devices, now)

          cond do
            fleet_w > @collapse_threshold_w ->
              # Fleet is producing — cancel any pending collapse
              # timer and reset `collapse_since` so the next zero
              # reading starts a fresh window.
              new_user_state = cancel_timer(user_state)
              put_in(state, [:users, user_id], %{new_user_state | collapse_since: nil})

            true ->
              user = safe_get_user(user_id)

              if in_sun_window?(user, now) do
                new_user_state = arm_timer(user_id, user_state)
                put_in(state, [:users, user_id], new_user_state)
              else
                # Out of sun-window: do nothing. SunDown owns
                # the night-fleet-zero signal; we don't double-fire.
                state
              end
          end
      end
    end
  end

  # Test override for "now" — mirrors the date-override inside
  # `user_today/1`. Lets the suite compute the sun-window for
  # a fixed instant without mocking Process or the system clock.
  defp read_now do
    case Application.get_env(:dtu_app, :yield_anomaly_now, :__unset__) do
      :__unset__ -> Time.utc_now()
      %DateTime{} = configured -> configured
    end
  end

  # True iff we're between today's sunrise and sunset (UTC,
  # per the user's geographic position). Conservative on
  # missing data: if either side of `sunrise_sunset_utc/3`
  # returns nil (no coords, polar edge case, …) we treat the
  # window as "undefined" and skip the fire rather than
  # alerting on data we can't model.
  defp in_sun_window?(%User{} = user, now) do
    case sun_window_for(user, DateTime.to_date(now)) do
      {:ok, sunrise, sunset} ->
        DateTime.compare(now, sunrise) in [:gt, :eq] and
          DateTime.compare(now, sunset) == :lt

      {:skip, _reason} ->
        false
    end
  end

  defp in_sun_window?(_user, _now), do: false

  # Compute today's sunrise / sunset for `user`. Returns
  # `{:ok, sunrise, sunset}` when both are known,
  # `{:skip, reason}` otherwise. The reason is for
  # logging only — the caller collapses both `:skip`
  # branches to "don't arm the timer".
  defp sun_window_for(%User{latitude: nil}, _date), do: {:skip, :no_lat}
  defp sun_window_for(%User{longitude: nil}, _date), do: {:skip, :no_lon}

  defp sun_window_for(%User{} = user, %Date{} = date) do
    case SunCalc.sunrise_sunset_utc(user.latitude, user.longitude, date) do
      {nil, _} ->
        # Polar night at this location on this date.
        {:skip, :polar_night}

      {_sunrise, nil} ->
        # Polar day at this location on this date. The window
        # is effectively "always in sun" — define it as
        # local midnight → next local midnight so the
        # comparison below stays well-defined. Sunrise itself
        # is irrelevant for this branch.
        {:ok, local_midnight(user, date), local_midnight(user, Date.add(date, 1))}

      {%DateTime{} = sunrise, %DateTime{} = sunset} ->
        {:ok, sunrise, sunset}

      _ ->
        {:skip, :unknown}
    end
  end

  # Local-midnight (UTC) for the user's local date. The user
  # offset is `User.tz_offset_seconds`; "local midnight" is
  # the instant when their wall clock reads 00:00:00.
  defp local_midnight(%User{tz_offset_seconds: offset}, %Date{} = date) do
    base = DateTime.new!(date, ~T[00:00:00])
    DateTime.add(base, -offset, :second)
  end

  defp arm_timer(user_id, user_state) do
    collapse_ms = read_collapse_ms()
    timer = Process.send_after(self(), {:fire_yield_anomaly, user_id}, collapse_ms)
    %{user_state | timer: timer}
  end

  defp cancel_timer(user_state) do
    if user_state.timer, do: Process.cancel_timer(user_state.timer)
    %{user_state | timer: nil}
  end

  # Lazy read so tests can override via `Application.put_env`.
  # `:__unset__` → default; `nil` → 0 (used by the dedup
  # tests that don't want any timer).
  # Lazy read so tests can override via `Application.put_env`.
  # `:__unset__` → default; `nil` → 0 (used by the dedup tests
  # that don't want any timer). Values are in milliseconds
  # because `Process.send_after/3` is millisecond-native.
  defp read_collapse_ms do
    case Application.get_env(:dtu_app, :yield_anomaly_collapse_ms, :__unset__) do
      :__unset__ -> @default_collapse_ms
      nil -> 0
      n when is_integer(n) -> n
    end
  end

  defp fire_for_user(state, user_id) do
    case Map.get(state.users, user_id) do
      nil ->
        state

      %{timer: timer} = user_state when not is_nil(timer) ->
        # Timer fired but is still in `state.users.timer` —
        # cancel the (now-stale) handle so a subsequent
        # reading doesn't see a "pending" timer that's
        # already done.
        Process.cancel_timer(timer)
        do_fire_for_user(state, user_id, %{user_state | timer: nil})

      %{timer: nil} = user_state ->
        do_fire_for_user(state, user_id, user_state)
    end
  end

  defp do_fire_for_user(state, user_id, user_state) do
    user = safe_get_user(user_id)

    if is_nil(user) or user.notify_yield_anomaly != true do
      state
    else
      case try_fire(user) do
        :fired ->
          %{state | users: Map.put(state.users, user_id, %{user_state | collapse_since: nil})}

        :duplicate ->
          state
      end
    end
  end

  # Insert into `yield_anomaly_fires`. The unique
  # `(user_id, fired_on)` constraint makes a duplicate insert
  # a no-op for our purposes (any second fire on the same day
  # raises `Ecto.ConstraintError`, which we swallow). The
  # actual `fire/2` call happens *only* when the insert
  # succeeded — that prevents a race where two timer fires
  # arrive in close succession and both compute `today`
  # before either insert has been committed.
  defp try_fire(%User{} = user) do
    today = user_today(user)

    case insert_fire(user.id, today) do
      :ok ->
        Gettext.with_locale(DtuAppWeb.Gettext, user.locale || "en", fn ->
          fire(user, today)
        end)

        :fired

      {:error, :duplicate} ->
        :duplicate
    end
  end

  defp insert_fire(user_id, %Date{} = fired_on) do
    %YieldAnomalyFire{}
    |> YieldAnomalyFire.changeset(%{user_id: user_id, fired_on: fired_on})
    # Source-of-truth constraint is the composite PK on
    # `(user_id, fired_on)`. Why `:raise` instead of
    # `:nothing`?  Because the schema declares
    # `primary_key: false`, Ecto omits `RETURNING` from the
    # INSERT — without `RETURNING`, the `:nothing` path
    # silently returns `{:ok, %YieldAnomalyFire{}}` for
    # both an actual insert AND a swallowed conflict (the
    # struct is built from the changeset, not the DB),
    # which would let every fire re-fire. Raising and
    # catching the `Ecto.ConstraintError` gives a clean
    # duplicate signal — same fix as `SunUpFire.insert_fire/2`.
    |> Repo.insert(on_conflict: :raise)
    |> case do
      {:ok, %YieldAnomalyFire{}} -> :ok
      {:error, _changeset} -> {:error, :duplicate}
    end
  catch
    :error, %Ecto.ConstraintError{} -> {:error, :duplicate}
  end

  # Resolve the user's "today" with the test override applied.
  # `Application.put_env(:dtu_app, :yield_anomaly_offset_seconds, N)`
  # makes the producer pretend every user has offset N.
  # `nil` clears it.
  defp user_today(%User{tz_offset_seconds: stored_offset}) do
    offset =
      case Application.get_env(:dtu_app, :yield_anomaly_offset_seconds, :__unset__) do
        :__unset__ -> stored_offset
        nil -> 0
        n when is_integer(n) -> n
      end

    now =
      case Application.get_env(:dtu_app, :yield_anomaly_now, :__unset__) do
        :__unset__ -> DateTime.utc_now()
        %DateTime{} = configured -> configured
      end

    Notifications.SunUp.local_date(now, offset)
  end

  defp safe_get_user(user_id) do
    try do
      Repo.get(User, user_id)
    rescue
      _ -> nil
    end
  end

  # The user-visible payload. Title + body are gettext
  # strings, but they're wrapped in `Gettext.with_locale/2`
  # at the call site (see `try_fire/1`) so they pick up the
  # user's locale — the YieldAnomaly GenServer has no
  # request context, so a bare `gettext/1` would default to
  # whatever Gettext was initialized with (≈ "en")
  # regardless of preference.
  defp fire(%User{} = user, %Date{} = today) do
    payload = %{
      event: "yield_anomaly",
      title: gettext("⚠️ Production has stalled"),
      # `body` is a list (the email/layout pipeline expects a
      # list of paragraphs). The dispatcher's history-row
      # insert coerces it back to a single string for the
      # `:body` column. The in-page JS hook accepts either
      # string or array body via the Notification API.
      body: [yield_anomaly_body()],
      tag: "yield_anomaly:#{Date.to_iso8601(today)}"
    }

    # In-page PubSub broadcast for the dashboard LiveView
    # hook (`Notifications.subscribe(user.id)` →
    # `handle_info({:notification, payload}, ...)`). The
    # dispatcher fan-out below handles push + email +
    # history.
    Phoenix.PubSub.broadcast(
      DtuApp.PubSub,
      Notifications.user_topic(user.id),
      {:notification, payload}
    )

    Dispatcher.fire(user, "yield_anomaly", payload)
  end

  defp yield_anomaly_body do
    gettext(
      "Your panels stopped producing for over 15 minutes while the sun was up — even though no inverter reported an outage. Worth a look at the array."
    )
  end
end
