defmodule DtuAppWeb.DeviceLive.Details do
  @moduledoc """
  Live, in-browser view of everything a single DTU is currently
  publishing on MQTT — every topic, every payload, regardless of
  whether the parser interprets the field.

  Two columns (single LiveView page):

    * **Topics tree** — the device's `DtuApp.MqttBroker.TopicRegistry`
      snapshot rendered as a tree of `<details>` elements, one per
      path segment. JSON payloads pretty-print; scalar payloads render
      inline. Updates live on each `:topic_seen` PubSub event.

    * **Error status** — the same per-message rollup as the devices
      index's expansion panel (`DtuApp.Devices.list_dtu_error_groups/1`),
      which already filters to errors within the last 48 hours.

  The page is reached by clicking the **Details** link on a device
  row in `/devices`. It is its own LiveView module (not a new action
  on `DeviceLive.Index`) so the heavy live-topic subscription doesn't
  leak into the index — opening a details tab doesn't slow down the
  manage-device list for users who never open a details page.
  """

  use DtuAppWeb, :live_view

  alias DtuApp.Devices
  alias DtuApp.Devices.Dtu
  alias DtuApp.MqttBroker.Telemetry
  alias DtuApp.MqttBroker.TopicRegistry

  @impl true
  def mount(%{"id" => raw_id}, _session, socket) do
    case Integer.parse(to_string(raw_id)) do
      {id, ""} ->
        user = socket.assigns.current_scope.user
        device = Devices.get_device(user, id)

        if device do
          if connected?(socket) do
            # Subscribe to per-uplink topic events so the topic tree
            # refreshes without a page reload. The handle_info/2
            # clause below filters to this device's id so events for
            # other DTUs are no-ops.
            TopicRegistry.subscribe_topics()
            # Subscribe to per-device status updates (errors) so a
            # newly-recorded error refreshes the right column.
            Telemetry.subscribe_status()
          end

          {:ok,
           socket
           |> assign(:page_title, gettext("DTU details — %{name}", name: device.name))
           |> assign(:device, device)
           |> assign(:topics, TopicRegistry.get_topics_for(device.id))
           |> assign(:error_groups, Devices.list_dtu_error_groups(device.id))
           |> assign(:locale, Gettext.get_locale(DtuAppWeb.Gettext))
           |> assign_tree()}
        else
          # Foreign / deleted device — same UX as the dashboard's
          # deep-link: redirect to /devices with no error toast. The
          # LiveView process will be torn down by the redirect.
          {:ok, push_navigate(socket, to: ~p"/devices")}
        end

      _ ->
        # Non-integer id — same fallback.
        {:ok, push_navigate(socket, to: ~p"/devices")}
    end
  end

  @impl true
  def handle_info({:topic_seen, dtu_id}, socket) do
    if socket.assigns.device.id == dtu_id do
      socket =
        socket
        |> assign(:topics, TopicRegistry.get_topics_for(dtu_id))
        |> assign_tree()

      {:noreply, socket}
    else
      # Event for another DTU — ignore (the subscription is shared
      # across all subscribers).
      {:noreply, socket}
    end
  end

  def handle_info({:dtu_error, dtu_id}, socket) do
    if socket.assigns.device.id == dtu_id do
      {:noreply, assign(socket, :error_groups, Devices.list_dtu_error_groups(dtu_id))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:dtu_seen, dtu_id}, socket) do
    # Touch last_seen_at — mirror what `Telemetry` writes so the
    # device's `Dtu.online?/2` reflects real-time liveness while the
    # user has the details page open. The "online" indicator on the
    # page reads from `Dtu.online?/2` via the `@device.last_seen_at`
    # assign refreshed by the broadcast.
    if socket.assigns.device.id == dtu_id do
      {:noreply,
       assign(socket, :device, Devices.get_device!(socket.assigns.current_scope.user, dtu_id))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("copy_topics_as_json", _params, socket) do
    # Build the JSON document on demand and push it to the client
    # as a `copy_topics_json` event. The colocated `CopyTopicsJson`
    # JS hook on the button element receives the event, writes the
    # JSON to the clipboard, and shows a "Copied" indicator. We
    # build the JSON on click rather than rendering it into the
    # DOM as a `data-value` attribute: a 200-topic × 4 KB-payload
    # tree can be ~800 KB, which would bloat every render even
    # when the user never clicks the button. Building on demand
    # keeps the steady-state DOM size bounded.
    json = topics_as_json(socket.assigns.device, socket.assigns.topics)

    {:noreply,
     push_event(socket, "copy_topics_json", %{
       json: json,
       topic_count: map_size(socket.assigns.topics)
     })}
  end

  # --- Tree rendering ---------------------------------------------------------

  @doc """
  Group the topic map into a tree keyed by path segments.

  Topics come in as flat strings like `"solar/HM1234/realtime/data"`.
  We split each into segments and walk the map to build a nested
  tree of nodes:

    * **leaf** — the segment is the last component of a topic and the
      payload + `received_at` are attached.
    * **branch** — the segment is an intermediate component; its
      children are the union of all next-segments across topics that
      start with this prefix.

  Returns a sorted list of root nodes (always non-empty unless the
  map is empty). Each node is `%{segment, kind: :leaf | :branch,
  payload, received_at, children}` so the template can render
  uniformly.
  """
  @typedoc "One node in the topic tree produced by `build_tree/2`."
  @type tree_node :: %{
          segment: String.t(),
          kind: :leaf | :branch,
          payload: {String.t(), DateTime.t()} | nil,
          topic: String.t() | nil,
          dom_id: String.t(),
          payload_rendered: String.t(),
          children: [tree_node()]
        }

  @spec build_tree(%{String.t() => {String.t(), DateTime.t()}}, keyword()) :: [tree_node()]
  def build_tree(topics, opts \\ [])

  def build_tree(topics, opts) when is_map(topics) do
    # The tree's root segments come from the leading path component
    # of each topic. Strip the user's `base_topic` prefix off so the
    # tree starts at the firmware's namespace — `solar/` for
    # OpenDTU, `inverter/` for AhoyDTU, `shellies/...` for Shelly —
    # which is the meaningful boundary for the user.
    base_topic = Keyword.get(opts, :base_topic, "")

    topics
    |> Enum.map(fn {topic, payload_at} ->
      {strip_prefix(topic, base_topic), payload_at}
    end)
    |> Enum.reject(fn {topic, _} -> topic == "" end)
    |> Enum.group_by(fn {topic, _} -> first_segment(topic) end)
    |> Enum.map(fn {root, items} ->
      build_node(root, items, [])
    end)
    |> Enum.sort_by(& &1.segment)
  end

  def build_tree(_, _), do: []

  # Strip `prefix` (e.g. `"solar"`) from the front of `topic` (e.g.
  # `"solar/HM1234/realtime/data"`) so the tree starts at the
  # firmware-namespace segment. Returns `topic` unchanged if it
  # doesn't begin with `prefix + "/"`, so a misconfigured DTU
  # publishing on a different prefix still shows up.
  defp strip_prefix(topic, ""), do: topic

  defp strip_prefix(topic, prefix) do
    with prefix_with_sep <- prefix <> "/",
         true <- String.starts_with?(topic, prefix_with_sep) do
      String.replace_prefix(topic, prefix_with_sep, "")
    else
      _ -> topic
    end
  end

  # First `/`-separated segment of `topic`. `"a/b/c"` → `"a"`. An
  # empty input returns `""` so the caller can drop it.
  defp first_segment(topic) do
    case String.split(topic, "/", parts: 2) do
      [first, _rest] -> first
      [only] -> only
      [] -> ""
    end
  end

  # Walk the topic map recursively, building a node tree. `items` is
  # the list of `{topic, payload_at}` tuples that share the prefix
  # represented by `segment`. `segment_path` is the dotted prefix
  # (`"solar.HM1234"`) used for `dom_id` uniqueness.
  defp build_node(segment, items, segment_path) do
    {leaves, branches} =
      Enum.split_with(items, fn {topic, _} ->
        case String.split(topic, "/", parts: 2) do
          [_first, _rest] -> false
          [_only] -> true
          _ -> false
        end
      end)

    case {leaves, branches} do
      # A leaf — the topic is exactly `segment`. Multiple leaves
      # can't happen for one segment because topics are unique, but
      # the split_with/2 above can return a single-element list and
      # the case clauses need to match that shape.
      {[{topic, payload_at}], []} ->
        %{
          segment: segment,
          kind: :leaf,
          payload: payload_at,
          topic: topic,
          dom_id: dom_id_for(segment_path ++ [segment]),
          payload_rendered: render_payload(payload_at)
        }

      # A branch — children share the segment as their prefix. Recurse
      # one level deeper, keyed by the next segment.
      {[], _} ->
        children_by_segment =
          branches
          |> Enum.map(fn {topic, payload_at} ->
            {strip_first_segment(topic), payload_at}
          end)
          |> Enum.group_by(fn {topic, _} -> first_segment(topic) end)

        children =
          children_by_segment
          |> Enum.map(fn {child_segment, child_items} ->
            build_node(child_segment, child_items, segment_path ++ [segment])
          end)
          |> Enum.sort_by(& &1.segment)

        %{
          segment: segment,
          kind: :branch,
          children: children,
          dom_id: dom_id_for(segment_path ++ [segment])
        }

      # Mixed (a single-segment topic AND deeper branches under the
      # same segment). Render as a branch with the leaf as a virtual
      # first child whose segment is `"(payload)"` so the user sees
      # both. This happens when a topic exactly matches the segment
      # AND another topic continues under it — rare in real firmware
      # but defensive against it.
      _ ->
        children =
          Enum.map(leaves, fn {topic, payload_at} ->
            %{
              segment: topic,
              kind: :leaf,
              payload: payload_at,
              topic: topic,
              dom_id: dom_id_for(segment_path ++ [segment, topic]),
              payload_rendered: render_payload(payload_at)
            }
          end)

        children =
          children ++
            (branches
             |> Enum.map(fn {topic, payload_at} ->
               {strip_first_segment(topic), payload_at}
             end)
             |> Enum.group_by(fn {topic, _} -> first_segment(topic) end)
             |> Enum.map(fn {child_segment, child_items} ->
               build_node(child_segment, child_items, segment_path ++ [segment])
             end))

        %{
          segment: segment,
          kind: :branch,
          children: children,
          dom_id: dom_id_for(segment_path ++ [segment])
        }
    end
  end

  # Drop the leading `/`-separated segment. `"a/b/c"` → `"b/c"`.
  defp strip_first_segment(topic) do
    case String.split(topic, "/", parts: 2) do
      [_first, rest] -> rest
      [only] -> only
      _ -> ""
    end
  end

  # HTML-safe `id` for the segment. Dots in the path are common in
  # base_topic prefixes (`shellies.shellyplus3em`) — replaced so the
  # resulting attribute is a valid CSS selector.
  defp dom_id_for(path_segments) do
    Enum.join(path_segments, "-") |> String.replace(".", "-")
  end

  # Render a payload for inline display:
  #   * If it's JSON, decode + pretty-print so a Shelly `status/em:0`
  #     blob renders structurally rather than as one long line.
  #   * Otherwise, render verbatim. Truncation is upstream
  #     (`TopicRegistry.truncate_payload/1`) so this never has to
  #     worry about 4 KB blobs.
  @spec render_payload({String.t(), DateTime.t()}) :: String.t()
  def render_payload({payload, _received_at}) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, value} when is_map(value) or is_list(value) ->
        Jason.encode_to_iodata!(value, pretty: true) |> IO.iodata_to_binary()

      _ ->
        payload
    end
  end

  def render_payload(_), do: ""

  # Build a JSON document describing the DTU's live topic map.
  # Used by the "Copy as JSON" button via `push_event/3` — the JS
  # hook receives the event, writes the payload to the clipboard,
  # and shows a "Copied" indicator. Building the JSON on demand
  # keeps the per-render DOM size bounded (200 topics × 4 KB
  # payloads is ~800 KB worst case; shipping that on every
  # render is wasteful, especially when most visits don't click
  # the button).
  #
  # Shape:
  #
  #     {
  #       "dtu_id": <int>,
  #       "dtu_name": "...",
  #       "base_topic": "...",
  #       "captured_at": "<ISO-8601>",
  #       "topic_count": <int>,
  #       "topics": {
  #         "<topic>": { "payload": "<raw string>", "received_at": "<ISO-8601>" },
  #         ...
  #       }
  #     }
  #
  # `payload` is the raw wire-level string the firmware sent (NOT
  # re-decoded JSON) so the document round-trips exactly. The
  # on-screen tree view pretty-prints payloads via `render_payload/1`
  # independently.
  @doc """
  Build the JSON document for clipboard export. Public so unit
  tests can verify the shape without mounting the LV.
  """
  @spec topics_as_json(%Dtu{}, map()) :: String.t()
  def topics_as_json(%Dtu{} = device, topics) when is_map(topics) do
    topics_block =
      Map.new(topics, fn {topic, {payload, received_at}} ->
        {topic, %{"payload" => payload, "received_at" => DateTime.to_iso8601(received_at)}}
      end)

    document = %{
      "dtu_id" => device.id,
      "dtu_name" => device.name,
      "base_topic" => device.base_topic,
      "captured_at" => DateTime.to_iso8601(DtuApp.Time.utc_now()),
      "topic_count" => map_size(topics),
      "topics" => topics_block
    }

    Jason.encode_to_iodata!(document, pretty: true) |> IO.iodata_to_binary()
  end

  # --- Formatting -------------------------------------------------------------

  # Friendly relative-time label for a topic's `received_at`. Mirrors
  # the dashboard's `relative_time_label/1` and the index's
  # `format_relative/1`. Returns "just now" for sub-second gaps.
  # Uses the long form ("X minutes ago") to match the error panel's
  # vocabulary — a user scanning the page sees consistent time
  # phrases across both columns.
  @spec format_relative_time(DateTime.t()) :: String.t()
  def format_relative_time(%DateTime{} = dt) do
    diff_seconds = DateTime.diff(DtuApp.Time.utc_now(), dt, :second)

    cond do
      diff_seconds < 60 -> gettext("just now")
      diff_seconds < 3600 -> gettext("%{n} minutes ago", n: div(diff_seconds, 60))
      diff_seconds < 86_400 -> gettext("%{n} hours ago", n: div(diff_seconds, 3600))
      true -> gettext("%{n} days ago", n: div(diff_seconds, 86_400))
    end
  end

  # Online indicator mirroring `Dtu.producing_power?/2`. Reads from
  # `last_power_at`, refreshed by every AC-aggregate reading persisted
  # via `Devices.create_reading_and_touch_power_at/1` and re-loaded
  # into `@device` on every `:dtu_seen` broadcast above. Using
  # `producing_power?/2` here (instead of `Dtu.online?/2`'s
  # `last_seen_at` check) is what keeps the header pill in sync with
  # the dashboard's device-card pill and the device-list green dot —
  # a DTU whose MQTT session stays connected but whose inverter has
  # stopped reporting telemetry flips to "offline" on all three
  # indicators together. See `Dtu.producing_power?/2` for the rule.
  @spec online?(%Dtu{}) :: boolean()
  def online?(%Dtu{} = device), do: Dtu.producing_power?(device)

  # Recompute the topic tree on every `mount/3` and `:topic_seen`
  # event so the template reads from a pre-computed `:tree` assign
  # rather than calling `build_tree/2` inline. Inline computation in
  # the template would risk re-running on every render even when
  # nothing changed, which is wasteful for a tree that can have
  # ~200 entries per DTU.
  defp assign_tree(socket) do
    assign(
      socket,
      :tree,
      build_tree(socket.assigns.topics, base_topic: socket.assigns.device.base_topic)
    )
  end

  # --- Function component: topic tree -----------------------------------------

  @doc """
  Render the topic tree built by `build_tree/2`. Recurses into
  branch nodes by calling itself with the child list — function
  components in Phoenix LiveView support direct self-recursion when
  invoked by name (`<.render_tree nodes={node.children} />`).

  Branches render as `<details open>` so the structure is visible
  immediately on mount; leaves render as a `<details>` (collapsed
  by default) carrying the pretty-printed payload. A JSON payload
  of hundreds of bytes shouldn't dominate the page on first load.
  """
  attr :nodes, :list, default: [], doc: "Tree nodes from build_tree/2."

  def render_tree(assigns) do
    ~H"""
    <ul class="divide-y divide-zinc-100 dark:divide-zinc-800 font-mono text-sm">
      <%= for node <- @nodes do %>
        <%= case node.kind do %>
          <% :branch -> %>
            <li class="px-4 py-2" id={"topic-node-#{node.dom_id}"}>
              <details open class="space-y-1">
                <summary class="cursor-pointer select-none text-zinc-700 dark:text-zinc-300 hover:text-zinc-900 dark:hover:text-zinc-100 transition font-medium">
                  <span class="inline-flex items-center gap-1">
                    <.icon name="hero-folder" class="size-4 text-zinc-400" />
                    {node.segment}
                  </span>
                </summary>
                <div class="ml-4 mt-1 pl-3 border-l border-zinc-200 dark:border-zinc-700">
                  <.render_tree nodes={node.children} />
                </div>
              </details>
            </li>
          <% :leaf -> %>
            <li class="px-4 py-2" id={"topic-node-#{node.dom_id}"}>
              <div class="flex items-baseline gap-2 break-all">
                <span class="inline-flex items-center gap-1 text-zinc-700 dark:text-zinc-300">
                  <.icon name="hero-document-text" class="size-4 text-zinc-400 shrink-0" />
                  <span class="truncate">{node.topic}</span>
                </span>
                <span class="text-xs text-zinc-400 shrink-0">
                  {DtuAppWeb.DeviceLive.Details.format_relative_time(elem(node.payload, 1))}
                </span>
              </div>
              <details class="mt-1 ml-5 text-xs">
                <summary class="cursor-pointer text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 select-none">
                  {gettext("payload")}
                </summary>
                <pre class="mt-1 font-mono text-zinc-800 dark:text-zinc-200 bg-zinc-50 dark:bg-zinc-800 px-2 py-1.5 rounded whitespace-pre-wrap break-all max-h-60 overflow-auto border border-zinc-200/60 dark:border-zinc-700/40"><code>{node.payload_rendered}</code></pre>
              </details>
            </li>
        <% end %>
      <% end %>
    </ul>
    """
  end
end
