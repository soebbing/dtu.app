defmodule DtuApp.Repo do
  use Ecto.Repo,
    otp_app: :dtu_app,
    adapter: Ecto.Adapters.Postgres
end
