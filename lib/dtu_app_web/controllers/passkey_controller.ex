defmodule DtuAppWeb.PasskeyController do
  @moduledoc """
  HTTP endpoints for the browser-side WebAuthn ceremony.

  Four actions: registration begin/finish and authentication begin/finish.
  All return JSON. The full implementation lands in Task 5 and Task 6;
  this file is the routes-level placeholder that the kill switch
  disables.
  """

  use DtuAppWeb, :controller

  def registration_options(conn, _params), do: guard(conn)
  def verify_registration(conn, _params), do: guard(conn)
  def authentication_options(conn, _params), do: guard(conn)
  def verify_authentication(conn, _params), do: guard(conn)

  defp guard(conn) do
    if Application.get_env(:dtu_app, :passkeys_enabled, true) do
      conn
      |> put_status(:not_implemented)
      |> json(%{error: "not_implemented"})
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "not_found"})
    end
  end
end
