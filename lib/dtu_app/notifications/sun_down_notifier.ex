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

  use Gettext, backend: DtuAppWeb.Gettext

  require Logger

  alias DtuApp.Accounts.User
  alias DtuApp.Devices
  alias DtuApp.Emails.SunDownChart
  alias DtuApp.Notifications
  alias DtuApp.Notifications.Dispatcher
  alias DtuApp.Notifications.SunDownFire
  alias DtuApp.Repo
  alias DtuApp.Time

  @reading_topic "dtu:reading"

  # Lazy-resolved on every timer arm so tests can swap the value at
  # runtime via `Application.put_env` without recompiling.
  @default_idle_seconds 15 * 60

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
  @fleet_reading_stale_seconds 300

  @doc "The PubSub topic this producer subscribes to. Exposed for tests."
  def reading_topic, do: @reading_topic

  @doc """
  Build the `sun_down` notification payload for `user` and `date`.

  Computes today's + yesterday's daily stats via
  `DtuApp.Devices.get_daily_stats/3` and returns a map shaped for
  `assets/js/notifications.js`'s `formatPayload` — see the
  `sun_down` branch at line ~212 of that file. `today_yield` is
  converted from Wh to kWh (the readings schema stores Wh; the JS
  formatter expects kWh). `peak_power` is already W.

  Returns `nil` when the user has no devices (no point firing a
  summary that reads "0.0 kWh today" — the user has nothing to
  summarise). Caller is expected to no-op on `nil`.
  """
  @spec build_payload(User.t(), Date.t()) :: map() | nil
  def build_payload(%User{} = user, %Date{} = date) do
    today = Devices.get_daily_stats(user, nil, date)

    # A user with no devices / no readings at all returns
    # `current_power: 0.0` and `per_series: []`. Skip the notification
    # — the user has nothing to summarise, so the OS banner would
    # just read "Today: 0.0 kWh, peak 0.0 W." (annoying and useless).
    if today.current_power == 0.0 and today.per_series == [] do
      nil
    else
      yesterday = Devices.get_daily_stats(user, nil, Date.add(date, -1))

      %{
        event: "sun_down",
        title: gettext("Sun's down — daily summary"),
        body: body_for(today, yesterday),
        tag: "sun_down:#{Date.to_iso8601(date)}",
        date: Date.to_iso8601(date),
        # `today_yield` is already converted Wh → kWh inside
        # `Devices.get_daily_stats/3` (the readings table stores Wh;
        # the function divides by 1000 before returning). The JS hook
        # expects kWh, so we pass it through unchanged.
        today_yield_kwh: today.today_yield,
        peak_power_w: today.peak_power,
        today_yield_yesterday_kwh: yesterday.today_yield,
        peak_power_yesterday_w: yesterday.peak_power
      }
    end
  end

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    Phoenix.PubSub.subscribe(DtuApp.PubSub, @reading_topic)
    Logger.info("[Notifications.SunDown] subscribed to #{@reading_topic}")
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

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # Extract `dtu_id` from a Reading struct or a stripped test map.
  defp reading_dtu_id(%{dtu_id: id}) when is_integer(id), do: id
  defp reading_dtu_id(%{dtu_id: id}) when not is_nil(id), do: id
  defp reading_dtu_id(_), do: nil

  # AC power: only valid on the AC-aggregate row (mppt_index = 0).
  # Per-MPPT rows (mppt_index >= 1) carry `dc_power`, not `ac_power`,
  # so we explicitly ignore them. A nil `ac_power` is treated as 0 W
  # (matches `get_daily_stats` / `assign_dashboard_data` semantics).
  defp reading_ac_power(%{mppt_index: 0, ac_power: w}) when is_number(w), do: w * 1.0
  defp reading_ac_power(%{mppt_index: 0, ac_power: nil}), do: 0.0
  defp reading_ac_power(%{ac_power: _}), do: :ignore
  defp reading_ac_power(_), do: :ignore

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
  defp active_fleet_w(devices, now) do
    devices
    |> Map.values()
    |> Enum.filter(fn %{last_reading_at: last} ->
      DateTime.diff(now, last, :second) < @fleet_reading_stale_seconds
    end)
    |> Enum.map(& &1.power_w)
    |> Enum.sum()
  end

  # True iff `now - last_reading_at < @fleet_reading_stale_seconds`
  # for every device the user owns. A user with no devices at all
  # returns `true` (vacuous truth — they have no fleet to be down).
  # Used by `maybe_arm_timer/2` to handle the "all devices went silent
  # at the same time" case: even if the cached `power_w` for a silent
  # device is non-zero (because it published once at startup and never
  # again), the timer still arms because every entry is stale.
  defp all_devices_silent?(%{devices: devices}, now) do
    devices == [] or
      Enum.all?(devices, fn {_id, %{last_reading_at: last}} ->
        DateTime.diff(now, last, :second) >= @fleet_reading_stale_seconds
      end)
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

  defp maybe_arm_timer(state, device_id) do
    user_id = Map.get(state.device_to_user, device_id)

    if is_nil(user_id) do
      state
    else
      case Map.get(state.users, user_id) do
        nil ->
          state

        %{devices: devices, zero_since: zero_since, timer: timer} = user_state ->
          now = Time.utc_now()
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
            (fleet_w == 0.0 or silent?) and zero_since == nil ->
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
    today = Date.utc_today()

    case insert_fire(user.id, today) do
      :ok ->
        # The SunDown producer runs as a long-lived GenServer
        # without a request context, so `gettext/1` would default to
        # whatever Gettext was initialized with (≈ "en") regardless
        # of the user's preference. Wrap the build_payload +
        # dispatch pair in the user's locale so the title/body
        # strings are generated in the right language — both the
        # in-page PubSub broadcast and the dispatcher's email
        # rendering (handled inside `Dispatcher.fire/3` via its own
        # `Gettext.with_locale/2` wrapper) carry that locale.
        Gettext.with_locale(DtuAppWeb.Gettext, user.locale || "en", fn ->
          case build_payload(user, today) do
            nil ->
              :ok

            payload ->
              # Augment the payload with the email-specific keys.
              # `build_payload/2` retains the in-page JS shape
              # (`today_yield_yesterday_kwh` /
              # `peak_power_yesterday_w`) for the JS hook's
              # `formatPayload` consumer; the email renderer
              # (`SunDownEmail`) reads the renamed keys
              # (`yesterday_yield_kwh` / `peak_yesterday_w`) and
              # the inline chart + dashboard CTA. Both shapes ride
              # along in the dispatcher's payload. `body` is
              # wrapped in a list to match the dispatcher's email
              # / layout contract — SunDownEmail accepts either
              # shape but the JS hook + history-row insert are
              # consistent with the other producers' list shape.
              full =
                Map.merge(payload, %{
                  body: [payload[:body]],
                  yesterday_yield_kwh: payload[:today_yield_yesterday_kwh],
                  peak_yesterday_w: payload[:peak_power_yesterday_w],
                  chart_svg: SunDownChart.render(user, today),
                  dashboard_path: "/dashboard"
                })

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
          end
        end)

      {:error, :duplicate} ->
        :ok
    end
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

  defp clear_user_state(state, user_id) do
    case Map.get(state.users, user_id) do
      nil -> state
      %{timer: timer} when not is_nil(timer) -> Process.cancel_timer(timer)
      _ -> :ok
    end

    %{state | users: Map.delete(state.users, user_id)}
  end

  defp safe_get_user(user_id) do
    try do
      Repo.get(User, user_id)
    rescue
      _ -> nil
    end
  end

  defp idle_seconds do
    Application.get_env(:dtu_app, :sun_down_idle_seconds, @default_idle_seconds)
  end

  defp body_for(today, yesterday) do
    yield_diff = compare(today.today_yield, yesterday.today_yield, "kWh")
    peak_diff = compare(today.peak_power, yesterday.peak_power, "W")

    gettext(
      "Today: %{today_kwh} kWh%{yield_diff}, peak %{peak_w} W%{peak_diff}.",
      today_kwh: format_kwh(today.today_yield),
      yield_diff: yield_diff,
      peak_w: format_w(today.peak_power),
      peak_diff: peak_diff
    )
  end

  defp compare(today, yesterday, unit) when is_number(yesterday) do
    cond do
      today == yesterday ->
        gettext(" (same as yesterday)")

      true ->
        diff = today - yesterday
        sign = if diff > 0, do: "+", else: ""

        if unit == "kWh" do
          gettext(" (%{sign}%{diff} kWh vs yesterday)", sign: sign, diff: format_kwh(diff))
        else
          gettext(" (%{sign}%{diff} W vs yesterday)", sign: sign, diff: format_w(diff))
        end
    end
  end

  defp compare(_, _, _), do: ""

  # `today_yield` is already in kWh (see `build_payload/2`); pass
  # it through to the formatter. Power fields are already W.
  defp format_kwh(kwh) when is_number(kwh), do: :erlang.float_to_binary(kwh, decimals: 1)
  defp format_kwh(_), do: "—"

  defp format_w(w) when is_number(w), do: :erlang.float_to_binary(w, decimals: 1)
  defp format_w(_), do: "—"
end
