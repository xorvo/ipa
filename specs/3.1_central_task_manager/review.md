# Architectural Review: Central Task Manager (Component 3.1)

**Date**: 2025-11-06
**Reviewer**: Claude (System Architecture Expert)
**Component**: 3.1 Central Task Manager
**Version**: 1.0 (Initial Review)

---

## Executive Summary

**Overall Score**: 6.5/10
**Approval Status**: ⚠️ **NEEDS REVISION** - Requires critical fixes before implementation
**Recommendation**: Address all P0 and P1 issues before proceeding with implementation

### Issue Summary
- **Critical (P0)**: 5 issues
- **Major (P1)**: 8 issues
- **Minor (P2)**: 4 issues

### Key Concerns
1. **Severe architectural boundary violations** - Component assumes Layer 2 responsibilities
2. **Dangerous state aggregation** - Reading raw events violates event sourcing patterns
3. **Missing critical dependencies** - Relies on non-existent Event Store functions
4. **Inconsistent API design** - Public API doesn't align with facade pattern
5. **Race conditions** - Inadequate handling of concurrent pod operations

---

## 1. Architecture Overview

### Component Position

The Central Task Manager is positioned as **Layer 3: Central Management**, intended to be:
- Primary entry point for task operations
- Coordinator between Event Store (Layer 1) and Pod Supervisor (Layer 2)
- High-level API for Central Dashboard UI

### Stated Responsibilities
- Task creation and initialization in Event Store
- Pod lifecycle coordination
- Task listing and querying
- Pod crash detection and recovery
- Centralized task state aggregation

### Actual Architecture
The component has a clean separation intent but the implementation violates several architectural boundaries as detailed below.

---

## 2. Critical Issues (P0)

### **P0-1: Severe Architectural Boundary Violation - Direct Event Reading**

**Severity**: Critical
**Issue**: The `get_task/1` and `list_tasks/1` functions directly read and interpret events from the Event Store, bypassing Pod State Manager entirely.

**Code Location**: Lines 489-557 (`get_task/1`, `build_task_from_events/1`, `infer_phase_from_events/1`, `infer_status_from_events/1`)

**Why This Is Wrong**:
1. **Duplicates Layer 2 Logic**: Lines 516-557 duplicate event projection logic that already exists in Pod State Manager (2.2)
2. **Violates Single Source of Truth**: Pod State Manager is the authoritative source for task state within a pod, not raw events
3. **Event Schema Coupling**: Central Manager now must understand event structure (`transition_approved`, etc.), creating tight coupling to event schema
4. **Inconsistent State**: Active pods have in-memory state (via Pod State Manager), but Central Manager rebuilds state from events, potentially showing stale/inconsistent data
5. **Performance Problem**: Reading all events for every task listing is inefficient (O(n*m) where n=tasks, m=events per task)

**Correct Architecture**:
```
Layer 3 (Central Manager)
  ↓ asks Pod Supervisor
Layer 2 (Pod Supervisor)
  ↓ queries Pod State Manager
Layer 2 (Pod State Manager)
  ↓ returns in-memory state
```

**Instead of**:
```
Layer 3 (Central Manager)
  ↓ reads raw events
Layer 1 (Event Store)
  ↓ returns events
Layer 3 (Central Manager) interprets events ← WRONG!
```

**Solution**:
- For **active pods**: Query Pod State Manager via registry lookup
- For **inactive pods**: Store minimal metadata in a separate `tasks` table (stream_type, title, phase, status, created_at, updated_at)
- Central Manager should NEVER interpret raw events

**Implementation Example**:
```elixir
def get_task(task_id) do
  case Ipa.PodSupervisor.pod_running?(task_id) do
    true ->
      # Pod is active - get live state from Pod State Manager
      case Ipa.Pod.State.get_state(task_id) do
        {:ok, state} ->
          {:ok, pid} = Ipa.PodSupervisor.get_pod_pid(task_id)
          {:ok, Map.merge(state, %{
            pod_pid: pid,
            pod_status: :running
          })}
        {:error, reason} ->
          {:error, reason}
      end

    false ->
      # Pod is inactive - get metadata from tasks table
      case get_task_metadata(task_id) do
        {:ok, metadata} ->
          {:ok, Map.merge(metadata, %{
            pod_pid: nil,
            pod_status: :stopped
          })}
        {:error, reason} ->
          {:error, reason}
      end
  end
end
```

**Impact**: Critical - violates core event sourcing principles and architectural layering

---

### **P0-2: Missing Critical Event Store Functions**

**Severity**: Critical
**Issue**: The spec assumes Event Store (1.1) provides `start_stream/1` and `list_streams/1`, but these functions don't exist in the Event Store spec.

**Missing Functions**:
1. **`start_stream/1`** (line 636): Used in task creation
2. **`list_streams/1`** (line 567): Used in task listing

**Event Store Actual API** (from 1.1 spec):
- `start_stream/2` - Requires both stream_type AND stream_id
- No `list_streams/1` function - Only has generic stream reading

**Why This Is Wrong**:
- Central Manager assumes it can create streams with auto-generated IDs
- Central Manager assumes it can list all task streams
- These assumptions are not supported by Event Store API

**Solution**:
1. Use `start_stream/2` with explicit stream_id generation:
   ```elixir
   task_id = UUID.uuid4()
   Ipa.EventStore.start_stream("task", task_id)
   ```

2. Add a lightweight `tasks` metadata table:
   ```sql
   CREATE TABLE tasks (
     task_id TEXT PRIMARY KEY,
     title TEXT NOT NULL,
     status TEXT NOT NULL,  -- 'active', 'inactive', 'completed', 'cancelled'
     phase TEXT NOT NULL,   -- 'spec_clarification', 'planning', etc.
     created_at INTEGER NOT NULL,
     updated_at INTEGER NOT NULL,
     created_by TEXT,
     FOREIGN KEY (task_id) REFERENCES streams(id) ON DELETE CASCADE
   );

   CREATE INDEX idx_tasks_status ON tasks(status);
   CREATE INDEX idx_tasks_phase ON tasks(phase);
   CREATE INDEX idx_tasks_created_at ON tasks(created_at);
   ```

3. Maintain this table on task lifecycle events:
   - INSERT on `create_task/2`
   - UPDATE on `cancel_task/2`, `complete_task/1`
   - Pod State Manager updates on phase transitions

**Impact**: Critical - component cannot be implemented as specified

---

### **P0-3: Race Condition in Pod Lifecycle Management**

**Severity**: Critical
**Issue**: The `start_pod/1` implementation (lines 404-428) has a race condition between checking pod status and starting pod.

**Code Flow**:
```elixir
def handle_call({:start_pod, task_id}, _from, state) do
  case Ipa.EventStore.stream_exists?(task_id) do  # Check 1
    false -> {:error, :task_not_found}
    true ->
      case Ipa.PodSupervisor.start_pod(task_id) do  # Check 2 (inside PodSupervisor)
        {:ok, pid} ->
          # Race: Another process could start pod between Check 1 and here
          ref = Process.monitor(pid)
          # ...
```

**Race Condition**:
1. Process A calls `start_pod(task_id)` → verifies stream exists
2. Process B calls `start_pod(task_id)` → verifies stream exists
3. Process A calls `Ipa.PodSupervisor.start_pod(task_id)` → succeeds
4. Process B calls `Ipa.PodSupervisor.start_pod(task_id)` → fails with `:already_started`
5. But Process A has already monitored the pod - what about Process B's monitor entry?

**Additional Problem**: No handling for `:already_started` error case

**Solution**:
```elixir
def handle_call({:start_pod, task_id}, _from, state) do
  # Check if already monitored (idempotent)
  if Map.has_key?(state.monitors, task_id) do
    {:reply, {:error, :already_started}, state}
  else
    case Ipa.EventStore.stream_exists?(task_id) do
      false ->
        {:reply, {:error, :task_not_found}, state}
      true ->
        case Ipa.PodSupervisor.start_pod(task_id) do
          {:ok, pid} ->
            ref = Process.monitor(pid)
            new_monitors = Map.put(state.monitors, task_id, ref)
            {:reply, {:ok, pid}, %{state | monitors: new_monitors}}

          {:error, :already_started} = error ->
            # Pod was started by another process - this is OK
            {:reply, error, state}

          error ->
            {:reply, error, state}
        end
    end
  end
end
```

**Impact**: Critical - can cause crashes and inconsistent monitor state

---

### **P0-4: Inconsistent Public API Design**

**Severity**: Critical
**Issue**: The public API (`Ipa.CentralManager`) claims to be a facade but has inconsistent function signatures and missing critical options.

**Problems**:

1. **Inconsistent parameter patterns**:
   ```elixir
   create_task(title, opts)      # Uses opts
   cancel_task(task_id, reason)  # Reason is positional
   # Should be: cancel_task(task_id, opts) with :reason key
   ```

2. **No `actor_id` tracking** for task operations:
   - `create_task/2` has `:created_by` but doesn't pass to Event Store as `actor_id`
   - `cancel_task/2`, `complete_task/1` have no actor attribution
   - This breaks audit trail that Event Store supports

3. **Missing correlation tracking**:
   - No way to pass `correlation_id` for tracing
   - Central Manager operations are not traceable across system

**Why This Matters**:
- Event Store (1.1) and Pod State Manager (2.2) both support `actor_id` and `correlation_id`
- Breaking this chain at Layer 3 means audit trail is incomplete
- Can't trace "who completed this task" or "which request caused this cancellation"

**Correct Design**:
```elixir
# Consistent opts-based API
@spec create_task(title :: String.t(), opts :: keyword()) ::
  {:ok, task_id :: String.t()} | {:error, term()}

@spec cancel_task(task_id :: String.t(), opts :: keyword()) ::
  :ok | {:error, term()}
# opts: :reason (required), :actor_id, :correlation_id

@spec complete_task(task_id :: String.t(), opts :: keyword()) ::
  :ok | {:error, term()}
# opts: :actor_id, :correlation_id

# Always pass actor_id to Event Store
Ipa.EventStore.append(
  task_id,
  "task_cancelled",
  %{reason: reason},
  actor_id: opts[:actor_id] || "system",
  correlation_id: opts[:correlation_id]
)
```

**Impact**: Critical - breaks audit trail and API consistency

---

### **P0-5: Dangerous Pod Crash Detection Logic**

**Severity**: Critical
**Issue**: The `handle_info({:DOWN, ...})` implementation (lines 431-452) uses `find_task_by_ref/2` but this function is not defined, and the logic has flaws.

**Code**:
```elixir
def handle_info({:DOWN, ref, :process, pid, reason}, state) do
  # Find task_id for this monitor
  task_id = find_task_by_ref(state.monitors, ref)  # UNDEFINED FUNCTION

  Logger.warning("Pod crashed for task #{task_id}: #{inspect(reason)}")
  # ...
```

**Problems**:
1. **Undefined function**: `find_task_by_ref/2` is used but never defined in the spec
2. **No nil handling**: What if `task_id` is nil? (ref not in monitors map)
3. **Monitor cleanup timing**: Removes monitor before deciding on restart, but restart needs to re-monitor
4. **Race condition**: Between crash detection and restart, another process might start the pod

**Why This Will Crash**:
```elixir
# This will raise UndefinedFunctionError
task_id = find_task_by_ref(state.monitors, ref)  # BOOM!

# Even if it existed, this could be nil:
Logger.warning("Pod crashed for task #{task_id}: ...")  # String interpolation with nil
```

**Correct Implementation**:
```elixir
def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
  case find_task_by_monitor_ref(state.monitors, ref) do
    nil ->
      # Unknown monitor - this is a bug, log and continue
      require Logger
      Logger.error("Received DOWN for unknown monitor ref: #{inspect(ref)}")
      {:noreply, state}

    task_id ->
      Logger.warning("Pod crashed for task #{task_id}: #{inspect(reason)}")

      # Remove monitor
      new_monitors = Map.delete(state.monitors, task_id)

      # Record crash
      new_crash_history = record_crash(state.crash_history, task_id)

      # Decide on restart
      new_state = %{state | monitors: new_monitors, crash_history: new_crash_history}

      if should_auto_restart?(new_state, task_id) do
        Logger.info("Auto-restarting pod for task #{task_id}")
        # Use cast to avoid blocking this handler
        GenServer.cast(self(), {:restart_pod, task_id})
      end

      {:noreply, new_state}
  end
end

# Helper function to find task_id by monitor ref
defp find_task_by_monitor_ref(monitors, ref) do
  Enum.find_value(monitors, fn {task_id, monitor_ref} ->
    if monitor_ref == ref, do: task_id, else: nil
  end)
end
```

**Impact**: Critical - undefined function will crash the GenServer, destroying all pod monitors

---

## 3. Major Issues (P1)

### **P1-1: State Aggregation Ignores Pod State Manager**

**Severity**: Major
**Issue**: The `get_task/1` function checks if pod is running (line 501) but then doesn't query Pod State Manager for actual state.

**Code**:
```elixir
pod_status = case Ipa.PodSupervisor.pod_running?(task_id) do
  true ->
    {:ok, pid} = Ipa.PodSupervisor.get_pod_pid(task_id)
    %{pod_pid: pid, pod_status: :running}
  false ->
    %{pod_pid: nil, pod_status: :stopped}
end
```

**What's Missing**:
- If pod is running, should query `Ipa.Pod.State.get_state(task_id)` for current state
- Current implementation shows stale state from events instead of live state
- This means users see outdated state even though pod has live, up-to-date state

**Example of Problem**:
```
1. Task is in :planning phase (from events)
2. Pod starts, agent transitions to :development
3. User calls get_task(task_id)
4. Central Manager reads events, still shows :planning
5. User is confused - UI shows old state
```

**Solution**: See P0-1 implementation example

**Impact**: Major - returns incorrect state for active tasks

---

### **P1-2: Missing Metadata Table for Inactive Tasks**

**Severity**: Major
**Issue**: The spec has no strategy for efficiently listing tasks that don't have active pods.

**Current Approach** (lines 565-593):
```elixir
def list_tasks(opts \\ []) do
  {:ok, streams} = Ipa.EventStore.list_streams(stream_type: "task")

  tasks = streams
    |> Enum.map(fn stream_id ->
      case get_task(stream_id) do  # Reads ALL events for EACH task!
        {:ok, task} -> task
        _ -> nil
      end
    end)
```

**Problems**:
1. Reads all events for all tasks (even inactive ones)
2. No way to filter by status before reading events
3. Performance: O(n*m) where n=tasks, m=events per task
4. Doesn't scale beyond ~100 tasks

**Why This Is Bad**:
- 100 tasks with 50 events each = 5,000 event reads just to list tasks
- Can't filter by status without reading all events first
- Each listing re-processes all event history

**Solution**: Add tasks metadata table (see P0-2)

**Impact**: Major - component cannot scale without metadata table

---

### **P1-3: Task Creation Doesn't Validate Title**

**Severity**: Major
**Issue**: The `create_task/2` function claims to validate title (line 139) but no validation logic is shown.

**Error Listed** (line 139):
```elixir
{:error, :invalid_title} - Title is empty or invalid
```

**Implementation** (lines 123-135): No validation!

**Should Include**:
```elixir
defp validate_title(title) do
  cond do
    not is_binary(title) ->
      {:error, :invalid_title}
    String.trim(title) == "" ->
      {:error, :invalid_title}
    String.length(title) > 255 ->
      {:error, {:invalid_title, "Title too long (max 255 characters)"}}
    true ->
      :ok
  end
end
```

**Impact**: Major - missing input validation allows invalid data

---

### **P1-4: No Supervision Tree Integration Example**

**Severity**: Major
**Issue**: The spec shows supervision tree wiring (lines 839-867) but has critical error in ordering.

**Code**:
```elixir
children = [
  Ipa.EventStore.Repo,
  {Registry, keys: :unique, name: Ipa.PodRegistry},
  {DynamicSupervisor, strategy: :one_for_one, name: Ipa.PodSupervisor},

  # Central Management (THIS COMPONENT)
  Ipa.Central.TaskManager,  # ← WRONG! Should be supervised

  {Phoenix.PubSub, name: Ipa.PubSub},
  IpaWeb.Endpoint
]
```

**Problems**:
1. `Ipa.Central.TaskManager` is not wrapped in proper child_spec
2. No restart strategy specified
3. No shutdown timeout specified

**Correct Implementation**:
```elixir
children = [
  Ipa.EventStore.Repo,
  {Registry, keys: :unique, name: Ipa.PodRegistry},
  {DynamicSupervisor, strategy: :one_for_one, name: Ipa.PodSupervisor},

  # Central Management (THIS COMPONENT)
  {Ipa.Central.TaskManager, name: Ipa.Central.TaskManager},

  {Phoenix.PubSub, name: Ipa.PubSub},
  IpaWeb.Endpoint
]

# In Ipa.Central.TaskManager
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

**Impact**: Major - component may not restart correctly

---

### **P1-5: Stop Pod Doesn't Demonitor**

**Severity**: Major
**Issue**: The `stop_pod/1` implementation is not shown but the pseudocode (lines 183-194) mentions "Demonitor pod process" without showing how.

**Expected Code**:
```elixir
def handle_call({:stop_pod, task_id}, _from, state) do
  case Map.get(state.monitors, task_id) do
    nil ->
      # Not monitoring - might not be running
      case Ipa.PodSupervisor.stop_pod(task_id) do
        :ok -> {:reply, :ok, state}
        error -> {:reply, error, state}
      end

    ref ->
      # Demonitor to avoid receiving DOWN message
      Process.demonitor(ref, [:flush])

      case Ipa.PodSupervisor.stop_pod(task_id) do
        :ok ->
          new_monitors = Map.delete(state.monitors, task_id)
          {:reply, :ok, %{state | monitors: new_monitors}}
        error ->
          # Stop failed - keep monitoring
          {:reply, error, state}
      end
  end
end
```

**Why This Matters**:
- Without demonitor, Central Manager will receive `:DOWN` message for intentional stop
- Monitor map grows without cleanup
- Memory leak over time

**Impact**: Major - memory leak in monitors map

---

### **P1-6: No Handling for Pod Supervisor Failures**

**Severity**: Major
**Issue**: The spec doesn't address what happens if `Ipa.PodSupervisor` itself crashes or becomes unavailable.

**Scenarios Not Covered**:
1. PodSupervisor crashes while Central Manager is calling it
2. PodSupervisor is temporarily unavailable during restart
3. Registry becomes unavailable

**Why This Matters**:
- PodSupervisor is a single point of failure
- If it crashes, Central Manager has stale monitor data
- All monitored pods are effectively gone but monitors remain

**Should Add**:
```elixir
# In init/1, monitor the PodSupervisor
def init(_opts) do
  # Monitor PodSupervisor
  pod_supervisor_pid = Process.whereis(Ipa.PodSupervisor)
  if pod_supervisor_pid do
    Process.monitor(pod_supervisor_pid)
  end

  state = %__MODULE__{
    monitors: %{},
    config: load_config(),
    crash_history: %{},
    pod_supervisor_pid: pod_supervisor_pid
  }

  {:ok, state}
end

# Handle PodSupervisor crash
def handle_info({:DOWN, _ref, :process, pid, reason}, %{pod_supervisor_pid: pid} = state) do
  require Logger
  Logger.error("PodSupervisor crashed: #{inspect(reason)}")

  # Clear all monitors (pods are gone)
  new_state = %{state | monitors: %{}, pod_supervisor_pid: nil}

  # Wait for supervisor to restart PodSupervisor
  Process.send_after(self(), :reconnect_pod_supervisor, 100)

  {:noreply, new_state}
end

def handle_info(:reconnect_pod_supervisor, state) do
  case Process.whereis(Ipa.PodSupervisor) do
    nil ->
      # Not restarted yet
      Process.send_after(self(), :reconnect_pod_supervisor, 100)
      {:noreply, state}

    pid ->
      Process.monitor(pid)
      Logger.info("Reconnected to PodSupervisor")
      {:noreply, %{state | pod_supervisor_pid: pid}}
  end
end
```

**Impact**: Major - Central Manager becomes inoperable if PodSupervisor crashes

---

### **P1-7: No GenServer Timeout Configuration**

**Severity**: Major
**Issue**: All GenServer calls use default 5-second timeout, which may not be appropriate for all operations.

**Operations That May Need Longer Timeout**:
- `start_pod/1` - Pod startup can be slow with large event history
- `list_tasks/1` - Can be slow with many tasks
- `restart_pod/1` - Combines stop + start

**Should Add**:
```elixir
@timeout 30_000  # 30 seconds for slow operations

def start_pod(task_id) do
  GenServer.call(__MODULE__, {:start_pod, task_id}, @timeout)
end

def list_tasks(opts \\ []) do
  GenServer.call(__MODULE__, {:list_tasks, opts}, @timeout)
end
```

**Impact**: Major - operations can timeout unnecessarily

---

### **P1-8: Crash History Management Has No Cleanup**

**Severity**: Major
**Issue**: The crash_history map (line 393) grows unbounded - no cleanup for old crash records.

**Problem**:
```elixir
crash_history: %{
  "task-1" => [timestamp1, timestamp2, timestamp3, ...],  # Never cleaned up!
  "task-2" => [timestamp1, timestamp2, ...],
  # After 1000 tasks with crashes, this map has 1000 entries
}
```

**Solution**:
```elixir
# Periodic cleanup of old crash records
def init(_opts) do
  # Schedule cleanup every hour
  Process.send_after(self(), :cleanup_crash_history, :timer.hours(1))
  # ...
end

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

  # Schedule next cleanup
  Process.send_after(self(), :cleanup_crash_history, :timer.hours(1))

  {:noreply, %{state | crash_history: new_crash_history}}
end
```

**Impact**: Major - memory leak

---

## 4. Minor Issues (P2)

### **P2-1: No Task Archival Strategy**

**Severity**: Minor
**Issue**: Completed/cancelled tasks remain in active listings forever.

**Recommendation**: Add task archival:
- After 30 days, move completed tasks to `tasks_archived` table
- Provide `list_archived_tasks/1` function
- Allow restoring archived tasks if needed

---

### **P2-2: Missing Telemetry Events**

**Severity**: Minor
**Issue**: No telemetry instrumentation for monitoring.

**Should Add**:
```elixir
:telemetry.execute(
  [:ipa, :task, :created],
  %{count: 1},
  %{task_id: task_id}
)

:telemetry.execute(
  [:ipa, :pod, :started],
  %{duration: duration},
  %{task_id: task_id}
)

:telemetry.execute(
  [:ipa, :pod, :crashed],
  %{count: 1},
  %{task_id: task_id, reason: reason}
)
```

---

### **P2-3: No Circuit Breaker for Event Store**

**Severity**: Minor
**Issue**: If Event Store is slow/unavailable, Central Manager will timeout on every call.

**Recommendation**: Add circuit breaker pattern:
- Track Event Store failures
- Open circuit after N consecutive failures
- Return fast errors when circuit is open
- Periodically retry to close circuit

---

### **P2-4: Configuration Loading Not Shown**

**Severity**: Minor
**Issue**: The config (lines 598-620) shows configuration values but not how they're loaded in `init/1`.

**Should Add**:
```elixir
defp load_config do
  config = Application.get_env(:ipa, Ipa.Central.TaskManager, [])

  %{
    auto_restart_on_crash: Keyword.get(config, :auto_restart_on_crash, false),
    max_restart_attempts: Keyword.get(config, :max_restart_attempts, 3),
    restart_window_seconds: Keyword.get(config, :restart_window_seconds, 60)
  }
end
```

---

## 5. Risk Analysis

### Technical Debt Introduced

1. **Event Interpretation Logic**: If Central Manager directly interprets events, changes to event schema require updates in multiple places (Pod State Manager + Central Manager)

2. **Performance Bottleneck**: Reading all events for all tasks on every listing will not scale

3. **State Inconsistency**: Active tasks showing stale event-sourced state instead of live Pod State Manager state

### Scalability Concerns

- **Current Design**: O(n*m) for list_tasks where n=tasks, m=events per task
- **With Metadata Table**: O(n) for list_tasks where n=tasks
- **Breaking Point**: ~100-200 tasks with current design

### Maintenance Burden

- **High Coupling**: Central Manager coupled to event schema, Event Store, Pod Supervisor, and Registry
- **Hard to Test**: State aggregation logic requires complex setup of Event Store with realistic event sequences
- **Hard to Change**: Event schema changes require coordinated updates across multiple components

---

## 6. Recommendations

### Critical Path (Must Fix Before Implementation)

1. **Remove Event Interpretation Logic** (P0-1)
   - Delete `build_task_from_events/1`, `infer_phase_from_events/1`, `infer_status_from_events/1`
   - Query Pod State Manager for active tasks
   - Add tasks metadata table for inactive tasks

2. **Add Tasks Metadata Table** (P0-2)
   - Create migration for tasks table
   - Update on task lifecycle events
   - Use for listing/filtering

3. **Fix Race Conditions** (P0-3)
   - Add idempotency check in `start_pod/1`
   - Handle `:already_started` error case
   - Fix monitor map consistency

4. **Fix Public API** (P0-4)
   - Make all functions use consistent opts-based API
   - Add actor_id tracking to all mutating operations
   - Add correlation_id support

5. **Implement Crash Detection Correctly** (P0-5)
   - Define `find_task_by_monitor_ref/2`
   - Add nil handling
   - Fix monitor cleanup logic

### High Priority (Should Fix)

6. Query Pod State Manager for active pods (P1-1)
7. Add input validation (P1-3)
8. Fix supervision integration (P1-4)
9. Implement demonitor (P1-5)
10. Monitor PodSupervisor (P1-6)
11. Add timeouts (P1-7)
12. Cleanup crash history (P1-8)

### Nice to Have

13. Add telemetry (P2-2)
14. Add circuit breaker (P2-3)
15. Add task archival (P2-1)

---

## 7. Revised Architecture Proposal

### Layer 1: Event Store
- Stores events
- No business logic

### Layer 1.5: Tasks Metadata (NEW)
```sql
CREATE TABLE tasks (
  task_id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  status TEXT NOT NULL,  -- 'active', 'inactive', 'completed', 'cancelled'
  phase TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  created_by TEXT,
  FOREIGN KEY (task_id) REFERENCES streams(id) ON DELETE CASCADE
);
```

### Layer 2: Pod State Manager
- Manages in-memory state for active pods
- Updates tasks table on state changes
- Source of truth for active task state

### Layer 3: Central Manager
- Creates tasks (writes to Event Store + tasks table)
- Starts/stops pods (coordinates with Pod Supervisor)
- Lists tasks (reads from tasks table, enriches with Pod State for active)
- Never interprets raw events

### Data Flow for `get_task/1`
```
Active Pod:
  Central Manager → Pod State Manager → return live state

Inactive Pod:
  Central Manager → tasks table → return metadata
```

### Data Flow for `list_tasks/1`
```
Central Manager → tasks table (filter by status/phase)
  → for active tasks: enrich with Pod State Manager data
  → return combined results
```

---

## 8. Testing Strategy Gaps

### Missing Test Cases

1. **Concurrent pod start attempts** - Race condition testing
2. **Event Store unavailability** - Error handling
3. **Pod Supervisor crash recovery** - Resilience testing
4. **Monitor map consistency** - State invariant testing
5. **Crash history cleanup** - Memory leak prevention

### Recommended Additional Tests

```elixir
test "concurrent start_pod calls return error for duplicate" do
  task_id = create_task("Test")

  # Spawn 10 processes trying to start same pod
  tasks = for _ <- 1..10 do
    Task.async(fn -> Ipa.CentralManager.start_pod(task_id) end)
  end

  results = Enum.map(tasks, &Task.await/1)

  # Only one should succeed
  assert Enum.count(results, &match?({:ok, _}, &1)) == 1
  assert Enum.count(results, &match?({:error, :already_started}, &1)) == 9
end

test "monitors are cleaned up when pod stops" do
  task_id = create_task("Test")
  {:ok, _pid} = Ipa.CentralManager.start_pod(task_id)

  # Check monitor exists
  state = :sys.get_state(Ipa.Central.TaskManager)
  assert Map.has_key?(state.monitors, task_id)

  :ok = Ipa.CentralManager.stop_pod(task_id)

  # Check monitor removed
  state = :sys.get_state(Ipa.Central.TaskManager)
  refute Map.has_key?(state.monitors, task_id)
end
```

---

## 9. Positive Aspects Worth Preserving

1. **Auto-restart strategy** - Well thought out with frequency limits
2. **Monitor-based pod tracking** - Good use of OTP patterns
3. **Configuration approach** - Flexible and testable
4. **GenServer state design** - Minimal and focused
5. **Error handling categories** - Comprehensive error cases identified

---

## 10. Conclusion

The Central Task Manager spec has good intentions and some solid OTP patterns, but suffers from critical architectural flaws:

1. **Violates layering** by interpreting raw events instead of using Pod State Manager
2. **Missing critical infrastructure** (tasks metadata table)
3. **Has race conditions** and undefined functions
4. **Inconsistent API design** that breaks audit trail

The component needs significant revision before implementation can begin. The core issue is attempting to aggregate state from events at Layer 3 instead of properly delegating to Layer 2 (Pod State Manager).

---

## Review Status

- [x] Spec reviewed
- [x] Issues identified
- [ ] Critical issues resolved
- [ ] Spec approved

## Approval

- [ ] Spec approved for implementation
- [x] Spec needs revisions

**Approval Decision**: ⚠️ **NEEDS REVISION**

**Rationale**:
- Multiple P0 issues that violate core architectural principles
- Implementation as specified would not work (missing Event Store functions, undefined functions)
- Race conditions and missing error handling would cause crashes
- State aggregation approach is fundamentally flawed

**Approval Criteria**:
1. Remove all direct event interpretation logic (P0-1)
2. Add tasks metadata table (P0-2 solution)
3. Fix all race conditions (P0-3)
4. Fix public API consistency (P0-4)
5. Implement crash detection correctly (P0-5)
6. Address at least 4 of the P1 issues

**Estimated Revision Effort**: 2-3 days

---

**Reviewer**: Claude (System Architecture Expert)
**Review Completed**: 2025-11-06
