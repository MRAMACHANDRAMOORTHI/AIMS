defmodule Aims.Repo do
  use Ecto.Repo,
    otp_app: :aims,
    adapter: Ecto.Adapters.Postgres
end
