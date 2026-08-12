defmodule DtuAppWeb.DeviceLive.Index do
  @moduledoc false
  use DtuAppWeb, :live_view

  alias DtuApp.Devices
  alias DtuApp.Devices.Dtu
  alias DtuApp.MqttBroker.Telemetry

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # `:dtu_seen` fires on every MQTT uplink (and CONNECT / DISCONNECT).
      # Re-stream the device list so the online indicator on each row
      # stays current without forcing the user to refresh the page.
      Telemetry.subscribe_status()
    end

    {:ok,
     socket
     |> stream(:devices, Devices.list_devices(socket.assigns.current_scope.user))
     |> assign(:deleting_device, nil)
     |> assign(:created_device, nil)
     |> assign(:mqtt_host, mqtt_host())
     |> assign(:expanded_dtu_id, nil)
     |> assign_form(Devices.change_device(socket.assigns.current_scope.user))}
  end

  @impl true
  def handle_info({:dtu_seen, _device_id}, socket) do
    # Re-stream every device so each row's `Dtu.online?/2` call sees a
    # fresh `last_seen_at`. `stream/3` is a no-op when the underlying
    # row hasn't changed, so the cost is one query plus one diff pass
    # per status flip.
    {:noreply,
     stream(socket, :devices, Devices.list_devices(socket.assigns.current_scope.user),
       reset: true
     )}
  end

  # `:dtu_error` is broadcast by `Telemetry.record_dtu_error/2` whenever
  # the parser rejects an uplink or a DB insert fails for a user's DTU.
  # The condition is already persisted on `dtus.last_error` and on a row
  # in `dtu_errors`; we re-stream the device list here so the warning
  # fill (and the expansion panel, if the affected row is currently
  # expanded) stays current without waiting for the next MQTT uplink.
  # The expansion panel's `list_dtu_error_groups/1` is re-fetched below
  # so a freshly-fired error shows up without a page refresh.
  @impl true
  def handle_info({:dtu_error, device_id}, socket) do
    socket =
      socket
      |> stream(:devices, Devices.list_devices(socket.assigns.current_scope.user), reset: true)
      |> maybe_refresh_expanded_errors(device_id)

    {:noreply, socket}
  end

  # When the broadcast is for the currently-expanded device, re-fetch
  # the per-message rollup so the user sees the new error appear in
  # the panel without any further interaction. For other devices, the
  # stream reset above already moved the row's distinct-error badge
  # count up to date.
  defp maybe_refresh_expanded_errors(socket, _device_id)
       when socket.assigns.expanded_dtu_id == nil,
       do: socket

  defp maybe_refresh_expanded_errors(socket, device_id) do
    if socket.assigns.expanded_dtu_id == device_id do
      assign(
        socket,
        :expanded_error_groups,
        Devices.list_dtu_error_groups(device_id)
      )
    else
      socket
    end
  end

  # Host shown to users as the MQTT broker address in the created-device modal.
  # Prefers an explicit MQTT_HOST override (when the broker runs on a different
  # domain than the web app), falling back to the web app's host (PHX_HOST).
  defp mqtt_host do
    case Application.get_env(:dtu_app, :mqtt_host) do
      host when is_binary(host) and host != "" -> host
      _ -> endpoint_host()
    end
  end

  defp endpoint_host do
    [host: host] = Keyword.take(DtuAppWeb.Endpoint.config(:url) || [], [:host])
    host || "localhost"
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    # Deep-link from the dashboard's edge-badge click:
    # `/devices?expand=<dtu_id>` opens this page with the right device
    # expanded to its full error panel. The id is validated against the
    # user's owned devices — an attacker-crafted id expands nothing
    # rather than leaking the error history of someone else's device.
    socket
    |> assign_expansion(params)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, gettext("Add DTU"))
    |> assign_form(Devices.change_device(socket.assigns.current_scope.user))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    device = Devices.get_device!(socket.assigns.current_scope.user, id)

    socket
    |> assign(:page_title, gettext("Edit DTU"))
    |> assign(:device, device)
    |> assign_form(Devices.change_device(socket.assigns.current_scope.user, device))
  end

  # Read the `expand` query param and decide whether to open an
  # expansion panel for the matching device. Invalid ids (non-integer,
  # not owned by the current user) collapse to `expanded_dtu_id = nil`
  # rather than 404-ing the page — the device list still renders, the
  # user just sees no expanded panel.
  defp assign_expansion(socket, %{"expand" => raw}) do
    case Integer.parse(to_string(raw)) do
      {id, ""} ->
        user = socket.assigns.current_scope.user

        if Devices.get_device(user, id) do
          socket
          |> assign(:expanded_dtu_id, id)
          |> assign(:expanded_error_groups, Devices.list_dtu_error_groups(id))
        else
          socket
          |> assign(:expanded_dtu_id, nil)
          |> assign(:expanded_error_groups, [])
        end

      _ ->
        socket
        |> assign(:expanded_dtu_id, nil)
        |> assign(:expanded_error_groups, [])
    end
  end

  defp assign_expansion(socket, _params) do
    socket
    |> assign(:expanded_dtu_id, nil)
    |> assign(:expanded_error_groups, [])
  end

  @impl true
  def handle_event("validate", %{"dtu" => dtu_params}, socket) do
    changeset =
      Devices.change_device(
        socket.assigns.current_scope.user,
        dtu_changeset_target(socket),
        dtu_params
      )

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"dtu" => dtu_params}, socket) do
    save_device(socket, socket.assigns.live_action, dtu_params)
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    device = Devices.get_device!(socket.assigns.current_scope.user, id)
    {:noreply, assign(socket, :deleting_device, device)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :deleting_device, nil)}
  end

  def handle_event("close_created_modal", _params, socket) do
    {:noreply, assign(socket, :created_device, nil)}
  end

  # Close the expanded error panel by clearing the `expand` query
  # param. `push_patch` keeps the URL in sync (so a refresh re-opens
  # it) and avoids the full-page navigation that `navigate` would
  # trigger — the device list itself doesn't change, only the panel
  # collapses.
  def handle_event("close_expanded_errors", _params, socket) do
    {:noreply,
     socket
     |> assign(:expanded_dtu_id, nil)
     |> assign(:expanded_error_groups, [])
     |> push_patch(to: ~p"/devices")}
  end

  # Toggle the error expansion panel for a device. Wired to the
  # `phx-click` on the row's content area (the clickable zone that
  # opens the panel — Edit and Remove are separate elements inside
  # the row and consume their own clicks so they don't fire this).
  #
  # Behaviour:
  # * If the clicked device's panel is already open, close it
  #   (mirrors the dashboard deep-link's open/close semantic and
  #   keeps the URL in sync with the panel state).
  # * If the panel is closed (or another device's panel is open),
  #   open it for the clicked device. The "no errors" empty-state
  #   in the panel reads `gettext("No errors recorded for this DTU
  #   yet.")` (already extracted to the German/French locale files
  #   in MR #89).
  #
  # Security: `Devices.get_device/2` is the non-raising variant so
  # an attacker-crafted `id` parameter that doesn't belong to the
  # current user (or doesn't exist) silently no-ops rather than
  # raising — a row click that races with the device being deleted
  # from another tab is the realistic case this guards against.
  def handle_event("toggle_expanded_errors", %{"id" => raw}, socket) do
    case Integer.parse(to_string(raw)) do
      {id, ""} ->
        user = socket.assigns.current_scope.user

        if Devices.get_device(user, id) do
          if socket.assigns.expanded_dtu_id == id do
            # Already open for this device — close it. Push a patch
            # to drop the `expand` query param so the URL stays in
            # sync and a refresh doesn't reopen the panel.
            {:noreply,
             socket
             |> assign(:expanded_dtu_id, nil)
             |> assign(:expanded_error_groups, [])
             |> push_patch(to: ~p"/devices")}
          else
            # Open it for the new device. Push a patch to set
            # `?expand=<id>` so the URL is bookmarkable and a
            # refresh re-opens the same panel.
            {:noreply,
             socket
             |> assign(:expanded_dtu_id, id)
             |> assign(:expanded_error_groups, Devices.list_dtu_error_groups(id))
             |> push_patch(to: ~p"/devices?expand=#{id}")}
          end
        else
          # Foreign / deleted device — silent no-op so a stale
          # `phx-click` from a row the user already deleted doesn't
          # crash the LiveView.
          {:noreply, socket}
        end

      _ ->
        # Non-integer `id` payload — silent no-op. Should never
        # happen (Phoenix's `phx-value-id` is just an integer),
        # but defensive so a malformed event doesn't crash the LV.
        {:noreply, socket}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    device = Devices.get_device!(socket.assigns.current_scope.user, id)
    {:ok, _} = Devices.delete_device(device)

    {:noreply,
     socket
     |> stream_delete(:devices, device)
     |> assign(:deleting_device, nil)
     |> put_flash(:info, gettext("DTU removed"))}
  end

  defp save_device(%{assigns: %{live_action: :new}} = socket, _action, dtu_params) do
    case Devices.create_device(socket.assigns.current_scope.user, dtu_params) do
      {:ok, device} ->
        {:noreply,
         socket
         |> stream_insert(:devices, device, at: 0)
         |> put_flash(:info, gettext("DTU added"))
         |> assign(:created_device, device)
         |> push_patch(to: ~p"/devices")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_device(
         %{assigns: %{live_action: :edit, device: device}} = socket,
         _action,
         dtu_params
       ) do
    case Devices.update_device(device, dtu_params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> stream_insert(:devices, updated)
         |> put_flash(:info, gettext("DTU updated"))
         |> push_patch(to: ~p"/devices")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: :dtu))
  end

  # When editing, validate against the existing device so unique constraints
  # (name, username) resolve correctly; otherwise build against a fresh struct.
  defp dtu_changeset_target(%{assigns: %{device: %Dtu{} = device}}), do: device
  defp dtu_changeset_target(_socket), do: %Dtu{}

  # Friendly relative-time label for the expansion panel's
  # "last seen" line on each error group. Lightweight format that
  # reads naturally in both English and German (`vor 5 Minuten`) —
  # the dashboard's `relative_time_label/1` is private, so we inline
  # a similar-enough helper here rather than coupling the two
  # LiveViews. Returns "just now" for sub-minute timestamps.
  defp format_relative(%DateTime{} = dt) do
    diff_seconds = DateTime.diff(DtuApp.Time.utc_now(), dt, :second)

    cond do
      diff_seconds < 60 -> gettext("just now")
      diff_seconds < 3600 -> gettext("%{n} minutes ago", n: div(diff_seconds, 60))
      diff_seconds < 86_400 -> gettext("%{n} hours ago", n: div(diff_seconds, 3600))
      true -> gettext("%{n} days ago", n: div(diff_seconds, 86_400))
    end
  end

  # Parse a stored `dtu_errors.message` into the structured parts the
  # expansion panel renders. The message formats we know about:
  #
  #   * `"<KIND> uplink rejected (<REASON> on topic \"<TOPIC>\") — payload: <PAYLOAD>"`
  #     — `Telemetry`'s `handle_<kind>dtu` rejected an uplink.
  #   * `"Failed to save <KIND> reading: <CHANGESET> — payload: <PAYLOAD>"`
  #     — DB insert failure (Record validation).
  #   * `"Shelly topic mismatch (expected \"<EXPECTED>\", got \"<GOT>\") — check the device's MQTT prefix — payload: <PAYLOAD>"`
  #     — Shelly base-topic mismatch.
  #   * `"<KIND> status patch failed: <REASON>"`
  #     — OpenDTU / AhoyDTU status patch failure.
  #   * Anything else (forward-compatible / pre-existing rows)
  #     — render as a single `pre` block.
  #
  # Returns `%{kind: string, reason: string, topic: string | nil,
  #           payload: string | nil, raw: string}` so the template can
  # pick parts to render explicitly without re-parsing the message in
  # HEEx. `raw` is the original message so a future / unknown format
  # still renders something useful.
  @spec parse_error_message(String.t()) :: %{
          kind: String.t(),
          reason: String.t(),
          topic: String.t() | nil,
          payload: String.t() | nil,
          raw: String.t()
        }
  def parse_error_message(message) when is_binary(message) do
    {payload, head} = split_payload(message)

    base =
      cond do
        # "<KIND> uplink rejected (<REASON> on topic \"<TOPIC>\")"
        result = parse_uplink_rejected(head) ->
          result

        # "Failed to save <KIND> reading: <CHANGESET>"
        result = parse_save_reading(head) ->
          result

        # "Shelly topic mismatch (expected \"<EXPECTED>\", got \"<GOT>\") — <hint>"
        result = parse_shelly_topic_mismatch(head) ->
          result

        # "<KIND> status patch failed: <REASON>" (also matches the
        # broader uplink-rejected regex shape — selected last so the
        # upper-priority matchers win).
        result = parse_status_patch_failed(head) ->
          result

        # Unrecognised format — render the whole message as the
        # reason. The template's `raw` field carries the literal text
        # so a future-aware rendering layer could still inspect it.
        true ->
          %{kind: "Error", reason: head, topic: nil}
      end

    base
    |> Map.put(:payload, payload)
    |> Map.put(:raw, message)
  end

  # Split the message at the canonical "— payload:" separator introduced
  # by `Telemetry.format_payload_snippet/1`. Returns `{payload, head}`
  # where `head` is the message with the trailing payload section
  # stripped. Returns `{nil, message}` if the separator isn't present
  # (legacy row written before this change).
  defp split_payload(message) do
    case String.split(message, " — payload: ", parts: 2) do
      [head, payload] -> {payload, head}
      [only] -> {nil, only}
    end
  end

  # "<KIND> uplink rejected (<REASON> on topic \"<TOPIC>\")"
  defp parse_uplink_rejected(head) do
    case Regex.run(
           ~r/^(\w+) uplink rejected \((.+) on topic (".+")\)\.?$/,
           head,
           capture: :all_but_first
         ) do
      [kind, reason, topic] ->
        # Strip the surrounding quotes around the topic — the parser
        # stored `inspect(topic_str)` which double-quotes the binary.
        %{kind: kind, reason: reason, topic: strip_inspect_quotes(topic)}

      _ ->
        nil
    end
  end

  # "Failed to save <KIND> reading: <CHANGESET>"
  defp parse_save_reading(head) do
    case Regex.run(~r/^Failed to save (\w+) reading: (.+)$/, head, capture: :all_but_first) do
      [kind, reason] ->
        %{kind: kind <> " insert", reason: reason, topic: nil}

      _ ->
        nil
    end
  end

  # "<KIND> status patch failed: <REASON>"
  # The OpenDTU / AhoyDTU `patch_latest_reading_status/3` failures are
  # recorded without a topic or a payload — the JSON was already parsed
  # upstream and the failure happened on the DB write path. Render the
  # kind as `<KIND> status patch failed` so the chip carries the same
  # vocabulary as the function name.
  defp parse_status_patch_failed(head) do
    case Regex.run(
           ~r/^(\w+) status patch failed: (.+)$/,
           head,
           capture: :all_but_first
         ) do
      [kind, reason] ->
        %{kind: kind <> " status patch failed", reason: reason, topic: nil}

      _ ->
        nil
    end
  end

  # `Shelly topic mismatch (expected "<EXPECTED>", got "<GOT>") — <hint>`
  defp parse_shelly_topic_mismatch(head) do
    case Regex.run(
           ~r/^Shelly topic mismatch \(expected (".+"), got (".+")\)(?: — (.+))?\.?$/,
           head,
           capture: :all_but_first
         ) do
      [expected, got, hint] ->
        expected_t = strip_inspect_quotes(expected)
        got_t = strip_inspect_quotes(got)

        reason =
          "base_topic #{expected_t}, device sent #{got_t}" <>
            if(hint, do: " — #{hint}", else: "")

        %{kind: "Shelly", reason: reason, topic: nil, payload: nil}

      _ ->
        nil
    end
  end

  # `inspect/1` produces a binary like `"\"foo\""` when applied to a
  # non-printable binary; otherwise it returns the bare string. Strip
  # one pair of surrounding double-quotes so the topic displays as
  # `solar/INV-1/realtime/data` rather than `"solar/INV-1/realtime/data"`.
  # Returns the input unchanged if it's shorter than 2 chars or doesn't
  # have matching outer quotes.
  defp strip_inspect_quotes(quoted) when is_binary(quoted) do
    cond do
      byte_size(quoted) < 2 ->
        quoted

      String.starts_with?(quoted, "\"") and String.ends_with?(quoted, "\"") ->
        binary_part(quoted, 1, byte_size(quoted) - 2)

      true ->
        quoted
    end
  end
end
