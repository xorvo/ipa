defmodule Ipa.EventStore.Event do
  use Ecto.Schema
  import Ecto.Changeset

  schema "events" do
    field :stream_id, :string
    field :event_type, :string
    field :event_data, :string
    field :version, :integer
    field :actor_id, :string
    field :causation_id, :string
    field :correlation_id, :string
    field :metadata, :string
    field :inserted_at, :integer
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :stream_id,
      :event_type,
      :event_data,
      :version,
      :actor_id,
      :causation_id,
      :correlation_id,
      :metadata,
      :inserted_at
    ])
    |> validate_required([:stream_id, :event_type, :event_data, :version, :inserted_at])
    |> unique_constraint([:stream_id, :version],
      name: :events_stream_id_version_index
    )
  end
end
