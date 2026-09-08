defmodule SpojitiRelayWeb.QueueChannel do
  @moduledoc """
  Per-account real-time queue. On join we flush anything the account missed
  while offline; thereafter we route ciphertext live.

  Delivery is at-least-once: the client dedupes by `id` and must send
  `message:ack` so the relay can forget the envelope. A flush that never
  landed (a socket that died moments after join) is re-pushed on a bounded,
  widening retry while the socket is alive.

  The Core keeps the authenticated send (`message:send`) for a peer that
  cannot open a sealed envelope; a sealed-capable peer is written to through
  the anonymous lane (SealedChannel), which is the path the relay learns
  nothing from.
  """
  use SpojitiRelayWeb, :channel

  alias SpojitiRelay.{Accounts, Messaging}
  alias SpojitiRelayWeb.Delivery

  require Logger

  @reflush_ms 20_000
  @reflush_tries 3

  @impl true
  def join("queue:" <> account_id, _payload, socket) do
    if account_id != socket.assigns.account_id do
      {:error, %{reason: "forbidden"}}
    else
      send(self(), :touch_seen)
      send(self(), :flush_pending)
      {:ok, %{"caps" => ["send_batch"]}, socket}
    end
  end

  @impl true
  def handle_info(:touch_seen, socket) do
    Accounts.touch_last_seen(socket.assigns.account_id)
    {:noreply, socket}
  end

  def handle_info(:flush_pending, socket) do
    account_id = socket.assigns.account_id
    flushed = Messaging.pending(account_id)
    for msg <- flushed, do: push(socket, "message:new", Delivery.render(msg))
    if flushed != [], do: Process.send_after(self(), {:reflush_pending, 1}, @reflush_ms)
    {:noreply, socket}
  end

  def handle_info({:reflush_pending, try_n}, socket) do
    left = Messaging.pending(socket.assigns.account_id)

    if left != [] do
      Logger.info("queue: reflush ##{try_n} → #{length(left)} unacked")
      for msg <- left, do: push(socket, "message:new", Delivery.render(msg))

      if try_n < @reflush_tries do
        Process.send_after(self(), {:reflush_pending, try_n + 1}, @reflush_ms * (try_n + 1))
      end
    end

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    Accounts.touch_last_seen(socket.assigns.account_id)
    :ok
  end

  @impl true
  def handle_in("message:send_batch", %{"items" => items}, socket) when is_list(items) do
    if length(items) > Delivery.batch_cap() do
      {:reply, {:error, %{reason: "batch_too_large", cap: Delivery.batch_cap()}}, socket}
    else
      {ok, bad} = Delivery.deliver_batch(items, socket.assigns.account_id)
      {:reply, {:ok, %{n: ok, failed: bad}}, socket}
    end
  end

  def handle_in("message:send", %{"to" => _, "ciphertext" => _} = payload, socket) do
    case Delivery.deliver_one(payload, socket.assigns.account_id) do
      {:ok, stored} -> {:reply, {:ok, %{id: stored.id, status: "queued"}}, socket}
      {:error, _} -> {:reply, {:error, %{reason: "invalid_message"}}, socket}
    end
  end

  def handle_in("message:ack", %{"id" => id}, socket) do
    Messaging.ack(id, socket.assigns.account_id)
    {:reply, :ok, socket}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}
end
