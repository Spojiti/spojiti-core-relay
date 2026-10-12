defmodule SpojitiRelayWeb.KeyController do
  use SpojitiRelayWeb, :controller

  alias SpojitiRelay.Keys

  # GET /api/keys/:account_id  — fetch a bundle to start a session.
  def show(conn, %{"account_id" => account_id}) do
    case Keys.take_bundle(account_id) do
      {:ok, bundle} ->
        json(conn, bundle)

      {:error, :not_found} ->
        # #442 · not on this cell: the home cell answers, one hop. An
        # account nobody serves is the 404 it always was.
        case SpojitiRelay.CellForward.route(account_id) do
          {:remote, endpoint} ->
            case SpojitiRelay.CellForward.fetch_bundle(endpoint, account_id) do
              {:ok, bundle} -> json(conn, bundle)
              {:error, 404} -> conn |> put_status(:not_found) |> json(%{error: "account_not_found"})
              {:error, 409} -> conn |> put_status(:conflict) |> json(%{error: "no_signed_prekey"})
              {:error, _} -> conn |> put_status(:service_unavailable) |> json(%{error: "cell_unavailable"})
            end

          _ ->
            conn |> put_status(:not_found) |> json(%{error: "account_not_found"})
        end

      {:error, :no_signed_prekey} ->
        conn |> put_status(:conflict) |> json(%{error: "no_signed_prekey"})
    end
  end

  # POST /api/keys  (authed) — replenish one-time prekeys.
  def replenish(conn, %{"one_time_prekeys" => otks}) when is_list(otks) do
    account_id = conn.assigns.account_id

    case Keys.replenish(account_id, otks) do
      {:ok, count} ->
        json(conn, %{accepted: count, available: Keys.available_count(account_id)})

      {:error, _} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_prekeys"})
    end
  end

  def replenish(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "one_time_prekeys required"})
  end
  # #60 · PQXDH — publish or rotate this account's ML-KEM prekey.
  # Authed (the pipeline already resolved account_id); the relay does not and
  # cannot verify the ML-KEM key itself — it stores the blob and the Ed25519
  # signature, and the RECIPIENT verifies that signature before ever using it.
  def put_pq(conn, %{"key_id" => key_id, "public_key" => pk, "signature" => sig} = params)
      when is_integer(key_id) and is_binary(pk) and is_binary(sig) do
    # #378 · PQ-2 adds alg ("ml-kem-1024") and the ML-DSA-65 signature; both
    # optional so a PQ-1 client's publish still lands unchanged.
    attrs = %{
      "key_id" => key_id,
      "public_key" => pk,
      "signature" => sig,
      "alg" => optional_binary(params["alg"]),
      "pq_signature" => optional_binary(params["pq_signature"])
    }

    case SpojitiRelay.Accounts.put_pq_prekey(conn.assigns.account_id, attrs) do
      {:ok, _} -> json(conn, %{ok: true})
      {:error, _cs} -> conn |> put_status(:bad_request) |> json(%{error: "bad_pq_prekey"})
    end
  end

  def put_pq(conn, _), do: conn |> put_status(:bad_request) |> json(%{error: "bad_request"})

  # Idempotent: no row is a success, not a 404. The client calls this from an
  # error path and must never have to reason about whether it had published.
  # #381 · `{"caps": ["sealed"]}` — what this account's clients can receive.
  def put_caps(conn, %{"caps" => caps}) when is_list(caps) do
    case SpojitiRelay.Accounts.put_caps(conn.assigns.account_id, caps) do
      {:ok, acct} -> json(conn, %{ok: true, caps: acct.caps})
      {:error, _} -> conn |> put_status(:bad_request) |> json(%{error: "bad_caps"})
    end
  end

  def put_caps(conn, _), do: conn |> put_status(:bad_request) |> json(%{error: "caps required"})

  def del_pq(conn, _params) do
    SpojitiRelay.Accounts.delete_pq_prekey(conn.assigns.account_id)
    json(conn, %{ok: true})
  end

  # #378 · POST /api/keys/pqauth — publish the account's ML-DSA-65 signing key
  # and its signature over the classical signed prekey. Authed; opaque to the
  # relay; verified by every peer under the safety-number model.
  def put_pq_auth(conn, %{"pq_signing_key" => pk, "spk_pq_signature" => sig} = params)
      when is_binary(pk) and is_binary(sig) do
    case SpojitiRelay.Accounts.put_pq_auth(conn.assigns.account_id, params) do
      {:ok, _} -> json(conn, %{ok: true})
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "account_not_found"})
      {:error, :no_signed_prekey} -> conn |> put_status(:conflict) |> json(%{error: "no_signed_prekey"})
      {:error, _} -> conn |> put_status(:bad_request) |> json(%{error: "bad_pq_auth"})
    end
  end

  def put_pq_auth(conn, _), do: conn |> put_status(:bad_request) |> json(%{error: "bad_request"})

  defp optional_binary(v) when is_binary(v), do: v
  defp optional_binary(_), do: nil
end
