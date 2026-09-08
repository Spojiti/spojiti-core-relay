defmodule SpojitiRelayWeb.UserSocket do
  # #247 · log: false. NOT tidiness — Phoenix logs socket CONNECT at :info
  # including its parameters, and this socket's parameters are
  # %{"token" => token}. `filter_parameters` defaults to ["password"], so the
  # token is not redacted: every connection was writing a live credential into
  # the container log, on every box, kept for 30 MB of rotation.
  #
  # Verified in deps/phoenix/lib/phoenix/logger.ex — phoenix_socket_connected
  # short-circuits on `%{log: false}`, which is what this sets.
  use Phoenix.Socket, log: false

  channel "queue:*", SpojitiRelayWeb.QueueChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case SpojitiRelayWeb.Auth.verify(token) do
      {:ok, account_id} -> {:ok, assign(socket, :account_id, account_id)}
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "socket:#{socket.assigns.account_id}"
end
