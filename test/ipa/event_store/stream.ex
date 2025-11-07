defmodule Ipa.EventStore.Stream do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "streams" do
    field :stream_type, :string
    field :created_at, :integer
    field :updated_at, :integer
  end

  def changeset(stream, attrs) do
    stream
    |> cast(attrs, [:id, :stream_type, :created_at, :updated_at])
    |> validate_required([:id, :stream_type, :created_at, :updated_at])
    |> unique_constraint(:id, name: "streams_pkey")
  end
end
