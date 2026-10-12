defmodule SpojitiRelay.RateLimiter do
  @moduledoc """
  S4 · App-layer rate limiting — fixed-window counters in ETS, no deps, no
  Redis. Owns one public ETS table of `{ {bucket, id, window_ms, window} =>
  count }` and sweeps genuinely-expired windows on a timer.

  `check/4` is a single atomic `:ets.update_counter` — safe under concurrency,
  O(1), and cheap enough to sit in front of every abuse-prone endpoint.

      RateLimiter.check("register", ip, 30, 60_000)
      # => :ok | {:deny, retry_after_seconds}

  KEYING NOTE (honest): behind the S1 stream gateway + Caddy, the relay sees
  the proxy's IP, not the real client's, for unauthed routes — so an `ip`
  bucket there behaves as a GLOBAL flood cap (still valuable: it caps a
  registration/provision storm and protects the box), not per-attacker. True
  per-IP needs PROXY-protocol propagation (S4.1) — until then, per-ACCOUNT
  buckets on authed routes are the precise control, and #30 bot-gate
  (attestation/PoW) is the real sybil defense. Limits are set with this in
  mind (generous global caps, tight per-account caps).
  """
  use GenServer

  @table :spojiti_rate_limiter
  @sweep_interval_ms 60_000
  @grace_ms 300_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Returns `:ok` if this hit is within `limit` per `window_ms` for
  `{bucket, id}`, else `{:deny, retry_after_seconds}`. Fail-open: if the table
  is somehow unavailable (startup race), allow — the limiter must never take
  the relay down.
  """
  def check(bucket, id, limit, window_ms, cost \\ 1) do
    now = System.system_time(:millisecond)
    window = div(now, window_ms)
    # window_ms is part of the key so the sweeper can compute each row's exact
    # expiry regardless of which bucket's window size it belongs to.
    key = {bucket, id, window_ms, window}

    try do
      # #340 · `cost` lets a batch spend N units at once (discovery: numbers
      # per day, not requests per day). Default 1 keeps every caller as it was.
      count = :ets.update_counter(@table, key, {2, cost}, {key, 0})

      if count <= limit do
        :ok
      else
        retry_after = div((window + 1) * window_ms - now, 1000) + 1
        {:deny, retry_after}
      end
    rescue
      ArgumentError -> :ok
    end
  end

  @doc """
  B378 · a small value kept beside the counters, in the same table and swept
  by the same rule: `{bucket, id}` for the CURRENT `window_ms` window. Used by
  /api/turn to remember WHEN an account was last charged against its daily
  budget (never a credential). Fail-open like `check/5`.
  """
  def put_memo(bucket, id, window_ms, value) do
    now = System.system_time(:millisecond)

    try do
      :ets.insert(@table, {{bucket, id, window_ms, div(now, window_ms)}, value})
      :ok
    rescue
      ArgumentError -> :ok
    end
  end

  @doc "B378 · the value `put_memo/4` left for `{bucket, id}` this window, or nil."
  def get_memo(bucket, id, window_ms) do
    now = System.system_time(:millisecond)

    try do
      case :ets.lookup(@table, {bucket, id, window_ms, div(now, window_ms)}) do
        [{_, value}] -> value
        _ -> nil
      end
    rescue
      ArgumentError -> nil
    end
  end

  # --- GenServer: owns the table + periodic sweep -----------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)
    cutoff = now - @grace_ms
    # Delete rows whose window END ((window+1)*window_ms) is older than cutoff.
    # Match-spec arithmetic computes expiry per-row, so heterogeneous window
    # sizes are each judged correctly — live long-window buckets are kept.
    :ets.select_delete(@table, [
      {
        {{:_, :_, :"$1", :"$2"}, :_},
        [{:<, {:*, {:+, :"$2", 1}, :"$1"}, cutoff}],
        [true]
      }
    ])

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
