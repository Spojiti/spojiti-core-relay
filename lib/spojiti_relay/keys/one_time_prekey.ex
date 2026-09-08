defmodule SpojitiRelay.Keys.OneTimePrekey do
  @moduledoc "A single-use prekey. Handed out once, then deleted."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Jason.Encoder, only: [:key_id, :public_key]}
  schema "one_time_prekeys" do
    field :key_id, :integer
    field :public_key, :string
    belongs_to :account, SpojitiRelay.Accounts.Account

    timestamps(type: :utc_datetime)
  end

  def changeset(otp, attrs) do
    otp
    |> cast(attrs, [:key_id, :public_key, :account_id])
    |> validate_required([:key_id, :public_key, :account_id])
  end
end
