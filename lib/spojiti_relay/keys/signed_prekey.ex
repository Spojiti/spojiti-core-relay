defmodule SpojitiRelay.Keys.SignedPrekey do
  @moduledoc "The account's current signed prekey (public part + signature)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Jason.Encoder, only: [:key_id, :public_key, :signature, :pq_signature]}
  schema "signed_prekeys" do
    field :key_id, :integer
    field :public_key, :string
    field :signature, :string
    # #378 · ML-DSA-65 signature over the same public key (3309 B → 4412 b64).
    # Nil ⇒ the account authenticates classically only.
    field :pq_signature, :string
    belongs_to :account, SpojitiRelay.Accounts.Account

    timestamps(type: :utc_datetime)
  end

  def changeset(spk, attrs) do
    spk
    |> cast(attrs, [:key_id, :public_key, :signature, :pq_signature, :account_id])
    |> validate_required([:key_id, :public_key, :signature, :account_id])
    |> validate_length(:pq_signature, min: 4000, max: 8192)
  end
end
