defmodule DtuAppWeb.PageController do
  use DtuAppWeb, :controller

  def home(conn, _params) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      redirect(conn, to: ~p"/dashboard")
    else
      render(conn, :home)
    end
  end
end
