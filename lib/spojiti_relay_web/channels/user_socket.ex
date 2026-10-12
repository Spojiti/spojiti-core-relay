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

  # 2026-10-06 · C1 + C5 · ONE LOOKUP PER CONNECT, NOTHING PER MESSAGE.
  #
  #   C1 · a token whose account no longer exists (the beta clean slate, an
  #        owner's delete on another device) is refused at the handshake
  #        (403). It used to connect, join, and sit on a queue nobody could
  #        ever send to. The app, refused, asks /api/me, hears account_gone
  #        and starts fresh. A lookup that could not run (a shed pool, a
  #        Postgres restart) proves nothing and the socket connects as before:
  #        refusing every reconnect during a database blip would turn the blip
  #        into a reconnect storm.
  #   C5 · the same row says whether this is a load-test account; with
  #        :Spojiti it is :uncounted, and QueueChannel marks its process so
  #        nothing it does is counted as people (SpojitiRelay.Stats).
  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    with {:ok, account_id} <- SpojitiRelayWeb.Auth.verify(token),
         {:ok, synthetic?} <- live(account_id) do
      uncounted? = synthetic? or account_id == SpojitiRelay.Accounts.official_id()
      {:ok, socket |> assign(:account_id, account_id) |> assign(:uncounted, uncounted?)}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  defp live(account_id) do
    case SpojitiRelay.Accounts.status(account_id) do
      {:ok, synthetic?} -> {:ok, synthetic?}
      :unknown -> {:ok, false}
      :gone -> :gone
      # #476 · moved away: no socket here; /api/me names the new home
      {:moved, _} -> :moved
    end
  end

  @impl true
  def id(socket), do: "socket:#{socket.assigns.account_id}"
end
