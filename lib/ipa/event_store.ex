defmodule Ipa.EventStore do
  @moduledoc """
  Generic event store for IPA using SQLite with JSON-serialized events.

  This is a low-level event store that knows nothing about business logic.
  Higher-level components (Task Manager, Pod State Manager) use this for persistence.

  ## Single Stream Per Task Architecture

  IPA uses a single stream per task. All task-related events (task lifecycle,
  workstreams, agents, messages) are stored in one stream with `stream_id = task_id`.

  This simplifies:
  - Event ordering (single version sequence)
  - State replay (one stream to read)
  - Concurrency control (one version to check)

  ## PubSub Integration

  The EventStore broadcasts all event appends to enable real-time UI updates.
  Subscribe to `"events:<stream_id>"` to receive `{:event_appended, stream_id, event}` messages.
  """

  import Ecto.Query
  require Logger
  alias Ipa.Repo
  alias Ipa.EventStore.{Stream, Event, Snapshot}
  alias UUID

  @type event :: %{
          stream_id: String.t(),
          event_type: String.t(),
          data: map(),
          version: integer(),
          actor_id: String.t() | nil,
          causation_id: String.t() | nil,
          correlation_id: String.t() | nil,
          metadata: map() | nil,
          inserted_at: integer()
        }

  @doc """
  Creates a new event stream with auto-generated UUID.

  ## Examples

      {:ok, stream_id} = Ipa.EventStore.start_stream("task")
  """
  @spec start_stream(stream_type :: String.t()) ::
          {:ok, stream_id :: String.t()} | {:error, term()}
  def start_stream(stream_type) do
    stream_id = UUID.uuid4()
    start_stream(stream_type, stream_id)
  end

  @doc """
  Creates a new event stream with a specific stream_id.

  ## Examples

      {:ok, stream_id} = Ipa.EventStore.start_stream("task", "my-task-id")
  """
  @spec start_stream(stream_type :: String.t(), stream_id :: String.t()) ::
          {:ok, stream_id :: String.t()} | {:error, :already_exists | term()}
  def start_stream(stream_type, stream_id) do
    now = System.system_time(:second)

    %Stream{}
    |> Stream.changeset(%{
      id: stream_id,
      stream_type: stream_type,
      created_at: now,
      updated_at: now
    })
    |> Repo.insert()
    |> case do
      {:ok, _stream} ->
        {:ok, stream_id}

      {:error, %Ecto.Changeset{errors: errors}} ->
        case Keyword.get(errors, :id) do
          {_, opts} when is_list(opts) ->
            if Keyword.get(opts, :constraint) == :unique do
              {:error, :already_exists}
            else
              {:error, :invalid_changeset}
            end

          _ ->
            {:error, :invalid_changeset}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Appends an event to a stream.

  ## Options

    * `:expected_version` - For optimistic concurrency control
    * `:actor_id` - Who/what caused this event
    * `:causation_id` - ID of event that caused this event
    * `:correlation_id` - ID for tracing related events
    * `:metadata` - Additional metadata map (will be JSON encoded)

  ## Examples

      {:ok, version} = Ipa.EventStore.append(
        stream_id,
        "task_created",
        %{title: "My Task"},
        actor_id: "system"
      )

      # With optimistic concurrency
      {:ok, version} = Ipa.EventStore.append(
        stream_id,
        "spec_approved",
        %{spec: %{...}},
        expected_version: 5,
        actor_id: user_id
      )
  """
  @spec append(
          stream_id :: String.t(),
          event_type :: String.t(),
          event_data :: map(),
          opts :: keyword()
        ) :: {:ok, version :: integer()} | {:error, term()}
  def append(stream_id, event_type, event_data, opts \\ []) do
    Repo.transaction(fn ->
      # Get current version
      current_version = get_max_version(stream_id) || 0

      # Check expected version if provided
      if expected_version = Keyword.get(opts, :expected_version) do
        if expected_version != current_version do
          Repo.rollback(:version_conflict)
        end
      end

      new_version = current_version + 1

      # Prepare event attributes
      now = System.system_time(:second)

      metadata =
        case Keyword.get(opts, :metadata) do
          nil -> nil
          map -> Jason.encode!(map)
        end

      event_attrs = %{
        stream_id: stream_id,
        event_type: event_type,
        event_data: Jason.encode!(event_data),
        version: new_version,
        actor_id: Keyword.get(opts, :actor_id),
        causation_id: Keyword.get(opts, :causation_id),
        correlation_id: Keyword.get(opts, :correlation_id),
        metadata: metadata,
        inserted_at: now
      }

      # Insert event
      case %Event{} |> Event.changeset(event_attrs) |> Repo.insert() do
        {:ok, inserted_event} ->
          # Update stream timestamp
          update_stream_timestamp(stream_id, now)
          # Return both version and decoded event for broadcasting
          {new_version, decode_event(inserted_event)}

        {:error, %Ecto.Changeset{errors: errors}} ->
          case Keyword.get(errors, :version) do
            {_, opts} when is_list(opts) ->
              if Keyword.get(opts, :constraint) == :unique do
                Repo.rollback(:version_conflict)
              else
                Repo.rollback(:changeset_error)
              end

            _ ->
              Repo.rollback(:changeset_error)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {version, event}} ->
        # Broadcast the event for real-time updates
        broadcast_event_appended(stream_id, event)
        {:ok, version}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Appends multiple events to a stream atomically within a transaction.

  All events succeed or all fail together.

  ## Examples

      {:ok, final_version} = Ipa.EventStore.append_batch(
        stream_id,
        [
          %{
            event_type: "spec_approved",
            data: %{spec: %{...}},
            opts: [actor_id: user_id]
          },
          %{
            event_type: "transition_requested",
            data: %{from: :spec, to: :planning},
            opts: [actor_id: "system"]
          }
        ],
        expected_version: 5,
        correlation_id: request_id
      )
  """
  @spec append_batch(
          stream_id :: String.t(),
          events :: [
            %{
              event_type: String.t(),
              data: map(),
              opts: keyword()
            }
          ],
          opts :: keyword()
        ) :: {:ok, new_version :: integer()} | {:error, term()}
  def append_batch(stream_id, events, opts \\ []) when is_list(events) do
    Repo.transaction(fn ->
      # Get current version
      current_version = get_max_version(stream_id) || 0

      # Check expected version if provided
      if expected_version = Keyword.get(opts, :expected_version) do
        if expected_version != current_version do
          Repo.rollback(:version_conflict)
        end
      end

      now = System.system_time(:second)
      global_correlation_id = Keyword.get(opts, :correlation_id)
      global_actor_id = Keyword.get(opts, :actor_id)

      # Insert each event, collecting decoded events for broadcast
      result =
        Enum.reduce_while(events, {current_version, []}, fn event, {version, inserted_events} ->
          new_version = version + 1
          event_opts = Map.get(event, :opts, [])

          metadata =
            case Keyword.get(event_opts, :metadata) do
              nil -> nil
              map -> Jason.encode!(map)
            end

          event_attrs = %{
            stream_id: stream_id,
            event_type: event.event_type,
            event_data: Jason.encode!(event.data),
            version: new_version,
            actor_id: Keyword.get(event_opts, :actor_id, global_actor_id),
            causation_id: Keyword.get(event_opts, :causation_id),
            correlation_id: Keyword.get(event_opts, :correlation_id, global_correlation_id),
            metadata: metadata,
            inserted_at: now
          }

          case %Event{} |> Event.changeset(event_attrs) |> Repo.insert() do
            {:ok, inserted_event} ->
              {:cont, {new_version, [decode_event(inserted_event) | inserted_events]}}
            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)

      case result do
        {:error, reason} ->
          Repo.rollback(reason)

        {version, inserted_events} when is_integer(version) ->
          update_stream_timestamp(stream_id, now)
          # Return version and events (reversed to maintain order)
          {version, Enum.reverse(inserted_events)}
      end
    end)
    |> case do
      {:ok, {version, inserted_events}} ->
        # Broadcast all events
        Enum.each(inserted_events, &broadcast_event_appended(stream_id, &1))
        {:ok, version}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Reads all events from a stream, ordered by version.

  ## Options

    * `:from_version` - Read from specific version (default: 0)
    * `:max_count` - Maximum number of events to return
    * `:event_types` - Filter by specific event types (list of strings)

  ## Examples

      {:ok, events} = Ipa.EventStore.read_stream(stream_id)
      {:ok, events} = Ipa.EventStore.read_stream(stream_id, from_version: 10)
      {:ok, events} = Ipa.EventStore.read_stream(stream_id, event_types: ["task_created"])
  """
  @spec read_stream(stream_id :: String.t(), opts :: keyword()) ::
          {:ok, [event()]} | {:error, :not_found | term()}
  def read_stream(stream_id, opts \\ []) do
    from_version = Keyword.get(opts, :from_version, 0)
    max_count = Keyword.get(opts, :max_count)
    event_types = Keyword.get(opts, :event_types)

    query =
      from e in Event,
        where: e.stream_id == ^stream_id and e.version > ^from_version,
        order_by: [asc: e.version]

    query =
      if event_types do
        from e in query, where: e.event_type in ^event_types
      else
        query
      end

    query =
      if max_count do
        from e in query, limit: ^max_count
      else
        query
      end

    # Let DB errors crash - they indicate real problems (connection issues, etc.)
    # Let decode errors crash - they indicate data corruption or schema bugs
    events =
      query
      |> Repo.all()
      |> Enum.map(&decode_event/1)

    {:ok, events}
  end

  @doc """
  Gets the current version of a stream (highest event version).

  ## Examples

      {:ok, version} = Ipa.EventStore.stream_version(stream_id)
  """
  @spec stream_version(stream_id :: String.t()) ::
          {:ok, version :: integer()} | {:error, :not_found}
  def stream_version(stream_id) do
    case get_max_version(stream_id) do
      nil -> {:error, :not_found}
      version -> {:ok, version}
    end
  end

  @doc """
  Checks if a stream exists.

  ## Examples

      if Ipa.EventStore.stream_exists?(stream_id) do
        # Stream exists
      end
  """
  @spec stream_exists?(stream_id :: String.t()) :: boolean()
  def stream_exists?(stream_id) do
    query = from s in Stream, where: s.id == ^stream_id, select: count(s.id)

    case Repo.one(query) do
      1 -> true
      _ -> false
    end
  end

  @doc """
  Saves a state snapshot at a specific version.

  ## Examples

      :ok = Ipa.EventStore.save_snapshot(stream_id, %{phase: :executing}, 42)
  """
  @spec save_snapshot(
          stream_id :: String.t(),
          state :: map(),
          version :: integer()
        ) :: :ok | {:error, term()}
  def save_snapshot(stream_id, state, version) do
    now = System.system_time(:second)

    %Snapshot{}
    |> Snapshot.changeset(%{
      stream_id: stream_id,
      snapshot_data: Jason.encode!(state),
      version: version,
      created_at: now
    })
    |> Repo.insert(on_conflict: :replace_all, conflict_target: :stream_id)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Loads the most recent snapshot for a stream.

  ## Examples

      {:ok, %{state: state, version: 42}} = Ipa.EventStore.load_snapshot(stream_id)
  """
  @spec load_snapshot(stream_id :: String.t()) ::
          {:ok, %{state: map(), version: integer()}} | {:error, :not_found}
  def load_snapshot(stream_id) do
    case Repo.get(Snapshot, stream_id) do
      nil ->
        {:error, :not_found}

      snapshot ->
        {:ok,
         %{
           state: Jason.decode!(snapshot.snapshot_data, keys: :atoms),
           version: snapshot.version
         }}
    end
  end

  @doc """
  Deletes a stream and all its events/snapshots (CASCADE).

  ## Examples

      :ok = Ipa.EventStore.delete_stream(stream_id)
  """
  @spec delete_stream(stream_id :: String.t()) :: :ok | {:error, term()}
  def delete_stream(stream_id) do
    case Repo.get(Stream, stream_id) do
      nil ->
        {:error, :not_found}

      stream ->
        case Repo.delete(stream) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Lists all streams, optionally filtered by type.

  ## Examples

      {:ok, task_streams} = Ipa.EventStore.list_streams("task")
      {:ok, all_streams} = Ipa.EventStore.list_streams(nil)
  """
  @spec list_streams(stream_type :: String.t() | nil) :: {:ok, [map()]}
  def list_streams(stream_type \\ nil) do
    query =
      if stream_type do
        from s in Stream, where: s.stream_type == ^stream_type
      else
        from(s in Stream)
      end

    streams =
      query
      |> Repo.all()
      |> Enum.map(fn stream ->
        %{
          id: stream.id,
          stream_type: stream.stream_type,
          created_at: stream.created_at,
          updated_at: stream.updated_at
        }
      end)

    {:ok, streams}
  end

  # Private helper functions

  defp get_max_version(stream_id) do
    query =
      from e in Event,
        where: e.stream_id == ^stream_id,
        select: max(e.version)

    Repo.one(query)
  end

  defp update_stream_timestamp(stream_id, timestamp) do
    from(s in Stream, where: s.id == ^stream_id)
    |> Repo.update_all(set: [updated_at: timestamp])
  end

  defp decode_event(event) do
    %{
      stream_id: event.stream_id,
      event_type: event.event_type,
      data: Jason.decode!(event.event_data, keys: :atoms),
      version: event.version,
      actor_id: event.actor_id,
      causation_id: event.causation_id,
      correlation_id: event.correlation_id,
      metadata: if(event.metadata, do: Jason.decode!(event.metadata, keys: :atoms), else: nil),
      inserted_at: event.inserted_at
    }
  end

  # ============================================================================
  # PubSub Integration
  # ============================================================================

  @doc """
  Subscribes the calling process to event notifications for a stream.

  Messages received: `{:event_appended, stream_id, event}`

  ## Examples

      Ipa.EventStore.subscribe(stream_id)
      # Process will now receive {:event_appended, stream_id, event} messages
  """
  @spec subscribe(stream_id :: String.t()) :: :ok
  def subscribe(stream_id) do
    Phoenix.PubSub.subscribe(Ipa.PubSub, "events:#{stream_id}")
  end

  @doc """
  Unsubscribes the calling process from event notifications for a stream.
  """
  @spec unsubscribe(stream_id :: String.t()) :: :ok
  def unsubscribe(stream_id) do
    Phoenix.PubSub.unsubscribe(Ipa.PubSub, "events:#{stream_id}")
  end

  defp broadcast_event_appended(stream_id, event) do
    case Phoenix.PubSub.broadcast(
           Ipa.PubSub,
           "events:#{stream_id}",
           {:event_appended, stream_id, event}
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to broadcast event_appended for stream #{stream_id}: #{inspect(reason)}"
        )

        :ok
    end
  end
end
