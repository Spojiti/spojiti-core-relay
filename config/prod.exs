import Config

# Compile-time prod config. Everything environment-specific (host, secret, DB
# URL, whether the server listens) is resolved at boot in runtime.exs.
config :spojiti_relay, SpojitiRelayWeb.Endpoint,
  cache_static_manifest: nil

# Do not print debug messages in production.
config :logger, level: :info
