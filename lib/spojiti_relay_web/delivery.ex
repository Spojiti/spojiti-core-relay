defmodule SpojitiRelayWeb.Delivery do
  @moduledoc """
  ONE ENVELOPE, ONE PATH. Store, then deliver-if-online. The authenticated
  queue channel and the anonymous sealed lane both call this, so the two can
  never drift.

  What the Core deliberately does not have: push wakes (a phone that is not
  connected collects on its next connect), per-device fan-out (one device
  per account), and tiers (one retention window). The full product adds
  those on top of exactly this door.

  `from` is the sender's account id on the authenticated channel and `nil`
  on the sealed lane — the relay does not know, and the row says so.
  """
  alias SpojitiRelay.Messaging
  alias SpojitiRelayWeb.Endpoint

  @batch_cap 600
  def batch_cap, do: @batch_cap

  @doc "The wire shape of a stored envelope, as the recipient's channel pushes it."
  def render(%Messaging.InboxMessage{} = m) do
    %{
      id: m.id,
      # nil for a sealed envelope: the relay never held a sender.
      from: m.sender_account_id,
      type: m.message_type,
      ciphertext: m.ciphertext,
      at: m.inserted_at
    }
  end

  @doc """
  One envelope: store it, then hand it to the recipient's live channel if
  there is one.

  A SHED QUERY MUST NOT COST THE USER THEIR SOCKET. DBConnection sheds by
  RAISING, and unguarded that raise kills the channel process and the client
  reads a disconnect. The guard sits HERE, on the one path every send takes
  (both lanes, single and batch), so no door can be left bare: a shed is
  `{:error, :busy}` -- the send fails, the socket lives, the client retries.
  """
  def deliver_one(%{"to" => to, "ciphertext" => ciphertext} = payload, from) do
    attrs = %{
      "recipient_account_id" => to,
      "sender_account_id" => from,
      "message_type" => Map.get(payload, "type", "signal"),
      "ciphertext" => ciphertext
    }

    case Messaging.enqueue(attrs) do
      {:ok, stored} ->
        Endpoint.broadcast("queue:#{to}", "message:new", render(stored))
        {:ok, stored}

      {:error, changeset} ->
        {:error, changeset}
    end
  rescue
    _ in DBConnection.ConnectionError -> {:error, :busy}
  end

  @doc """
  A fan-out frame: every well-formed item goes through `deliver_one/2`; the
  reply counts. `{ok, bad}` when the frame ran to its end; `{:busy, ok, bad}`
  when the pool shed part-way -- the items after the shed were not attempted
  and the reply says so, so the sender retries the frame.
  """
  def deliver_batch(items, from) when is_list(items) do
    Enum.reduce_while(items, {0, 0}, fn item, {ok, bad} ->
      case item do
        %{"to" => _, "ciphertext" => _} ->
          case deliver_one(item, from) do
            {:ok, _} -> {:cont, {ok + 1, bad}}
            {:error, :busy} -> {:halt, {:busy, ok, bad}}
            _ -> {:cont, {ok, bad + 1}}
          end

        _ ->
          {:cont, {ok, bad + 1}}
      end
    end)
  end
end
