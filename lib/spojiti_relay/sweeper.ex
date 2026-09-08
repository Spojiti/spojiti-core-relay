defmodule SpojitiRelay.Sweeper do
  @moduledoc """
  Deletes envelopes whose retention window has passed. Nothing is archived:
  an envelope that was never collected simply stops existing.
  """
  use GenServer
  require Logger

  @every_ms 10 * 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :sweep, @every_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    n = SpojitiRelay.Messaging.sweep_expired()
    if n > 0, do: Logger.info("sweeper: #{n} expired envelope(s) removed")
    Process.send_after(self(), :sweep, @every_ms)
    {:noreply, state}
  end
end
