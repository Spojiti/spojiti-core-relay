defmodule SpojitiRelayWeb.Plugs.RateLimit do
  @moduledoc """
  S4 · Rate-limit plug. Put it in a router pipeline or in front of a route:

      plug SpojitiRelayWeb.Plugs.RateLimit,
        bucket: "register", by: :ip, limit: 30, window_ms: 60_000

  `by:`
    * `:account` — keys on conn.assigns.account_id (authed routes only; the
      precise per-identity control). Falls back to :ip if no account assigned.
    * `:ip`      — keys on the REAL client address (Plugs.RealIp), resolved
      from X-Forwarded-For but ONLY when the immediate peer is one of our own
      proxies. Before #216 this keyed on conn.remote_ip, which behind the S1
      gateway is Caddy for every request — making every cap a single global
      budget rather than a per-client one.

  On limit: 429 with a Retry-After header + a JSON body, and `halt`. Zero
  knowledge holds — the limiter stores only counters keyed by opaque ids, no
  content, no PII, and the buckets evaporate on their own.
  """
  import Plug.Conn
  alias SpojitiRelay.RateLimiter

  def init(opts) do
    %{
      bucket: Keyword.fetch!(opts, :bucket),
      by: Keyword.get(opts, :by, :ip),
      limit: Keyword.fetch!(opts, :limit),
      window_ms: Keyword.fetch!(opts, :window_ms)
    }
  end

  def call(conn, %{bucket: bucket, by: by, limit: limit, window_ms: window_ms}) do
    id = key_for(conn, by)

    case RateLimiter.check(bucket, id, limit, window_ms) do
      :ok ->
        conn

      {:deny, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_status(:too_many_requests)
        |> Phoenix.Controller.json(%{error: "rate_limited", retry_after: retry_after})
        |> halt()
    end
  end

  defp key_for(conn, :account) do
    case conn.assigns[:account_id] do
      nil -> ip_key(conn)
      account_id -> "acct:" <> account_id
    end
  end

  defp key_for(conn, :ip), do: ip_key(conn)

  # #216 · the REAL client, not our own proxy. Before this, every `by: :ip`
  # bucket keyed on Caddy's address and was therefore one global budget shared
  # by everyone on earth — see SpojitiRelayWeb.Plugs.RealIp for the whole
  # story and for why the forwarded header is only trusted from our own hops.
  defp ip_key(conn) do
    "ip:" <> SpojitiRelayWeb.Plugs.RealIp.key(conn)
  end
end
