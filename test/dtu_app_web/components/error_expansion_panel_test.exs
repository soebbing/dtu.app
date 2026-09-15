defmodule DtuAppWeb.ErrorExpansionPanelTest do
  @moduledoc """
  Render tests for `DtuAppWeb.ErrorExpansionPanel`.

  Pure render-only tests — no LiveView, no DB. The component
  consumes the same `%{message, occurrences, last_seen}` shape
  that `DtuApp.Devices.list_dtu_error_groups/1` returns, so we
  build test fixtures directly from message strings + counts +
  a `DateTime` rather than wiring up a DB round-trip.

  Uses `DtuApp.DataCase` because the per-group "last seen"
  label is a `format_relative/1` call that bottoms out in
  `DtuApp.Time.utc_now()`, which queries the database through
  the time cache. The sandbox checkout is the same one
  DataCase sets up for any DB-using test; render-only here just
  means "no LiveView socket, no PubSub".

  Covers:

    - Panel chrome: `device-error-panel-<id>` dom id +
      `data-test="error-panel"` selector + rose-tinted borders.
    - Empty state: "No errors recorded for this DTU yet." caption
      when `error_groups == []`.
    - Grouped state heading: "N distinct, M total occurrences"
      aggregation when groups are present.
    - Per-group rendering: kind chip + reason text + topic
      (when parsed) + payload (when parsed) + "%{n} occurrences"
      footer.
    - Close button: `btn-close-error-panel-<id>` id +
      `phx-click="close_expanded_errors"` wiring.
  """

  # Not `async: true` — `format_relative/1` calls
  # `DtuApp.Time.utc_now()` which queries the database through
  # the time cache, so this test needs a sandbox connection.
  use DtuApp.DataCase, async: false

  import Phoenix.LiveViewTest

  alias DtuApp.Devices.Dtu
  alias DtuAppWeb.ErrorExpansionPanel

  # Build a Dtu struct with the one field the panel reads (`id`).
  # `name` is reserved for future per-row labels but not
  # currently consumed by the component.
  defp dtu(attrs) do
    defaults = %{
      id: 42,
      name: "Test Inverter"
    }

    struct(Dtu, Map.merge(defaults, Map.new(attrs)))
  end

  # Build an error group from a raw `message` string. The
  # panel calls `parse_error_message/1` to turn the message
  # into the structured parts the template renders. `last_seen`
  # defaults to "2 hours ago" so the footer takes the "%{n}
  # hours ago" branch — comfortably inside the relative-time
  # format even if the test takes a second or two to run.
  defp group(message, attrs \\ []) do
    defaults = %{
      message: message,
      occurrences: 1,
      last_seen: DateTime.add(DateTime.utc_now(), -7_200, :second)
    }

    Map.merge(defaults, Map.new(attrs))
  end

  describe "panel chrome" do
    test "renders the panel with the device-error-panel-<id> dom id and rose-tinted chrome" do
      html =
        render_component(&ErrorExpansionPanel.error_expansion_panel/1, %{
          device: dtu(%{id: 7}),
          error_groups: []
        })

      assert html =~ ~s(id="device-error-panel-7")
      # `data-test="error-panel"` is the selector the dashboard's
      # `?expand=<id>` deep-link integration tests target.
      assert html =~ ~s(data-test="error-panel")
      assert html =~ "bg-rose-50/40"
      assert html =~ "border-l-4 border-r border-b border-rose-300"
    end

    test "close button has the btn-close-error-panel-<id> id and routes to close_expanded_errors" do
      html =
        render_component(&ErrorExpansionPanel.error_expansion_panel/1, %{
          device: dtu(%{id: 7}),
          error_groups: []
        })

      assert html =~ ~s(id="btn-close-error-panel-7")
      assert html =~ ~s(phx-click="close_expanded_errors")
      # The "Close" label is the visible button text.
      assert html =~ "✕ Close"
    end
  end

  describe "empty state" do
    test "renders the 'No errors recorded' caption when error_groups is empty" do
      html =
        render_component(&ErrorExpansionPanel.error_expansion_panel/1, %{
          device: dtu(%{}),
          error_groups: []
        })

      assert html =~ "No errors recorded for this DTU yet."
      # The grouped-state heading is NOT shown when there are no
      # groups — the "N distinct, M total occurrences" template
      # only renders when @error_groups != [].
      refute html =~ "distinct"
      refute html =~ "occurrences"
    end

    test "does NOT render a `<ul>` when error_groups is empty" do
      html =
        render_component(&ErrorExpansionPanel.error_expansion_panel/1, %{
          device: dtu(%{}),
          error_groups: []
        })

      refute html =~ "<ul"
      refute html =~ "<li"
    end
  end

  describe "grouped state heading" do
    test "aggregates distinct + total occurrences across groups" do
      # 2 distinct groups with 3 + 1 = 4 total occurrences.
      groups = [
        group("Shelly topic mismatch", %{occurrences: 3}),
        group("Different error", %{occurrences: 1})
      ]

      html =
        render_component(&ErrorExpansionPanel.error_expansion_panel/1, %{
          device: dtu(%{}),
          error_groups: groups
        })

      assert html =~ "2 distinct"
      assert html =~ "4 total occurrences"
    end

    test "renders a single distinct / single occurrence when one group is present" do
      html =
        render_component(&ErrorExpansionPanel.error_expansion_panel/1, %{
          device: dtu(%{}),
          error_groups: [group("Single error", %{occurrences: 1})]
        })

      assert html =~ "1 distinct"
      assert html =~ "1 total occurrences"
    end
  end

  describe "per-group rendering — topic-bearing format" do
    test "renders the kind chip + reason + topic for an OpenDTU uplink rejection" do
      # `parse_error_message/1` parses this into
      # `%{kind: "OpenDTU", reason: ..., topic: "solar/INV1/realtime"}`.
      msg = "OpenDTU uplink rejected (malformed JSON on topic \"solar/INV1/realtime\")"

      html =
        render_component(&ErrorExpansionPanel.error_expansion_panel/1, %{
          device: dtu(%{}),
          error_groups: [group(msg)]
        })

      # Kind chip carries the DTU kind (without the surrounding
      # "uplink rejected" suffix — `parse_uplink_rejected/1` strips
      # that and puts it in `reason`).
      assert html =~ "OpenDTU"
      assert html =~ "malformed JSON"
      # Topic chip renders the unquoted topic string.
      assert html =~ "solar/INV1/realtime"
      assert html =~ ~s(data-test="error-topic")
    end

    test "renders the reason but no topic for a status patch failure" do
      # `parse_status_patch_failed/1` produces
      # `%{kind: "AhoyDTU status patch failed", reason: ..., topic: nil}`.
      msg = "AhoyDTU status patch failed: not connected"

      html =
        render_component(&ErrorExpansionPanel.error_expansion_panel/1, %{
          device: dtu(%{}),
          error_groups: [group(msg)]
        })

      assert html =~ "AhoyDTU status patch failed"
      assert html =~ "not connected"
      refute html =~ ~s(data-test="error-topic")
    end
  end

  describe "per-group rendering — payload-bearing format" do
    test "renders the payload inside a <details> with a byte-count label" do
      # `parse_save_reading/1` includes a payload in the
      # `"Failed to save <KIND> reading: <CHANGESET> — payload: ..."`
      # format. The "— payload: " separator is the split point
      # the parser uses to extract `payload`. The payload string
      # here has no `<`, `>`, `&`, or `"` characters so we can
      # assert the raw bytes without worrying about HEEx's HTML
      # escaping.
      payload = ~s({power:1234,voltage:230})
      msg = "Failed to save OpenDTU reading: invalid — payload: " <> payload

      html =
        render_component(&ErrorExpansionPanel.error_expansion_panel/1, %{
          device: dtu(%{}),
          error_groups: [group(msg)]
        })

      # `<details>` block with the byte-count label.
      assert html =~ "<details"
      assert html =~ "payload (#{byte_size(payload)} chars)"
      # The `<pre>` carries `data-test="error-payload"` and the
      # raw payload text.
      assert html =~ ~s(data-test="error-payload")
      assert html =~ payload
    end

    test "does NOT render a payload block when the parser didn't extract one" do
      # A plain "Some error" message — `parse_error_message/1`
      # falls through to the unrecognised-format branch, which
      # produces `%{kind: "Error", reason: "Some error",
      # topic: nil, payload: nil}`.
      html =
        render_component(&ErrorExpansionPanel.error_expansion_panel/1, %{
          device: dtu(%{}),
          error_groups: [group("Some error")]
        })

      refute html =~ "<details"
      refute html =~ ~s(data-test="error-payload")
    end
  end

  describe "per-group footer" do
    test "renders the '%{count} occurrences · last seen %{when}' line" do
      html =
        render_component(&ErrorExpansionPanel.error_expansion_panel/1, %{
          device: dtu(%{}),
          error_groups: [group("OpenDTU error", %{occurrences: 7})]
        })

      # The footer text carries the count and the relative-time
      # label. The string "%{count} occurrences · last seen
      # %{when}" has no singular form in gettext — the count is
      # always rendered with "occurrences" even for count=1
      # (verified against the existing device_live_test
      # assertions on this same shape).
      assert html =~ "7 occurrences"
      assert html =~ "last seen"
      # 2 hours ago → "%{n} hours ago".
      assert html =~ "hours ago"
    end
  end

  describe "structure guards" do
    test "does NOT render device list chrome (no per-device rows, no Add DTU link)" do
      # The expansion panel is purely the panel — it must not
      # bleed into the surrounding device-list page.
      html =
        render_component(&ErrorExpansionPanel.error_expansion_panel/1, %{
          device: dtu(%{}),
          error_groups: []
        })

      refute html =~ "id=\"devices\""
      refute html =~ "Add DTU"
      refute html =~ "dtu-error-message-"
      refute html =~ "btn-delete-"
    end
  end
end
