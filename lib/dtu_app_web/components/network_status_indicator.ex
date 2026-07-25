defmodule DtuAppWeb.NetworkStatusIndicator do
  @moduledoc """
  A component that displays the current network status with visual indicators.
  Integrates with the NetworkStatus hook to show online/offline status.
  """

  use DtuAppWeb, :html

  attr :id, :string, default: "network-status"
  attr :show_text, :boolean, default: true
  attr :show_detailed, :boolean, default: false
  attr :class, :string, default: ""

  def network_status_indicator(assigns) do
    assigns =
      assign(
        assigns,
        :connection_class,
        "network-online"
      )

    ~H"""
    <div
      id={@id}
      class={[
        "network-status-indicator",
        "flex items-center gap-2 px-3 py-1.5 rounded-lg text-xs font-medium transition-all duration-300",
        "bg-zinc-100 dark:bg-zinc-900/50 border border-zinc-200 dark:border-zinc-800",
        @class
      ]}
      phx-hook="NetworkStatus"
      data-network-status="online"
    >
      <div
        data-network-indicator
        class={[
          "w-2 h-2 rounded-full transition-all duration-300",
          "bg-emerald-500",
          "animate-pulse"
        ]}
        aria-label="Network status indicator"
      />
      <%= if @show_text do %>
        <span class="network-status-text text-zinc-600 dark:text-zinc-400">
          Online
        </span>
      <% end %>

      <%= if @show_detailed do %>
        <div class="network-details hidden group-hover:block absolute top-full left-0 mt-2 p-3 bg-white dark:bg-zinc-900 rounded-lg shadow-lg border border-zinc-200 dark:border-zinc-800 text-xs min-w-[200px] z-50">
          <div class="space-y-1">
            <div class="flex justify-between">
              <span class="text-zinc-500">Status:</span>
              <span class="font-medium text-zinc-900 dark:text-zinc-100 network-detailed-status">Online</span>
            </div>
            <div class="flex justify-between">
              <span class="text-zinc-500">Connection:</span>
              <span class="font-medium text-zinc-900 dark:text-zinc-100 network-detailed-connection">-</span>
            </div>
            <div class="flex justify-between">
              <span class="text-zinc-500">Updated:</span>
              <span class="font-medium text-zinc-900 dark:text-zinc-100 network-detailed-time">Just now</span>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
