defmodule SpojitiRelayWeb.Auth do
  @moduledoc """
  Bearer-token auth. Tokens are signed with `Phoenix.Token` at registration and
  carry only the opaque account id — no PII.
  """
  import Plug.Conn

  # 1 year; the client refreshes by re-registering its device if needed.
  @max_age 60 * 60 * 24 * 365
  @salt "spojiti.account.auth.v1"

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, account_id} <- verify_any(token) do
      assign(conn, :account_id, account_id)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "unauthorized"})
        |> halt()
    end
  end

  # B386 · this box's own secret first; on the directory (ctl), a token a
  # CELL minted is verified by that cell (SpojitiRelay.CellAuth).
  defp verify_any(token) do
    case verify(token) do
      {:ok, _} = ok -> ok
      _ -> SpojitiRelay.CellAuth.verify_remote(token)
    end
  end

  def sign(account_id),
    do: Phoenix.Token.sign(SpojitiRelayWeb.Endpoint, @salt, account_id)

  def verify(token),
    do: Phoenix.Token.verify(SpojitiRelayWeb.Endpoint, @salt, token, max_age: @max_age)

  # --- Device-restore login challenge -----------------------------------------
  # A short-lived, server-signed envelope carrying the account id and a random
  # nonce. The client signs the nonce with its Ed25519 key to prove possession
  # of the identity, then hands the envelope back for verification.
  @challenge_salt "spojiti.login.challenge.v1"
  @challenge_max_age 120

  def sign_challenge(account_id, nonce_b64),
    do:
      Phoenix.Token.sign(SpojitiRelayWeb.Endpoint, @challenge_salt, %{
        "account_id" => account_id,
        "nonce" => nonce_b64
      })

  def verify_challenge(token),
    do:
      Phoenix.Token.verify(SpojitiRelayWeb.Endpoint, @challenge_salt, token,
        max_age: @challenge_max_age
      )
end
