# IPA Component API Specification

This document provides a comprehensive reference for all component APIs, interfaces, and contracts. Use this as a guide when implementing components and when integrating them together.

## Table of Contents

1. [Layer 1: Shared Persistence APIs](#layer-1-shared-persistence-apis)
2. [Layer 2: Pod Infrastructure APIs](#layer-2-pod-infrastructure-apis)
3. [Layer 3: Central Management APIs](#layer-3-central-management-apis)
4. [Event Schemas](#event-schemas)
5. [State Schemas](#state-schemas)
6. [Error Handling](#error-handling)

---

## Layer 1: Shared Persistence APIs

### 1.1 SQLite Event Store

**Module**: `Ipa.EventStore`

The Event Store is a simple SQLite-based event sourcing implementation. Events are stored as JSON in a single database file (`priv/ipa.db`).

#### Database Schema

**Tasks Table**:
```sql
CREATE TABLE tasks (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
```

**Events Table**:
```sql
CREATE TABLE events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  event_data TEXT NOT NULL,  -- JSON
  version INTEGER NOT NULL,
  actor_id TEXT,
  metadata TEXT,  -- JSON
  inserted_at INTEGER NOT NULL,
  FOREIGN KEY (task_id) REFERENCES tasks(id),
  UNIQUE (task_id, version)
);
CREATE INDEX idx_events_task_id ON events(task_id);
CREATE INDEX idx_events_version ON events(task_id, version);
```

**Snapshots Table** (optional, for performance):
```sql
CREATE TABLE snapshots (
  task_id TEXT PRIMARY KEY,
  state TEXT NOT NULL,  -- JSON
  version INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  FOREIGN KEY (task_id) REFERENCES tasks(id)
);
```

#### Core API

**Create Task**:
```elixir
{:ok, task_id} = Ipa.EventStore.create_task(%{title: "Implement authentication"})
# Creates task record and emits :task_created event
# Returns: {:ok, task_id} | {:error, reason}
```

**Append Event**:
```elixir
{:ok, version} = Ipa.EventStore.append(
  task_id,
  :transition_approved,
  %{to_phase: :planning, approved_by: user_id},
  %{actor_id: user_id, metadata: %{ip: "127.0.0.1"}}
)
# Returns: {:ok, new_version} | {:error, :version_conflict} | {:error, reason}
```

**Load Events**:
```elixir
# Load all events for a task
{:ok, events} = Ipa.EventStore.load_events(task_id)
# Returns: {:ok, [%{event_type: atom, data: map, version: int, inserted_at: timestamp}, ...]}

# Load events since specific version (for incremental replay)
{:ok, events} = Ipa.EventStore.load_events_since(task_id, from_version)
```

**Snapshots** (optional, for performance):
```elixir
# Save snapshot
:ok = Ipa.EventStore.save_snapshot(task_id, state_map, version)

# Load snapshot
{:ok, %{state: state_map, version: version}} = Ipa.EventStore.load_snapshot(task_id)
# Returns: {:ok, snapshot} | {:error, :not_found}
```

**List Tasks**:
```elixir
# List all tasks
{:ok, tasks} = Ipa.EventStore.list_tasks()
# Returns: {:ok, [%{id: uuid, title: string, created_at: timestamp}, ...]}

# Get task metadata
{:ok, task} = Ipa.EventStore.get_task(task_id)
# Returns: {:ok, %{id: uuid, title: string, created_at: timestamp, updated_at: timestamp}}
```

**Delete Task** (cleanup):
```elixir
:ok = Ipa.EventStore.delete_task(task_id)
# Deletes task, all events, and snapshot
```

#### Implementation Notes

1. **Optimistic Concurrency**: The `UNIQUE (task_id, version)` constraint ensures that concurrent writes are detected and rejected.

2. **JSON Serialization**: Events are stored as JSON strings. Use `Jason.encode!/1` and `Jason.decode!/1` for serialization.

3. **Timestamps**: Use Unix timestamps (seconds since epoch) for `inserted_at`, `created_at`, `updated_at`.

4. **Error Handling**:
   - `{:error, :version_conflict}` - Another process wrote an event with the same version
   - `{:error, :not_found}` - Task or snapshot doesn't exist
   - `{:error, reason}` - Database error (e.g., constraint violation)

5. **Testing**: Use `:memory:` database for tests to avoid file I/O overhead.

---

## Layer 2: Pod Infrastructure APIs

### 2.1 Task Pod Supervisor

**Module**: `Ipa.Pod.Supervisor`

**API**:
```elixir
# Start pod supervisor
{:ok, pid} = Ipa.Pod.Supervisor.start_link(task_id)

# Get pod PID via registry
{:ok, pid} = Ipa.Pod.Supervisor.whereis(task_id)

# Stop pod
:ok = Ipa.Pod.Supervisor.stop(task_id)
```

**Child Specification**:
```elixir
# Returns child spec for DynamicSupervisor
child_spec = Ipa.Pod.Supervisor.child_spec(task_id)
```

**Supervision Strategy**: `:one_for_all`
- If any child crashes, all children restart
- Pod state reloads from persisted events

---

### 2.2 Pod State Manager

**Module**: `Ipa.Pod.State`

**API**:
```elixir
# Start state manager (called by Pod Supervisor)
{:ok, pid} = Ipa.Pod.State.start_link(task_id)

# Append event with optimistic concurrency check
{:ok, new_version} = Ipa.Pod.State.append_event(
  task_id,
  :agent_started,
  %{agent_id: "abc123", agent_type: "planning"},
  expected_version  # Current version, for conflict detection
)
# Returns: {:ok, new_version} | {:error, :version_conflict}

# Get current state
{:ok, state} = Ipa.Pod.State.get_state(task_id)
# Returns current state map (see State Schema below)

# Subscribe to state changes
:ok = Ipa.Pod.State.subscribe(task_id)
# Subscriber receives: {:state_updated, task_id, new_state}

# Unsubscribe
:ok = Ipa.Pod.State.unsubscribe(task_id)
```

**Pub-Sub Topic**: `"pod:#{task_id}:state"`

**Messages Published**:
```elixir
{:state_updated, task_id, new_state}
```

**Internal Behavior**:
1. On `start_link`: Load events from Ash, replay to build state
2. On `append_event`: Check version → call Ash action → update memory → publish
3. On `get_state`: Return in-memory state (fast)

---

### 2.3 Pod Scheduler

**Module**: `Ipa.Pod.Scheduler`

**API**:
```elixir
# Start scheduler (called by Pod Supervisor)
{:ok, pid} = Ipa.Pod.Scheduler.start_link(task_id)

# Interrupt running agent
:ok = Ipa.Pod.Scheduler.interrupt_agent(task_id, agent_id)

# Force immediate evaluation (for testing)
:ok = Ipa.Pod.Scheduler.evaluate_now(task_id)
```

**Internal Behavior**:
1. Subscribe to `"pod:#{task_id}:state"`
2. On `{:state_updated, ...}`: Evaluate state machine
3. Determine action (spawn agent, wait, transition, etc.)
4. Execute action (may append events)
5. Respect cooldowns between evaluations

**State Machine Rules** (examples):
```elixir
# Phase: spec_clarification, spec approved → transition to planning
if state.phase == :spec_clarification && state.spec.approved? do
  append_event(:transition_requested, %{to_phase: :planning})
end

# Phase: planning, no plan, no active agents → spawn planning agent
if state.phase == :planning && !state.plan && no_active_agents?(state) do
  workspace = create_workspace(task_id, agent_id)
  spawn_agent(:planning, workspace)
  append_event(:agent_started, %{agent_id: agent_id, workspace: workspace})
end

# Phase: development, agent completed → check if tests pass
if state.phase == :development && agent_completed?(state) do
  # Run tests, then either spawn test-fix agent or transition to review
end
```

---

### 2.4 Pod Workspace Manager

**Module**: `Ipa.Pod.WorkspaceManager`

**API**:
```elixir
# Start workspace manager (called by Pod Supervisor)
{:ok, pid} = Ipa.Pod.WorkspaceManager.start_link(task_id)

# Create workspace for agent
{:ok, workspace_path} = Ipa.Pod.WorkspaceManager.create_workspace(
  task_id,
  agent_id,
  %{
    repo: "git@github.com:xorvo/ipa.git",
    branch: "main",
    clone: true  # Whether to git clone
  }
)
# Returns: {:ok, "/ipa/workspaces/{task_id}/{agent_id}"}

# Get workspace path
{:ok, workspace_path} = Ipa.Pod.WorkspaceManager.get_workspace(task_id, agent_id)
# Returns: {:ok, path} | {:error, :not_found}

# Read file from workspace
{:ok, contents} = Ipa.Pod.WorkspaceManager.read_file(
  task_id,
  agent_id,
  "lib/some_file.ex"  # Relative path
)
# Returns: {:ok, binary} | {:error, :not_found}

# Write file to workspace
:ok = Ipa.Pod.WorkspaceManager.write_file(
  task_id,
  agent_id,
  "lib/some_file.ex",
  contents
)

# Git operations
{:ok, diff} = Ipa.Pod.WorkspaceManager.git_diff(task_id, agent_id)
{:ok, status} = Ipa.Pod.WorkspaceManager.git_status(task_id, agent_id)
:ok = Ipa.Pod.WorkspaceManager.git_commit(task_id, agent_id, "message")

# Cleanup workspace (delete directory)
:ok = Ipa.Pod.WorkspaceManager.cleanup_workspace(task_id, agent_id)

# List active workspaces for task
{:ok, [agent_id1, agent_id2]} = Ipa.Pod.WorkspaceManager.list_workspaces(task_id)
```

**Workspace Path Convention**: `/ipa/workspaces/{task_id}/{agent_id}/`

---

### 2.5 Pod External Sync Engine

**Module**: `Ipa.Pod.ExternalSync`

**API**:
```elixir
# Start external sync (called by Pod Supervisor)
{:ok, pid} = Ipa.Pod.ExternalSync.start_link(task_id, config)
# config: %{github: %{enabled: bool, repo: string}, jira: %{enabled: bool, project: string}}

# Force sync now (push pending updates)
:ok = Ipa.Pod.ExternalSync.sync_now(task_id)

# Get sync status
{:ok, status} = Ipa.Pod.ExternalSync.get_status(task_id)
# Returns: %{github: %{synced_at: timestamp, pending: bool}, jira: %{...}}
```

**Internal Behavior**:
1. Subscribe to `"pod:#{task_id}:state"`
2. On `{:state_updated, ...}`: Determine what changed
3. Queue updates (with deduplication)
4. Batch updates (wait 1s for more changes)
5. Push to external systems (GitHub, JIRA)
6. Poll external systems periodically for incoming changes
7. If external change detected, append event to Pod State

**Connectors**:

#### GitHub Connector
```elixir
# Create PR
{:ok, pr_number} = Ipa.ExternalSync.GitHub.create_pr(%{
  repo: "xorvo/ipa",
  title: "Feature: ...",
  body: "...",
  base: "main",
  head: "feature-branch"
})

# Update PR
:ok = Ipa.ExternalSync.GitHub.update_pr(repo, pr_number, %{
  body: "Updated description..."
})

# Get PR comments
{:ok, comments} = Ipa.ExternalSync.GitHub.get_pr_comments(repo, pr_number)

# Check if PR merged
{:ok, merged?} = Ipa.ExternalSync.GitHub.pr_merged?(repo, pr_number)
```

#### JIRA Connector
```elixir
# Update ticket status
:ok = Ipa.ExternalSync.Jira.update_ticket_status(ticket_id, "In Progress")

# Post comment
:ok = Ipa.ExternalSync.Jira.post_comment(ticket_id, "Agent completed planning phase")

# Get ticket updates
{:ok, ticket} = Ipa.ExternalSync.Jira.get_ticket(ticket_id)
```

---

### 2.6 Pod LiveView UI

**Module**: `IpaWeb.Pod.TaskLive`

**Route**: `/pods/:task_id`

**LiveView Callbacks**:
```elixir
def mount(%{"task_id" => task_id}, _session, socket) do
  # Subscribe to pod-local pub-sub
  Phoenix.PubSub.subscribe(Ipa.PubSub, "pod:#{task_id}:state")

  # Load current state
  {:ok, state} = Ipa.Pod.State.get_state(task_id)

  {:ok, assign(socket, task_id: task_id, state: state)}
end

def handle_info({:state_updated, _task_id, new_state}, socket) do
  {:noreply, assign(socket, state: new_state)}
end

def handle_event("approve_transition", %{"to_phase" => to_phase}, socket) do
  Ipa.Pod.State.append_event(
    socket.assigns.task_id,
    :transition_approved,
    %{to_phase: String.to_atom(to_phase), approved_by: socket.assigns.user_id},
    socket.assigns.state.version
  )
  {:noreply, socket}
end

def handle_event("interrupt_agent", %{"agent_id" => agent_id}, socket) do
  Ipa.Pod.Scheduler.interrupt_agent(socket.assigns.task_id, agent_id)
  {:noreply, socket}
end
```

**UI Sections**:
- Task header (title, phase, status)
- Spec section (display spec, approval button)
- Plan section (display plan, approval button)
- Active agents (streaming logs, interrupt button)
- Workspace browser (file tree, file viewer)
- External sync status (GitHub PR, JIRA ticket)

---

## Layer 3: Central Management APIs

### 3.1 Central Task Manager

**Module**: `Ipa.CentralManager`

**API**:
```elixir
# Start pod for task
{:ok, pod_pid} = Ipa.CentralManager.start_pod(task_id)
# Spawns Pod Supervisor via DynamicSupervisor

# Stop pod
:ok = Ipa.CentralManager.stop_pod(task_id)
# Gracefully shuts down pod, flushes state

# Get active pods
[task_id1, task_id2] = Ipa.CentralManager.get_active_pods()

# Check if pod is running
true = Ipa.CentralManager.pod_running?(task_id)

# Handle pod crash (called by supervisor)
# This is internal - logs crash, notifies user
```

**Registry**: Uses Elixir `Registry` to track `task_id → pod_pid`

---

### 3.2 Central Dashboard UI

**Module**: `IpaWeb.Dashboard.TasksLive`

**Route**: `/`

**LiveView Callbacks**:
```elixir
def mount(_params, _session, socket) do
  # Load task list (not real-time, loaded on mount)
  tasks = IPA.Tasks.Task.list_all()
  {:ok, assign(socket, tasks: tasks)}
end

def handle_event("create_task", %{"title" => title}, socket) do
  # Create task
  {:ok, task} = IPA.Tasks.Task.create_task(%{title: title})

  # Start pod
  {:ok, _pod_pid} = Ipa.CentralManager.start_pod(task.id)

  # Navigate to pod UI
  {:noreply, push_navigate(socket, to: "/pods/#{task.id}")}
end

def handle_event("navigate_to_pod", %{"task_id" => task_id}, socket) do
  {:noreply, push_navigate(socket, to: "/pods/#{task_id}")}
end

def handle_event("complete_task", %{"task_id" => task_id}, socket) do
  task = IPA.Tasks.Task.get!(task_id)
  {:ok, _task} = IPA.Tasks.Task.complete_task(task)
  Ipa.CentralManager.stop_pod(task_id)
  {:noreply, socket}
end
```

**UI Sections**:
- Task list (table with title, phase, status, timestamps)
- Create task button
- Task actions (view, complete, cancel)

---

## Event Schemas

### Event Types

All events are stored in `IPA.Tasks.TaskEvent` with this structure:

```elixir
%IPA.Tasks.TaskEvent{
  event_type: atom,
  data: map,  # Event-specific data
  version: integer,  # Incremental version number
  actor_id: uuid | nil,  # Who triggered this event
  metadata: map  # Additional context (e.g., IP, user agent)
}
```

### Event Type Definitions

#### Task Lifecycle Events

**:task_created**
```elixir
%{title: string, created_by: uuid}
```

**:task_completed**
```elixir
%{completed_at: timestamp}
```

**:task_cancelled**
```elixir
%{reason: string, cancelled_by: uuid}
```

#### Phase Transition Events

**:transition_requested**
```elixir
%{from_phase: atom, to_phase: atom, reason: string}
```

**:transition_approved**
```elixir
%{to_phase: atom, approved_by: uuid}
```

**:transition_rejected**
```elixir
%{reason: string, rejected_by: uuid}
```

#### Spec Phase Events

**:spec_updated**
```elixir
%{
  spec: %{
    description: string,
    requirements: [string],
    acceptance_criteria: [string]
  }
}
```

**:spec_approved**
```elixir
%{approved_by: uuid}
```

#### Planning Phase Events

**:plan_generated**
```elixir
%{
  plan: %{
    steps: [%{description: string, estimated_hours: float}],
    total_estimated_hours: float
  },
  generated_by: uuid  # Agent ID
}
```

**:plan_approved**
```elixir
%{approved_by: uuid}
```

#### Development Phase Events

**:agent_started**
```elixir
%{
  agent_id: uuid,
  agent_type: string,  # "planning", "development", "testing", etc.
  workspace: string,
  started_at: timestamp
}
```

**:agent_completed**
```elixir
%{
  agent_id: uuid,
  result: map,  # Agent-specific result data
  duration_ms: integer,
  completed_at: timestamp
}
```

**:agent_failed**
```elixir
%{
  agent_id: uuid,
  error: string,
  failed_at: timestamp
}
```

**:agent_interrupted**
```elixir
%{
  agent_id: uuid,
  interrupted_by: uuid,
  interrupted_at: timestamp
}
```

#### External Sync Events

**:github_pr_created**
```elixir
%{pr_number: integer, pr_url: string, created_at: timestamp}
```

**:github_pr_updated**
```elixir
%{pr_number: integer, updated_at: timestamp}
```

**:github_pr_merged**
```elixir
%{pr_number: integer, merged_by: string, merged_at: timestamp}
```

**:jira_ticket_updated**
```elixir
%{ticket_id: string, status: string, updated_at: timestamp}
```

---

## State Schemas

### Task State (In-Memory Projection)

This is the structure maintained by `Ipa.Pod.State`:

```elixir
%{
  # Metadata
  task_id: uuid,
  version: integer,  # Current event version
  created_at: timestamp,
  updated_at: timestamp,

  # Core state
  phase: :spec_clarification | :planning | :development | :review | :completed | :cancelled,
  title: string,

  # Phase-specific data
  spec: %{
    description: string | nil,
    requirements: [string],
    acceptance_criteria: [string],
    approved?: boolean,
    approved_by: uuid | nil,
    approved_at: timestamp | nil
  },

  plan: %{
    steps: [%{description: string, estimated_hours: float, status: atom}],
    total_estimated_hours: float,
    approved?: boolean,
    approved_by: uuid | nil,
    approved_at: timestamp | nil
  },

  # Active agents
  agents: [
    %{
      agent_id: uuid,
      agent_type: string,
      status: :running | :completed | :failed | :interrupted,
      workspace: string,
      started_at: timestamp,
      completed_at: timestamp | nil,
      duration_ms: integer | nil,
      result: map | nil,
      error: string | nil
    }
  ],

  # External sync status
  external_sync: %{
    github: %{
      pr_number: integer | nil,
      pr_url: string | nil,
      pr_merged?: boolean,
      synced_at: timestamp | nil
    },
    jira: %{
      ticket_id: string | nil,
      status: string | nil,
      synced_at: timestamp | nil
    }
  }
}
```

---

## Error Handling

### Standard Error Returns

All components follow this convention:

**Success**: `{:ok, result}`
**Error**: `{:error, reason}`

### Common Error Reasons

**Optimistic Concurrency**:
```elixir
{:error, :version_conflict}
# Returned when expected_version doesn't match current version
# Caller should reload state and retry
```

**Not Found**:
```elixir
{:error, :not_found}
# Returned when task_id, agent_id, workspace, or file not found
```

**Invalid State Transition**:
```elixir
{:error, {:invalid_transition, from_phase, to_phase}}
# Returned when state machine doesn't allow transition
```

**Agent Spawn Failure**:
```elixir
{:error, {:agent_spawn_failed, reason}}
# Returned when Claude Code SDK fails to spawn agent
```

**External Sync Failure**:
```elixir
{:error, {:sync_failed, system, reason}}
# system: :github | :jira
# Returned when external API call fails
```

### Error Handling Strategy

1. **Transient Errors** (network, rate limits): Retry with exponential backoff
2. **Permanent Errors** (not found, invalid): Log and notify user
3. **Concurrency Conflicts**: Reload and retry (up to 3 times)
4. **Agent Failures**: Log, record event, scheduler decides next action

### Logging

All components use standard Elixir Logger:

```elixir
require Logger

Logger.info("Pod started", task_id: task_id)
Logger.error("Agent failed", task_id: task_id, agent_id: agent_id, error: error)
```

**Log Levels**:
- `:debug` - Internal state transitions, message passing
- `:info` - Significant events (pod start/stop, agent spawn, phase transition)
- `:warning` - Recoverable errors (retries, conflicts)
- `:error` - Unrecoverable errors (agent crashes, external sync failures)

---

## Testing Contracts

### Unit Test Requirements

Each component must have unit tests that verify:

1. **Happy path**: All public API functions work correctly
2. **Error cases**: All error returns are handled
3. **Edge cases**: Empty data, nil values, concurrent calls
4. **State invariants**: Internal state stays consistent

### Integration Test Requirements

Component pairs must have integration tests:

1. **Pod State ↔ Scheduler**: State changes trigger scheduler actions
2. **Scheduler ↔ Workspace Manager**: Agent spawn creates workspace
3. **State ↔ LiveView**: State changes update UI in real-time
4. **Central Manager ↔ Pod Supervisor**: Pod lifecycle works correctly

### Mocking Strategy

- **Ash Resources**: Use `Ash.Test` helpers or in-memory data layer
- **External APIs** (GitHub, JIRA): Use `Mox` or `Tesla.Mock`
- **Claude Code SDK**: Create test adapter that simulates agent behavior
- **Pub-Sub**: Use test process to assert messages published

---

## Versioning & Compatibility

### API Versioning

- **Current Version**: v1 (initial implementation)
- **Breaking Changes**: Will require migration scripts
- **Event Schema Changes**: Use event versioning (`:v1`, `:v2` suffix on event types)

### Event Versioning Strategy

When event schema changes:

```elixir
# Old event
:agent_started  # v1 schema

# New event (if schema changes)
:agent_started_v2  # v2 schema

# State projection handles both:
defp apply_event({:agent_started, data}, state), do: # v1 logic
defp apply_event({:agent_started_v2, data}, state), do: # v2 logic
```

This ensures old events can always be replayed.

---

## Summary Checklist

When implementing a component, ensure:

- [ ] All public functions documented
- [ ] Return types follow `{:ok, result} | {:error, reason}` convention
- [ ] Error cases handled and logged
- [ ] Tests written (unit + integration)
- [ ] Pub-sub topics/messages documented (if applicable)
- [ ] State schemas documented (if applicable)
- [ ] Migration path considered (if changing schemas)
