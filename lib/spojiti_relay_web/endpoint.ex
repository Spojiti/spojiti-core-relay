defmodule SpojitiRelayWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :spojiti_relay

  # The authenticated channel: clients present the bearer token minted at
  # registration as the `token` connect param.
  socket "/socket", SpojitiRelayWeb.UserSocket,
    websocket: [timeout: 45_000],
    longpoll: false

  # THE ANONYMOUS LANE. No token: a sealed envelope arrives here so the relay
  # never sees a sender on the socket that carries it. The only thing taken
  # from the connection is the peer address, for a connect-rate bucket
  # (RealIp rules: honoured through your own proxy chain only, never stored).
  socket "/sealed", SpojitiRelayWeb.SealedSocket,
    websocket: [timeout: 45_000, connect_info: [:peer_data, :x_headers]],
    longpoll: false

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    length: 1_000_000,
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug SpojitiRelayWeb.Router
end
