defmodule SpojitiRelayWeb.ConnCase do
  @moduledoc """
  Test case for controller/endpoint tests. Sets up a sandboxed DB connection and
  a `conn` for building requests.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint SpojitiRelayWeb.Endpoint
      import Plug.Conn
      import Phoenix.ConnTest
      import SpojitiRelayWeb.ConnCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(SpojitiRelay.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
