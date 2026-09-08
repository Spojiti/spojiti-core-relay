defmodule SpojitiRelayWeb.RegistrationController do
  use SpojitiRelayWeb, :controller

  alias SpojitiRelay.Accounts
  alias SpojitiRelay.Pow
  alias SpojitiRelayWeb.Auth

  require Logger

  # POST /api/register
  # #30 · bot gate (build 98): when PoW is enabled the client must attach a
  # solved challenge ("pow" => %{challenge, sig, nonce}). POW_REQUIRED=false
  # keeps a grace window for pre-98 clients: failures are logged, not fatal.
  def create(conn, params) do
    case pow_gate(params) do
      :ok ->
        do_register(conn, params)

      {:soft, reason} ->
        Logger.info("pow_soft_miss reason=#{reason}")
        do_register(conn, params)

      {:error, reason} ->
        conn
        |> put_status(428)
        |> json(%{error: "pow_required", reason: to_string(reason), bits: Pow.bits()})
    end
  end

  defp pow_gate(params) do
    pow = params["pow"]

    cond do
      not Pow.enabled?() ->
        :ok

      is_map(pow) ->
        case Pow.verify(pow) do
          :ok -> :ok
          {:error, r} -> if Pow.required?(), do: {:error, r}, else: {:soft, r}
        end

      Pow.required?() ->
        {:error, :missing}

      true ->
        {:soft, :missing}
    end
  end

  defp do_register(conn, params) do
    case Accounts.register(params) do
      {:ok, account} ->
        token = Auth.sign(account.id)

        body = %{
          account_id: account.id,
          registration_id: account.registration_id,
          token: token
        }

        conn
        |> put_status(:created)
        |> json(body)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_registration", details: translate_errors(changeset)})
    end
  end


  # GET /api/me  (authed)
  def me(conn, _params) do
    json(conn, %{account_id: conn.assigns.account_id})
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end
end
