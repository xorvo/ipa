defmodule Ipa.Repo.Migrations.CreateEventStoreTables do
  use Ecto.Migration

  def change do
    # Streams table - a stream is a sequence of related events
    create table(:streams, primary_key: false) do
      add :id, :text, primary_key: true
      add :stream_type, :text, null: false
      add :created_at, :integer, null: false
      add :updated_at, :integer, null: false
    end

    create index(:streams, [:stream_type])
    create index(:streams, [:updated_at])

    # Events table - individual events within a stream
    create table(:events) do
      add :stream_id, references(:streams, column: :id, type: :text, on_delete: :delete_all),
        null: false

      add :event_type, :text, null: false
      add :event_data, :text, null: false
      add :version, :integer, null: false
      add :actor_id, :text
      add :causation_id, :text
      add :correlation_id, :text
      add :metadata, :text
      add :inserted_at, :integer, null: false
    end

    create index(:events, [:stream_id])
    create unique_index(:events, [:stream_id, :version])
    create index(:events, [:event_type])
    create index(:events, [:correlation_id])
    create index(:events, [:actor_id])

    # Snapshots table - optional snapshots for performance optimization
    create table(:snapshots, primary_key: false) do
      add :stream_id, references(:streams, column: :id, type: :text, on_delete: :delete_all),
        primary_key: true

      add :snapshot_data, :text, null: false
      add :version, :integer, null: false
      add :created_at, :integer, null: false
    end
  end
end
