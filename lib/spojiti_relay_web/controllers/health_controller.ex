defmodule SpojitiRelayWeb.HealthController do
  @moduledoc """
  GET /api/health -- the one question a box outside this node can ask it.

  Until 2026-09-23 this returned `ok` from memory: a relay whose database was
  gone, or whose pool was saturated, still said `ok` to every prober, and the
  cell check's public door proved only that Caddy and the BEAM were up. That
  is the wrong half of the truth: a node that cannot reach its data cannot
  serve a single message, and "degrade, do not collapse" starts with saying so.

  So the check now touches the database through the same pool the channels
  use -- one `select 1`, bounded by the pool's own queue timeout. 200 means
  this node can serve; 503 with `db` set to what went wrong means it cannot,
  and a probe (or a load balancer, when there is one) can act on that.
  """
  use SpojitiRelayWeb, :controller

  alias SpojitiRelay.Repo

  def index(conn, _params) do
    {db, status} = db_status()

    conn
    |> put_status(if(status == "ok", do: 200, else: 503))
    |> json(%{
      status: status,
      db: db,
      service: "spojiti-relay",
      version: to_string(Application.spec(:spojiti_relay, :vsn) || "dev"),
      ops: ops_status(),
      # B360 (7.1) · the trial a NEW account gets here, as this node will
      # mint it (Ops slot, else the rail rule: Beta 2, Prod 7). A door reads
      # it from outside the box; a beta relay answering 7 is a finding.
      trial_days: SpojitiRelay.OpsSettings.trial_days(),
      # #455 · the signals a prober watches: push configuration per provider,
      # GeoIP state, counts since boot. Words and numbers only
      # (SpojitiRelay.Signals); the version above is the stale-ctl signal.
      signals: SpojitiRelay.Signals.read(),
      time: DateTime.utc_now()
    })
  end

  # 2026-09-28 · can this node read the Ops console's settings? "ok" (ctl's
  # book over CTL_URL answered), "unreachable" (every knob is on its
  # default), or "local" (this is ctl, or a box with no CTL_URL). Reported,
  # never fatal: a relay whose control plane is away still carries messages,
  # so the status code stays about the database. The doors read this field
  # to prove a release from outside the box.
  defp ops_status do
    if SpojitiRelay.OpsSettings.remote_book?() do
      _ = SpojitiRelay.OpsSettings.slot_value("ops.trial_days")

      case SpojitiRelay.OpsSettings.book_status() do
        :ok -> "ok"
        _ -> "unreachable"
      end
    else
      "local"
    end
  rescue
    _ -> "unreachable"
  end

  # The pool's queue_target/queue_interval already bound how long a checkout
  # waits before DBConnection gives up, so a saturated pool answers `busy`
  # quickly instead of piling probes on top of real traffic.
  defp db_status do
    case Repo.query("select 1", [], timeout: 2_000) do
      {:ok, %{rows: [[1]]}} -> {"ok", "ok"}
      {:ok, _} -> {"unexpected", "degraded"}
      {:error, %DBConnection.ConnectionError{}} -> {"busy", "degraded"}
      {:error, _} -> {"unreachable", "degraded"}
    end
  rescue
    _ -> {"unreachable", "degraded"}
  end
end
