defmodule SpojitiRelay.Keys do
  @moduledoc "The prekey directory — hands out bundles to bootstrap Signal sessions."
  import Ecto.Query, warn: false
  alias SpojitiRelay.Repo
  alias SpojitiRelay.Accounts
  alias SpojitiRelay.Accounts.Account
  alias SpojitiRelay.Keys.OneTimePrekey

  @doc """
  Builds a prekey bundle for `account_id`, consuming one one-time prekey if
  available (Signal works fine without one, just with weaker forward secrecy
  on the very first message).
  """
  def take_bundle(account_id) do
    case Repo.get(Account, account_id) |> Repo.preload([:signed_prekey, :pq_signed_prekey]) do
      nil ->
        {:error, :not_found}

      %Account{signed_prekey: nil} ->
        {:error, :no_signed_prekey}

      %Account{} = account ->
        otk = take_one_time_prekey(account_id)

        # Core: one device per account, one prekey directory. The multi-device
        # directory (per-device signed prekeys) is not part of the Core.
        {:ok,
         %{
           account_id: account.id,
           registration_id: account.registration_id,
           identity_key: account.identity_key,
           # G3 · the account's Ed25519 signing pubkey, so group members can
           # verify admin-signed grp_meta. Public material only — same trust
           # model as identity_key (safety-number verification covers a lying
           # relay). Additive: old clients ignore the extra field.
           signing_key: account.signing_key,
           # #378 · the ML-DSA-65 signing key and the post-quantum signature
           # over the classical prekey. Additive and nil-able: a pre-PQ-2
           # account has neither and peers verify it classically.
           pq_signing_key: account.pq_signing_key,
           # #381 · "sealed" ⇒ this peer opens sealed-sender envelopes; a
           # sender seals to it and the relay never learns who wrote.
           caps: account.caps || [],
           signed_prekey: %{
             key_id: account.signed_prekey.key_id,
             public_key: account.signed_prekey.public_key,
             signature: account.signed_prekey.signature,
             pq_signature: account.signed_prekey.pq_signature
           },
           one_time_prekey:
             otk && %{key_id: otk.key_id, public_key: otk.public_key},
           # #60 · PQXDH. Additive and nil-able: absent ⇒ the peer is
           # classical-only and the initiator skips the KEM leg. Old clients
           # ignore the extra field entirely.
           pq_signed_prekey:
             account.pq_signed_prekey &&
               %{
                 key_id: account.pq_signed_prekey.key_id,
                 alg: account.pq_signed_prekey.alg,
                 public_key: account.pq_signed_prekey.public_key,
                 signature: account.pq_signed_prekey.signature,
                 pq_signature: account.pq_signed_prekey.pq_signature
               }
         }}
    end
  end

  # Atomically claim + delete one unused one-time prekey.
  defp take_one_time_prekey(account_id) do
    Repo.transaction(fn ->
      query =
        from o in OneTimePrekey,
          where: o.account_id == ^account_id,
          order_by: o.inserted_at,
          limit: 1,
          lock: "FOR UPDATE SKIP LOCKED"

      case Repo.one(query) do
        nil -> nil
        otk -> Repo.delete!(otk)
      end
    end)
    |> case do
      {:ok, otk} -> otk
      _ -> nil
    end
  end

  @doc "Adds fresh one-time prekeys for an account (replenishment)."
  def replenish(account_id, one_time_prekeys) do
    Accounts.insert_one_time_prekeys(Repo, account_id, one_time_prekeys)
  end

  def available_count(account_id) do
    Repo.aggregate(from(o in OneTimePrekey, where: o.account_id == ^account_id), :count)
  end
end
