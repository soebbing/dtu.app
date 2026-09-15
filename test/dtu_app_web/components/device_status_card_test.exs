defmodule DtuAppWeb.DeviceStatusCardTest do
  @moduledoc """
  Render tests for `DtuAppWeb.DeviceStatusCard`.

  Pure render-only tests — no LiveView, no GenServer. We build a
  lightweight `%Dtu{}` struct directly (skipping the
  `device_fixture/2` DB round-trip) because the predicates this
  component consults (`Dtu.online?/1`, `Dtu.nighttime?/1`,
  `DtuKinds.ro_sink_kind?/1`) only read `last_seen_at`,
  `last_power_at`, and `kind` from the struct — the same fields a
  render-only test can fill in by hand.

  Uses `DtuApp.DataCase` because `Dtu.online?/1` and
  `Dtu.nighttime?/1` both call `DtuApp.Time.utc_now()` which queries
  the database through the time cache. The sandbox checkout is the
  same one DataCase sets up for any DB-using test; render-only here
  just means "no LiveView socket, no PubSub".

  Covers the three-state pill (online+producing / online+nighttime
  / offline), the sink badge, the error badge (including the "99+"
  overflow), the last-seen "never" / relative label paths, and the
  link target.
  """

  # Not `async: true` — `Dtu.online?/1` and `Dtu.nighttime?/1` both
  # call `DtuApp.Time.utc_now()` which queries the database through
  # the time cache, so this test needs a sandbox connection. DataCase
  # sets up an Ecto sandbox checkout per test.
  use DtuApp.DataCase, async: false

  import Phoenix.LiveViewTest

  alias DtuApp.Devices.Dtu
  alias DtuAppWeb.DeviceStatusCard

  # Build a Dtu struct with the three fields the predicates consult.
  # `id` is what the link target + dom-id fragments use; `name` is
  # what renders in the card title. We set the bare minimum to make
  # the predicates return the desired truthy / falsy answer.
  defp dtu(attrs) do
    now = DateTime.utc_now()

    defaults = %{
      id: 42,
      name: "Test Inverter",
      kind: :opendtu,
      last_seen_at: now,
      last_power_at: now
    }

    struct(Dtu, Map.merge(defaults, Map.new(attrs)))
  end

  describe "three-state pill" do
    test "online + producing renders the green pill" do
      now = DateTime.utc_now()

      html =
        render_component(&DeviceStatusCard.device_status_card/1, %{
          device: dtu(%{last_seen_at: now, last_power_at: now}),
          error_count: 0
        })

      assert html =~ ~s(id="device-card-42")
      assert html =~ "bg-emerald-100"
      # The pill label text. Phoenix renders text nodes with
      # surrounding whitespace, so we match the bare label rather
      # than a `label</span>` close-tag pattern.
      assert html =~ "\n          online\n        "
      # Title tooltip explains the producing state.
      assert html =~ "Online — this DTU has reported AC power within the last 2 minutes"
    end

    test "online + nighttime renders the amber pill (alive but no power data)" do
      now = DateTime.utc_now()

      html =
        render_component(&DeviceStatusCard.device_status_card/1, %{
          device: dtu(%{last_seen_at: now, last_power_at: nil}),
          error_count: 0
        })

      assert html =~ "bg-amber-100"
      assert html =~ "\n          nighttime\n        "

      assert html =~
               "Nighttime — MQTT is alive but no AC power reading has arrived"
    end

    test "offline (stale last_seen_at) renders the zinc pill" do
      stale = DateTime.add(DateTime.utc_now(), -3_600, :second)

      html =
        render_component(&DeviceStatusCard.device_status_card/1, %{
          device: dtu(%{last_seen_at: stale}),
          error_count: 0
        })

      assert html =~ "bg-zinc-100"
      assert html =~ "\n          offline\n        "
      assert html =~ "Offline — no MQTT activity in the last 5 minutes"
    end

    test "offline (nil last_seen_at) renders the zinc pill" do
      # Brand-new device, never reported — same conservative "offline"
      # answer as a stale reading.
      html =
        render_component(&DeviceStatusCard.device_status_card/1, %{
          device: dtu(%{last_seen_at: nil, last_power_at: nil}),
          error_count: 0
        })

      assert html =~ "bg-zinc-100"
      assert html =~ "\n          offline\n        "
    end
  end

  describe "sink badge" do
    test "renders for a mqtt_ro_sink device" do
      html =
        render_component(&DeviceStatusCard.device_status_card/1, %{
          device: dtu(%{kind: :mqtt_ro_sink}),
          error_count: 0
        })

      assert html =~ ~s(id="dtu-sink-badge-42")
      # The "sink" label is the visible badge text; the icon `<span>`
      # sits inside the badge before the text node, so a bare `sink`
      # match is the right pattern (no direct `<span>...</span>`
      # close to the label).
      assert html =~ "\n              sink\n            "
    end

    test "does not render for a non-sink device" do
      html =
        render_component(&DeviceStatusCard.device_status_card/1, %{
          device: dtu(%{kind: :opendtu}),
          error_count: 0
        })

      refute html =~ "dtu-sink-badge"
      refute html =~ "\n              sink\n            "
    end
  end

  describe "error badge" do
    test "renders when error_count > 0" do
      html =
        render_component(&DeviceStatusCard.device_status_card/1, %{
          device: dtu(%{}),
          error_count: 1
        })

      assert html =~ ~s(id="dtu-error-edge-badge-42")
      assert html =~ ~s(aria-label="1 distinct errors")
      # The card link also flips its aria-label to the error variant.
      assert html =~ ~s(aria-label="1 errors, view details")
      # The rose border is set on the card frame.
      assert html =~ "border-rose-300"
    end

    test "renders the exact count for moderate error counts" do
      html =
        render_component(&DeviceStatusCard.device_status_card/1, %{
          device: dtu(%{}),
          error_count: 50
        })

      assert html =~ ~s(aria-label="50 distinct errors")
      # The count is the badge body — match the surrounding whitespace
      # rather than a `count</span>` close-tag (which the icon-less
      # text-only badge still wouldn't render directly).
      assert html =~ "\n      50\n    "
    end

    test "caps at 99+ when error_count > 99" do
      html =
        render_component(&DeviceStatusCard.device_status_card/1, %{
          device: dtu(%{}),
          error_count: 150
        })

      assert html =~ "\n      99+\n    "
      refute html =~ "\n      150\n    "
      # The aria-label keeps the real count for screen readers.
      assert html =~ ~s(aria-label="150 distinct errors")
    end

    test "omits the badge entirely when error_count == 0" do
      html =
        render_component(&DeviceStatusCard.device_status_card/1, %{
          device: dtu(%{}),
          error_count: 0
        })

      refute html =~ "dtu-error-edge-badge"
      # Card frame uses the default zinc border, not the rose error border.
      refute html =~ "border-rose-300"
      # Card link uses the default "Manage device" aria-label.
      assert html =~ ~s(aria-label="Manage device")
    end
  end

  describe "last-seen line" do
    test "renders 'never' when last_seen_at is nil" do
      html =
        render_component(&DeviceStatusCard.device_status_card/1, %{
          device: dtu(%{last_seen_at: nil}),
          error_count: 0
        })

      assert html =~ "Last seen:"
      # The "never" branch has no `title=` attribute on the inner
      # span, so it renders without the whitespace the relative-label
      # branch inserts.
      assert html =~ ~s(<span>never</span>)
    end

    test "renders a relative label when last_seen_at is a few minutes ago" do
      # Five minutes is comfortably inside the "minutes ago" branch
      # (60 ≤ diff < 3_600), with margin for the test running a bit
      # slower than wall-clock would suggest.
      at = DateTime.add(DateTime.utc_now(), -300, :second)

      html =
        render_component(&DeviceStatusCard.device_status_card/1, %{
          device: dtu(%{last_seen_at: at}),
          error_count: 0
        })

      assert html =~ "Last seen:"
      assert html =~ "minutes ago"
      # Hover tooltip carries the absolute UTC timestamp for screen-readers
      # and tooltip-equipped users who want exact values.
      assert html =~ Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")
    end
  end

  describe "link target" do
    test "links to /devices?expand=<id>" do
      html =
        render_component(&DeviceStatusCard.device_status_card/1, %{
          device: dtu(%{id: 123}),
          error_count: 0
        })

      assert html =~ ~s(href="/devices?expand=123")
    end
  end
end
