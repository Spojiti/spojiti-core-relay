defmodule SpojitiRelayWeb do
  @moduledoc """
  Entrypoint macros for the web layer: `use SpojitiRelayWeb, :controller`,
  `:router`, or `:channel`.
  """

  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]
      import Plug.Conn
    end
  end

  def router do
    quote do
      use Phoenix.Router
      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def channel do
    quote do
      # #247 · ZERO-PII APPLIES TO OUR OWN LOGS, and it did not.
      #
      # log_join defaults to :info and logs the TOPIC. Our topic is
      # "queue:<account_id>", so every join wrote an account identifier to
      # disk. That is the one thing this architecture is built not to keep.
      #
      # log_handle_in defaults to :debug and logs the event PARAMETERS —
      # for "message:send" that is the sender (topic), the recipient ("to")
      # and the ciphertext. Production runs at :info so those were being
      # dropped, but the protection was a LOG LEVEL, which is one config
      # line away from being gone. The social graph must not depend on
      # somebody remembering not to turn on debug logging.
      #
      # Set here rather than per-channel so a future channel inherits it
      # instead of having to remember.
      use Phoenix.Channel, log_join: false, log_handle_in: false
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
