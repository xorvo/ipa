# Component Spec: 3.1 Central Task Manager (REVISED)

**Version**: 2.0 (Post-Review Revision)
**Last Updated**: 2025-11-06
**Review Status**: Addresses all P0 and P1 issues from architectural review

## Overview

The Central Task Manager is the **primary entry point** for all task operations in the IPA system. It provides a high-level API for creating, managing, and monitoring tasks, and coordinates between the Event Store (Layer 1) and Pod Supervisor (Layer 2).

This component provides:
- Task creation and initialization (Event Store + metadata table)
- Pod lifecycle coordination (via Pod Supervisor)
- Task listing and querying (metadata table + Pod State Manager)
- Pod crash detection and recovery
- Centralized task state aggregation

## Purpose

- **Task Management**: Create, list, and query tasks
- **Pod Coordination**: Start/stop pods for tasks via Pod Supervisor
- **State Aggregation**: Combine metadata (inactive tasks) with live state (active pods via Pod State Manager)
- **Crash Recovery**: Monitor pods and handle crashes gracefully
- **Central API**: Provide unified interface for Central Dashboard UI

## Architecture Position

```
Layer 3: Central Management
         ┌──────────────────────────────────────────┐
         │  3.1 Central Task Manager (THIS)         │
         │  - Creates tasks (Event Store + metadata)│
         │  - Coordinates pod lifecycle             │
         │  - Aggregates task state (NOT events!)   │
         │  - Monitors pod health                   │
         └──────────────────────────────────────────┘
           ↓ uses                    ↓ used by
┌──────────────────┐      ┌──────────────────────────┐
│  1.1 Event Store │      │  3.2 Central Dashboard   │
│  + tasks table   │      │  (Task listing UI)       │
└──────────────────┘      └──────────────────────────┘
           ↓ coordinates              ↓ queries
┌─────────────────────────┐  ┌───────────────────────┐
│  2.1 Pod Supervisor     │  │  2.2 Pod State Manager│
│  (Pod lifecycle)        │  │  (Live state)         │
└─────────────────────────┘  └───────────────────────┘
```

**Key Architectural Principle**: Central Manager NEVER interprets raw events. It queries Pod State Manager for active pods and uses the tasks metadata table for inactive pods.

## Dependencies

- **Internal**:
  - 1.1 SQLite Event Store (for task events and metadata table)
  - 2.1 Pod Supervisor (for pod lifecycle management)
  - 2.2 Pod State Manager (for live task state via Registry)
- **External**:
  - Elixir, OTP (GenServer, Registry, Process)
  - Phoenix.PubSub (for pod monitoring)

## Database Schema

### Tasks Metadata Table

**Purpose**: Efficient task listing without reading events, maintains summary for inactive tasks.

```sql
-- Migration: priv/repo/migrations/XXXXXX_create_tasks_table.exs
CREATE TABLE tasks (
  task_id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT,
  status TEXT NOT NULL,  -- 'active', 'inactive', 'completed', 'cancelled'
  phase TEXT NOT NULL,   -- 'spec_clarification', 'planning', 'development', 'review', 'completed', 'cancelled'
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  created_by TEXT,
  FOREIGN KEY (task_id) REFERENCES streams(id) ON DELETE CASCADE
);

CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_phase ON tasks(phase);
CREATE INDEX idx_tasks_created_at ON tasks(created_at);
CREATE INDEX idx_tasks_updated_at ON tasks(updated_at);
```

**Maintenance**:
- INSERT on `create_task/2`
- UPDATE on `cancel_task/2`, `complete_task/2`
- Pod State Manager updates on phase transitions (via pub-sub)

**Why This Solves P0-1 and P0-2**:
- Enables O(n) task listing instead of O(n×m)
- No need to interpret raw events
- Supports filtering by status/phase efficiently
- Single source of truth for inactive task metadata

## Module Structure

```
lib/ipa/central/
  ├── task_manager.ex           # Main GenServer for task coordination
  └── tasks.ex                  # Ecto schema for tasks metadata table

lib/ipa/
  └── central_manager.ex        # Public facade
```

## Responsibilities

### Core Responsibilities

1. **Task Creation**
   - Create new task stream in Event Store (using correct API)
   - Insert task metadata into tasks table
   - Emit `:task_created` event with actor_id tracking
   - Optionally auto-start pod for task

2. **Pod Lifecycle Coordination**
   - Start pods via `Ipa.PodSupervisor.start_pod/1` (with race condition protection)
   - Stop pods via `Ipa.PodSupervisor.stop_pod/1` (with proper demonitor)
   - Monitor pod processes for crashes
   - Handle Pod Supervisor failures

3. **Task Querying**
   - List tasks from metadata table (efficient filtering)
   - Get task details: active pods via Pod State Manager, inactive via metadata
   - Never interpret raw events

4. **Pod Monitoring**
   - Monitor pod crashes via Process.monitor/1
   - Optional auto-restart on crash (with frequency limits)
   - Track and cleanup pod crash history
   - Monitor Pod Supervisor itself for resilience

5. **State Aggregation**
   - For **active pods**: Query Pod State Manager for live state
   - For **inactive tasks**: Read from tasks metadata table
   - Provide unified view combining both sources

### Non-Responsibilities

- **NOT** interpreting raw events (belongs to Pod State Manager)
- **NOT** managing pod children (handled by Pod Supervisor)
- **NOT** agent execution (handled by Pod Scheduler)
- **NOT** UI rendering (handled by Dashboard LiveView)

## Public API

### Module: `Ipa.CentralManager`

High-level facade for task operations. Internally delegates to `Ipa.Central.TaskManager`.

#### `create_task/2`

```elixir
@spec create_task(title :: String.t(), opts :: keyword()) ::
  {:ok, task_id :: String.t()} | {:error, term()}
```

Creates a new task with event tracking and metadata.

**Options**:
- `:description` - Task description (string)
- `:actor_id` - User ID of creator (string, **required for audit trail**)
- `:correlation_id` - Request correlation ID (string, optional)
- `:auto_start` - Automatically start pod (boolean, default: false)
- `:metadata` - Additional metadata (map, optional)

**Process**:
1. Validate title (non-empty, max 255 chars)
2. Generate unique task_id (UUID)
3. Create stream in Event Store: `Ipa.EventStore.start_stream("task", task_id)`
4. Append `:task_created` event with actor_id and correlation_id
5. Insert metadata into tasks table
6. If `auto_start: true`, call `start_pod/1`
7. Return task_id

**Example**:
```elixir
{:ok, task_id} = Ipa.CentralManager.create_task(
  "Implement user authentication",
  description: "Add JWT-based auth to API",
  actor_id: "user-123",
  correlation_id: "req-456",
  auto_start: true
)
```

**Errors**:
- `{:error, :invalid_title}` - Title is empty or too long
- `{:error, :missing_actor_id}` - actor_id not provided
- `{:error, :event_store_unavailable}` - Cannot reach Event Store
- `{:error, reason}` - Other Event Store or database errors

#### `start_pod/1`

```elixir
@spec start_pod(task_id :: String.t(), opts :: keyword()) ::
  {:ok, pid()} | {:error, :already_started | :task_not_found | term()}
```

Starts a pod for the given task with race condition protection.

**Options**:
- `:actor_id` - Who started the pod (for audit, optional)
- `:correlation_id` - Request correlation ID (optional)

**Preconditions**:
- Task must exist in Event Store and tasks table
- Pod must not already be running (idempotent check)

**Process**:
1. Check if already monitoring this task (idempotent)
2. Verify task exists in tasks table
3. Call `Ipa.PodSupervisor.start_pod(task_id)`
4. Handle `:already_started` error gracefully
5. Monitor pod process for crashes
6. Update tasks table status to 'active'
7. Return pod PID

**Example**:
```elixir
{:ok, pod_pid} = Ipa.CentralManager.start_pod(
  "task-uuid-123",
  actor_id: "user-123"
)
```

**Errors**:
- `{:error, :task_not_found}` - Task doesn't exist
- `{:error, :already_started}` - Pod is already running (safe, idempotent)
- `{:error, reason}` - Pod Supervisor error

#### `stop_pod/2`

```elixir
@spec stop_pod(task_id :: String.t(), opts :: keyword()) ::
  :ok | {:error, :not_running | term()}
```

Gracefully stops a pod with proper demonitor.

**Options**:
- `:actor_id` - Who stopped the pod (optional)
- `:reason` - Reason for stopping (optional, default: :normal)

**Process**:
1. Check if monitoring this task
2. Demonitor with [:flush] to avoid receiving DOWN message
3. Call `Ipa.PodSupervisor.stop_pod(task_id)`
4. Remove monitor from internal map
5. Update tasks table status to 'inactive'
6. Return :ok

**Example**:
```elixir
:ok = Ipa.CentralManager.stop_pod(
  "task-uuid-123",
  actor_id: "user-123",
  reason: :task_completed
)
```

**Errors**:
- `{:error, :not_running}` - Pod is not running

#### `restart_pod/2`

```elixir
@spec restart_pod(task_id :: String.t(), opts :: keyword()) ::
  {:ok, pid()} | {:error, term()}
```

Restarts a pod (stop + start) with tracking.

**Options**:
- `:actor_id` - Who restarted the pod (optional)
- `:correlation_id` - Request correlation ID (optional)

**Use Cases**:
- Recovery from error state
- Manual intervention after crash

**Example**:
```elixir
{:ok, new_pid} = Ipa.CentralManager.restart_pod(
  "task-uuid-123",
  actor_id: "user-123"
)
```

#### `get_task/1`

```elixir
@spec get_task(task_id :: String.t()) ::
  {:ok, task :: map()} | {:error, :not_found}
```

Gets detailed task information using proper layering.

**Implementation Strategy**:
- **If pod is running**: Query `Ipa.Pod.State.get_state/1` via Registry for live state
- **If pod is NOT running**: Read from tasks metadata table

**Returns**: Task map with:
- `task_id` - UUID
- `title` - Task title
- `description` - Task description
- `phase` - Current phase (from Pod State Manager if active, else from table)
- `status` - `:active` | `:inactive` | `:completed` | `:cancelled`
- `created_at` - Creation timestamp
- `updated_at` - Last update timestamp
- `created_by` - Creator user ID
- `pod_pid` - Pod PID if running (nil otherwise)
- `pod_status` - `:running` | `:stopped`
- `version` - Current state version (from Pod State Manager if active)

**Example**:
```elixir
{:ok, task} = Ipa.CentralManager.get_task("task-uuid-123")
# %{
#   task_id: "task-uuid-123",
#   title: "Implement auth",
#   description: "Add JWT authentication",
#   phase: :development,
#   status: :active,
#   created_at: 1699564800,
#   updated_at: 1699568400,
#   created_by: "user-123",
#   pod_pid: #PID<0.234.0>,
#   pod_status: :running,
#   version: 42
# }
```

**Errors**:
- `{:error, :not_found}` - Task doesn't exist

#### `list_tasks/1`

```elixir
@spec list_tasks(opts :: keyword()) :: {:ok, [task :: map()]}
```

Lists all tasks efficiently using metadata table.

**Options**:
- `:status` - Filter by status (`:active`, `:inactive`, `:completed`, `:cancelled`)
- `:phase` - Filter by phase (`:spec_clarification`, `:planning`, etc.)
- `:created_after` - Filter by creation time (timestamp)
- `:created_by` - Filter by creator
- `:limit` - Max number of results (default: 100, max: 1000)
- `:offset` - Pagination offset (default: 0)
- `:order_by` - Sort field (default: :updated_at)
- `:order` - Sort direction (:asc | :desc, default: :desc)

**Returns**: List of task maps (same structure as `get_task/1`)

**Performance**: O(n) where n = matching tasks (efficient database query)

**Example**:
```elixir
{:ok, tasks} = Ipa.CentralManager.list_tasks(
  status: :active,
  limit: 10,
  order_by: :created_at,
  order: :desc
)
```

#### `get_active_pods/0`

```elixir
@spec get_active_pods() :: [task_id :: String.t()]
```

Returns list of task_ids with active pods (from internal monitors map).

**Example**:
```elixir
task_ids = Ipa.CentralManager.get_active_pods()
# ["uuid-1", "uuid-2", "uuid-3"]
```

#### `pod_running?/1`

```elixir
@spec pod_running?(task_id :: String.t()) :: boolean()
```

Checks if a pod is currently running for a task.

**Example**:
```elixir
if Ipa.CentralManager.pod_running?("task-uuid-123") do
  # Pod is active
end
```

#### `count_tasks/1`

```elixir
@spec count_tasks(opts :: keyword()) :: {:ok, non_neg_integer()}
```

Counts tasks efficiently using metadata table (same filters as `list_tasks/1`).

**Example**:
```elixir
{:ok, count} = Ipa.CentralManager.count_tasks(status: :active)
# 5
```

#### `cancel_task/2`

```elixir
@spec cancel_task(task_id :: String.t(), opts :: keyword()) ::
  :ok | {:error, term()}
```

Cancels a task with audit trail.

**Options** (**required**):
- `:reason` - Reason for cancellation (string, **required**)
- `:actor_id` - Who cancelled the task (string, **required for audit**)
- `:correlation_id` - Request correlation ID (optional)

**Process**:
1. Verify task exists and is not already completed/cancelled
2. Append `:task_cancelled` event with actor_id, reason, correlation_id
3. Update tasks table: status = 'cancelled', phase = 'cancelled'
4. Stop pod if running
5. Return :ok

**Example**:
```elixir
:ok = Ipa.CentralManager.cancel_task(
  "task-uuid-123",
  reason: "User requested cancellation",
  actor_id: "user-123",
  correlation_id: "req-789"
)
```

**Errors**:
- `{:error, :not_found}` - Task doesn't exist
- `{:error, :already_cancelled}` - Task already cancelled
- `{:error, :already_completed}` - Task already completed
- `{:error, :missing_reason}` - reason not provided
- `{:error, :missing_actor_id}` - actor_id not provided

#### `complete_task/2`

```elixir
@spec complete_task(task_id :: String.t(), opts :: keyword()) ::
  :ok | {:error, term()}
```

Marks a task as completed with audit trail.

**Options**:
- `:actor_id` - Who completed the task (string, **required for audit**)
- `:correlation_id` - Request correlation ID (optional)

**Process**:
1. Verify task exists and is not already completed/cancelled
2. Append `:task_completed` event with actor_id, correlation_id
3. Update tasks table: status = 'completed', phase = 'completed'
4. Stop pod if running
5. Return :ok

**Example**:
```elixir
:ok = Ipa.CentralManager.complete_task(
  "task-uuid-123",
  actor_id: "user-123"
)
```

**Errors**:
- `{:error, :not_found}` - Task doesn't exist
- `{:error, :already_completed}` - Task already completed
- `{:error, :already_cancelled}` - Task already cancelled
- `{:error, :missing_actor_id}` - actor_id not provided

## Internal Implementation

### GenServer State

```elixir
defmodule Ipa.Central.TaskManager do
  use GenServer
  require Logger

  @call_timeout 30_000  # 30 seconds for slow operations

  defstruct [
    # Map of task_id => monitor_ref for pod monitoring
    monitors: %{},

    # Monitor ref for Pod Supervisor itself
    pod_supervisor_ref: nil,

    # Configuration
    config: %{
      auto_restart_on_crash: false,
      max_restart_attempts: 3,
      restart_window_seconds: 60
    },

    # Crash history: task_id => [timestamps]
    # Cleaned up periodically
    crash_history: %{}
  ]
end
```

### Initialization

```elixir
def start_link(opts) do
  GenServer.start_link(__MODULE__, opts, name: __MODULE__)
end

def init(_opts) do
  # Load configuration
  config = load_config()

  # Monitor Pod Supervisor for resilience
  pod_supervisor_ref = monitor_pod_supervisor()

  # Schedule periodic crash history cleanup
  schedule_crash_history_cleanup()

  state = %__MODULE__{
    monitors: %{},
    pod_supervisor_ref: pod_supervisor_ref,
    config: config,
    crash_history: %{}
  }

  {:ok, state}
end

defp load_config do
  config = Application.get_env(:ipa, __MODULE__, [])

  %{
    auto_restart_on_crash: Keyword.get(config, :auto_restart_on_crash, false),
    max_restart_attempts: Keyword.get(config, :max_restart_attempts, 3),
    restart_window_seconds: Keyword.get(config, :restart_window_seconds, 60)
  }
end

defp monitor_pod_supervisor do
  case Process.whereis(Ipa.PodSupervisor) do
    nil ->
      Logger.warning("PodSupervisor not available at init, will retry")
      nil
    pid ->
      Process.monitor(pid)
  end
end

defp schedule_crash_history_cleanup do
  # Cleanup every hour
  Process.send_after(self(), :cleanup_crash_history, :timer.hours(1))
end
```

### Task Creation Implementation

```elixir
def handle_call({:create_task, title, opts}, _from, state) do
  with :ok <- validate_title(title),
       :ok <- validate_actor_id(opts),
       task_id <- generate_task_id(),
       :ok <- create_task_stream(task_id, title, opts),
       :ok <- insert_task_metadata(task_id, title, opts) do

    # Optionally auto-start pod
    if opts[:auto_start] do
      GenServer.cast(self(), {:start_pod, task_id, opts})
    end

    {:reply, {:ok, task_id}, state}
  else
    {:error, reason} -> {:reply, {:error, reason}, state}
  end
end

defp validate_title(title) do
  cond do
    not is_binary(title) ->
      {:error, :invalid_title}
    String.trim(title) == "" ->
      {:error, {:invalid_title, "Title cannot be empty"}}
    String.length(title) > 255 ->
      {:error, {:invalid_title, "Title too long (max 255 characters)"}}
    true ->
      :ok
  end
end

defp validate_actor_id(opts) do
  case Keyword.get(opts, :actor_id) do
    nil -> {:error, :missing_actor_id}
    "" -> {:error, :missing_actor_id}
    _actor_id -> :ok
  end
end

defp generate_task_id do
  UUID.uuid4()
end

defp create_task_stream(task_id, title, opts) do
  # Use correct Event Store API
  case Ipa.EventStore.start_stream("task", task_id) do
    :ok ->
      # Append task_created event with audit trail
      event_data = %{
        "title" => title,
        "description" => opts[:description],
        "metadata" => opts[:metadata]
      }

      Ipa.EventStore.append(
        task_id,
        "task_created",
        event_data,
        actor_id: opts[:actor_id],
        correlation_id: opts[:correlation_id]
      )

    {:error, reason} ->
      {:error, reason}
  end
end

defp insert_task_metadata(task_id, title, opts) do
  now = System.system_time(:second)

  metadata = %{
    task_id: task_id,
    title: title,
    description: opts[:description],
    status: "inactive",
    phase: "spec_clarification",
    created_at: now,
    updated_at: now,
    created_by: opts[:actor_id]
  }

  case Ipa.Central.Tasks.insert(metadata) do
    {:ok, _} -> :ok
    {:error, reason} -> {:error, reason}
  end
end
```

### Pod Lifecycle with Race Condition Protection

```elixir
def handle_call({:start_pod, task_id, opts}, _from, state) do
  # P0-3 FIX: Idempotent check first
  if Map.has_key?(state.monitors, task_id) do
    {:reply, {:error, :already_started}, state}
  else
    # Verify task exists
    case task_exists?(task_id) do
      false ->
        {:reply, {:error, :task_not_found}, state}

      true ->
        # Start pod via Pod Supervisor
        case Ipa.PodSupervisor.start_pod(task_id) do
          {:ok, pid} ->
            # Monitor pod for crashes
            ref = Process.monitor(pid)
            new_monitors = Map.put(state.monitors, task_id, ref)

            # Update tasks table status
            update_task_status(task_id, "active")

            {:reply, {:ok, pid}, %{state | monitors: new_monitors}}

          {:error, :already_started} = error ->
            # P0-3 FIX: Handle race condition gracefully
            Logger.debug("Pod already started for task #{task_id}, this is OK")
            {:reply, error, state}

          {:error, reason} = error ->
            {:reply, error, state}
        end
    end
  end
end

def handle_call({:stop_pod, task_id, opts}, _from, state) do
  case Map.get(state.monitors, task_id) do
    nil ->
      # Not monitoring - might not be running
      case Ipa.PodSupervisor.stop_pod(task_id) do
        :ok ->
          update_task_status(task_id, "inactive")
          {:reply, :ok, state}
        error ->
          {:reply, error, state}
      end

    ref ->
      # P1-5 FIX: Demonitor to avoid receiving DOWN message
      Process.demonitor(ref, [:flush])

      case Ipa.PodSupervisor.stop_pod(task_id) do
        :ok ->
          new_monitors = Map.delete(state.monitors, task_id)
          update_task_status(task_id, "inactive")
          {:reply, :ok, %{state | monitors: new_monitors}}

        error ->
          # Stop failed - keep monitoring
          {:reply, error, state}
      end
  end
end

defp task_exists?(task_id) do
  case Ipa.Central.Tasks.get(task_id) do
    {:ok, _task} -> true
    {:error, :not_found} -> false
  end
end

defp update_task_status(task_id, status) do
  Ipa.Central.Tasks.update(task_id, %{
    status: status,
    updated_at: System.system_time(:second)
  })
end
```

### Pod Crash Detection (P0-5 FIX)

```elixir
def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
  # P0-5 FIX: Properly find task_id and handle nil case
  case find_task_by_monitor_ref(state.monitors, ref) do
    nil ->
      # Unknown monitor - this is a bug, log and continue
      Logger.error("Received DOWN for unknown monitor ref: #{inspect(ref)}")
      {:noreply, state}

    task_id ->
      Logger.warning("Pod crashed for task #{task_id}: #{inspect(reason)}")

      # Remove monitor
      new_monitors = Map.delete(state.monitors, task_id)

      # Record crash
      new_crash_history = record_crash(state.crash_history, task_id)

      # Update task status
      update_task_status(task_id, "inactive")

      # Decide on restart
      new_state = %{state | monitors: new_monitors, crash_history: new_crash_history}

      if should_auto_restart?(new_state, task_id) do
        Logger.info("Auto-restarting pod for task #{task_id}")
        GenServer.cast(self(), {:restart_pod, task_id, %{}})
      end

      {:noreply, new_state}
  end
end

# P0-5 FIX: Define the helper function
defp find_task_by_monitor_ref(monitors, ref) do
  Enum.find_value(monitors, fn {task_id, monitor_ref} ->
    if monitor_ref == ref, do: task_id, else: nil
  end)
end

defp record_crash(crash_history, task_id) do
  now = System.system_time(:second)
  existing = Map.get(crash_history, task_id, [])
  Map.put(crash_history, task_id, [now | existing])
end

defp should_auto_restart?(state, task_id) do
  config = state.config

  # Check if auto-restart is enabled
  unless config.auto_restart_on_crash, do: false

  # Check crash frequency
  recent_crashes = get_recent_crashes(
    state.crash_history,
    task_id,
    config.restart_window_seconds
  )

  length(recent_crashes) < config.max_restart_attempts
end

defp get_recent_crashes(crash_history, task_id, window_seconds) do
  now = System.system_time(:second)
  cutoff = now - window_seconds

  crash_history
  |> Map.get(task_id, [])
  |> Enum.filter(&(&1 >= cutoff))
end
```

### Pod Supervisor Monitoring (P1-6 FIX)

```elixir
# Handle PodSupervisor crash
def handle_info({:DOWN, ref, :process, _pid, reason}, %{pod_supervisor_ref: ref} = state) do
  Logger.error("PodSupervisor crashed: #{inspect(reason)}")

  # Clear all monitors (pods are gone)
  new_state = %{state | monitors: %{}, pod_supervisor_ref: nil}

  # Update all active tasks to inactive
  update_all_active_tasks_to_inactive()

  # Wait for supervisor to restart PodSupervisor
  Process.send_after(self(), :reconnect_pod_supervisor, 100)

  {:noreply, new_state}
end

def handle_info(:reconnect_pod_supervisor, state) do
  case Process.whereis(Ipa.PodSupervisor) do
    nil ->
      # Not restarted yet, retry
      Process.send_after(self(), :reconnect_pod_supervisor, 100)
      {:noreply, state}

    pid ->
      ref = Process.monitor(pid)
      Logger.info("Reconnected to PodSupervisor")
      {:noreply, %{state | pod_supervisor_ref: ref}}
  end
end

defp update_all_active_tasks_to_inactive do
  Ipa.Central.Tasks.update_where(%{status: "active"}, %{status: "inactive"})
end
```

### Crash History Cleanup (P1-8 FIX)

```elixir
def handle_info(:cleanup_crash_history, state) do
  now = System.system_time(:second)
  cutoff = now - :timer.hours(24)  # Keep last 24 hours

  new_crash_history = state.crash_history
    |> Enum.map(fn {task_id, timestamps} ->
      recent = Enum.filter(timestamps, &(&1 >= cutoff))
      {task_id, recent}
    end)
    |> Enum.reject(fn {_task_id, timestamps} -> Enum.empty?(timestamps) end)
    |> Map.new()

  Logger.debug("Cleaned up crash history: #{map_size(state.crash_history)} -> #{map_size(new_crash_history)} entries")

  # Schedule next cleanup
  schedule_crash_history_cleanup()

  {:noreply, %{state | crash_history: new_crash_history}}
end
```

## State Aggregation (P0-1 and P1-1 FIX)

```elixir
def get_task(task_id) do
  GenServer.call(__MODULE__, {:get_task, task_id}, @call_timeout)
end

def handle_call({:get_task, task_id}, _from, state) do
  result = case Ipa.PodSupervisor.pod_running?(task_id) do
    true ->
      # P0-1 FIX: Query Pod State Manager for live state
      get_task_from_pod_state_manager(task_id)

    false ->
      # P0-1 FIX: Query metadata table for inactive task
      get_task_from_metadata(task_id)
  end

  {:reply, result, state}
end

defp get_task_from_pod_state_manager(task_id) do
  # Query Pod State Manager via Registry
  case Registry.lookup(Ipa.PodRegistry, {:pod_state, task_id}) do
    [{pid, _}] ->
      # Get live state from Pod State Manager
      case GenServer.call(pid, :get_state) do
        {:ok, state} ->
          {:ok, pod_pid} = Ipa.PodSupervisor.get_pod_pid(task_id)

          task = %{
            task_id: state.task_id,
            title: state.title || get_title_from_metadata(task_id),
            description: state.description,
            phase: state.phase,
            status: :active,
            created_at: state.created_at,
            updated_at: state.updated_at,
            created_by: get_created_by_from_metadata(task_id),
            pod_pid: pod_pid,
            pod_status: :running,
            version: state.version
          }

          {:ok, task}

        {:error, reason} ->
          {:error, reason}
      end

    [] ->
      # Pod State Manager not found, fall back to metadata
      get_task_from_metadata(task_id)
  end
end

defp get_task_from_metadata(task_id) do
  case Ipa.Central.Tasks.get(task_id) do
    {:ok, metadata} ->
      task = %{
        task_id: metadata.task_id,
        title: metadata.title,
        description: metadata.description,
        phase: String.to_atom(metadata.phase),
        status: String.to_atom(metadata.status),
        created_at: metadata.created_at,
        updated_at: metadata.updated_at,
        created_by: metadata.created_by,
        pod_pid: nil,
        pod_status: :stopped,
        version: nil
      }

      {:ok, task}

    {:error, :not_found} ->
      {:error, :not_found}
  end
end

defp get_title_from_metadata(task_id) do
  case Ipa.Central.Tasks.get(task_id) do
    {:ok, metadata} -> metadata.title
    _ -> nil
  end
end

defp get_created_by_from_metadata(task_id) do
  case Ipa.Central.Tasks.get(task_id) do
    {:ok, metadata} -> metadata.created_by
    _ -> nil
  end
end
```

## Task Listing (P1-2 FIX)

```elixir
def list_tasks(opts \\ []) do
  GenServer.call(__MODULE__, {:list_tasks, opts}, @call_timeout)
end

def handle_call({:list_tasks, opts}, _from, state) do
  # P1-2 FIX: Use metadata table for efficient listing
  result = case Ipa.Central.Tasks.list(opts) do
    {:ok, metadata_list} ->
      # Enrich active tasks with live state
      tasks = Enum.map(metadata_list, fn metadata ->
        if metadata.status == "active" do
          # Try to get live state from Pod State Manager
          case get_task_from_pod_state_manager(metadata.task_id) do
            {:ok, live_task} -> live_task
            _ -> metadata_to_task_map(metadata)
          end
        else
          metadata_to_task_map(metadata)
        end
      end)

      {:ok, tasks}

    {:error, reason} ->
      {:error, reason}
  end

  {:reply, result, state}
end

defp metadata_to_task_map(metadata) do
  %{
    task_id: metadata.task_id,
    title: metadata.title,
    description: metadata.description,
    phase: String.to_atom(metadata.phase),
    status: String.to_atom(metadata.status),
    created_at: metadata.created_at,
    updated_at: metadata.updated_at,
    created_by: metadata.created_by,
    pod_pid: nil,
    pod_status: :stopped,
    version: nil
  }
end
```

## Configuration

```elixir
# config/config.exs
config :ipa, Ipa.Central.TaskManager,
  # Auto-restart pods on crash
  auto_restart_on_crash: false,

  # Max restart attempts within window
  max_restart_attempts: 3,

  # Time window for restart attempts (seconds)
  restart_window_seconds: 60,

  # Default pagination limit
  default_list_limit: 100,

  # Max pagination limit
  max_list_limit: 1000

# config/test.exs
config :ipa, Ipa.Central.TaskManager,
  auto_restart_on_crash: false,
  max_restart_attempts: 1,
  restart_window_seconds: 10,
  default_list_limit: 10,
  max_list_limit: 100
```

## Supervision Tree Integration (P1-4 FIX)

```elixir
# In lib/ipa/application.ex
defmodule Ipa.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Event Store
      Ipa.EventStore.Repo,

      # Pod infrastructure (order matters - Registry before Supervisor)
      {Registry, keys: :unique, name: Ipa.PodRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Ipa.PodSupervisor},

      # Central Management (THIS COMPONENT) - P1-4 FIX
      {Ipa.Central.TaskManager, []},

      # Phoenix PubSub
      {Phoenix.PubSub, name: Ipa.PubSub},

      # Web endpoints
      IpaWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Ipa.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

# In lib/ipa/central/task_manager.ex
# P1-4 FIX: Proper child_spec
def child_spec(opts) do
  %{
    id: __MODULE__,
    start: {__MODULE__, :start_link, [opts]},
    type: :worker,
    restart: :permanent,  # Should always restart
    shutdown: 5_000
  }
end
```

## Integration with Other Components

### With Event Store (1.1)

**Uses Event Store For**:
- Creating task streams: `start_stream("task", task_id)`
- Appending lifecycle events with audit trail
- Checking stream existence (indirectly via tasks table)

**Does NOT Use Event Store For**:
- ❌ Reading/interpreting raw events
- ❌ Listing streams
- ❌ Building state projections

### With Pod Supervisor (2.1)

**Uses Pod Supervisor For**:
- Starting pods: `start_pod(task_id)`
- Stopping pods: `stop_pod(task_id)`
- Querying pod status: `pod_running?(task_id)`, `get_pod_pid(task_id)`
- Monitoring Pod Supervisor process for resilience

### With Pod State Manager (2.2)

**Uses Pod State Manager For**:
- Querying live state for active pods via Registry lookup
- Getting current phase, version, and state data

**Communication Pattern**:
```elixir
# Look up Pod State Manager via Registry
[{pid, _}] = Registry.lookup(Ipa.PodRegistry, {:pod_state, task_id})

# Query state directly
{:ok, state} = GenServer.call(pid, :get_state)
```

### With Central Dashboard (3.2)

**Provides API For**:
- Creating tasks
- Listing/filtering tasks
- Starting/stopping pods
- Getting task details
- Completing/canceling tasks

## Error Handling

### Common Errors

All errors now include proper context and handling:

- `:invalid_title` - Title validation failed
- `:missing_actor_id` - Required actor_id not provided
- `:missing_reason` - Required reason not provided (cancel_task)
- `:task_not_found` - Task doesn't exist
- `:already_started` - Pod already running (safe, idempotent)
- `:already_completed` - Task already completed
- `:already_cancelled` - Task already cancelled
- `:not_running` - Pod not running
- `:event_store_unavailable` - Cannot reach Event Store

### Resilience Features

1. **Pod Supervisor Monitoring** - Detects and recovers from Pod Supervisor crashes
2. **Idempotent Operations** - start_pod is safe to call multiple times
3. **Proper Demonitor** - Prevents memory leaks in monitors map
4. **Crash History Cleanup** - Prevents unbounded growth
5. **Timeouts** - All GenServer calls have 30-second timeout
6. **Graceful Degradation** - Falls back to metadata if Pod State Manager unavailable

## Testing Requirements

### Unit Tests

1. **Task Creation**
   - ✅ Validates title (empty, too long, valid)
   - ✅ Requires actor_id
   - ✅ Creates stream with correct API
   - ✅ Inserts metadata into tasks table
   - ✅ Handles Event Store errors

2. **Pod Lifecycle**
   - ✅ Starts pod with idempotency check
   - ✅ Handles :already_started gracefully
   - ✅ Monitors pod process
   - ✅ Stops pod with demonitor
   - ✅ Updates tasks table status

3. **State Aggregation**
   - ✅ Queries Pod State Manager for active pods
   - ✅ Queries metadata table for inactive tasks
   - ✅ Falls back gracefully if Pod State Manager unavailable

4. **Task Listing**
   - ✅ Lists from metadata table efficiently
   - ✅ Enriches active tasks with live state
   - ✅ Filters work correctly
   - ✅ Pagination works

5. **Crash Detection**
   - ✅ Finds task by monitor ref
   - ✅ Handles nil case
   - ✅ Records crash history
   - ✅ Auto-restarts if configured
   - ✅ Respects max restart attempts

### Integration Tests

1. **Pod Supervisor Resilience**
   - ✅ Detects Pod Supervisor crash
   - ✅ Clears monitors
   - ✅ Reconnects after restart
   - ✅ Updates task statuses

2. **Concurrent Operations**
   - ✅ Race condition test: 10 concurrent start_pod calls
   - ✅ Only one succeeds, others get :already_started
   - ✅ Monitor map stays consistent

3. **Memory Leak Prevention**
   - ✅ Monitors cleaned up on stop_pod
   - ✅ Crash history cleaned up periodically

4. **End-to-End**
   - ✅ Create → start pod → query (live state) → stop → query (metadata)
   - ✅ Create → pod crashes → auto-restart works
   - ✅ Create → complete → status updated

### Performance Tests

1. **List Performance**
   - ✅ list_tasks with 100 tasks < 100ms
   - ✅ list_tasks with 1000 tasks < 500ms
   - ✅ Filtering by status/phase efficient

2. **State Aggregation**
   - ✅ get_task < 10ms per task
   - ✅ Active pod query < 5ms

## Acceptance Criteria

- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [ ] Can create task with audit trail
- [ ] Task creation validates input
- [ ] Can start pod (idempotent)
- [ ] Can stop pod (with demonitor)
- [ ] State aggregation uses Pod State Manager (not events)
- [ ] Task listing uses metadata table (efficient)
- [ ] Pod crashes detected and handled
- [ ] Auto-restart works with frequency limits
- [ ] Pod Supervisor crash handled gracefully
- [ ] Crash history cleaned up periodically
- [ ] All tests pass

## Migration & Deployment

### Database Migration

```elixir
# priv/repo/migrations/XXXXXX_create_tasks_table.exs
defmodule Ipa.Repo.Migrations.CreateTasksTable do
  use Ecto.Migration

  def change do
    create table(:tasks, primary_key: false) do
      add :task_id, :text, primary_key: true
      add :title, :text, null: false
      add :description, :text
      add :status, :text, null: false
      add :phase, :text, null: false
      add :created_at, :integer, null: false
      add :updated_at, :integer, null: false
      add :created_by, :text
    end

    create index(:tasks, [:status])
    create index(:tasks, [:phase])
    create index(:tasks, [:created_at])
    create index(:tasks, [:updated_at])
    create index(:tasks, [:created_by])

    # Foreign key to streams table
    execute "ALTER TABLE tasks ADD FOREIGN KEY (task_id) REFERENCES streams(id) ON DELETE CASCADE"
  end
end
```

### Deployment Steps

1. Run database migration
2. Add `Ipa.Central.TaskManager` to supervision tree
3. Configure auto-restart behavior
4. No downtime required (component is new)

## Future Enhancements

### Phase 2

1. **Task Templates** - Pre-defined task configurations
2. **Task Scheduling** - Cron-like scheduled execution
3. **Task Dependencies** - Task A depends on Task B
4. **Task Priorities** - Priority queue for execution
5. **Task Analytics** - Duration, success rates, bottlenecks
6. **Task Archival** - Move old tasks to archive table
7. **Telemetry** - Comprehensive instrumentation
8. **Circuit Breaker** - For Event Store resilience

## References

- Elixir GenServer: https://hexdocs.pm/elixir/GenServer.html
- Process Monitoring: https://hexdocs.pm/elixir/Process.html#monitor/1
- Registry: https://hexdocs.pm/elixir/Registry.html
- Event Sourcing Patterns: https://martinfowler.com/eaaDev/EventSourcing.html
- Ecto Schemas: https://hexdocs.pm/ecto/Ecto.Schema.html
