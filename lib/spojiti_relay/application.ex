defmodule SpojitiRelay.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SpojitiRelay.Repo,
      {Phoenix.PubSub, name: SpojitiRelay.PubSub},
      SpojitiRelay.RateLimiter,
      SpojitiRelay.Pow,
      SpojitiRelay.Sweeper,
      SpojitiRelayWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: SpojitiRelay.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    SpojitiRelayWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
