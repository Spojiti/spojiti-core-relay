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

  2026-10-06 (CEO item 5) · THE WEBSITE BOX IS A PROXY TOO. Website traffic
  takes one more hop than the app's: browser → the web box's Caddy → the
  relay's Caddy (which trusts exactly that box, TRUSTED_WEB_PROXY, and
  APPENDS it) → here. X-Forwarded-For arrives as "client, webbox". The walk
  below took the rightmost entry that was not internal — the web box, a
  public address — so every visitor to beta.spojiti.world shared ONE bucket:
  a single script could lock the whole website out of tickets, codes and
  sign-ins, and every per-address limit on it meant nothing. The relay now
  reads the same TRUSTED_WEB_PROXY (a cell line from tools/cell-render.py,
  passed to the relay and ctl services by compose) and walks past those
  addresses too, taking the rightmost entry that is NOT one of our proxies.
  Only the immediate peer decides whether the header is read at all; a web
  box address merely appearing in a client-sent header buys nothing, because
  the web box's Caddy replaces X-Forwarded-For with the connecting address.

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
        {:ok, ip} -> if trusted_peer?(ip) or web_proxy?(ip), do: nil, else: ip
        :error -> nil
      end
    end)
  end

  @doc """
  Is `ip` one of the rail's website boxes (TRUSTED_WEB_PROXY: CIDRs separated
  by spaces or commas — the exact value Caddy's `trusted_proxies static`
  reads)? Unset or unparseable entries trust nothing extra.
  """
  def web_proxy?(ip) when is_tuple(ip) do
    Enum.any?(web_proxies(), fn net -> in_cidr?(ip, net) end)
  end

  def web_proxy?(_), do: false

  # Parsed once per distinct value: the env is read per request (cheap), the
  # parse is redone only when the value changes (once per boot in practice).
  defp web_proxies do
    raw = System.get_env("TRUSTED_WEB_PROXY") || ""

    case :persistent_term.get({__MODULE__, :web}, nil) do
      {^raw, nets} ->
        nets

      _ ->
        nets =
          raw
          |> String.split([" ", ",", "\t", "\n"], trim: true)
          |> Enum.flat_map(fn cidr ->
            case cidr(cidr) do
              {:ok, net} -> [net]
              :error -> []
            end
          end)

        :persistent_term.put({__MODULE__, :web}, {raw, nets})
        nets
    end
  end

  defp cidr(s) do
    {addr, len} =
      case String.split(s, "/", parts: 2) do
        [a, l] -> {a, Integer.parse(l)}
        [a] -> {a, nil}
      end

    with {:ok, ip} <- :inet.parse_address(String.to_charlist(addr)) do
      bits = tuple_size(ip) * if(tuple_size(ip) == 4, do: 8, else: 16)

      case len do
        nil -> {:ok, {ip, bits}}
        {n, ""} when n >= 0 and n <= bits -> {:ok, {ip, n}}
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  defp in_cidr?(ip, {net, len}) when tuple_size(ip) == tuple_size(net) do
    size = if tuple_size(ip) == 4, do: 8, else: 16
    <<a::bitstring-size(^len), _::bitstring>> = to_bits(ip, size)
    <<b::bitstring-size(^len), _::bitstring>> = to_bits(net, size)
    a == b
  end

  # An IPv4 client may arrive as ::ffff:a.b.c.d on a dual-stack listener.
  defp in_cidr?({0, 0, 0, 0, 0, 0xFFFF, x, y}, {net, _} = n) when tuple_size(net) == 4,
    do: in_cidr?({div(x, 256), rem(x, 256), div(y, 256), rem(y, 256)}, n)

  defp in_cidr?(_, _), do: false

  defp to_bits(ip, size), do: for(p <- Tuple.to_list(ip), into: <<>>, do: <<p::size(size)>>)

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
