defmodule SpojitiRelay.Release do
  @moduledoc """
  Release tasks callable from a built release without Mix installed, e.g.:

      bin/spojiti_relay eval "SpojitiRelay.Release.migrate"

  Used by the Fly.io release_command and the Docker start script to run
  database migrations before the app boots.
  """
  @app :spojiti_relay

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.load(@app)
  end
end
