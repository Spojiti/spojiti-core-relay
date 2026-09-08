defmodule SpojitiRelay.Pow do
  @moduledoc """
  #30 · Bot gate, layer 1 — stateless proof-of-work challenges for
  registration (build 98 / open-beta hardening).

  The beta APK + TestFlight links are public and `POST /api/register` is
  unauthed by design (no PII, ever) — so account creation needs a cost.
  S4 rate limits cap the FLOOD; PoW prices each individual account: the
  client must find a nonce where `sha256(challenge <> "." <> nonce)` has
  `bits` leading zero bits (~1–3 s of phone CPU at 18 bits, unnoticeable
  once per install; expensive at bot scale).

  Design:
    * STATELESS mint — the challenge is `v1.<ts>.<rand>.<bits>` plus an
      HMAC(secret_key_base) signature. No DB row, no ETS entry, nothing to
      flood at mint time.
    * ONE-TIME redeem — a verified challenge is burned in ETS until its
      TTL passes, so a single solution cannot be replayed in a loop.
    * ENV-GATED rollout — `POW_BITS` (default 18; 0 disables entirely) and
      `POW_REQUIRED` (default false = grace window: solutions are verified
      + logged but absence is tolerated, so b97 clients keep onboarding).
      Flip `POW_REQUIRED=true` once build 98 is the download default.

  HONEST LIMIT (recorded, same spirit as the RateLimiter moduledoc): PoW
  raises the marginal cost of a fake account, it does not prove a human or
  a genuine device. Layer 2 of #30 — Play Integrity / App Attest with a
  PoW fallback — is the real sybil defense and rides a later native pass.
  """

  use GenServer

  @table :spojiti_pow_used
  # Challenge lifetime. Generous: mobile CPUs solve in seconds, but the
  # register call itself may ride out a flaky-network retry window.
  @ttl_ms 600_000
  @sweep_ms 120_000
  @default_bits 18

  # ---- config ----

  def bits do
    case Integer.parse(System.get_env("POW_BITS") || "") do
      {n, _} when n >= 0 and n <= 30 -> n
      _ -> @default_bits
    end
  end

  def required?, do: System.get_env("POW_REQUIRED") in ["true", "1"]
  def enabled?, do: bits() > 0

  # ---- mint ----

  @doc "Mint a fresh challenge map for the client. Stateless until redeemed."
  def challenge do
    ts = System.system_time(:millisecond)
    rand = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    payload = "v1.#{ts}.#{rand}.#{bits()}"

    %{
      challenge: payload,
      sig: sign(payload),
      bits: bits(),
      algo: "sha256-lz",
      ttl_s: div(@ttl_ms, 1000)
    }
  end

  # ---- verify ----

  @doc """
  Verify a solved challenge (`%{"challenge" => _, "sig" => _, "nonce" => _}`).
  Returns `:ok` or `{:error, reason}`; success burns the challenge (one-time).
  """
  def verify(%{"challenge" => payload, "sig" => sig, "nonce" => nonce})
      when is_binary(payload) and is_binary(sig) and is_binary(nonce) and
             byte_size(payload) <= 128 and byte_size(sig) <= 128 and
             byte_size(nonce) <= 64 do
    with ["v1", ts_s, _rand, bits_s] <- String.split(payload, ".", parts: 4),
         {ts, ""} <- Integer.parse(ts_s),
         {cbits, ""} <- Integer.parse(bits_s),
         # The client must have solved at the CURRENT difficulty or harder —
         # a hostile client cannot mint itself an easy challenge because the
         # HMAC covers the bits field.
         true <- cbits >= bits() or {:error, :weak},
         true <- Plug.Crypto.secure_compare(sign(payload), sig) or {:error, :bad_sig},
         true <- System.system_time(:millisecond) - ts < @ttl_ms or {:error, :expired},
         true <-
           leading_zero_bits(:crypto.hash(:sha256, payload <> "." <> nonce)) >= cbits or
             {:error, :bad_pow},
         true <- :ets.insert_new(@table, {sig, ts + @ttl_ms}) or {:error, :replayed} do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed}
    end
  end

  def verify(_), do: {:error, :malformed}

  defp sign(payload) do
    secret = SpojitiRelayWeb.Endpoint.config(:secret_key_base)

    Base.url_encode64(
      :crypto.mac(:hmac, :sha256, "spojiti.pow.v1|" <> secret, payload),
      padding: false
    )
  end

  defp leading_zero_bits(bin), do: lzb(bin, 0)
  defp lzb(<<0::size(1), rest::bitstring>>, n), do: lzb(rest, n + 1)
  defp lzb(_, n), do: n

  # ---- GenServer: owns the burned-challenge table + timed sweep ----

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end
end
