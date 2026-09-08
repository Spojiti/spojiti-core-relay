defmodule SpojitiRelayWeb.ChannelCase do
  @moduledoc "Test case for Phoenix channel tests, with a sandboxed DB connection."
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint SpojitiRelayWeb.Endpoint
      import Phoenix.ChannelTest
      import SpojitiRelayWeb.ChannelCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(SpojitiRelay.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
