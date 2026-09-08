defmodule SpojitiRelayWeb.SealedChannelTest do
  @moduledoc """
  #381 · The anonymous lane keeps the delivery promise and forgets the sender:
  an envelope sent on `sealed:lobby` is stored with NO sender, reaches the
  recipient's queue as `message:new` with `from: nil`, and the lane refuses
  what it must (unsealed ciphertext, floods, malformed frames).
  """
  use SpojitiRelayWeb.ChannelCase, async: false

  alias SpojitiRelay.Messaging
  alias SpojitiRelayWeb.{QueueChannel, SealedChannel, SealedSocket, UserSocket}

  defp sealed_conn do
    {:ok, _reply, socket} =
      SealedSocket
      |> socket(nil, %{})
      |> subscribe_and_join(SealedChannel, "sealed:lobby", %{})

    socket
  end

  defp recipient_online(account_id) do
    {:ok, _reply, socket} =
      UserSocket
      |> socket("socket:#{account_id}", %{account_id: account_id})
      |> subscribe_and_join(QueueChannel, "queue:#{account_id}", %{})

    socket
  end

  @sealed "ss1.AAAA"

  test "a sealed envelope is stored without a sender and delivered with from: nil" do
    recipient = Ecto.UUID.generate()
    _rq = recipient_online(recipient)
    lane = sealed_conn()

    ref = push(lane, "sealed:send", %{"to" => recipient, "ciphertext" => @sealed, "wake" => "none"})
    assert_reply ref, :ok, %{status: "queued", id: id}

    assert_push "message:new", %{id: ^id, from: nil, ciphertext: @sealed}

    [row] = Messaging.pending(recipient)
    assert row.sender_account_id == nil
    assert row.ciphertext == @sealed
  end

  test "an unsealed ciphertext is refused — the lane carries sealed envelopes only" do
    lane = sealed_conn()
    ref = push(lane, "sealed:send", %{"to" => Ecto.UUID.generate(), "ciphertext" => "Y2xhc3NpYw=="})
    assert_reply ref, :error, %{reason: "unsealed"}
    assert Messaging.pending(Ecto.UUID.generate()) == []
  end

  test "a frame without the two required fields is invalid" do
    lane = sealed_conn()
    ref = push(lane, "sealed:send", %{"to" => Ecto.UUID.generate()})
    assert_reply ref, :error, %{reason: "invalid_message"}
  end

  test "a fan-out batch goes through the same door, item by item" do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()
    lane = sealed_conn()

    items = [
      %{"to" => a, "ciphertext" => @sealed, "wake" => "none"},
      %{"to" => b, "ciphertext" => @sealed, "wake" => "none"},
      %{"to" => b, "ciphertext" => "not-sealed"}
    ]

    ref = push(lane, "sealed:send_batch", %{"items" => items})
    assert_reply ref, :error, %{reason: "unsealed_item"}

    ref = push(lane, "sealed:send_batch", %{"items" => Enum.take(items, 2)})
    assert_reply ref, :ok, %{n: 2, failed: 0}
    assert length(Messaging.pending(a)) == 1
    assert length(Messaging.pending(b)) == 1
    assert Enum.all?(Messaging.pending(b), &is_nil(&1.sender_account_id))
  end

  test "the per-recipient window answers rate_limited past 600 in 10 s" do
    to = Ecto.UUID.generate()
    lane = sealed_conn()
    # Spend the recipient's budget directly (the bucket the channel uses).
    :ok = SpojitiRelay.RateLimiter.check("sealed_to", to, 600, 10_000, 600)

    ref = push(lane, "sealed:send", %{"to" => to, "ciphertext" => @sealed, "wake" => "none"})
    assert_reply ref, :error, %{reason: "rate_limited"}
    assert Messaging.pending(to) == []
  end

  test "an entitlement token on the frame sets the retention window; garbage is free" do
    to = Ecto.UUID.generate()
    lane = sealed_conn()

    ref = push(lane, "sealed:send", %{"to" => to, "ciphertext" => @sealed, "wake" => "none", "ent" => "nonsense"})
    assert_reply ref, :ok, %{status: "queued"}
    [row] = Messaging.pending(to)
    free = SpojitiRelay.Retention.expires_at("free")
    assert DateTime.diff(row.expires_at, free, :second) |> abs() < 5
  end
end
