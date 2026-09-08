defmodule SpojitiRelay.MixProject do
  use Mix.Project

  # Spojiti Private Messenger Core — the relay half.
  # The free text-messaging path of Spojiti, published so the zero-PII
  # architecture and the cryptography can be verified line by line.
  # Licence: GNU AGPL v3 (see LICENSE).
  def project do
    [
      app: :spojiti_relay,
      version: "1.0.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      releases: releases(),
      deps: deps()
    ]
  end

  defp releases do
    [
      spojiti_relay: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  # The blind relay: holds live WebSocket connections, routes ciphertext, and
  # forgets it on delivery. It never sees plaintext or private keys.
  def application do
    [
      mod: {SpojitiRelay.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto, :public_key]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7.14"},
      {:phoenix_ecto, "~> 4.6"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.5"}
    ]
  end

  # `mix test` sets up a fresh test DB and runs migrations first.
  defp aliases do
    [
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
