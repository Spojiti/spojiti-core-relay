defmodule SpojitiRelayWeb.SessionController do
  @moduledoc """
  Device-restore login via challenge–response.

  A user who reinstalls or switches phones re-derives the *same* identity from
  their recovery phrase, but not the relay-assigned account id or bearer token
  (those only lived on the old device). This flow lets them prove possession of
  the identity and mint a fresh token — no PII, no password, no re-registration.

      POST /api/login/challenge  {identity_key}          -> {account_id, nonce, challenge}
      # client signs the raw nonce bytes with its Ed25519 signing key
      POST /api/login/verify     {challenge, signature}  -> {account_id, token}
  """
  use SpojitiRelayWeb, :controller

  alias SpojitiRelay.Accounts
  alias SpojitiRelayWeb.Auth

  # POST /api/login/challenge
  def challenge(conn, %{"identity_key" => identity_key})
      when is_binary(identity_key) do
    case Accounts.get_by_identity_key(identity_key) do
      %{signing_key: sk} = account when is_binary(sk) ->
        nonce = Base.encode64(:crypto.strong_rand_bytes(32))
        token = Auth.sign_challenge(account.id, nonce)

        json(conn, %{account_id: account.id, nonce: nonce, challenge: token})

      %{} ->
        # Registered before signing keys existed — can't do device-restore.
        conn
        |> put_status(:conflict)
        |> json(%{error: "no_signing_key"})

      nil ->
        # #476 · an identity that registered here and moved cells is sent on,
        # never told "not registered" (which makes an app register anew)
        case SpojitiRelay.AccountMove.Cell.moved_identity(identity_key) do
          {:ok, %{endpoint: e}} ->
            conn |> put_status(421) |> json(%{error: "account_moved", endpoint: e})

          :none ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "not_registered"})
        end
    end
  end

  def challenge(conn, _),
    do: conn |> put_status(:bad_request) |> json(%{error: "identity_key required"})

  # POST /api/login/verify
  def verify(conn, %{"challenge" => challenge, "signature" => signature})
      when is_binary(challenge) and is_binary(signature) do
    with {:ok, %{"account_id" => account_id, "nonce" => nonce_b64}} <-
           Auth.verify_challenge(challenge),
         %{signing_key: sk} <- Accounts.get(account_id),
         false <- is_nil(sk),
         {:ok, nonce} <- Base.decode64(nonce_b64),
         {:ok, sig} <- Base.decode64(signature),
         {:ok, pub} <- Base.decode64(sk),
         true <- verify_ed25519(nonce, sig, pub) do
      json(conn, %{account_id: account_id, token: Auth.sign(account_id)})
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "challenge_failed"})
    end
  end

  def verify(conn, _),
    do: conn |> put_status(:bad_request) |> json(%{error: "challenge and signature required"})

  defp verify_ed25519(message, signature, public_key) do
    :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519])
  rescue
    _ -> false
  end
end
