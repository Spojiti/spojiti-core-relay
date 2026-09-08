defmodule SpojitiRelay.Retention do
  @moduledoc """
  #154 + TIERED RELAY RETENTION — how long an undelivered envelope waits.

  THE PRODUCT RULE (CEO, 2026-08-28): a message the recipient has not collected
  is held for a published window and then swept. Free 24h, Pro 48h, Pro+ 120h.
  After that it is gone, by design, and the tier pages say so plainly. This is
  the first thing in the system that ever deleted a parked envelope: until now
  NOTHING swept inbox_messages, so the queue grew without bound and the disk
  had an undated appointment with zero bytes free.

  WHOSE TIER GOVERNS — AND WHY THE CRYPTO DECIDED IT. The SENDER's. Only the
  sender is present at enqueue, and only the sender can present a blind-signed
  entitlement token; the socket already carries the verified tier from join
  (queue_channel: Entitlement.tier_of/1). Recipient-governed retention would
  need the relay to hold a per-account tier — a standing commercial fact about
  a named account, which is exactly the knowledge this relay is built not to
  have. So the privacy-correct answer and the architecturally natural one are
  the same, and it reads well besides: your messages are held for up to N hours
  while your contact is offline. A Free user hearing from a Pro+ friend gets
  the benefit, which helps us rather than costs us.

  ZERO-KNOWLEDGE HOLDS. The token's bucket is (tier, expiry-month), encoded by
  WHICH RSA key verifies it and never by payload bytes (EntBlind). The relay
  learns "this send is entitled to the Pro+ window" and cannot learn which
  account holds Pro+. Nothing tier-shaped is stored on the row: only a
  timestamp, which is exactly as revealing as inserted_at already was.

  TRIAL RIDES THE TOP WINDOW deliberately — a trial should show the best of the
  product, not a middle of it. One line to change if the CEO rules otherwise.
  """

  # The single source of truth. Anything that prints these hours to a user —
  # tier pages, corpus, in-app copy — must read them from here or be checked
  # against here, or we are back to a claim that outlived its mechanism.
  @hours %{"free" => 24, "trial" => 120, "pro" => 48, "proplus" => 120}
  @default_hours 24

  @doc "Retention window in hours for a resolved tier. Unknown ⇒ free."
  def hours_for(tier) when is_binary(tier), do: Map.get(@hours, tier, @default_hours)
  def hours_for(_), do: @default_hours

  @doc "The longest window any tier can buy — the safe horizon for blob sweeps."
  def max_hours, do: @hours |> Map.values() |> Enum.max()

  @doc "The whole table, for ops display and for content checks."
  def table, do: @hours

  @doc "Absolute expiry for an envelope enqueued now under `tier`."
  def expires_at(tier, from \\ nil) do
    (from || DateTime.utc_now())
    |> DateTime.add(hours_for(tier) * 3600, :second)
    |> DateTime.truncate(:second)
  end
end
