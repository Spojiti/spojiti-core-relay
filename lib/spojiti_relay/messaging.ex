defmodule SpojitiRelay.Messaging do
  @moduledoc """
  Store-and-forward for opaque ciphertext. The relay parks undelivered
  envelopes, streams them on (re)connect, and deletes them on ack. Nothing is
  archived: history lives only on the two devices.
  """
  import Ecto.Query, warn: false
  alias SpojitiRelay.Repo
  alias SpojitiRelay.Messaging.InboxMessage

  @doc """
  Persist an envelope for later delivery. Returns {:ok, message}.

  The Core has one tier — free — and one retention window. The expiry is
  set on the STRUCT, not through the changeset, so no client payload can cast
  its own envelope into a longer life.
  """
  def enqueue(attrs, tier \\ "free") do
    %InboxMessage{expires_at: SpojitiRelay.Retention.expires_at(tier)}
    |> InboxMessage.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Undelivered envelopes for an account, oldest first."
  def pending(account_id) do
    Repo.all(
      from(m in InboxMessage,
        where: m.recipient_account_id == ^account_id,
        order_by: m.inserted_at
      )
    )
  end

  @doc """
  Ack a delivered envelope: it is deleted, and only the rightful recipient
  account may ack. The Core is one device per account, so the first ack is
  the last one.
  """
  def ack(message_id, account_id) do
    from(m in InboxMessage,
      where: m.id == ^message_id and m.recipient_account_id == ^account_id
    )
    |> Repo.delete_all()
  end

  @doc """
  #92 · True while this envelope is still undelivered (row not yet acked). The
  zombie-socket wake guard uses it: a message a CONNECTED recipient hasn't acked
  within the grace window means its socket was a Doze zombie, so we fall back to
  a push wake instead of silently dropping it.
  """
  def still_pending?(message_id) do
    Repo.exists?(from(m in InboxMessage, where: m.id == ^message_id))
  end

  @doc """
  #154 · Sweep every envelope whose published window has passed. Returns the
  count. Rows with a NULL expiry are pre-policy leftovers and are held to the
  LONGEST window before going, so nothing is ever cut short by a migration.
  """
  def sweep_expired do
    now = DateTime.utc_now()

    {expired, _} =
      from(m in InboxMessage, where: not is_nil(m.expires_at) and m.expires_at <= ^now)
      |> Repo.delete_all()

    legacy_cutoff = DateTime.add(now, -SpojitiRelay.Retention.max_hours() * 3600, :second)

    {legacy, _} =
      from(m in InboxMessage, where: is_nil(m.expires_at) and m.inserted_at < ^legacy_cutoff)
      |> Repo.delete_all()

    expired + legacy
  end

  @doc "Housekeeping: drop envelopes older than `days` (undeliverable)."
  def purge_older_than(days) when is_integer(days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)
    from(m in InboxMessage, where: m.inserted_at < ^cutoff) |> Repo.delete_all()
  end
end
