defmodule SpojitiRelay.Repo.Migrations.AccountsSynthetic do
  use Ecto.Migration

  # The shared account schema (lib/spojiti_relay/accounts/account.ex, the
  # product's file byte for byte) gained `synthetic` in the product on
  # 2026-10-06: a load-test account, kept out of the counts. The Core never
  # sets it (a request body cannot: it is not in the changeset's cast); the
  # column is here so the shared file reads and writes the same rows.
  def change do
    alter table(:accounts) do
      add :synthetic, :boolean, null: false, default: false
    end
  end
end
