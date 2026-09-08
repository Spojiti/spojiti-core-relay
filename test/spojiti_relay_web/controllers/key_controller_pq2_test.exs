defmodule SpojitiRelayWeb.KeyControllerPq2Test do
  @moduledoc """
  #377 / #378 · PQ-2 on the relay: the bundle carries the post-quantum
  authentication and the ML-KEM-1024 prekey exactly as published, nil-able
  for accounts that predate it, and the relay never interprets a byte.
  """
  use SpojitiRelayWeb.ConnCase, async: true

  alias SpojitiRelayWeb.Auth

  defp b64(n), do: Base.encode64(:crypto.strong_rand_bytes(n))

  defp register(conn, extra \\ %{}) do
    body =
      Map.merge(
        %{
          "identity_key" => b64(32),
          "signing_key" => b64(32),
          "registration_id" => 7,
          "signed_prekey" => %{"key_id" => 1, "public_key" => b64(32), "signature" => b64(64)},
          "one_time_prekeys" => [%{"key_id" => 1, "public_key" => b64(32)}]
        },
        extra
      )

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/register", body)
    |> json_response(201)
    |> Map.fetch!("account_id")
  end

  defp bundle(conn, id), do: conn |> get("/api/keys/#{id}") |> json_response(200)

  test "a pre-PQ-2 account's bundle omits every post-quantum auth field", %{conn: conn} do
    id = register(conn)
    b = bundle(conn, id)
    assert b["pq_signing_key"] == nil
    assert b["signed_prekey"]["pq_signature"] == nil
    assert b["pq_signed_prekey"] == nil
  end

  test "registration carries the ML-DSA key, the spk pq signature and the 1024 prekey verbatim",
       %{conn: conn} do
    pqk = b64(1952)
    spk_sig = b64(3309)
    ek = b64(1568)
    pq_sig = b64(3309)

    id =
      register(conn, %{
        "pq_signing_key" => pqk,
        "signed_prekey" => %{
          "key_id" => 1,
          "public_key" => b64(32),
          "signature" => b64(64),
          "pq_signature" => spk_sig
        },
        "pq_signed_prekey" => %{
          "key_id" => 2,
          "alg" => "ml-kem-1024",
          "public_key" => ek,
          "signature" => b64(64),
          "pq_signature" => pq_sig
        }
      })

    b = bundle(conn, id)
    assert b["pq_signing_key"] == pqk
    assert b["signed_prekey"]["pq_signature"] == spk_sig
    assert b["pq_signed_prekey"]["key_id"] == 2
    assert b["pq_signed_prekey"]["alg"] == "ml-kem-1024"
    assert b["pq_signed_prekey"]["public_key"] == ek
    assert b["pq_signed_prekey"]["pq_signature"] == pq_sig
  end

  test "POST /api/keys/pqauth upgrades an older account without re-registering", %{conn: conn} do
    id = register(conn)
    pqk = b64(1952)
    sig = b64(3309)

    resp =
      conn
      |> put_req_header("authorization", "Bearer " <> Auth.sign(id))
      |> put_req_header("content-type", "application/json")
      |> post("/api/keys/pqauth", %{"pq_signing_key" => pqk, "spk_pq_signature" => sig})
      |> json_response(200)

    assert resp["ok"] == true
    b = bundle(conn, id)
    assert b["pq_signing_key"] == pqk
    assert b["signed_prekey"]["pq_signature"] == sig

    # And the 1024 prekey through the existing route, with the new fields.
    ek = b64(1568)

    conn
    |> put_req_header("authorization", "Bearer " <> Auth.sign(id))
    |> put_req_header("content-type", "application/json")
    |> post("/api/keys/pq", %{
      "key_id" => 2,
      "alg" => "ml-kem-1024",
      "public_key" => ek,
      "signature" => b64(64),
      "pq_signature" => b64(3309)
    })
    |> json_response(200)

    b2 = bundle(conn, id)
    assert b2["pq_signed_prekey"]["key_id"] == 2
    assert b2["pq_signed_prekey"]["alg"] == "ml-kem-1024"
    assert b2["pq_signed_prekey"]["public_key"] == ek
  end

  test "a malformed pqauth is refused and changes nothing", %{conn: conn} do
    id = register(conn)

    conn
    |> put_req_header("authorization", "Bearer " <> Auth.sign(id))
    |> put_req_header("content-type", "application/json")
    |> post("/api/keys/pqauth", %{"pq_signing_key" => "short", "spk_pq_signature" => b64(3309)})
    |> json_response(400)

    assert bundle(conn, id)["pq_signing_key"] == nil
  end
end
