defmodule DtuApp.Notifications.YieldAnomaly.Payload do
  @moduledoc """
  Pure payload builders extracted from
  `DtuApp.Notifications.YieldAnomaly`.

  Owns the three pure helpers that shape a `yield_anomaly`
  notification payload:

    * `title/0` — the gettext-scoped notification title (alert
      tone — the producer's body copy leans into the
      "something is wrong, look at your array" framing)
    * `body/2` — the gettext-scoped notification body, which
      carries the diagnostic paragraph about how long the
      collapse lasted and what threshold we used
    * `build/3` — the full payload map the
      `Notifications.Dispatcher` and the in-page PubSub
      broadcast both consume

  Split mirrors `DtuApp.Notifications.DtuConnection.Payload`
  (and `SunDown.Payload`). Re-exposed through
  `DtuApp.Notifications.YieldAnomaly` via `defdelegate` so the
  producer's call sites and the existing test surface stay
  unchanged.

  ## Why these live in a sibling module

  Mirrors the DtuConnection.Payload rationale: the producer
  is a 564-line GenServer whose remaining logic is all
  state-machine + PubSub + DB; pulling the payload builders
  out keeps the producer's moduledoc focused on the firing
  semantics and lets unit tests exercise the title/body/build
  shapes without booting a GenServer.

  The `build/3` map shape is the contract
  `Notifications.broadcast/2` and `Dispatcher.fire/3`
  consume — `event`, `title`, `body`, `tag`, `since`. Changing
  the keys here is a downstream-visible change.

  ## Why `build/3` takes `now` as an argument

  The `:since` field is read by the email subject + body
  lines and by history drill-down UIs to render "at HH:MM".
  Stamping `DateTime.utc_now()` inline would make the
  payload time-sensitive to test ordering. Taking `now` as
  an argument lets the producer pass `DateTime.utc_now()`
  once per fire and lets unit tests pass a fixed `DateTime`.

  ## Diagnostic paragraph

  The producer now threads the actual collapse window
  (`collapse_minutes`) and the threshold that fired the
  alert (`threshold_w`) into `build/4`. The user sees a
  concrete "collapsed for 60 min while the sun was up"
  paragraph instead of the generic "for over 15 minutes"
  the old hard-coded copy used. The threshold is included
  so a user who reads the message and looks at the array
  can match the alert against their panel math ("15 W — my
  gateway itself uses about 5 W, so 15 W is 'the array went
  dark'").
  """

  use Gettext, backend: DtuAppWeb.Gettext

  @doc """
  Notification title (alert tone).
  """
  def title do
    gettext("⚠️ Production has stalled")
  end

  @doc """
  Notification body — second paragraph is the diagnostic
  carrying the actual collapse window + threshold that
  fired this alert.

  `collapse_minutes` is the floor-rounded minutes the fleet
  spent below the threshold before we fired. `threshold_w`
  is the W value the fleet sum had to drop below for the
  timer to arm.
  """
  def body(collapse_minutes, threshold_w)
      when is_integer(collapse_minutes) and is_number(threshold_w) do
    collapse_str = format_minutes(collapse_minutes)
    threshold_str = format_threshold(threshold_w)

    gettext(
      "Your panels stopped producing for %{duration} while the sun was up — the fleet sum stayed below %{threshold} even though no inverter reported an outage. Worth a look at the array.",
      duration: collapse_str,
      threshold: threshold_str
    )
  end

  def body(_collapse_minutes, _threshold_w), do: nil

  @doc """
  Build the full `yield_anomaly` payload map the dispatcher
  and the in-page PubSub broadcast consume.

  `now` is stamped on the `:since` field so tests can pass
  a fixed `DateTime` rather than racing the system clock;
  `collapse_minutes` and `threshold_w` thread into the
  diagnostic paragraph.

  `tag_date` is the dedup date for the tag
  (`yield_anomaly:YYYY-MM-DD`). The producer passes the
  user's local date here — `User.tz_offset_seconds` shifts
  the local date around midnight UTC, so a producer that
  just derived the tag from `now` would mis-tag users in
  non-UTC zones whose collapse fires in the last/first
  hour of the day. Keep this in sync with the producer's
  `user_today/1` (which writes the dedup row).

  The `body` field is a list (the email/layout pipeline
  expects a list of paragraphs; the dispatcher's history-row
  insert coerces it back to a single string for the `:body`
  column).
  """
  @spec build(DateTime.t(), non_neg_integer(), number(), Date.t()) :: map()
  def build(%DateTime{} = now, collapse_minutes, threshold_w, %Date{} = tag_date) do
    %{
      event: "yield_anomaly",
      title: title(),
      body: [body(collapse_minutes, threshold_w)],
      tag: "yield_anomaly:#{Date.to_iso8601(tag_date)}",
      since: now
    }
  end

  # ── formatting helpers ──────────────────────────────────────────────

  defp format_minutes(minutes) when minutes < 60 do
    gettext("%{n} minutes", n: minutes)
  end

  defp format_minutes(minutes) do
    hours = div(minutes, 60)
    rem_min = rem(minutes, 60)

    case rem_min do
      0 -> gettext("%{n} hours", n: hours)
      _ -> gettext("%{h} hours %{m} minutes", h: hours, m: rem_min)
    end
  end

  # Strip trailing `.0` for clean "15 W" rather than "15.0 W".
  defp format_threshold(w) when w == round(w), do: "#{round(w)} W"
  defp format_threshold(w), do: "#{w} W"
end
