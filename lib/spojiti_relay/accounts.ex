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
  def register(attrs, opts \\ []) do
    # C5 · `synthetic: true` only from a caller that has PROVEN a load test
    # (RegistrationController's LOADTEST_KEY check, or an operator's rpc in
    # Beta-CrossCell-Proof.sh); the changeset never casts it from attrs.
    account = %Account{synthetic: Keyword.get(opts, :synthetic, false) == true}

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:account, Account.changeset(account, attrs))
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

  # 2026-10-06 · THE OFFICIAL ACCOUNT, :Spojiti. Pinned in the app
  # (spojiti/lib/data/official_account.dart); the relay needs only its id,
  # to leave it out of every "people" number (C5: accounts, active, beta
  # seats) and out of the per-message counters, and so that the beta clean
  # slate (Beta-Clean-Slate.sh) keeps it.
  @official_id "917ae952-8702-4102-8a5f-5ac88b6245e2"

  @doc "The :Spojiti official account's id."
  def official_id, do: @official_id

  @doc """
  2026-10-06 · C1 + C5 · does this account still exist, and is it a load-test
  account -- ONE indexed lookup by primary key, made once per socket connect
  and once per GET /api/me, never per message.

    {:ok, synthetic?}  the row is there
    :gone              the database answered, and there is no such row
    :unknown           the database did not answer (a shed pool, a restart)

  :gone is only ever said on a real answer. The app wipes its identity and
  every local chat when it hears account_gone (the beta clean slate), so a
  pool blip that read as "gone" would destroy a working install: a lookup
  that cannot prove absence says :unknown, and the callers fail open.
  """
  def status(account_id) do
    case Ecto.UUID.cast(account_id) do
      {:ok, uuid} ->
        case from(a in Account, where: a.id == ^uuid, select: a.synthetic) |> Repo.all() do
          [s] ->
            {:ok, s == true}

          [] ->
            # #476 · an account that MOVED to another cell is not gone: the
            # forwarding address is the answer, never "gone" (which an app
            # reads as "wipe this identity")
            case SpojitiRelay.AccountMove.Cell.moved(uuid) do
              {:ok, %{endpoint: e}} -> {:moved, e}
              :none -> :gone
            end
        end

      # A token is signed by this relay over an account id, so a value that is
      # not a uuid cannot name an account that exists.
      :error ->
        :gone
    end
  rescue
    _ -> :unknown
  catch
    :exit, _ -> :unknown
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

  @doc """
  2026-09-28 · THE OWNER DELETES THE ACCOUNT, EVERYWHERE ON THIS RELAY.

  Until now nothing could: no route removed an `accounts` row, so an
  identity the owner had wiped on every device still sat here with its
  public keys, device records, wake handles and last-seen time, for ever
  (DATA-INVENTORY.md recorded it as a finding). This removes, in one
  transaction: the account's wake handles (push_tokens), its encrypted
  backup slot, every envelope still waiting FOR it, and the account row --
  whose foreign keys take its prekeys and device records with it; its
  discovery beacons become tombstones (#442: every cell mirrors them, and
  a tombstone is how the others learn). Its encrypted media is swept after the commit (object store
  first, SpojitiRelay.Media.sweep_where/1). Envelopes it SENT to others stay
  theirs to collect, as they would after any sender goes offline.

  What survives is only what never named it: the daily counts in
  stats_daily (a deletion is itself counted there, as a number). The
  passkey recovery blob is keyed so this relay cannot tell whose it is; the
  app deletes it with its own owner tag.

  `{:ok, :deleted}` or `{:ok, :not_found}` -- idempotent, like every other
  delete here.
  """
  def delete_account(account_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(account_id) do
      result =
        Repo.transaction(fn ->
          for {table, col} <- [{"push_tokens", :account_id}, {"account_backups", :account_id},
                               {"inbox_messages", :recipient_account_id}] do
            from(r in table, where: field(r, ^col) == type(^uuid, :binary_id))
            |> Repo.delete_all()
          end

          # #442 · the account's beacons: a tombstone each, not a cascade --
          # the other cells mirror them and must learn the opt-out (the
          # foreign key that used to take them went with relay 1.32.0)
          :ok = SpojitiRelay.Discovery.delete_beacon(uuid)

          # C5 · the row says whether it was a person; a load-test account's
          # deletion is not one of "accounts deleted by their owners"
          {n, synth} = from(a in Account, where: a.id == ^uuid, select: a.synthetic) |> Repo.delete_all()
          {n, synth == [true] or uuid == @official_id}
        end)

      case result do
        {:ok, {1, uncounted?}} ->
          SpojitiRelay.Media.sweep_where(dynamic([b], b.owner_account_id == type(^uuid, :binary_id)))
          unless uncounted?, do: SpojitiRelay.Stats.bump("deletions")
          {:ok, :deleted}

        {:ok, {0, _}} ->
          {:ok, :not_found}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :error -> {:ok, :not_found}
    end
  end
end
