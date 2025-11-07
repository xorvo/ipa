defmodule Ipa.EventStore.Snapshot do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:stream_id, :string, autogenerate: false}
  schema "snapshots" do
    field :snapshot_data, :string
    field :version, :integer
    field :created_at, :integer
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:stream_id, :snapshot_data, :version, :created_at])
    |> validate_required([:stream_id, :snapshot_data, :version, :created_at])
    |> unique_constraint(:stream_id, name: :snapshots_pkey)
  end
end
