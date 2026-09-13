defmodule DtuAppWeb.DashboardLive.ShareLink do
  @moduledoc """
  Share-link toggle helpers used by the dashboard's toolbar.

  Two functions, both pure (modulo the `Logger.warning` call):

    * `apply_result/2` — translates the result of
      `DtuApp.Accounts.create_shared_link/1` into the socket's
      `share_active?` / `share_url` / `share_loading?` assigns.
    * `url_for_token/1` — builds the public share URL from a
      plaintext token. Uses `DtuAppWeb.Endpoint.url/0` so the link
      points at the right deployment (dev / staging / production)
      without a hard-coded hostname.

  Both are wired into `handle_info({:mint_shared_link, ...})` /
  `handle_info({:revoke_shared_link, ...})` in `DashboardLive` via
  the alias `alias DtuAppWeb.DashboardLive.ShareLink`.
  """

  require Logger

  alias DtuAppWeb.Endpoint

  @spec apply_result(
          Phoenix.LiveView.Socket.t(),
          {:ok, {String.t(), String.t()}} | {:error, term()}
        ) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def apply_result(socket, {:ok, {plaintext, _link}}) do
    {:noreply,
     socket
     |> Phoenix.Component.assign(:share_active?, true)
     |> Phoenix.Component.assign(:share_url, url_for_token(plaintext))
     |> Phoenix.Component.assign(:share_loading?, false)}
  end

  def apply_result(socket, {:error, reason}) do
    user = socket.assigns.current_scope.user

    Logger.warning(
      "[dashboard] create_shared_link failed user=#{user.id} reason=#{inspect(reason)}"
    )

    {:noreply,
     socket
     |> Phoenix.Component.assign(:share_loading?, false)
     |> Phoenix.Component.assign(:share_active?, false)
     |> Phoenix.Component.assign(:share_url, nil)}
  end

  @spec url_for_token(String.t()) :: String.t()
  # Build the public share URL from a plaintext token. Uses the configured
  # PHX_HOST so the link points at the right deployment (dev / staging /
  # production) without a hard-coded hostname.
  def url_for_token(token) do
    Endpoint.url() <> "/s/" <> token
  end
end
