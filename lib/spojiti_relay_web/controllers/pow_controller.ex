defmodule SpojitiRelayWeb.PowController do
  use SpojitiRelayWeb, :controller

  alias SpojitiRelay.Pow

  # GET /api/pow — mint a #30 bot-gate challenge. Unauthed (registration has
  # no token yet) and rate-limited (rides rl_register). Stateless mint: no
  # storage cost until a solution is actually redeemed.
  def show(conn, _params) do
    if Pow.enabled?() do
      json(conn, Map.put(Pow.challenge(), :required, Pow.required?()))
    else
      json(conn, %{required: false, bits: 0})
    end
  end
end
