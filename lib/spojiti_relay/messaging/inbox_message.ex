defmodule SpojitiRelay.Messaging.InboxMessage do
  @moduledoc """
  A stored-and-forwarded envelope. `ciphertext` is opaque to the server — it is
  the Signal-encrypted payload. Deleted as soon as the recipient acks delivery.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Jason.Encoder, only: [:id, :sender_account_id, :message_type, :ciphertext, :inserted_at]}
  schema "inbox_messages" do
    field :recipient_account_id, :binary_id
    field :sender_account_id, :binary_id
    field :message_type, :string, default: "signal"
    field :ciphertext, :string
    # Tiered retention (#154). Set ONCE at enqueue from the sender's verified
    # tier and never recomputed — a later downgrade must not retroactively
    # shorten a window the message was already accepted under. Deliberately NOT
    # in the cast list: it is set on the struct, so no client payload can ever
    # talk its own envelope into living longer.
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(msg, attrs) do
    msg
    |> cast(attrs, [:recipient_account_id, :sender_account_id, :message_type, :ciphertext])
    |> validate_required([:recipient_account_id, :ciphertext])
    |> validate_length(:ciphertext, max: 262_144)
  end
end
