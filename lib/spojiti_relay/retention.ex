defmodule SpojitiRelay.Retention do
  @moduledoc """
  #154 + RELAY RETENTION — how long an undelivered envelope waits.

  THE PRODUCT RULE: a message the recipient has not collected is held for a
  published window and then swept. After that it is gone, by design, and the
  pages say so plainly. This was the first thing in the system that ever
  deleted a parked envelope: before it NOTHING swept inbox_messages, so the
  queue grew without bound.

  ONE WINDOW FOR EVERYONE (B383 · #452 D-05 · CEO 2026-10-09, option A).
  From 2026-08-28 the SENDER's tier chose the window (Free 24h, Premium
  120h), read from the entitlement token on the frame. On the sealed lane
  that token was the one thing that tied an anonymous envelope back to an
  account: the app presented the SAME token on its authenticated join, so the
  relay could match a sealed send to the account that joined with it. The
  sealed lane now carries no token at all, so the relay cannot know the
  sender's plan there, and a window it cannot know cannot differ by plan.
  Every envelope, on every lane, waits for the same window: the LONGER of
  the two Ops columns ("Undelivered messages held"), 120 hours by default.
  Nobody who paid for five days lost them; Free gained them.

  `hours_for/1` keeps its argument so the delivery path (which still carries
  the authenticated lane's tier for its other caps) compiles unchanged; the
  tier no longer moves the answer. Recipient-governed retention stays out
  for the reason it always was: it would need the relay to hold a per-account
  tier, which is exactly the knowledge this relay is built not to have.
  """

  # The default, when Ops has set nothing. Anything that prints these hours to
  # a user — tier pages, corpus, in-app copy — must read them from here or be
  # checked against here (spojiti/test/retention_test.dart), or we are back to
  # a claim that outlived its mechanism. The tier keys stay so a token in the
  # field (a retired "pro", a "trial") still resolves; every one answers the
  # same window since B383.
  @hours %{"free" => 120, "trial" => 120, "pro" => 120, "proplus" => 120, "premium" => 120}
  @default_hours 120

  @doc """
  The one retention window, in hours: the longer of the Ops console's two
  "Undelivered messages held" columns (blank = 120). Taking the longer means
  no console edit can quietly shorten what a paying user was sold.
  """
  def window_hours do
    [col("free"), col("proplus")] |> Enum.max()
  end

  defp col(tier) do
    case SpojitiRelay.TierCaps.get("retentionHours", tier) do
      n when is_integer(n) and n >= 1 -> n
      _ -> Map.get(@hours, tier, @default_hours)
    end
  end

  @doc "Retention window for an envelope. The tier no longer moves it (B383 · D-05)."
  def hours_for(_tier), do: window_hours()

  @doc "The longest window an envelope can have — the safe horizon for blob sweeps."
  def max_hours do
    Enum.max([Enum.max(Map.values(@hours)), window_hours()])
  end

  @doc "The whole table, for ops display and for content checks."
  def table, do: @hours

  @doc "Absolute expiry for an envelope enqueued now under `tier`."
  def expires_at(tier, from \\ nil) do
    (from || DateTime.utc_now())
    |> DateTime.add(hours_for(tier) * 3600, :second)
    |> DateTime.truncate(:second)
  end
end
