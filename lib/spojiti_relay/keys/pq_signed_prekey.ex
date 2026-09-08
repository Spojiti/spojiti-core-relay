defmodule SpojitiRelay.Keys.PqSignedPrekey do
  @moduledoc """
  #60 · the account's ML-KEM-768 signed prekey (public part + Ed25519
  signature over it, made with the SAME signing key that signs the classical
  prekey).

  The relay's role is unchanged and deliberately dumb: store an opaque public
  blob, hand it back in the bundle, never interpret it. Signature verification
  happens on the CLIENT — a lying relay is caught by the same safety-number
  model that already covers identity_key and signed_prekey, and PQ inherits
  that property rather than needing a new one.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Jason.Encoder, only: [:key_id, :alg, :public_key, :signature, :pq_signature]}
  schema "pq_signed_prekeys" do
    field :key_id, :integer
    # #378 · "ml-kem-1024" from PQ-2 on (key_id 2); nil = the PQ-1 ML-KEM-768
    # key (key_id 1). The client decides by key_id AND length; this is a label.
    field :alg, :string
    field :public_key, :string
    field :signature, :string
    # ML-DSA-65 signature over PREFIX ‖ ek, beside the Ed25519 one.
    field :pq_signature, :string
    belongs_to :account, SpojitiRelay.Accounts.Account

    timestamps(type: :utc_datetime)
  end

  def changeset(spk, attrs) do
    spk
    |> cast(attrs, [:key_id, :alg, :public_key, :signature, :pq_signature, :account_id])
    |> validate_required([:key_id, :public_key, :signature, :account_id])
    # ML-KEM-768 ek is 1184 bytes ⇒ 1580 base64 chars; ML-KEM-1024 is 1568 ⇒
    # 2092. Bound it generously but finitely: the relay should never become a
    # place to park arbitrary data.
    |> validate_length(:public_key, min: 1000, max: 4096)
    |> validate_length(:signature, min: 16, max: 512)
    |> validate_length(:alg, max: 32)
    |> validate_length(:pq_signature, min: 4000, max: 8192)
    |> unique_constraint(:account_id)
  end
end
