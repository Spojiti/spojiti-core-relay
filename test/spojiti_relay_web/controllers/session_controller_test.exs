defmodule SpojitiRelayWeb.SessionControllerTest do
  @moduledoc """
  Proves device-restore login end to end: an Ed25519 keypair registers, then
  proves possession of that identity through the challenge–response flow and
  receives a working bearer token — all without any PII.
  """
  use SpojitiRelayWeb.ConnCase, async: true

  # Register an account carrying an Ed25519 signing key; return {conn, priv, ik}.
  defp register(conn) do
    {sign_pub, sign_priv} = :crypto.generate_key(:eddsa, :ed25519)
    identity_key = Base.encode64(:crypto.strong_rand_bytes(32))

    body = %{
      "identity_key" => identity_key,
      "signing_key" => Base.encode64(sign_pub),
      "registration_id" => 4242,
      "signed_prekey" => %{
        "key_id" => 1,
        "public_key" => Base.encode64(:crypto.strong_rand_bytes(32)),
        "signature" => Base.encode64(:crypto.strong_rand_bytes(64))
      },
      "one_time_prekeys" => [
        %{"key_id" => 1, "public_key" => Base.encode64(:crypto.strong_rand_bytes(32))}
      ]
    }

    resp =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/register", body)
      |> json_response(201)

    {resp["account_id"], sign_priv, identity_key}
  end

  test "restore login mints a working token after proving possession", %{conn: conn} do
    {account_id, sign_priv, identity_key} = register(conn)

    # 1. Ask for a challenge for this identity.
    chal =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/login/challenge", %{"identity_key" => identity_key})
      |> json_response(200)

    assert chal["account_id"] == account_id
    nonce = Base.decode64!(chal["nonce"])

    # 2. Sign the nonce with the Ed25519 private key (device-side).
    signature = :crypto.sign(:eddsa, :none, nonce, [sign_priv, :ed25519])

    # 3. Verify → fresh token.
    verify =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/login/verify", %{
        "challenge" => chal["challenge"],
        "signature" => Base.encode64(signature)
      })
      |> json_response(200)

    assert verify["account_id"] == account_id
    assert is_binary(verify["token"])

    # 4. The token actually authenticates.
    me =
      conn
      |> put_req_header("authorization", "Bearer " <> verify["token"])
      |> get("/api/me")
      |> json_response(200)

    assert me["account_id"] == account_id
  end

  test "a bogus signature is rejected", %{conn: conn} do
    {_account_id, _priv, identity_key} = register(conn)

    chal =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/login/challenge", %{"identity_key" => identity_key})
      |> json_response(200)

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/login/verify", %{
      "challenge" => chal["challenge"],
      "signature" => Base.encode64(:crypto.strong_rand_bytes(64))
    })
    |> json_response(401)
  end

  test "an unknown identity cannot get a challenge", %{conn: conn} do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/login/challenge", %{
      "identity_key" => Base.encode64(:crypto.strong_rand_bytes(32))
    })
    |> json_response(404)
  end
end
