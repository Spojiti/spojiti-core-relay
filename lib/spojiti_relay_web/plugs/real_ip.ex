defmodule SpojitiRelayWeb.Plugs.RealIp do
  @moduledoc """
  #216 · TEACH THE RELAY WHICH MACHINE IS ACTUALLY TALKING TO IT.

  THE BUG THIS FIXES, stated plainly. Every `by: :ip` rate-limit bucket in the
  router keyed on `conn.remote_ip`. Behind our own chain — nginx SNI gateway,
  then Caddy, then the relay — that address is *Caddy*, for every request on
  earth. So `register` at 40/minute was not "40 per attacker", it was one
  global budget shared by the entire planet: a single script could lock out
  every genuine sign-up, and 500 beta testers onboarding together would hit
  the wall in their first hour without anyone doing anything wrong.

  The limiter's own moduledoc said so. It had been true for months.

  HOW THE ADDRESS SURVIVES THE CHAIN. The gateway is layer 4 with PROXY
  protocol, so Caddy's peer IS the real client; Caddy then sets
  `X-Forwarded-For` to that address. Our job is only to trust that header —
  and to trust it ONLY when the request actually came from our own proxy.

  WHY THE TRUST CHECK IS NOT OPTIONAL. `X-Forwarded-For` is attacker-supplied
  data. A relay that reads it unconditionally is worse than one that ignores
  it: every limit becomes bypassable by sending one header, and every abuse
  counter can be pinned on an innocent address. So the header is honoured only
  when the immediate peer is inside the container network or loopback — the
  places only our own proxies can be — and is otherwise ignored entirely.

  WHAT IS AND IS NOT STORED. Nothing. This plug computes an address, puts it
  in `conn.assigns` for the limiter to hash into a bucket key, and stops. No
  IP is written to the database, none reaches a log line we emit, and the
  limiter's own buckets hold counters keyed by an opaque string and evaporate
  on their own. Zero-PII holds: knowing "some machine has tried to register
  forty times this minute" is not knowledge about a person.
  """
  import Plug.Conn

  @doc false
  def init(opts), do: opts

  def call(conn, _opts) do
    assign(conn, :real_ip, resolve(conn))
  end

  @doc """
  The address to rate-limit against: the client Caddy saw when the request
  reached us through our own chain, otherwise the peer itself.
  """
  def resolve(conn) do
    if trusted_peer?(conn.remote_ip) do
      conn
      |> get_req_header("x-forwarded-for")
      |> forwarded_client()
      |> case do
        nil -> conn.remote_ip
        ip -> ip
      end
    else
      conn.remote_ip
    end
  end

  @doc """
  #381 · The same resolution for a SOCKET connect: `connect_info` carries the
  peer and the x-headers Caddy set. Honoured through our own chain only, as
  above; returns the printable bucket key. Nothing is stored or logged.
  """
  def socket_key(%{peer_data: %{address: ip}} = info) when is_tuple(ip) do
    xff = for {"x-forwarded-for", v} <- Map.get(info, :x_headers, []) || [], do: v

    resolved =
      if trusted_peer?(ip) do
        forwarded_client(xff) || ip
      else
        ip
      end

    resolved |> :inet.ntoa() |> to_string()
  end

  def socket_key(_), do: "unknown"

  @doc "Printable form, for use as a rate-limit bucket key."
  def key(conn) do
    case conn.assigns[:real_ip] || resolve(conn) do
      ip when is_tuple(ip) -> ip |> :inet.ntoa() |> to_string()
      other -> to_string(other)
    end
  end

  # X-Forwarded-For is client, proxy1, proxy2... — appended left to right. Our
  # chain adds exactly one hop we control, so the RIGHTMOST entry that is not
  # itself one of our proxies is the closest thing to the truth we have. Walk
  # from the right and take the first address that is not internal; if every
  # entry is internal, there is no client address here worth having.
  defp forwarded_client([]), do: nil

  defp forwarded_client(values) do
    values
    |> Enum.join(",")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reverse()
    |> Enum.find_value(fn candidate ->
      case parse(candidate) do
        {:ok, ip} -> if trusted_peer?(ip), do: nil, else: ip
        :error -> nil
      end
    end)
  end

  # Strip an optional :port on IPv4 and the brackets IPv6 arrives in.
  defp parse(""), do: :error

  defp parse(raw) do
    raw =
      raw
      |> String.trim_leading("[")
      |> String.replace(~r/\](:\d+)?$/, "")

    raw =
      case String.split(raw, ":") do
        [v4, port] -> if match?({_, ""}, Integer.parse(port)), do: v4, else: raw
        _ -> raw
      end

    case :inet.parse_address(String.to_charlist(raw)) do
      {:ok, ip} -> {:ok, ip}
      _ -> :error
    end
  end

  # Loopback, link-local, and the RFC1918 ranges Docker allocates from. These
  # are the only places our own proxies can be, and no real client can reach
  # us from one.
  defp trusted_peer?({127, _, _, _}), do: true
  defp trusted_peer?({10, _, _, _}), do: true
  defp trusted_peer?({192, 168, _, _}), do: true
  defp trusted_peer?({169, 254, _, _}), do: true
  defp trusted_peer?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp trusted_peer?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # ::ffff:a.b.c.d — an IPv4 peer arriving on a dual-stack listener.
  defp trusted_peer?({0, 0, 0, 0, 0, 0xFFFF, a, b}),
    do: trusted_peer?({div(a, 256), rem(a, 256), div(b, 256), rem(b, 256)})

  # Unique-local IPv6 (fc00::/7). Arithmetic is not allowed in a pattern, so
  # this is a guard — and it must sit AFTER the two specific 8-tuple clauses
  # above or it would shadow them.
  defp trusted_peer?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: true
  defp trusted_peer?(_), do: false
end
