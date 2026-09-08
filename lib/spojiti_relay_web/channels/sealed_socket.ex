defmodule SpojitiRelayWeb.SealedSocket do
  @moduledoc """
  #381 · THE ANONYMOUS LANE. No token, no account, no `id/1` — a connection
  here is nobody, on purpose. It exists so a sealed envelope can reach the
  relay without arriving on a socket that authenticated its sender at
  connect; the authenticated `/socket` keeps everything else (flush, ack,
  presence, receipts for older peers).

  What the relay can still see on this socket is the peer address, and it is
  used for exactly one thing: a connect-rate bucket keyed by an opaque hash
  that evaporates on its own (see SpojitiRelayWeb.Plugs.RealIp on why nothing
  is stored and nothing is logged). Correlating that address with the
  authenticated socket from the same client is the residual Arch-SS-v1 §7
  states plainly; the IP route closes it.
  """
  use Phoenix.Socket, log: false

  channel "sealed:*", SpojitiRelayWeb.SealedChannel

  # Connects per minute PER ADDRESS. The first cut said 30 and was wrong for
  # the world this ships into: Indian mobile carriers put hundreds of phones
  # behind one CGNAT IPv4, so a reconnect wave after a drain (#208) from one
  # such address is a crowd, not a dialer loop. 600/min (10/s from one
  # address) still stops a loop; SEALED_CONNECTS_PER_MIN overrides it, and
  # the load harness needs that (every synthetic client shares one address).
  @default_connects_per_min 600
  def connects_per_min do
    case Integer.parse(System.get_env("SEALED_CONNECTS_PER_MIN") || "") do
      {n, _} when n > 0 -> n
      _ -> @default_connects_per_min
    end
  end

  @impl true
  def connect(_params, socket, connect_info) do
    key = SpojitiRelayWeb.Plugs.RealIp.socket_key(connect_info)

    case SpojitiRelay.RateLimiter.check("sealed_connect", key, connects_per_min(), 60_000) do
      :ok -> {:ok, socket}
      {:deny, _} -> :error
    end
  end

  # Anonymous: nothing to broadcast a disconnect to, nothing to name.
  @impl true
  def id(_socket), do: nil
end
