defmodule SpojitiRelayWeb.HealthController do
  use SpojitiRelayWeb, :controller

  def index(conn, _params) do
    json(conn, %{
      status: "ok",
      service: "spojiti-relay",
      version: to_string(Application.spec(:spojiti_relay, :vsn) || "dev"),
      time: DateTime.utc_now()
    })
  end
end
