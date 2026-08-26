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
  deduped by the per-user `sun_up_fires` row.

  ## Preference gate (producer-level)

  The producer itself checks `User.notify_sun_up` before doing
  anything visible — unlike `DtuConnection` and `SunDown` (which
  always publish and rely on `Notifications.broadcast/2` to gate
  the *native push* path while still recording history and
  publishing in-page). Sun-up is different: the user explicitly
  asked for "not sent, when disabled", so when the toggle is off
  we suppress the whole flow — no in-page broadcast, no native
  push, no history entry.

  ## Dedup persistence

  Dedup state lives in the `sun_up_fires` table (one row per
  user per local date). On every 0 W → > 0 W transition the
  producer computes the user's local date and attempts an insert;
  the unique `(user_id, fired_on)` constraint makes the insert
  idempotent — a second fire for the same user on the same date
  fails with `Ecto.ConstraintError`, which we swallow. The same
  supplier-level check protects against a duplicate fire racing
  through the producer after a GenServer restart (the previous
  in-memory `fired_on_date` cache was lost on every restart).

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
  alias DtuApp.Notifications.SunUpFire
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
    # In-memory state only carries the per-user latest fleet reading
    # plus a device→user cache (resolved via a single DB lookup per
    # device, then memoised). Per-user dedup state lives in the
    # `sun_up_fires` table — see moduledoc.
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

  # Record this device's latest reading in the per-user fleet-power
  # state. The fleet-power bookkeeping is still in-memory (it has to
  # be — it's the threshold that *triggers* the fire). The per-user
  # dedup record, by contrast, is in DB (see moduledoc).
  #
  # Two-step write (seed-if-missing, then update) because Elixir's
  # `Map.update/4` returns the default verbatim on a missing key —
  # the lambda is *not* called — which would silently drop the
  # first reading for any user the process has never seen before
  # (fleet power stays at 0 W and `sun_up` would never fire).
  defp update_user_power(state, device_id, power_w) do
    user_id = resolve_user_id(state, device_id)

    if is_nil(user_id) do
      state
    else
      users =
        state.users
        |> Map.put_new(user_id, %{devices: %{}})
        |> Map.update!(user_id, fn u ->
          %{u | devices: Map.put(u.devices, device_id, power_w)}
        end)

      %{
        state
        | users: users,
          device_to_user: Map.put(state.device_to_user, device_id, user_id)
      }
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

  # Check whether the user's fleet just crossed 0 W → > 0 W and fire
  # if so. Dedup is at the DB layer (insert into `sun_up_fires`); the
  # in-memory state is purely the threshold check.
  defp maybe_fire(state, device_id) do
    user_id = Map.get(state.device_to_user, device_id)

    if is_nil(user_id) do
      state
    else
      case Map.get(state.users, user_id) do
        nil ->
          state

        %{devices: devices} ->
          fleet_w = devices |> Map.values() |> Enum.sum()

          if fleet_w > 0.0 do
            case safe_get_user(user_id) do
              nil ->
                state

              user ->
                # Producer-level preference gate: respect
                # `User.notify_sun_up` before doing anything visible.
                # The user explicitly asked for "not sent, when
                # disabled", so we suppress the whole flow (in-page
                # broadcast, native push, history) — at the cost of
                # being inconsistent with `DtuConnection` / `SunDown`,
                # which always publish + record history and only gate
                # the native-push path. Sun-up is a single low-value
                # greeting and skipping it cleanly is the better UX.
                if user.notify_sun_up == true do
                  try_fire(user)
                end

                state
            end
          else
            state
          end
      end
    end
  end

  # Insert into `sun_up_fires`. The unique `(user_id, fired_on)`
  # constraint makes a duplicate insert a no-op for our purposes
  # (any second fire on the same day raises `Ecto.ConstraintError`,
  # which we swallow). The actual `fire/1` call happens *only* when
  # the insert succeeded — that prevents a race where two readings
  # arrive in close succession and both compute `today` before
  # either insert has been committed.
  defp try_fire(%User{} = user) do
    today = user_today(user)

    case insert_fire(user.id, today) do
      :ok ->
        # The SunUp producer runs as a long-lived GenServer without a
        # request context. Wrap `fire/2` (which builds the gettext
        # payload and calls `Notifications.broadcast/2`) in the user's
        # locale so the title/body strings are generated in the right
        # language — both the in-page PubSub broadcast and the
        # service-worker push fan-out (handled inside
        # `Notifications.broadcast/2` via its own `Gettext.with_locale/2`
        # wrapper) carry that locale.
        Gettext.with_locale(DtuAppWeb.Gettext, user.locale || "en", fn ->
          fire(user, today)
        end)

      {:error, :duplicate} ->
        :ok
    end
  end

  defp insert_fire(user_id, %Date{} = fired_on) do
    %SunUpFire{}
    |> SunUpFire.changeset(%{user_id: user_id, fired_on: fired_on})
    # Source-of-truth constraint is the composite PK on
    # `(user_id, fired_on)` — set up in the migration.
    #
    # Why `on_conflict: :raise` instead of `on_conflict: :nothing`?
    # Because the schema declares `primary_key: false`, Ecto omits
    # `RETURNING` from the INSERT — and with no `RETURNING`, there's
    # no row for Ecto to return. The `:nothing` path silently returns
    # `{:ok, %SunUpFire{}}` for both an actual insert AND a swallowed
    # conflict (the struct is built from the changeset, not the DB),
    # which would let every reading fire. Raising and catching the
    # `Ecto.ConstraintError` gives a clean duplicate signal.
    |> Repo.insert(on_conflict: :raise)
    |> case do
      {:ok, %SunUpFire{}} -> :ok
      {:error, _changeset} -> {:error, :duplicate}
    end
  catch
    :error, %Ecto.ConstraintError{} -> {:error, :duplicate}
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
  # `try_fire/1`) so they pick up the user's locale — the SunUp
  # GenServer has no request context, so a bare `gettext/1` would
  # default to whatever Gettext was initialized with (≈ "en")
  # regardless of preference.
  defp fire(%User{} = user, %Date{} = today) do
    Notifications.broadcast(user.id, %{
      event: "sun_up",
      title: gettext("☀️ The sun's awake!"),
      body: sun_up_body(),
      # Tag carries the producer's view of "today" — the date the
      # producer actually fired on, not the wall-clock UTC date.
      # Two producers in different timezones would otherwise share
      # a single tag and cause the in-page dedup to miss.
      tag: "sun_up:#{Date.to_iso8601(today)}"
    })
  end

  # Playful tone — lean into the morning energy rather than the dry
  # "production has started" default.
  defp sun_up_body do
    gettext("Your panels are sipping sunshine — first power of the day. Here's to a sunny one!")
  end
end
