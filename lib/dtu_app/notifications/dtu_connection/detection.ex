defmodule DtuApp.Notifications.DtuConnection.Detection do
  @moduledoc """
  Pure gate + DB-rescue helpers extracted from
  `DtuApp.Notifications.DtuConnection`.

  Owns the four gating predicates that drive the producer's
  `fire / don't-fire` decision on every connect / disconnect
  broadcast — `recently_active?/1`, `prior_uptime?/1`,
  `cooldown_over?/1` — plus the two defensive DB lookups
  (`safe_lookup/1` for the live `Dtu` row, `safe_get_user/1`
  for the locale-aware `User` lookup inside `fire/3`). Every
  function here is either pure (clock + state) or wraps a
  `Repo.get/2` in a `:rescue` so a brief DB hiccup degrades
  to "no fire" rather than crashing the producer.

  Split mirrors `DtuApp.Notifications.SunDown.Detection` and
  the `DtuApp.Devices/Stats` sub-folder pattern.
  Re-exported through `DtuApp.Notifications.DtuConnection` via
  `defdelegate` so the notifier's call sites and the existing
  test surface stay unchanged.

  ## Constant ownership

  The `@recency_seconds`, `@prior_uptime_seconds`, and
  `@cooldown_seconds` constants live here (Detection is the
  only consumer). The notifier's moduledoc references them in
  prose; the notifier module itself never reads them, so
  keeping them here doesn't fragment ownership.
  """

  alias DtuApp.Accounts.User
  alias DtuApp.Devices.Dtu
  alias DtuApp.Repo
  alias DtuApp.Time

  # Stale-post-deploy-reconnect threshold. Same value the previous
  # in-LiveView check used (see git history of `dashboard_live.ex`
  # before this module existed). A disconnect whose `last_seen_at`
  # is older than this is treated as a stale post-deploy reconnect,
  # not a real offline event.
  @recency_seconds 300

  # The "must have been online continuously for X before a
  # disconnect is notification-worthy" threshold. Raised from the
  # historical `@recency_seconds` (5 min) after user reports that
  # inverters which flap every few minutes (connect → ~10 min later
  # → disconnect → reconnect → ~10 min later → disconnect …) still
  # produced one push per cycle. 15 min catches the long-cycle
  # flapper without dropping notifications on devices that genuinely
  # reconnect and stay up.
  @prior_uptime_seconds 900

  # Per-device re-fire cooldown. After a `:went_offline` fires, the
  # same device is suppressed for this many seconds — even across
  # connect/disconnect cycles. See the notifier's moduledoc for the
  # design rationale.
  @cooldown_seconds 1800

  @doc """
  Connect-side recency guard: the `last_seen_at` reading must be
  within `@recency_seconds` of now for a connect to count as
  "back online". A reconnect whose prior reading is older than
  the threshold is treated as a stale post-deploy re-attachment.

  Returns `false` for non-DateTime input (the cache holds `nil`
  for `last_seen_at` when we have no live reading; the conservative
  answer is "don't fire").
  """
  def recently_active?(%DateTime{} = last_seen_at) do
    DateTime.after?(last_seen_at, DateTime.add(Time.utc_now(), -@recency_seconds, :second))
  end

  def recently_active?(_), do: false

  @doc """
  Disconnect-side prior-uptime gate: the device must have been
  online for at least `@prior_uptime_seconds` before a disconnect
  can be called "offline". Without this gate, a brief WiFi
  reconnect (connect → 30s later disconnect) would fire "Your
  inverter has gone offline" — a misleading notification on a
  device that was never actually online long enough to merit one.

  A `nil` value means we've never seen a connect for this device;
  the conservative answer is to suppress the fire.
  """
  def prior_uptime?(%DateTime{} = connected_at) do
    DateTime.before?(connected_at, DateTime.add(Time.utc_now(), -@prior_uptime_seconds, :second))
  end

  def prior_uptime?(_), do: false

  @doc """
  Per-device re-fire cooldown gate: returns true iff the
  re-fire window is open. `nil` (never fired) is always open.
  A timestamp within `@cooldown_seconds` is closed (suppress the
  fire). A timestamp older than `@cooldown_seconds` is open.
  """
  def cooldown_over?(nil), do: true

  def cooldown_over?(%DateTime{} = last_fired_at) do
    DateTime.before?(
      last_fired_at,
      DateTime.add(Time.utc_now(), -@cooldown_seconds, :second)
    )
  end

  @doc """
  Defensive lookup of the live `Dtu` row for `device_id`. Returns
  a map with `:user_id`, `:name`, and `:last_seen_at`, or `nil`
  when the device is missing or the DB briefly hiccups. Wrapped
  in `:rescue` so a producer crash doesn't break the consumer's
  GenServer.
  """
  def safe_lookup(device_id) do
    try do
      case Repo.get(Dtu, device_id) do
        nil ->
          nil

        %{user_id: user_id, name: name, last_seen_at: last_seen_at} ->
          %{user_id: user_id, name: name, last_seen_at: last_seen_at}
      end
    rescue
      _ -> nil
    end
  end

  @doc """
  Defensive lookup of the `User` struct for `user_id`. The
  producer's `fire/3` needs the full struct (locale-aware
  gettext, `notify_dtu_connection` flag) — not just the id.
  Wrapped in `:rescue` so a brief DB hiccup degrades to "no
  fire" rather than crashing the producer.
  """
  def safe_get_user(user_id) do
    try do
      Repo.get(User, user_id)
    rescue
      _ -> nil
    end
  end
end
