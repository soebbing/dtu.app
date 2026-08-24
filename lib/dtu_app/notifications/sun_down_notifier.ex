defmodule DtuApp.Notifications.SunDown do
  @moduledoc """
  Server-side producer for `event: "sun_down"` notifications.

  Watches every parsed reading on `dtu:reading`, maintains a per-user
  fleet-power state (`%{user_id => %{devices: %{device_id => latest_w},
  zero_since: ts | nil, fire_timer: ref | nil}}`), and — once the
  fleet has been at 0 W for `:sun_down_idle_seconds` (default 15 min)
  — fires `DtuApp.Notifications.broadcast/2` with the day's totals
  (today + yesterday, both as kWh and peak W). The receiver side
  (in-page JS hook + native Web Push) does the user-visible work;
  this module is the producer that lives **outside** the LiveView so
  the summary also fires when the user has no tab open.

  Why a timer instead of "fire on every reading at 0 W"? When the sun
  is fully down, no more readings arrive. The only reliable trigger
  is a timer set the moment the fleet first hits 0 W and not reset
  until either the fleet wakes up again or the timer fires.

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
  alias DtuApp.Notifications
  alias DtuApp.Repo
  alias DtuApp.Time

  @reading_topic "dtu:reading"

  # Lazy-resolved on every timer arm so tests can swap the value at
  # runtime via `Application.put_env` without recompiling.
  @default_idle_seconds 15 * 60

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
  # reading. Cache miss on the device → user mapping is resolved via
  # the DB (the `Device.user_id` FK lookup); cache hits are O(1).
  defp update_user_power(state, device_id, power_w) do
    user_id = resolve_user_id(state, device_id)

    if is_nil(user_id) do
      state
    else
      users =
        Map.update(state.users, user_id, %{devices: %{}, zero_since: nil, timer: nil}, fn u ->
          devices = Map.put(u.devices, device_id, power_w)
          %{u | devices: devices}
        end)

      %{state | users: users, device_to_user: Map.put(state.device_to_user, device_id, user_id)}
    end
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
          fleet_w = devices |> Map.values() |> Enum.sum()

          cond do
            fleet_w > 0.0 and timer != nil ->
              Process.cancel_timer(timer)
              put_in(state.users[user_id], %{user_state | zero_since: nil, timer: nil})

            fleet_w > 0.0 ->
              put_in(state.users[user_id], %{user_state | zero_since: nil})

            fleet_w == 0.0 and zero_since == nil ->
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

      %{devices: devices, zero_since: ts} ->
        fleet_w = devices |> Map.values() |> Enum.sum()

        # Race window: a non-zero reading may have arrived between the
        # timer being armed and it firing. Re-check before broadcasting.
        if fleet_w == 0.0 and not is_nil(ts) do
          case safe_get_user(user_id) do
            nil ->
              clear_user_state(state, user_id)

            user ->
              # The SunDown producer runs as a long-lived GenServer
              # without a request context, so `gettext/1` would default
              # to whatever Gettext was initialized with (≈ "en")
              # regardless of the user's preference. Wrap the
              # build_payload + broadcast pair in the user's locale so
              # the title/body strings are generated in the right
              # language — both the in-page PubSub broadcast and the
              # service-worker push fan-out (handled inside
              # `Notifications.broadcast/2` via its own
              # `Gettext.with_locale/2` wrapper) carry that locale.
              Gettext.with_locale(DtuAppWeb.Gettext, user.locale || "en", fn ->
                payload = build_payload(user, Date.utc_today())

                if payload do
                  Notifications.broadcast(user_id, payload)
                end
              end)

              clear_user_state(state, user_id)
          end
        else
          clear_user_state(state, user_id)
        end
    end
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
