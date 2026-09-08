defmodule SpojitiRelayWeb.SealedChannel do
  @moduledoc """
  #381 · `sealed:lobby` — the one topic on the anonymous socket. Two events,
  `sealed:send` and `sealed:send_batch`, both feeding the SAME
  `SpojitiRelayWeb.Delivery.deliver_one/2` the authenticated channel uses,
  with the sender `nil`: the row stores no sender, the recipient's
  `message:new` carries `from: nil`, and the sender's identity travels
  inside the sealed layer the recipient alone can open.

  WHAT THE LANE INSISTS ON. Every envelope must be a sealed one (`ss1.`
  prefix): the lane exists to carry envelopes the recipient can attribute
  by opening them, not to let an unsealed ratchet message arrive with no
  sender at all — which the recipient could not route and the app would
  drop. The prefix check is the only look the relay ever takes at the
  ciphertext, and it reads four bytes.

  ABUSE CONTROLS, since nobody is authenticated here (Arch-SS-v1 §3):
  per-connection and per-recipient fixed windows (RateLimiter), the
  connect-rate bucket on the socket, and — only when SEALED_POW_REQUIRED is
  on — a solved registration-style proof of work presented at join. The Core
  has one retention window for every envelope.
  """
  use SpojitiRelayWeb, :channel

  alias SpojitiRelayWeb.Delivery

  # A batch spends its item count; these are the windows Arch-SS-v1 §3 sets.
  @per_conn_limit 300
  @per_conn_window_ms 10_000
  @per_recipient_limit 600
  @per_recipient_window_ms 10_000

  # PoW AT THE LANE JOIN IS ITS OWN SWITCH, OFF BY DEFAULT (found by the load
  # harness, 2026-09-07): the challenge comes from /api/pow, which sits on the
  # REGISTRATION bucket (12/min per address) — the right budget for sign-ups,
  # and the wrong one for a lane every device re-joins on every reconnect.
  # Behind an Indian carrier's CGNAT, hundreds of phones share one address:
  # a reconnect wave would exhaust the bucket, the lanes would never join,
  # and sealed envelopes would sit in the app's buffer. The lane's abuse
  # controls are the three rate limits; SEALED_POW_REQUIRED=true turns the
  # stamp back on for a box under attack, knowingly.
  def sealed_pow_required?, do: System.get_env("SEALED_POW_REQUIRED") in ["true", "1"]

  @impl true
  def join("sealed:lobby", payload, socket) do
    if sealed_pow_required?() and not pow_ok?(payload) do
      {:error, %{reason: "pow_required"}}
    else
      # An opaque per-connection key for the rate bucket: random, never
      # logged, dies with the process.
      conn_key = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      {:ok, %{"caps" => ["send_batch"], "cap" => Delivery.batch_cap()}, assign(socket, :conn_key, conn_key)}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "forbidden"}}

  defp pow_ok?(%{"pow" => pow}) when is_map(pow), do: SpojitiRelay.Pow.verify(pow) == :ok
  defp pow_ok?(_), do: false

  @impl true
  def handle_in("sealed:send", %{"to" => to, "ciphertext" => ct} = payload, socket)
      when is_binary(to) and is_binary(ct) do
    with :ok <- sealed?(ct),
         :ok <- within_limits(socket, to, 1) do
      case Delivery.deliver_one(payload, nil) do
        {:ok, stored} -> {:reply, {:ok, %{id: stored.id, status: "queued"}}, socket}
        {:error, _} -> {:reply, {:error, %{reason: "invalid_message"}}, socket}
      end
    else
      {:error, reason} -> {:reply, {:error, %{reason: reason}}, socket}
      {:deny, retry} -> {:reply, {:error, %{reason: "rate_limited", retry_after: retry}}, socket}
    end
  end

  def handle_in("sealed:send", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_message"}}, socket}
  end

  def handle_in("sealed:send_batch", %{"items" => items}, socket) when is_list(items) do
    cond do
      length(items) > Delivery.batch_cap() ->
        {:reply, {:error, %{reason: "batch_too_large", cap: Delivery.batch_cap()}}, socket}

      Enum.any?(items, fn it -> not (is_map(it) and sealed?(Map.get(it, "ciphertext")) == :ok) end) ->
        {:reply, {:error, %{reason: "unsealed_item"}}, socket}

      true ->
        # The per-connection budget is spent once for the whole frame; the
        # per-recipient budget per distinct recipient in it.
        with :ok <- conn_limit(socket, length(items)),
             :ok <- recipients_limit(items) do
          {ok, bad} = Delivery.deliver_batch(items, nil)
          {:reply, {:ok, %{n: ok, failed: bad}}, socket}
        else
          {:deny, retry} ->
            {:reply, {:error, %{reason: "rate_limited", retry_after: retry}}, socket}
        end
    end
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- helpers ---------------------------------------------------------------

  defp sealed?("ss1." <> rest) when byte_size(rest) > 0, do: :ok
  defp sealed?(_), do: {:error, "unsealed"}

  defp within_limits(socket, to, cost) do
    with :ok <- conn_limit(socket, cost) do
      SpojitiRelay.RateLimiter.check(
        "sealed_to",
        to,
        @per_recipient_limit,
        @per_recipient_window_ms,
        cost
      )
    end
  end

  defp conn_limit(socket, cost) do
    SpojitiRelay.RateLimiter.check(
      "sealed_conn",
      socket.assigns.conn_key,
      @per_conn_limit,
      @per_conn_window_ms,
      cost
    )
  end

  defp recipients_limit(items) do
    items
    |> Enum.group_by(&Map.get(&1, "to"))
    |> Enum.reduce_while(:ok, fn {to, copies}, :ok ->
      case SpojitiRelay.RateLimiter.check(
             "sealed_to",
             to,
             @per_recipient_limit,
             @per_recipient_window_ms,
             length(copies)
           ) do
        :ok -> {:cont, :ok}
        deny -> {:halt, deny}
      end
    end)
  end
end
