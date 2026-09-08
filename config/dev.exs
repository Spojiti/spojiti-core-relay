import Config

# DB config lives in runtime.exs (env-driven) so Docker and bare-metal share one
# path with no precedence surprises.
config :spojiti_relay, SpojitiRelayWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  check_origin: false,
  debug_errors: true,
  code_reloader: false,
  secret_key_base: String.duplicate("dev_only_secret_key_base_", 3),
  watchers: []

config :logger, :console, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
