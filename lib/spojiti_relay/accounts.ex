defmodule SpojitiRelay.Accounts do
  @moduledoc "Anonymous account registration & lookup."
  import Ecto.Query, warn: false
  alias SpojitiRelay.Repo
  alias SpojitiRelay.Accounts.Account
  alias SpojitiRelay.Keys.{SignedPrekey, OneTimePrekey, PqSignedPrekey}

  @doc """
  Registers an anonymous account from a client-generated key bundle, atomically:
  the account, its signed prekey, and its initial one-time prekeys.

  `attrs` shape:
      %{
        "identity_key" => base64,
        "registration_id" => int,
        "signed_prekey" => %{"key_id" => int, "public_key" => base64, "signature" => base64},
        "one_time_prekeys" => [%{"key_id" => int, "public_key" => base64}, ...]
      }
  """
  def register(attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:account, Account.changeset(%Account{}, attrs))
    |> Ecto.Multi.insert(:signed_prekey, fn %{account: account} ->
      spk = Map.get(attrs, "signed_prekey", %{})
      SignedPrekey.changeset(%SignedPrekey{}, Map.put(spk, "account_id", account.id))
    end)
    |> Ecto.Multi.run(:one_time_prekeys, fn repo, %{account: account} ->
      otks = Map.get(attrs, "one_time_prekeys", [])
      insert_one_time_prekeys(repo, account.id, otks)
    end)
    # #60 · PQXDH prekey — OPTIONAL, and its optionality is the whole
    # compatibility story: a pre-PQ client simply omits it and registers
    # exactly as before. A malformed one must never fail an otherwise valid
    # registration, so it is skipped rather than aborting the transaction.
    |> Ecto.Multi.run(:pq_signed_prekey, fn repo, %{account: account} ->
      case Map.get(attrs, "pq_signed_prekey") do
        %{} = pq ->
          # :savepoint so that even a DB-level rejection of the PQ row cannot
          # poison the surrounding transaction and take the registration with
          # it. Belt and braces: the changeset catches the realistic failures
          # before they reach Postgres at all.
          case repo.insert(
                 PqSignedPrekey.changeset(%PqSignedPrekey{}, Map.put(pq, "account_id", account.id)),
                 mode: :savepoint
               ) do
            {:ok, row} -> {:ok, row}
            {:error, _cs} -> {:ok, nil}
          end

        _ ->
          {:ok, nil}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{account: account}} -> {:ok, account}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  # Repo.get/2 raises Ecto.Query.CastError when handed a value that isn't a valid
  # binary_id — e.g. a malformed or mis-pasted account id arriving from a client.
  # A lookup for a bad id is simply "no such account", not a crash. Returning nil
  # keeps one bad id from taking down the caller — most importantly the realtime
  # channel's presence:get handler, whose crash otherwise drops the whole socket.
  def get(account_id) do
    Repo.get(Account, account_id)
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc "Look up an account by its base64 X25519 identity key (used for device-restore login)."
  def get_by_identity_key(identity_key),
    do: Repo.get_by(Account, identity_key: identity_key)

  @doc "Stamp an account's last-seen time (called when its socket disconnects)."
  def touch_last_seen(account_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(a in Account, where: a.id == ^account_id)
    |> Repo.update_all(set: [last_seen_at: now])
  end

  def insert_one_time_prekeys(repo, account_id, otks) do
    results =
      Enum.map(otks, fn otk ->
        repo.insert(
          OneTimePrekey.changeset(%OneTimePrekey{}, Map.put(otk, "account_id", account_id))
        )
      end)

    if Enum.all?(results, &match?({:ok, _}, &1)) do
      {:ok, length(results)}
    else
      {:error, :invalid_prekeys}
    end
  end
  @doc """
  #60 · publish (or rotate) the account's PQ prekey.

  Exists because every account created before post-quantum has none, and we
  refuse to make people re-register to get quantum protection: a client
  derives its PQ prekey from the phrase it already has and calls this once.
  Idempotent — re-publishing the same derived key is a no-op in effect.
  """
  def put_pq_prekey(account_id, %{} = pq) do
    attrs = Map.put(pq, "account_id", account_id)

    case Repo.get_by(PqSignedPrekey, account_id: account_id) do
      nil -> PqSignedPrekey.changeset(%PqSignedPrekey{}, attrs)
      existing -> PqSignedPrekey.changeset(existing, attrs)
    end
    |> Repo.insert_or_update()
  end

  @doc """
  #60 · withdraw an account's PQ prekey.

  Idempotent by design: deleting a row that is not there is a success. The
  client calls this from a failure path (its KEM binding stopped working) and
  must not need to know whether it ever published.
  """
  def delete_pq_prekey(account_id) do
    case Repo.get_by(PqSignedPrekey, account_id: account_id) do
      nil -> {:ok, nil}
      row -> Repo.delete(row)
    end
  end

  @doc """
  #378 · publish (or refresh) an account's post-quantum authentication: the
  ML-DSA-65 public signing key on the account and its signature over the
  classical signed prekey. Both land in one transaction so a bundle can never
  show a signature without the key it verifies under, or the reverse.

  The relay checks shape only. A wrong signature is caught by every peer, and
  it is the peer's verdict that matters — the relay could not vouch for a key
  it does not understand, and pretending to would be worse than nothing.
  """
  def put_pq_auth(account_id, %{"pq_signing_key" => pk, "spk_pq_signature" => sig})
      when is_binary(pk) and is_binary(sig) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:account, fn repo, _ ->
      case repo.get(Account, account_id) do
        nil -> {:error, :not_found}
        acct -> repo.update(Account.changeset(acct, %{"pq_signing_key" => pk}))
      end
    end)
    |> Ecto.Multi.run(:spk, fn repo, _ ->
      case repo.get_by(SignedPrekey, account_id: account_id) do
        nil -> {:error, :no_signed_prekey}
        spk -> repo.update(SignedPrekey.changeset(spk, %{"pq_signature" => sig}))
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _} -> {:ok, :published}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  def put_pq_auth(_account_id, _), do: {:error, :bad_request}

  @doc """
  #381 · Publish what this account's clients can receive. Idempotent; the
  client sends it at every launch beside the PQ prekey. Only known caps are
  kept, so a stray string cannot grow the column.
  """
  @known_caps ["sealed"]
  def put_caps(account_id, caps) when is_list(caps) do
    caps = caps |> Enum.filter(&(&1 in @known_caps)) |> Enum.uniq()

    case Repo.get(Account, account_id) do
      nil -> {:error, :not_found}
      acct -> Repo.update(Account.changeset(acct, %{"caps" => caps}))
    end
  end

  def put_caps(_account_id, _), do: {:error, :bad_request}
end
