defmodule SpojitiRelay.Repo.Migrations.CreateCore do
  use Ecto.Migration

  # The whole durable set of the Core, and it is small on purpose: public
  # keys, one prekey directory per account, and envelopes that exist only
  # until they are collected. No name, number, e-mail, contact list, device
  # list or sender is stored anywhere in it.
  def change do
    create table(:accounts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :identity_key, :string, null: false
      add :signing_key, :string
      add :pq_signing_key, :text
      add :registration_id, :integer, null: false
      add :caps, {:array, :string}, default: [], null: false
      add :last_seen_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:accounts, [:identity_key])

    create table(:signed_prekeys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all), null: false
      add :key_id, :integer, null: false
      add :public_key, :string, null: false
      add :signature, :string, null: false
      add :pq_signature, :text
      timestamps(type: :utc_datetime)
    end

    create unique_index(:signed_prekeys, [:account_id])

    create table(:one_time_prekeys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all), null: false
      add :key_id, :integer, null: false
      add :public_key, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:one_time_prekeys, [:account_id])
    create unique_index(:one_time_prekeys, [:account_id, :key_id])

    create table(:pq_signed_prekeys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all), null: false
      add :key_id, :integer, null: false
      add :alg, :string
      add :public_key, :text, null: false
      add :signature, :text, null: false
      add :pq_signature, :text
      timestamps(type: :utc_datetime)
    end

    create unique_index(:pq_signed_prekeys, [:account_id])

    create table(:inbox_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :recipient_account_id, :binary_id, null: false
      add :sender_account_id, :binary_id
      add :message_type, :string, null: false, default: "signal"
      add :ciphertext, :text, null: false
      add :expires_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:inbox_messages, [:recipient_account_id, :inserted_at])
    create index(:inbox_messages, [:expires_at])
  end
end
