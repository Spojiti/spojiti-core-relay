# WHAT THE CORE DOES NOT HAVE, AS THE SHARED FILES MEET IT.
#
# Several relay files are copied into the Core byte for byte from the product
# (tools/core-extract.py, RELAY_VERBATIM): accounts, retention, auth, the
# health, key and session controllers. In the product they also reach parts
# of Spojiti that are deliberately not open source (SCOPE.md): other cells,
# accounts that moved between cells, discovery, media, the Ops console, the
# paid tiers, the operations counters.
#
# Each module below is the Core's answer for one of those parts: the answer of
# a relay that is a single cell, has no media, no discovery, no Ops console and
# no tiers. None of them stores, counts or sends anything. Where an answer
# decides trust, it refuses (CellAuth.verify_remote: a token this relay did
# not sign is never accepted). A shared file that starts calling something
# new fails the Core's own compile (Core-Check, warnings are errors) until it
# has an answer here: that is the point.
#
# The answers go through `SpojitiRelay.NotInCore.answer/1`, which returns its
# argument. It exists for the compiler, not for configuration: Elixir 1.20's
# type checker reads a literal answer and then refuses the shared file's
# branch for the product's other answers (a `{:remote, endpoint}` route, a
# moved account) as "will never match" -- in the Core those branches really
# are never taken, and that is fine.

defmodule SpojitiRelay.NotInCore do
  @moduledoc false
  @doc "Returns `value` (typed as any term, so the shared files keep their branches)."
  def answer(value), do: Application.get_env(:spojiti_relay, :__not_in_core_never_set__, value)
end

defmodule SpojitiRelay.AccountMove.Cell do
  @moduledoc "No other cells: no account has moved away from this one."
  def moved(_account_id), do: SpojitiRelay.NotInCore.answer(:none)
  def moved_identity(_identity_key), do: SpojitiRelay.NotInCore.answer(:none)
end

defmodule SpojitiRelay.CellForward do
  @moduledoc "One cell: every account this relay knows is local; there is nowhere to forward."
  def route(_account_id), do: SpojitiRelay.NotInCore.answer(:local)
  def fetch_bundle(_endpoint, _account_id), do: SpojitiRelay.NotInCore.answer({:error, 404})
end

defmodule SpojitiRelay.CellAuth do
  @moduledoc "One cell: a token this relay did not sign is refused (fails closed)."
  def verify_remote(_token), do: :error
end

defmodule SpojitiRelay.Discovery do
  @moduledoc "No contact discovery in the Core: no beacons to remove."
  def delete_beacon(_account_id), do: :ok
end

defmodule SpojitiRelay.Media do
  @moduledoc "No media in the Core: nothing to sweep."
  def sweep_where(_condition), do: :ok
end

defmodule SpojitiRelay.Stats do
  @moduledoc "No operations counters in the Core: nothing is counted."
  def bump(_metric, _n \\ 1), do: :ok
end

defmodule SpojitiRelay.TierCaps do
  @moduledoc "No tiers in the Core: every limit is the shared file's own default."
  def get(_key, _tier), do: SpojitiRelay.NotInCore.answer(nil)
end

defmodule SpojitiRelay.OpsSettings do
  @moduledoc "No Ops console in the Core: no trial, no remote settings book."
  def trial_days, do: SpojitiRelay.NotInCore.answer(nil)
  def remote_book?, do: SpojitiRelay.NotInCore.answer(false)
  def slot_value(_key), do: SpojitiRelay.NotInCore.answer(nil)
  def book_status, do: SpojitiRelay.NotInCore.answer(:local)
end

defmodule SpojitiRelay.Signals do
  @moduledoc "No push providers, GeoIP or counters in the Core: nothing to report."
  def read, do: %{}
end
