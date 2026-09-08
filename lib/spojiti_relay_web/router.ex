defmodule SpojitiRelayWeb.Router do
  @moduledoc """
  Every HTTP door of the Core. Registration and login are rate-limited per
  address; the bundle read is open (public keys only); everything else is
  authenticated with the bearer token minted at registration.
  """
  use SpojitiRelayWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug SpojitiRelayWeb.Plugs.RealIp
  end

  pipeline :authed do
    plug SpojitiRelayWeb.Auth
  end

  pipeline :rl_register do
    plug SpojitiRelayWeb.Plugs.RateLimit,
      bucket: "register", by: :ip, limit: 12, window_ms: 60_000
  end

  pipeline :rl_login do
    plug SpojitiRelayWeb.Plugs.RateLimit,
      bucket: "login", by: :ip, limit: 12, window_ms: 60_000
  end

  scope "/api", SpojitiRelayWeb do
    pipe_through :api

    get "/health", HealthController, :index

    scope "/" do
      pipe_through :rl_register
      get "/pow", PowController, :show
      post "/register", RegistrationController, :create
    end

    # A peer's public key bundle: identity key, signing keys, signed prekey,
    # one one-time prekey (consumed), the post-quantum prekey, caps.
    get "/keys/:account_id", KeyController, :show

    scope "/" do
      pipe_through :rl_login
      post "/login/challenge", SessionController, :challenge
      post "/login/verify", SessionController, :verify
    end

    scope "/" do
      pipe_through :authed
      post "/keys", KeyController, :replenish
      post "/keys/pq", KeyController, :put_pq
      delete "/keys/pq", KeyController, :del_pq
      post "/keys/pqauth", KeyController, :put_pq_auth
      post "/keys/caps", KeyController, :put_caps
      get "/me", RegistrationController, :me
    end
  end
end
