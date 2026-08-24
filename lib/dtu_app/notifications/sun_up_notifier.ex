defmodule DtuApp.Notifications.SunUp do
  @moduledoc """
  Server-side producer for `event: "sun_up"` notifications.

  Subscribes to `dtu:reading` (same topic `SunDown` uses) and fires
  `DtuApp.Notifications.broadcast/2` once per user per local day
  when the user's fleet transitions from 0 W to > 0 W — i.e. the
  moment the array has woken up for the day. Receiver-side (in-page
  JS hook + native Web Push) does the user-visible work.

  "Once per user per day" is the scope: the user picks
  `notify_sun_up` on the `/notifications` page and gets a single
  morning ping, regardless of how many inverters they have. Per-DTU
  granularity would have produced a flurry of pings for users with
  several inverters waking up over the course of a few minutes; the
  single morning ping is the calmer UX.

  "Local day" uses the user's persisted `tz_offset_seconds` (set by
  the dashboard JS on every mount; default 0 = UTC for users who've
  never loaded the dashboard with TZ detection enabled). The date
  boundary rolls over at local midnight, not at 00:00 UTC — a Berlin
  user gets the "sun's up!" ping once for their day, regardless of
  where the array sits geographically.

  Reading-payload tolerance mirrors `SunDown`: production broadcasts
  a full `DtuApp.Devices.Reading` struct; some tests broadcast a
  stripped-down map (`%{dtu_id: id}`). Stripped maps without
  `mppt_index` or `ac_power` are treated as 0 W (a synthetic
  "device offline" reading).

  The "fleet woke up" trigger is intentional: a single inverter
  blinking on and off mid-day (clouds, brief faults) is not a
  sun-up event — the trigger is a *fleet-wide* 0 W → > 0 W
  transition, which naturally only happens at sunrise (or after a
  full outage clears). Per-inverter wake-ups within a day are
  deduped by the per-user `fired_on_date` cache.

  Test override: `Application.put_env(:dtu_app, :sun_up_offset_seconds,
  N)` overrides the per-user TZ lookup with a fixed offset
  (`nil` clears it). The notification tests set this to a stable
  value rather than threading it through every fixture.
  """

  use GenServer

  use Gettext, backend: DtuAppWeb.Gettext

  require Logger

  alias DtuApp.Accounts.User
  alias DtuApp.Notifications
  alias DtuApp.Repo

  @reading_topic "dtu:reading"

  @doc "The PubSub topic this producer subscribes to. Exposed for tests."
  def reading_topic, do: @reading_topic

  @doc """
  Compute the user's local `Date` for `now_utc`.

  Subtracts the user's `tz_offset_seconds` from the UTC instant
  and takes the resulting calendar date. A user with
  `tz_offset_seconds: 7200` (CEST = UTC+2) at 2026-08-23T23:30Z
  gets `2026-08-24` (their local tomorrow).
  """
  @spec local_date(DateTime.t(), integer()) :: Date.t()
  def local_date(%DateTime{} = now_utc, offset_seconds) when is_integer(offset_seconds) do
    shifted = DateTime.add(now_utc, offset_seconds, :second)
    DateTime.to_date(shifted)
  end

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    Phoenix.PubSub.subscribe(DtuApp.PubSub, @reading_topic)
    Logger.info("[Notifications.SunUp] subscribed to #{@reading_topic}")
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
        {:noreply, state}

      true ->
        state = update_user_power(state, device_id, power_w)
        {:noreply, maybe_fire(state, device_id)}
    end
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
  # (matches `SunDown.reading_ac_power/1` semantics).
  defp reading_ac_power(%{mppt_index: 0, ac_power: w}) when is_number(w), do: w * 1.0
  defp reading_ac_power(%{mppt_index: 0, ac_power: nil}), do: 0.0
  defp reading_ac_power(%{ac_power: _}), do: :ignore
  defp reading_ac_power(_), do: :ignore

  # Update the per-user fleet-power state with this device's latest
  # reading. Cache miss on the device → user mapping is resolved via
  # the DB (the `Device.user_id` FK lookup); cache hits are O(1).
  #
  # `Map.update/4`'s default is inserted verbatim when the user key
  # is missing — the update fn isn't called. We work around that by
  # reading with `Map.get/3`, applying the device write in both
  # branches, and writing the result back via `Map.put/4`. Without
  # this, the first reading for a fleet leaves `devices: %{}` and
  # `maybe_fire/2` never crosses the 0 W threshold.
  defp update_user_power(state, device_id, power_w) do
    user_id = resolve_user_id(state, device_id)

    if is_nil(user_id) do
      state
    else
      existing = Map.get(state.users, user_id, %{devices: %{}, fired_on_date: nil})
      new_devices = Map.put(existing.devices, device_id, power_w)
      new_user_state = %{existing | devices: new_devices}

      users = Map.put(state.users, user_id, new_user_state)
      device_to_user = Map.put(state.device_to_user, device_id, user_id)

      %{state | users: users, device_to_user: device_to_user}
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

  # Check whether this reading flipped the user's fleet from 0 W to
  # > 0 W and we haven't fired yet today (in the user's local TZ).
  # If so, build the payload and fire via Notifications.broadcast/2.
  defp maybe_fire(state, device_id) do
    user_id = Map.get(state.device_to_user, device_id)

    if is_nil(user_id) do
      state
    else
      case Map.get(state.users, user_id) do
        nil ->
          state

        %{devices: devices, fired_on_date: fired_on_date} = _user_state ->
          fleet_w = devices |> Map.values() |> Enum.sum()

          cond do
            # Fleet still asleep — nothing to do.
            fleet_w <= 0.0 ->
              state

            # Fleet woke up but we already fired for this user's
            # local day — record the date so the next roll-over
            # knows when the "not yet fired" window opens up.
            not is_nil(fired_on_date) ->
              state

            true ->
              case safe_get_user(user_id) do
                nil ->
                  state

                user ->
                  today = user_today(user)

                  # Re-check inside the GenServer process: another
                  # reading racing through the pipeline could have
                  # fired first. The fired_on_date write is the
                  # single source of truth.
                  state =
                    Map.update!(state, :users, fn users ->
                      Map.update!(users, user_id, fn u ->
                        %{u | fired_on_date: today}
                      end)
                    end)

                  if fired_on_date != today do
                    # The SunUp producer runs as a long-lived GenServer
                    # without a request context. Wrap `fire/1` (which
                    # builds the gettext payload and calls
                    # `Notifications.broadcast/2`) in the user's locale
                    # so the title/body strings are generated in the
                    # right language — both the in-page PubSub
                    # broadcast and the service-worker push fan-out
                    # (handled inside `Notifications.broadcast/2` via
                    # its own `Gettext.with_locale/2` wrapper) carry
                    # that locale.
                    Gettext.with_locale(
                      DtuAppWeb.Gettext,
                      user.locale || "en",
                      fn -> fire(user) end
                    )
                  end

                  state
              end
          end
      end
    end
  end

  # Resolve the user's "today" with the test override applied.
  # `Application.put_env(:dtu_app, :sun_up_offset_seconds, N)` makes
  # the producer pretend every user has offset N (useful for the
  # date-rollover tests). `nil` clears it.
  defp user_today(%User{tz_offset_seconds: stored_offset}) do
    offset =
      case Application.get_env(:dtu_app, :sun_up_offset_seconds, :__unset__) do
        :__unset__ -> stored_offset
        nil -> 0
        n when is_integer(n) -> n
      end

    local_date(DateTime.utc_now(), offset)
  end

  defp safe_get_user(user_id) do
    try do
      Repo.get(User, user_id)
    rescue
      _ -> nil
    end
  end

  # The user-visible payload. Title + body are gettext strings, but
  # they're wrapped in `Gettext.with_locale/2` at the call site (see
  # `maybe_fire/2`) so they pick up the user's locale — the
  # SunUp GenServer has no request context, so a bare `gettext/1`
  # would default to whatever Gettext was initialized with (≈ "en")
  # regardless of preference. The opt-in gate for native push lives
  # in `DtuApp.Notifications.native_push_enabled?/2` — the in-page
  # broadcast is unconditional, matching the SunDown pattern.
  defp fire(%User{} = user) do
    Notifications.broadcast(user.id, %{
      event: "sun_up",
      title: gettext("☀️ The sun's awake!"),
      body: sun_up_body(),
      tag: "sun_up:#{Date.to_iso8601(Date.utc_today())}"
    })
  end

  # Playful tone — lean into the morning energy rather than the dry
  # "production has started" default.
  defp sun_up_body do
    gettext("Your panels are sipping sunshine — first power of the day. Here's to a sunny one!")
  end
end
