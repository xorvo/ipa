# Component Spec: 1.1 SQLite Event Store

## Overview

The SQLite Event Store is the **lowest-level persistence layer** for IPA. It provides generic event sourcing capabilities using SQLite with JSON-serialized events. This is a pure event store - it knows nothing about tasks, agents, or business logic.

Higher-level components (like Task Manager, Pod State Manager) will use this event store and add business logic on top.

## Purpose

- Provide durable, append-only event storage for any aggregate
- Enable event replay for state reconstruction
- Support optimistic concurrency control
- Offer snapshot capabilities for performance optimization
- Serve as foundation for all event-sourced components

## Separation of Concerns

```
Layer 3: Business Logic (Task Management, Agent Management)
           ↓ uses
Layer 2: Domain Events (Task events, Agent events)
           ↓ uses
Layer 1: Event Store (Generic append/load) ← THIS COMPONENT
```

**This component** provides generic event storage. It doesn't know about:
- Tasks
- Agents
- Business rules
- State machines

**Other components** will use this to:
- Store task lifecycle events
- Store agent execution events
- Build state projections
- Implement business logic

## Dependencies

- **External**: SQLite, Ecto, ecto_sqlite3, Jason
- **Internal**: None (foundation layer)

## Module Structure

```
lib/ipa/event_store.ex          # Main API module (low-level)
lib/ipa/event_store/repo.ex     # Ecto repository
lib/ipa/event_store/schemas/
  ├── stream.ex                 # Event stream (was "task")
  ├── event.ex                  # Individual events
  └── snapshot.ex               # Snapshots
```

## Database Schema

### Streams Table
A **stream** is a sequence of related events (e.g., all events for a task, or all events for an agent).

```sql
CREATE TABLE streams (
  id TEXT PRIMARY KEY,              -- UUID as text (stream_id)
  stream_type TEXT NOT NULL,        -- Type: "task", "agent", etc.
  created_at INTEGER NOT NULL,      -- Unix timestamp
  updated_at INTEGER NOT NULL       -- Updated on each event append
);

CREATE INDEX idx_streams_type ON streams(stream_type);
CREATE INDEX idx_streams_updated ON streams(updated_at);
```

### Events Table
```sql
CREATE TABLE events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  stream_id TEXT NOT NULL,
  event_type TEXT NOT NULL,         -- Atom as string (e.g., "task_created")
  event_data TEXT NOT NULL,         -- JSON string
  version INTEGER NOT NULL,         -- Incremental per stream
  actor_id TEXT,                    -- Who caused this event (user_id, agent_id, "system")
  causation_id TEXT,                -- Event that caused this event
  correlation_id TEXT,              -- For tracing related events
  metadata TEXT,                    -- JSON string (additional context)
  inserted_at INTEGER NOT NULL,     -- Unix timestamp
  FOREIGN KEY (stream_id) REFERENCES streams(id) ON DELETE CASCADE,
  UNIQUE (stream_id, version)       -- Ensures version uniqueness per stream
);

CREATE INDEX idx_events_stream_id ON events(stream_id);
CREATE INDEX idx_events_version ON events(stream_id, version);
CREATE INDEX idx_events_type ON events(event_type);
CREATE INDEX idx_events_correlation ON events(correlation_id);
CREATE INDEX idx_events_actor ON events(actor_id);
```

### Snapshots Table (Optional)
```sql
CREATE TABLE snapshots (
  stream_id TEXT PRIMARY KEY,
  snapshot_data TEXT NOT NULL,      -- JSON string of full state
  version INTEGER NOT NULL,         -- Event version at snapshot time
  created_at INTEGER NOT NULL,      -- Unix timestamp
  FOREIGN KEY (stream_id) REFERENCES streams(id) ON DELETE CASCADE
);
```

## Public API

### Module: `Ipa.EventStore`

This is a **low-level, generic API**. It has no concept of tasks, agents, or business logic.

#### `start_stream/1` or `start_stream/2`
```elixir
@spec start_stream(stream_type :: String.t()) ::
  {:ok, stream_id :: String.t()} | {:error, term()}

@spec start_stream(stream_type :: String.t(), stream_id :: String.t()) ::
  {:ok, stream_id :: String.t()} | {:error, :already_exists | term()}
```
Creates a new event stream. Call this before appending events to a new stream.

**Arity 1**: Auto-generates a UUID for the stream_id (recommended for most cases).

**Arity 2**: Uses the provided stream_id (useful for idempotency or when you need a specific ID).

**Examples**:
```elixir
# Auto-generate stream ID (recommended)
{:ok, stream_id} = Ipa.EventStore.start_stream("task")

# Use specific stream ID (for idempotency)
{:ok, stream_id} = Ipa.EventStore.start_stream("task", "custom-uuid-123")
```

#### `append/4`
```elixir
@spec append(
  stream_id :: String.t(),
  event_type :: String.t(),
  event_data :: map(),
  opts :: keyword()
) :: {:ok, version :: integer()} | {:error, :version_conflict | :stream_not_found | term()}
```
Appends an event to a stream.

**Options**:
- `:expected_version` - For optimistic concurrency (optional, but recommended for critical operations)
- `:actor_id` - Who/what caused this event (user_id, agent_id, "system")
- `:causation_id` - ID of event that caused this event (for event causality chains)
- `:correlation_id` - ID for tracing related events across streams
- `:metadata` - Additional metadata map (custom context, will be merged with system metadata)

**Note**: System metadata (timestamp, etc.) is automatically added. The `:metadata` option is for additional application-specific context.

**Examples**:
```elixir
# Simple append
{:ok, version} = Ipa.EventStore.append(
  stream_id,
  "spec_approved",
  %{approved_by: user_id, spec: %{...}},
  actor_id: user_id
)

# With optimistic concurrency control
{:ok, version} = Ipa.EventStore.append(
  stream_id,
  "spec_approved",
  %{approved_by: user_id, spec: %{...}},
  expected_version: 5,
  actor_id: user_id,
  correlation_id: request_id
)

# With full tracing
{:ok, version} = Ipa.EventStore.append(
  stream_id,
  "agent_completed",
  %{agent_id: agent_id, result: %{...}},
  actor_id: "system",
  causation_id: triggering_event_id,
  correlation_id: trace_id,
  metadata: %{execution_time_ms: 1234}
)
```

#### `append_batch/3`
```elixir
@spec append_batch(
  stream_id :: String.t(),
  events :: [%{event_type: String.t(), data: map(), opts: keyword()}],
  opts :: keyword()
) :: {:ok, new_version :: integer()} | {:error, :version_conflict | :stream_not_found | term()}
```
Appends multiple events to a stream atomically within a transaction. All events succeed or all fail together.

**Event Spec** (each map in the list):
- `event_type` - Event type string
- `data` - Event data map
- `opts` - Per-event options (actor_id, causation_id, correlation_id, metadata)

**Global Options** (apply to all events if not specified per-event):
- `:expected_version` - For optimistic concurrency
- `:actor_id` - Default actor for all events
- `:correlation_id` - Default correlation ID for all events

**Returns**: The final version after all events are appended.

**Use Case**: Atomic state transitions that produce multiple events.

**Example**:
```elixir
# Atomic multi-event append
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
      data: %{from_phase: :spec_clarification, to_phase: :planning},
      opts: [actor_id: "system", causation_id: previous_event_id]
    }
  ],
  expected_version: 5,
  correlation_id: request_id
)
```

#### `read_stream/2`
```elixir
@spec read_stream(stream_id :: String.t(), opts :: keyword()) ::
  {:ok, [event()]} | {:error, :not_found | term()}
```
Reads all events from a stream, ordered by version.

**Options**:
- `:from_version` - Read from specific version (default: 0)
- `:max_count` - Maximum number of events to return
- `:event_types` - Filter by specific event types (list of strings)

**Returns**: List of event maps with keys:
- `event_type` (string)
- `data` (map) - Deserialized from JSON
- `version` (integer)
- `actor_id` (string or nil)
- `causation_id` (string or nil)
- `correlation_id` (string or nil)
- `metadata` (map) - Deserialized from JSON
- `inserted_at` (integer timestamp)

**Examples**:
```elixir
# Read all events
{:ok, events} = Ipa.EventStore.read_stream(stream_id)

# Read from specific version (useful with snapshots)
{:ok, events} = Ipa.EventStore.read_stream(stream_id, from_version: 10)

# Read only specific event types
{:ok, agent_events} = Ipa.EventStore.read_stream(
  stream_id,
  event_types: ["agent_started", "agent_completed"]
)

# Paginate events
{:ok, events} = Ipa.EventStore.read_stream(
  stream_id,
  from_version: 100,
  max_count: 50
)
```

#### `stream_version/1`
```elixir
@spec stream_version(stream_id :: String.t()) ::
  {:ok, version :: integer()} | {:error, :not_found}
```
Gets the current version of a stream (highest event version).

**Example**:
```elixir
{:ok, version} = Ipa.EventStore.stream_version(stream_id)  # => {:ok, 42}
```

#### `stream_exists?/1`
```elixir
@spec stream_exists?(stream_id :: String.t()) :: boolean()
```
Checks if a stream exists. Convenience function for components that need to verify stream existence before operations.

**Implementation**: Lightweight query that checks if stream_id exists in streams table.

```elixir
def stream_exists?(stream_id) do
  case Repo.one(from s in Stream, where: s.id == ^stream_id, select: count(s.id)) do
    1 -> true
    0 -> false
  end
end
```

**Example**:
```elixir
if Ipa.EventStore.stream_exists?(stream_id) do
  # Stream exists, safe to proceed
else
  {:error, :stream_not_found}
end
```

**Use Cases**:
- Pod Supervisor verifies stream before starting pod
- Central Manager checks task existence
- Validation before operations

#### `save_snapshot/3`
```elixir
@spec save_snapshot(
  stream_id :: String.t(),
  state :: map(),
  version :: integer()
) :: :ok | {:error, term()}
```
Saves a state snapshot at a specific version.

#### `load_snapshot/1`
```elixir
@spec load_snapshot(stream_id :: String.t()) ::
  {:ok, %{state: map(), version: integer()}} | {:error, :not_found}
```
Loads the most recent snapshot for a stream.

#### `delete_stream/1`
```elixir
@spec delete_stream(stream_id :: String.t()) :: :ok | {:error, term()}
```
Deletes a stream and all its events/snapshots (CASCADE).

#### `list_streams/1`
```elixir
@spec list_streams(stream_type :: String.t() | nil) :: {:ok, [stream_info()]}
```
Lists all streams, optionally filtered by type.

**Example**:
```elixir
{:ok, task_streams} = Ipa.EventStore.list_streams("task")
{:ok, all_streams} = Ipa.EventStore.list_streams(nil)
```

## Usage Example (Higher-Level Component)

Here's how a **Task Manager** component would use this low-level event store:

```elixir
defmodule Ipa.TaskManager do
  alias Ipa.EventStore

  # Business logic: Create a task
  def create_task(title) do
    task_id = UUID.uuid4()

    # Start event stream
    :ok = EventStore.start_stream("task", task_id)

    # Append business event
    {:ok, _version} = EventStore.append(
      task_id,
      "task_created",  # Business event type
      %{title: title},  # Business data
      metadata: %{actor_id: "system"}
    )

    {:ok, task_id}
  end

  # Business logic: Approve spec
  def approve_spec(task_id, spec, user_id) do
    # Load current state to validate business rules
    {:ok, state} = get_task_state(task_id)

    # Business rule check
    if state.phase != :spec_clarification do
      {:error, :invalid_phase}
    else
      # Append business event
      EventStore.append(
        task_id,
        "spec_approved",
        %{spec: spec, approved_by: user_id},
        metadata: %{actor_id: user_id}
      )
    end
  end

  # Business logic: Build state from events
  defp get_task_state(task_id) do
    {:ok, events} = EventStore.read_stream(task_id)

    # Fold over events to build state (event sourcing pattern)
    state = Enum.reduce(events, initial_state(), &apply_event/2)
    {:ok, state}
  end

  defp apply_event(%{event_type: "task_created", data: data}, state) do
    %{state | title: data.title, phase: :spec_clarification}
  end

  defp apply_event(%{event_type: "spec_approved", data: data}, state) do
    %{state | spec: data.spec, phase: :planning}
  end

  # ... more event handlers
end
```

## Implementation Details

### Optimistic Concurrency Control

The `UNIQUE (stream_id, version)` constraint ensures that concurrent writes are detected atomically at the database level.

**Implementation Strategy**: Rely on database constraint enforcement within a transaction to prevent race conditions.

```elixir
def append(stream_id, event_type, event_data, opts) do
  expected_version = Keyword.get(opts, :expected_version)

  # Wrap in transaction to ensure atomicity
  Repo.transaction(fn ->
    # Get current max version inside transaction
    current_version = get_max_version_for_update(stream_id) || 0

    # Check expected version if provided (application-level validation)
    if expected_version && expected_version != current_version do
      Repo.rollback(:version_conflict)
    end

    new_version = current_version + 1

    # Insert event - UNIQUE constraint is the final safety net
    case insert_event(stream_id, event_type, event_data, new_version, opts) do
      {:ok, _event} ->
        # Update stream's updated_at timestamp
        update_stream_timestamp(stream_id)
        new_version
      {:error, %Ecto.Changeset{errors: [version: {_, [constraint: :unique, _]}]}} ->
        Repo.rollback(:version_conflict)
      {:error, reason} ->
        Repo.rollback(reason)
    end
  end)
  |> case do
    {:ok, version} -> {:ok, version}
    {:error, reason} -> {:error, reason}
  end
end
```

**Key Points**:
1. **Transaction Boundary**: All operations (read version, check, insert) happen within a single transaction
2. **Database Lock**: `get_max_version_for_update/1` uses `SELECT ... FOR UPDATE` to lock the stream row
3. **Double Defense**: Application-level check (fast fail) + database UNIQUE constraint (final enforcement)
4. **Atomic Update**: Stream's `updated_at` timestamp is updated in the same transaction

**Alternative Simpler Implementation** (rely solely on database constraint):
```elixir
def append(stream_id, event_type, event_data, opts) do
  Repo.transaction(fn ->
    current_version = get_max_version(stream_id) || 0
    new_version = current_version + 1

    # Let database enforce uniqueness - simpler and equally safe
    case insert_event(stream_id, event_type, event_data, new_version, opts) do
      {:ok, _event} ->
        update_stream_timestamp(stream_id)
        new_version
      {:error, %Ecto.Changeset{errors: [version: {_, [constraint: :unique, _]}]}} ->
        Repo.rollback(:version_conflict)
      {:error, reason} ->
        Repo.rollback(reason)
    end
  end)
  |> case do
    {:ok, version} -> {:ok, version}
    {:error, reason} -> {:error, reason}
  end
end
```

This simpler version relies entirely on the database UNIQUE constraint, which is atomic and reliable. The `expected_version` check can be omitted since the database will naturally detect conflicts.

### Event Versioning & Schema Evolution

As your application evolves, event schemas will need to change. This section provides strategies for handling event schema evolution.

**Problem**: What happens when an event structure changes?

```elixir
# V1 (original schema)
:agent_started -> %{agent_id: uuid, workspace: string}

# V2 (added agent_type field)
:agent_started -> %{agent_id: uuid, agent_type: string, workspace: string}
```

Events persisted with the V1 schema still exist in the database. Event replay must handle both versions.

**Solution Strategy**: Use metadata for schema versioning

```elixir
# When appending events, include schema version in metadata
Ipa.EventStore.append(
  stream_id,
  "agent_started",
  %{agent_id: uuid, agent_type: "planner", workspace: workspace},
  actor_id: "system",
  metadata: %{schema_version: 2}
)
```

**In Layer 2 (Domain Events), handle multiple versions:**

```elixir
defmodule Ipa.Pod.State do
  # V1 handler (backward compatibility)
  defp apply_event(%{
    event_type: "agent_started",
    data: %{agent_id: id, workspace: ws},
    metadata: %{schema_version: 1}
  }, state) do
    # Transform V1 to V2 structure (upcasting)
    agent = %{
      agent_id: id,
      agent_type: "legacy",  # Default for V1 events
      workspace: ws
    }
    update_in(state.agents, &[agent | &1])
  end

  # V2 handler (current schema)
  defp apply_event(%{
    event_type: "agent_started",
    data: data,
    metadata: metadata
  }, state) when metadata.schema_version >= 2 do
    update_in(state.agents, &[data | &1])
  end

  # No schema_version (very old events - assume V1)
  defp apply_event(%{
    event_type: "agent_started",
    data: data,
    metadata: metadata
  }, state) when not is_map_key(metadata, :schema_version) do
    apply_event(%{
      event_type: "agent_started",
      data: data,
      metadata: Map.put(metadata, :schema_version, 1)
    }, state)
  end
end
```

**Best Practices**:
1. **Always version events** - Include `schema_version` in metadata from day one
2. **Never modify existing events** - Events are immutable
3. **Upcasting in application** - Transform old events to new schema during replay
4. **Keep handlers for old versions** - Don't delete V1 handlers until all V1 events are archived
5. **Document schema changes** - Maintain changelog of event schema versions

**Alternative Approaches**:
- **Event Type Versioning**: Use `:agent_started_v1`, `:agent_started_v2` (verbose, pollutes event types)
- **Schema Version Column**: Add `schema_version` column to events table (less flexible)
- **Migration Events**: Emit "schema migration" events when upgrading (complex)

**Recommended**: Use metadata with `schema_version` field (most flexible, least intrusive).

### Standard Metadata Fields

The Event Store supports arbitrary metadata, but the following standard fields are recommended for consistency across the application.

**Standard Metadata Schema**:
```elixir
%{
  # Application metadata (all optional)
  schema_version: integer,        # Event schema version (e.g., 1, 2, 3)
  trace_id: string,               # Distributed tracing ID (same as correlation_id at store level)
  request_id: string,             # HTTP request ID or operation ID
  ip_address: string,             # Client IP address (for audit trail)
  user_agent: string,             # Client user agent (for audit trail)

  # System metadata (automatically added by Event Store)
  inserted_at: integer,           # Unix timestamp when event was persisted

  # Custom application metadata
  # ... any additional fields your application needs
}
```

**Usage Example**:
```elixir
Ipa.EventStore.append(
  stream_id,
  "spec_approved",
  %{spec: %{...}, approved_by: user_id},
  actor_id: user_id,
  correlation_id: request_id,
  metadata: %{
    schema_version: 1,
    request_id: request_id,
    ip_address: "192.168.1.1",
    user_agent: "Mozilla/5.0...",
    approval_method: "web_ui"  # Custom field
  }
)
```

**Notes**:
- System metadata (`inserted_at`, etc.) is added automatically by the Event Store
- Application metadata is provided via the `:metadata` option
- The two are merged, with system metadata taking precedence
- Standard fields are optional but recommended for consistency
- Add custom fields as needed for your specific use cases

### Stream Ownership & Isolation

The Event Store is a **shared** database. Multiple pods can technically read/write to any stream. This section clarifies the ownership model.

**Design Philosophy**: Streams have logical owners, but enforcement is application-level, not database-level.

**Ownership Model**:
- Each **stream** logically belongs to one **pod** (identified by stream_id = task_id)
- A pod is the primary writer for its own stream
- Other components can read any stream (for dashboards, monitoring, etc.)
- Cross-pod writes are **discouraged but not prevented** at the Event Store level

**Why Not Enforce at Database Level?**

Adding ownership tracking to the database would:
- Complicate the Event Store (violates single responsibility)
- Require pod registration/lifecycle management
- Make testing harder (need to track ownership)
- Reduce flexibility for legitimate cross-stream writes

**When Cross-Pod Writes Are Legitimate**:
- Central Manager appending system events to task streams
- External Sync Engine updating multiple streams atomically
- Background jobs performing bulk operations

**Enforcement Strategy**: Layer 2 (Pod State Manager) enforces ownership

```elixir
defmodule Ipa.Pod.State do
  def append_event(task_id, event_type, data, opts) do
    # Check that current pod owns this task
    current_pod = self()
    owner_pod = Registry.lookup(Ipa.PodRegistry, task_id)

    if current_pod != owner_pod do
      {:error, :not_owner}
    else
      # Proceed with append
      Ipa.EventStore.append(task_id, event_type, data, opts)
    end
  end
end
```

**For Layer 1 (Event Store)**: No ownership checks. It's a generic, unopinionated persistence layer.

**Summary**:
- Event Store = shared, generic persistence (no ownership enforcement)
- Pod State Manager = owner-aware, business logic layer (enforces ownership)
- This separation keeps concerns properly layered

### JSON Serialization

Events are stored as JSON strings:

```elixir
# Serialize on write
event_data_json = Jason.encode!(event_data)
metadata_json = Jason.encode!(metadata)

# Deserialize on read
event_data = Jason.decode!(event_data_json, keys: :atoms)
```

### Snapshot Strategy

Snapshots should be created:
- Every N events (e.g., every 100 events)
- On pod shutdown (to speed up next startup)
- Periodically in background (optional)

**Replay with snapshot**:
1. Load snapshot (if exists)
2. Load events since snapshot version
3. Apply events to snapshot state

### Error Handling

**Common errors**:
- `:not_found` - Task doesn't exist
- `:version_conflict` - Concurrent write detected
- `Ecto.ConstraintError` - Database constraint violation
- `Jason.DecodeError` - Invalid JSON in database

## Configuration

### Production Configuration

```elixir
# config/config.exs
config :ipa, Ipa.EventStore.Repo,
  database: "priv/ipa.db",
  pool_size: 5,
  timeout: 5000,
  journal_mode: :wal,              # Enable Write-Ahead Logging for better concurrency
  cache_size: -64000,              # 64MB cache (negative = KB)
  temp_store: :memory,             # Use memory for temporary tables
  synchronous: :normal,            # Balance between safety and performance
  foreign_keys: :on                # Enforce foreign key constraints

# Snapshot policy
config :ipa, :event_store,
  snapshot_enabled: true,
  snapshot_interval: 100,          # Create snapshot every N events
  snapshot_on_shutdown: true       # Always snapshot when pod shuts down
```

**Configuration Notes**:
- **journal_mode: :wal** - Critical for concurrent reads during writes. WAL mode allows multiple readers even when a write is in progress.
- **cache_size** - Larger cache improves read performance. Negative values are in KB (e.g., -64000 = 64MB).
- **synchronous: :normal** - Good balance. Use `:full` for maximum safety (slower) or `:off` for maximum speed (risky).
- **snapshot_interval** - Higher values = fewer snapshots (less write overhead), but slower replay. 100 is a good default.

### Test Configuration

```elixir
# config/test.exs
config :ipa, Ipa.EventStore.Repo,
  database: ":memory:",            # In-memory database for tests
  pool: Ecto.Adapters.SQL.Sandbox, # Sandbox mode for test isolation
  journal_mode: :memory            # Faster for tests

config :ipa, :event_store,
  snapshot_enabled: false          # Disable snapshots in tests for simplicity
```

### Scaling Guidelines

**Current Setup (SQLite with WAL):**
- ✅ Up to 100 concurrent pods
- ✅ ~1000 events/second write throughput
- ✅ Single-file portability
- ✅ Zero infrastructure overhead

**When to Migrate to PostgreSQL:**
- 100+ concurrent pods with heavy write activity
- Need for advanced querying (JSON queries, full-text search)
- Horizontal scaling requirements
- Geographic distribution

**Migration Path:**
- Schema is compatible with PostgreSQL
- Change adapter in config: `adapter: Ecto.Adapters.Postgres`
- Update connection parameters
- Run migrations
- Test thoroughly (JSON handling may differ slightly)

## Testing Requirements

### Unit Tests

1. **Task Creation**
   - Creates task with UUID
   - Emits `:task_created` event
   - Returns task_id

2. **Event Appending**
   - Appends event with correct version
   - Increments version correctly
   - Stores JSON correctly
   - Records actor_id and metadata

3. **Event Loading**
   - Loads events in order
   - Returns correct data structure
   - Handles missing task

4. **Optimistic Concurrency**
   - Detects version conflicts
   - Returns `:version_conflict` error
   - Allows retry with correct version

5. **Snapshots**
   - Saves snapshot correctly
   - Loads snapshot correctly
   - Handles missing snapshot

6. **JSON Serialization**
   - Serializes complex data structures
   - Deserializes with atom keys
   - Handles edge cases (nil, empty maps)

### Integration Tests

1. **Concurrent Writes**
   - Spawn multiple processes writing to same task
   - Verify only one succeeds per version
   - Verify final event count

2. **Event Replay**
   - Create task with 100 events
   - Load all events
   - Verify order and completeness

3. **Snapshot + Replay**
   - Create snapshot at version 50
   - Load snapshot + events 51-100
   - Verify state matches full replay

### Performance Tests

1. **Append Performance**
   - Measure time to append 1000 events
   - Should be < 1 second

2. **Load Performance**
   - Measure time to load 1000 events
   - Should be < 100ms

3. **Snapshot Performance**
   - Measure snapshot save time
   - Measure load time with snapshot vs full replay

## Acceptance Criteria

- [ ] All database tables created successfully
- [ ] Can create tasks and get unique UUIDs
- [ ] Can append events with auto-incrementing versions
- [ ] Version conflicts are detected and reported
- [ ] Events can be loaded in order
- [ ] Snapshots can be saved and loaded
- [ ] JSON serialization/deserialization works correctly
- [ ] All unit tests pass
- [ ] Concurrent write tests pass
- [ ] Performance meets requirements

## Migration Path

Since this is a new component, no migration needed. However, consider:

1. **Future: Add fields to events table**
   - Use Ecto migrations
   - Example: Add `correlation_id` for tracing

2. **Future: Migrate to PostgreSQL**
   - Schema should be compatible
   - Change adapter in config
   - Test thoroughly

## Security Considerations

1. **SQL Injection**: Use parameterized queries (Ecto handles this)
2. **File Permissions**: Ensure SQLite file is not world-readable
3. **Backup**: Regular backups of `priv/ipa.db`
4. **Actor Attribution**: Always record `actor_id` for audit trail

## Notes

- SQLite is single-writer, but IPA workload is mostly reads
- For high concurrency, consider migrating to PostgreSQL later
- Keep events immutable - never UPDATE or DELETE
- Consider event retention policy (archive old tasks)
