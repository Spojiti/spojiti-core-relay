defmodule SpojitiRelay.Accounts.Account do
  @moduledoc "An anonymous account — identified by its public identity key. No PII."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Jason.Encoder, only: [:id, :registration_id, :inserted_at]}
  schema "accounts" do
    # Base64 of the client's long-term Curve25519 public identity key.
    field :identity_key, :string
    # Base64 of the client's Ed25519 public *signing* key — used to verify the
    # challenge signature during device-restore login. No PII.
    field :signing_key, :string
    # #378 · Base64 of the client's ML-DSA-65 public signing key — the
    # post-quantum half of its authentication. Nil for every account that
    # predates PQ-2; the bundle then omits it and peers verify classically.
    field :pq_signing_key, :string
    # #381 · what this account's clients can receive ("sealed" ⇒ b316+ opens
    # sealed-sender envelopes). Published by the client, read by peers.
    field :caps, {:array, :string}, default: []
    # Signal registration id (per device).
    field :registration_id, :integer
    # Stamped when the account's last socket disconnects (for "last seen").
    field :last_seen_at, :utc_datetime
    # 2026-10-06 · C5 · a load-test account (load-rail.py, the cross-cell
    # proof). Set by Accounts.register/2's `synthetic: true` option, which
    # RegistrationController passes only for a request carrying this cell's
    # LOADTEST_KEY. DELIBERATELY NOT IN cast/3 BELOW: a request body that
    # says "synthetic" must never be able to hide an account from the counts.
    field :synthetic, :boolean, default: false

    has_one :signed_prekey, SpojitiRelay.Keys.SignedPrekey
    # #60 · PQXDH. Absent for every account registered before post-quantum —
    # its absence IS the signal that a peer is classical-only.
    has_one :pq_signed_prekey, SpojitiRelay.Keys.PqSignedPrekey
    has_many :one_time_prekeys, SpojitiRelay.Keys.OneTimePrekey

    timestamps(type: :utc_datetime)
  end

  def changeset(account, attrs) do
    account
    |> cast(attrs, [:identity_key, :signing_key, :registration_id, :pq_signing_key, :caps])
    |> validate_required([:identity_key, :registration_id])
    |> validate_length(:identity_key, min: 8, max: 512)
    |> validate_length(:signing_key, min: 8, max: 512)
    # ML-DSA-65 pk is 1952 bytes ⇒ 2604 base64 chars. Bounded, never parsed.
    |> validate_length(:pq_signing_key, min: 2000, max: 4096)
    |> unique_constraint(:identity_key)
  end
end
