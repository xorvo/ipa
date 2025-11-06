# Component Spec: 2.1 Pod Supervisor

## Overview

The Pod Supervisor is the **root supervision infrastructure** for the IPA task management system. Each active task runs in an isolated pod (Elixir supervision tree), and the Pod Supervisor manages the lifecycle of these pods.

This component provides:
- Dynamic pod creation and termination
- Pod registry for lookup and management
- Fault tolerance through Elixir supervision
- Graceful shutdown and restart capabilities
- Child process supervision within each pod

## Purpose

- **Isolate tasks**: Each task runs in its own supervised process tree
- **Fault tolerance**: Pod crashes don't affect other pods or the system
- **Lifecycle management**: Start, stop, and restart pods independently
- **Resource management**: Track active pods and their status
- **Supervision**: Monitor and restart child processes within pods

## Architecture Position

```
Layer 3: Central Management
           ↓ manages
Layer 2: Pod Infrastructure
         ┌──────────────────────────────────────┐
         │  2.1 Pod Supervisor (THIS COMPONENT) │
         │  - Creates/stops pods                │
         │  - Supervises pod processes          │
         │  - Registers pods for lookup         │
         └──────────────────────────────────────┘
           ↓ supervises
         ┌──────────────────────────────────────┐
         │  Pod Children (per task)             │
         │  - 2.2 Pod State Manager             │
         │  - 2.3 Pod Scheduler                 │
         │  - 2.4 Workspace Manager             │
         │  - 2.5 External Sync                 │
         │  - 2.6 LiveView                      │
         └──────────────────────────────────────┘
```

## Dependencies

- **External**: Elixir, OTP (DynamicSupervisor, Registry)
- **Internal**:
  - 1.1 SQLite Event Store (for state persistence)
  - None others (foundation of Layer 2)

## Module Structure

```
lib/ipa/pod/
  ├── pod.ex                      # Pod behavior and specification
  ├── supervisor.ex               # Root DynamicSupervisor for all pods
  └── registry.ex                 # Pod registry wrapper
```

## Supervision Tree Architecture

### System-Level Supervision

```
Application
  └── Ipa.Supervisor (top-level)
      ├── Ipa.EventStore.Repo
      ├── Ipa.PodRegistry (Registry - tracks pods)
      ├── Ipa.PodSupervisor (DynamicSupervisor - manages all pods)
      │   ├── Ipa.Pod (task_id: "uuid-1")  ← dynamically started
      │   ├── Ipa.Pod (task_id: "uuid-2")
      │   └── Ipa.Pod (task_id: "uuid-3")
      └── Phoenix.PubSub
```

**Wiring in Application**:
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

      # Phoenix PubSub for pod-local pub-sub
      {Phoenix.PubSub, name: Ipa.PubSub},

      # Web endpoints
      IpaWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Ipa.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

**Critical**: Registry MUST start before PodSupervisor, as pods register themselves during initialization.

### Per-Pod Supervision

Each `Ipa.Pod` is a Supervisor that manages its own children:

```
Ipa.Pod (task_id: "uuid-1")
  ├── Ipa.Pod.State (GenServer)
  ├── Ipa.Pod.Scheduler (GenServer)
  ├── Ipa.Pod.WorkspaceManager (GenServer)
  ├── Ipa.Pod.ExternalSync (GenServer)
  └── (LiveView processes - managed by Phoenix)
```

**Supervision Strategy**: `one_for_one`
- If a child crashes, only that child is restarted
- Other children in the pod continue running
- Pod itself survives child crashes

**Restart Strategy**: `transient`
- Restart only if child terminates abnormally
- Normal termination (`:normal`, `:shutdown`) doesn't trigger restart

### Pod Children Registration

All pod children register themselves in `Ipa.PodRegistry` for direct addressing:

**Registry Keys**:
- Pod itself: `{:pod, task_id}`
- Pod State: `{:pod_state, task_id}`
- Pod Scheduler: `{:pod_scheduler, task_id}`
- Workspace Manager: `{:pod_workspace, task_id}`
- External Sync: `{:pod_sync, task_id}`

**Implementation in Each Child**:
```elixir
defmodule Ipa.Pod.State do
  use GenServer

  def start_link(opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(task_id))
  end

  defp via_tuple(task_id) do
    {:via, Registry, {Ipa.PodRegistry, {:pod_state, task_id}}}
  end

  # Other processes can now address this child directly:
  # GenServer.call({:via, Registry, {Ipa.PodRegistry, {:pod_state, task_id}}}, :get_state)
end
```

**Benefits**:
- O(1) lookup by task_id + child type
- No need to traverse supervision tree
- Automatic cleanup when child terminates
- Type-safe addressing

## Pod Registry

Pods are registered in a global Registry for fast lookup:

```elixir
# Registry key: {:pod, task_id}
# Registry value: %{status: :active | :starting | :stopping, started_at: timestamp}

Registry.register(Ipa.PodRegistry, {:pod, task_id}, %{status: :active, started_at: now})
```

**Benefits**:
- O(1) lookup by task_id
- Automatic cleanup when pod terminates
- Supports pattern matching queries
- Built-in ETS performance

## Public API

### Module: `Ipa.PodSupervisor`

Main interface for managing pod lifecycle.

#### `start_pod/1`

```elixir
@spec start_pod(task_id :: String.t()) ::
  {:ok, pid()} | {:error, :already_started | :stream_not_found | term()}
```

Starts a new pod for the given task_id.

**Preconditions**:
- Stream must exist in Event Store (task must be created first)
- Pod must not already be running

**Process**:
1. Check if pod is already running (via registry)
2. Verify stream exists in Event Store
3. Start pod via `DynamicSupervisor.start_child/2`
4. Register pod in registry
5. Return pod PID

**Example**:
```elixir
{:ok, pod_pid} = Ipa.PodSupervisor.start_pod("task-uuid-123")
```

#### `stop_pod/1`

```elixir
@spec stop_pod(task_id :: String.t()) ::
  :ok | {:error, :not_running | term()}
```

Gracefully stops a pod and all its children.

**Process**:
1. Find pod PID via registry
2. Send shutdown signal to pod
3. Wait for children to terminate (with timeout)
4. Clean up registry entry
5. Pod processes are automatically unregistered

**Shutdown Sequence**:
- Pod State Manager flushes state to disk
- Scheduler cancels pending operations
- Workspace Manager cleans up temporary files
- External Sync completes in-flight requests

**Timeout**: 10 seconds (configurable)

**Critical**: All pod children MUST implement `terminate/2` callback for graceful shutdown:

```elixir
defmodule Ipa.Pod.State do
  use GenServer

  # ... other code

  @impl true
  def terminate(reason, state) do
    # Flush final state to Event Store
    case flush_state_to_store(state) do
      :ok ->
        Logger.info("Pod State #{state.task_id} terminated gracefully: #{inspect(reason)}")
      {:error, err} ->
        Logger.error("Pod State #{state.task_id} failed to flush: #{inspect(err)}")
    end
    :ok
  end
end
```

**Child Shutdown Requirements**:
- `Ipa.Pod.State`: Flush final state to Event Store
- `Ipa.Pod.Scheduler`: Cancel all pending operations, stop agents
- `Ipa.Pod.WorkspaceManager`: Clean up temporary files and workspaces
- `Ipa.Pod.ExternalSync`: Complete or cancel in-flight HTTP requests

**Shutdown Timeout Per Child**:
Each child has individual shutdown timeout specified in child_spec (default: 5 seconds):

```elixir
%{
  id: Ipa.Pod.State,
  start: {Ipa.Pod.State, :start_link, [opts]},
  restart: :transient,
  shutdown: 5_000,  # 5 second timeout for terminate/2
  type: :worker
}
```

If child doesn't exit within timeout, it's killed with `:kill` signal (not graceful).

**Example**:
```elixir
:ok = Ipa.PodSupervisor.stop_pod("task-uuid-123")
```

#### `stop_pod/2`

```elixir
@spec stop_pod(task_id :: String.t(), reason :: term()) ::
  :ok | {:error, :not_running | term()}
```

Stops a pod with a specific reason (for logging/debugging).

**Example**:
```elixir
:ok = Ipa.PodSupervisor.stop_pod("task-uuid-123", :user_requested)
```

#### `restart_pod/1`

```elixir
@spec restart_pod(task_id :: String.t()) ::
  {:ok, pid()} | {:error, term()}
```

Restarts a pod (stop + start).

**Use Cases**:
- Manual recovery from error state
- Applying configuration changes
- Resetting pod state

**Example**:
```elixir
{:ok, new_pid} = Ipa.PodSupervisor.restart_pod("task-uuid-123")
```

#### `get_pod_pid/1`

```elixir
@spec get_pod_pid(task_id :: String.t()) ::
  {:ok, pid()} | {:error, :not_found}
```

Gets the PID of a running pod.

**Example**:
```elixir
{:ok, pid} = Ipa.PodSupervisor.get_pod_pid("task-uuid-123")
```

#### `pod_running?/1`

```elixir
@spec pod_running?(task_id :: String.t()) :: boolean()
```

Checks if a pod is currently running.

**Example**:
```elixir
if Ipa.PodSupervisor.pod_running?("task-uuid-123") do
  # Pod is active
end
```

#### `list_pods/0`

```elixir
@spec list_pods() :: [%{task_id: String.t(), pid: pid(), status: atom(), started_at: integer()}]
```

Lists all active pods with their metadata.

**Returns**: List of pod info maps
- `task_id` - Task identifier
- `pid` - Pod process ID
- `status` - `:starting`, `:active`, `:stopping`
- `started_at` - Unix timestamp

**Example**:
```elixir
pods = Ipa.PodSupervisor.list_pods()
# [
#   %{task_id: "uuid-1", pid: #PID<0.123.0>, status: :active, started_at: 1699564800},
#   %{task_id: "uuid-2", pid: #PID<0.124.0>, status: :active, started_at: 1699564805}
# ]
```

#### `count_pods/0`

```elixir
@spec count_pods() :: non_neg_integer()
```

Returns the number of active pods.

**Example**:
```elixir
count = Ipa.PodSupervisor.count_pods()  # => 3
```

### Module: `Ipa.Pod`

Represents a single pod (Supervisor for a task's processes).

#### `start_link/1`

```elixir
@spec start_link(task_id :: String.t()) :: Supervisor.on_start()
```

Starts a pod supervisor with all child processes.

**Called by**: `Ipa.PodSupervisor` (not called directly by users)

**Children Started** (in order):
1. `Ipa.Pod.State` - Load events and manage state
2. `Ipa.Pod.WorkspaceManager` - Set up workspaces
3. `Ipa.Pod.Scheduler` - Start state machine
4. `Ipa.Pod.ExternalSync` - Connect to external systems

**Note**: LiveView processes are started on-demand by Phoenix, not supervised here.

#### `child_spec/1`

```elixir
@spec child_spec(task_id :: String.t()) :: Supervisor.child_spec()
```

Returns the child specification for DynamicSupervisor.

**Critical**: Must specify `restart: :temporary` to prevent automatic restarts after pod crashes.

**Example**:
```elixir
def child_spec(task_id) do
  %{
    id: {:pod, task_id},
    start: {__MODULE__, :start_link, [task_id]},
    restart: :temporary,  # Prevents auto-restart on crash
    type: :supervisor,
    shutdown: 10_000      # 10 second shutdown timeout
  }
end

# Usage
spec = Ipa.Pod.child_spec("task-uuid-123")
DynamicSupervisor.start_child(Ipa.PodSupervisor, spec)
```

## Pod Lifecycle

### Starting a Pod

```
1. User/Central Manager calls Ipa.PodSupervisor.start_pod(task_id)
2. PodSupervisor verifies stream exists in Event Store
3. PodSupervisor starts pod via DynamicSupervisor.start_child
4. Ipa.Pod.start_link(task_id) is called
5. Pod attempts to register itself in Ipa.PodRegistry
   - If registration succeeds → continue
   - If {:error, {:already_registered, _}} → fail fast with :already_started
6. Pod starts children in order:
   a. Ipa.Pod.State loads events and builds initial state
   b. Ipa.Pod.WorkspaceManager initializes workspaces
   c. Ipa.Pod.Scheduler starts state machine
   d. Ipa.Pod.ExternalSync connects to GitHub/JIRA
7. Pod transitions to :active status
8. PodSupervisor returns {:ok, pid}
```

**Race Condition Prevention**:

Registration happens **atomically** during pod initialization, not as a separate step. This prevents duplicate pods:

```elixir
defmodule Ipa.Pod do
  use Supervisor

  def start_link(task_id) do
    # Attempt registration BEFORE supervisor initialization
    case Registry.register(Ipa.PodRegistry, {:pod, task_id}, %{
      status: :starting,
      started_at: System.system_time(:second)
    }) do
      {:ok, _} ->
        # Registration successful - proceed with supervisor init
        Supervisor.start_link(__MODULE__, task_id, [])
      {:error, {:already_registered, pid}} ->
        # Pod already exists - fail immediately
        {:error, {:already_started, pid}}
    end
  end

  # ... rest of implementation
end
```

This ensures:
- No time-of-check-time-of-use (TOCTOU) race condition
- Registry uniqueness is the source of truth
- Failed registration prevents pod startup

### Stopping a Pod

```
1. User/Central Manager calls Ipa.PodSupervisor.stop_pod(task_id)
2. PodSupervisor finds pod PID via registry
3. PodSupervisor sends :shutdown signal to pod
4. Pod propagates shutdown to children (in reverse order):
   a. ExternalSync completes in-flight requests
   b. Scheduler cancels pending operations
   c. WorkspaceManager cleans up temp files
   d. State Manager flushes final state to Event Store
5. Children terminate gracefully
6. Pod supervisor terminates
7. Registry automatically unregisters pod
8. PodSupervisor returns :ok
```

### Pod Restart After Crash

```
1. Child process crashes (e.g., Scheduler raises exception)
2. Pod supervisor detects crash via monitoring
3. Pod supervisor checks restart strategy → :transient
4. If abnormal termination:
   a. Supervisor restarts just that child
   b. Child reloads state from Event Store
   c. Other children continue running
5. If normal termination:
   a. No restart (child meant to stop)
```

### Full Pod Crash

```
1. Pod supervisor itself crashes (rare, catastrophic error)
2. PodSupervisor (DynamicSupervisor) detects crash
3. Pod is NOT automatically restarted (must be manual)
4. Registry entry is automatically removed
5. Central Manager can detect missing pod and restart if needed
```

**Design Decision**: Pods don't auto-restart after full crash to prevent cascading failures. Recovery is manual/controlled.

## Registry Implementation

### Module: `Ipa.PodRegistry`

Wrapper around Elixir Registry for pod tracking.

```elixir
defmodule Ipa.PodRegistry do
  @moduledoc """
  Registry for tracking active pods.

  Uses Elixir's built-in Registry with:
  - Unique keys (one pod per task_id)
  - Automatic cleanup on process termination
  - Fast ETS-based lookup
  """

  def start_link(_opts) do
    Registry.start_link(keys: :unique, name: __MODULE__)
  end

  def register(task_id, metadata \\ %{}) do
    Registry.register(__MODULE__, {:pod, task_id}, metadata)
  end

  def unregister(task_id) do
    Registry.unregister(__MODULE__, {:pod, task_id})
  end

  def lookup(task_id) do
    case Registry.lookup(__MODULE__, {:pod, task_id}) do
      [{pid, metadata}] -> {:ok, pid, metadata}
      [] -> {:error, :not_found}
    end
  end

  def list_all do
    Registry.select(__MODULE__, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
  end
end
```

**Registry Metadata**:
```elixir
%{
  status: :starting | :active | :stopping,
  started_at: unix_timestamp,
  restarts: integer  # Number of child restarts
}
```

## Error Handling

### Common Errors

#### `:already_started`
- **Cause**: Attempted to start a pod that's already running
- **Recovery**: Check with `pod_running?/1` before starting
- **Example**:
  ```elixir
  unless Ipa.PodSupervisor.pod_running?(task_id) do
    Ipa.PodSupervisor.start_pod(task_id)
  end
  ```

#### `:stream_not_found`
- **Cause**: Task doesn't exist in Event Store
- **Recovery**: Create task in Event Store first
- **Example**:
  ```elixir
  {:ok, task_id} = Ipa.EventStore.start_stream("task")
  {:ok, pid} = Ipa.PodSupervisor.start_pod(task_id)
  ```

#### `:not_running`
- **Cause**: Attempted to stop a pod that's not running
- **Recovery**: Check with `pod_running?/1` first
- **Example**:
  ```elixir
  if Ipa.PodSupervisor.pod_running?(task_id) do
    Ipa.PodSupervisor.stop_pod(task_id)
  end
  ```

#### `:timeout`
- **Cause**: Pod didn't start within timeout (30 seconds)
- **Recovery**: Check logs, may indicate Event Store issues or slow state loading
- **Example**:
  ```elixir
  case Ipa.PodSupervisor.start_pod(task_id) do
    {:ok, pid} -> :ok
    {:error, :timeout} ->
      Logger.error("Pod start timeout for #{task_id}")
      # Investigate Event Store or state size
  end
  ```

### Supervision Strategies

**For PodSupervisor (DynamicSupervisor)**:
- Strategy: Dynamic (children started on-demand)
- Max restarts: N/A (pods don't auto-restart)
- Max seconds: N/A

**For Ipa.Pod (per-pod Supervisor)**:
- Strategy: `:one_for_one` (restart crashed child only)
- Max restarts: `3` in `5` seconds (configurable per pod)
- Restart: `:transient` (restart only on abnormal termination)

**Implementation**:
```elixir
# In Ipa.Pod.init/1
def init(task_id) do
  config = Application.get_env(:ipa, Ipa.Pod, [])
  max_restarts = Keyword.get(config, :max_restarts, 3)
  max_seconds = Keyword.get(config, :max_seconds, 5)

  children = [
    {Ipa.Pod.State, task_id: task_id},
    {Ipa.Pod.WorkspaceManager, task_id: task_id},
    {Ipa.Pod.Scheduler, task_id: task_id},
    {Ipa.Pod.ExternalSync, task_id: task_id}
  ]

  Supervisor.init(children,
    strategy: :one_for_one,
    max_restarts: max_restarts,
    max_seconds: max_seconds
  )
end
```

**If max restarts exceeded**:
- Pod supervisor terminates
- All children are stopped
- Registry entry removed
- Central Manager can detect and decide recovery

## Configuration

```elixir
# config/config.exs
config :ipa, Ipa.PodSupervisor,
  # Timeout for pod startup
  start_timeout: 30_000,  # 30 seconds

  # Timeout for graceful shutdown (for stop_pod operation)
  shutdown_timeout: 10_000  # 10 seconds

# Pod-level configuration (for children supervision)
config :ipa, Ipa.Pod,
  # Max restarts for pod children
  max_restarts: 3,
  max_seconds: 5,

  # Individual child shutdown timeouts
  child_shutdown: 5_000  # 5 seconds per child

# config/test.exs
config :ipa, Ipa.PodSupervisor,
  start_timeout: 5_000,
  shutdown_timeout: 2_000

config :ipa, Ipa.Pod,
  max_restarts: 3,
  max_seconds: 5,
  child_shutdown: 1_000
```

## Integration with Other Components

### With Event Store (1.1)

Pod Supervisor depends on Event Store for:
- Verifying stream exists before starting pod
- Pod State Manager loads events on startup

```elixir
def start_pod(task_id) do
  # Verify stream exists using Event Store API
  case Ipa.EventStore.stream_exists?(task_id) do
    true -> do_start_pod(task_id)
    false -> {:error, :stream_not_found}
  end
end
```

**Note**: Requires `stream_exists?/1` function in Event Store (1.1) spec. This is a convenience wrapper around checking if `read_stream/2` returns `:not_found`.

**Alternative implementation if stream_exists?/1 doesn't exist**:
```elixir
def start_pod(task_id) do
  # Verify by attempting to read stream
  case Ipa.EventStore.read_stream(task_id, max_count: 1) do
    {:ok, _events} -> do_start_pod(task_id)
    {:error, :not_found} -> {:error, :stream_not_found}
    {:error, reason} -> {:error, reason}
  end
end
```

### With Central Manager (3.1)

Central Manager uses Pod Supervisor to:
- Start pods when tasks are activated
- Stop pods when tasks complete or are cancelled
- List active pods for dashboard

```elixir
# In Central Manager
def activate_task(task_id) do
  case Ipa.PodSupervisor.start_pod(task_id) do
    {:ok, pid} -> {:ok, :activated}
    error -> error
  end
end
```

### With Pod Children (2.2-2.6)

Pod children are supervised by Ipa.Pod:
- Children receive task_id on startup
- Children can crash and restart independently
- Children access Event Store for state

## Testing Requirements

### Unit Tests

1. **Pod Start**
   - Starts pod successfully with valid task_id
   - Returns error if task_id doesn't exist
   - Returns error if pod already running
   - Registers pod in registry
   - Returns correct PID

2. **Pod Stop**
   - Stops pod gracefully
   - Unregisters from registry
   - Returns error if not running
   - Respects shutdown timeout

3. **Pod Restart**
   - Stops and starts pod
   - New PID returned
   - State is reloaded

4. **Registry Operations**
   - Lookup finds running pods
   - Lookup returns error for missing pods
   - List returns all pods
   - Count returns correct number

### Integration Tests

1. **Child Supervision**
   - Pod starts all children in correct order
   - Child crash triggers restart (not full pod)
   - Restarted child reloads state correctly
   - Max restarts causes pod termination

2. **Multiple Pods**
   - Can run multiple pods simultaneously
   - Pods are isolated (crash doesn't affect others)
   - Registry tracks all pods correctly
   - Can stop specific pods without affecting others

3. **Graceful Shutdown**
   - Children stop in reverse order
   - Children have time to clean up
   - Shutdown timeout is respected
   - Forced termination after timeout

### Performance Tests

1. **Startup Performance**
   - Pod startup < 100ms (with small event history)
   - Concurrent pod starts don't block each other

2. **Registry Performance**
   - Lookup < 1ms
   - List all pods < 10ms (for 100 pods)

3. **Shutdown Performance**
   - Graceful shutdown < 1 second
   - Multiple simultaneous shutdowns don't block

## Acceptance Criteria

- [ ] Can start a pod with valid task_id
- [ ] Cannot start duplicate pod
- [ ] Pod is registered in registry on start
- [ ] Can stop a running pod gracefully
- [ ] Pod is unregistered on stop
- [ ] Can list all active pods
- [ ] Child crashes restart child only (not full pod)
- [ ] Max restarts causes pod termination
- [ ] Multiple pods run independently
- [ ] Registry lookups are fast (< 1ms)
- [ ] All tests pass

## Migration & Deployment

### Initial Deployment

1. Add `Ipa.PodSupervisor` to application supervision tree
2. Add `Ipa.PodRegistry` to application supervision tree
3. No database migrations (uses Event Store)
4. No configuration changes required (defaults work)

### Monitoring

Key metrics to track:
- Number of active pods (`count_pods/0`)
- Pod start/stop rate
- Child restart frequency
- Pod crash rate
- Startup/shutdown times

## Future Enhancements

### Phase 2: Advanced Features

1. **Pod Health Checks**
   - Periodic health pings to children
   - Automatic restart if unresponsive
   - Expose health status in registry

2. **Pod Resource Limits**
   - Memory limits per pod
   - CPU limits per pod
   - Automatic termination if exceeded

3. **Pod Migration**
   - Move pod to different node
   - Useful for load balancing
   - Requires distributed Elixir setup

4. **Pod Grouping**
   - Group related pods (e.g., by project)
   - Bulk operations on groups
   - Group-level resource limits

## References

- Elixir Supervisor: https://hexdocs.pm/elixir/Supervisor.html
- DynamicSupervisor: https://hexdocs.pm/elixir/DynamicSupervisor.html
- Registry: https://hexdocs.pm/elixir/Registry.html
- OTP Supervision Principles: https://www.erlang.org/doc/design_principles/sup_princ.html
