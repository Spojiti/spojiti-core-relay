defmodule SpojitiRelay.Repo do
  use Ecto.Repo,
    otp_app: :spojiti_relay,
    adapter: Ecto.Adapters.Postgres
end
