import Config

# The suite talks to a real Postgres — the sandbox pool gives every test its
# own transaction. Connection details come from the environment so the same
# suite runs against a local server or an ephemeral container in CI.
config :spojiti_relay, SpojitiRelay.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: "spojiti_core_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :spojiti_relay, SpojitiRelayWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: String.duplicate("test_secret_key_base_", 4),
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
