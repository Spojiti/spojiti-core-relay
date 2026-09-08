import Config

config :spojiti_relay,
  ecto_repos: [SpojitiRelay.Repo],
  generators: [binary_id: true]

config :spojiti_relay, SpojitiRelayWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [formats: [json: SpojitiRelayWeb.ErrorJSON], layout: false],
  pubsub_server: SpojitiRelay.PubSub

config :phoenix, :json_library, Jason

# Zero-PII applies to the relay's own logs. Phoenix redacts these keys
# wherever it renders parameters: credentials, the envelope itself, and —
# the metadata a zero-PII relay exists in order not to hold — who is
# talking to whom.
config :phoenix, :filter_parameters,
       ["password", "secret", "token", "auth", "ciphertext", "to", "account_id"]

import_config "#{config_env()}.exs"
