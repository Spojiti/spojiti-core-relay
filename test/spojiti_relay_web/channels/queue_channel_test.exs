defmodule SpojitiRelayWeb.QueueChannelTest do
  @moduledoc """
  The relay's core promise: a message enqueued while the recipient is offline
  is flushed to them on join, ack removes it so it is never re-delivered, and
  a message sent while they are online reaches their channel at once.
  """
  use SpojitiRelayWeb.ChannelCase, async: false

  alias SpojitiRelay.Messaging
  alias SpojitiRelayWeb.{QueueChannel, UserSocket}

  defp connect_as(account_id) do
    UserSocket |> socket("socket:#{account_id}", %{account_id: account_id})
  end

  test "a message queued while offline is flushed on join, then acked away" do
    recipient = Ecto.UUID.generate()
    sender = Ecto.UUID.generate()

    {:ok, stored} =
      Messaging.enqueue(%{
        "recipient_account_id" => recipient,
        "sender_account_id" => sender,
        "ciphertext" => "Y2lwaGVydGV4dA=="
      })

    assert length(Messaging.pending(recipient)) == 1

    {:ok, _reply, socket} =
      connect_as(recipient) |> subscribe_and_join(QueueChannel, "queue:#{recipient}")

    id = stored.id
    assert_push "message:new", %{id: ^id, from: ^sender, ciphertext: "Y2lwaGVydGV4dA=="}

    ref = push(socket, "message:ack", %{"id" => id})
    assert_reply ref, :ok
    assert Messaging.pending(recipient) == []
  end

  test "an online recipient receives a live send, and only the recipient may ack" do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()
    {:ok, _, sa} = connect_as(a) |> subscribe_and_join(QueueChannel, "queue:#{a}")
    {:ok, _, _sb} = connect_as(b) |> subscribe_and_join(QueueChannel, "queue:#{b}")

    ref = push(sa, "message:send", %{"to" => b, "ciphertext" => "aGVsbG8="})
    assert_reply ref, :ok, %{status: "queued", id: id}
    assert_push "message:new", %{id: ^id, from: ^a}

    # a cannot ack b's envelope
    ref = push(sa, "message:ack", %{"id" => id})
    assert_reply ref, :ok
    assert length(Messaging.pending(b)) == 1
  end

  test "an account cannot join another account's queue" do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()
    assert {:error, %{reason: "forbidden"}} =
             connect_as(a) |> subscribe_and_join(QueueChannel, "queue:#{b}")
  end
end
