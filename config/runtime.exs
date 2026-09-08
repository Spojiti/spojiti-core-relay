import Config

# DATABASE_URL (ecto://USER:PASS@HOST/DB) or the PG* variables; SECRET_KEY_BASE
# (mix phx.gen.secret); PORT; PHX_HOST. Optional: POW_BITS (18), POW_REQUIRED
# (true), SEALED_CONNECTS_PER_MIN (600), SEALED_POW_REQUIRED (false),
# AUTH_SECRET (bearer-token signing secret; falls back to SECRET_KEY_BASE).
if config_env() != :test do
  case System.get_env("DATABASE_URL") do
    nil ->
      config :spojiti_relay, SpojitiRelay.Repo,
        username: System.get_env("PGUSER") || "postgres",
        password: System.get_env("PGPASSWORD") || "postgres",
        hostname: System.get_env("PGHOST") || "localhost",
        database: System.get_env("PGDATABASE") || "spojiti_core_dev",
        pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

    url ->
      config :spojiti_relay, SpojitiRelay.Repo,
        url: url,
        pool_size: String.to_integer(System.get_env("POOL_SIZE") || "25")
  end
end

if secret = System.get_env("SECRET_KEY_BASE") do
  config :spojiti_relay, SpojitiRelayWeb.Endpoint, secret_key_base: secret
end

if port = System.get_env("PORT") do
  config :spojiti_relay, SpojitiRelayWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(port)]
end

if config_env() == :prod do
  unless System.get_env("SECRET_KEY_BASE") do
    raise "SECRET_KEY_BASE is missing. Generate one with: mix phx.gen.secret"
  end

  unless System.get_env("DATABASE_URL") do
    raise "DATABASE_URL is missing (expected ecto://USER:PASS@HOST/DB)."
  end

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :spojiti_relay, SpojitiRelayWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    server: true,
    check_origin: false

  config :logger, level: :info
end
