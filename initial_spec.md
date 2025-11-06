# IPA: Component Architecture & Development Plan (v3 - Pod-Based)

## Top-level engineering requirements

(make sure this goes into Claude.md)

Following is an overview initial spec for the project. Please break down the work into multiple specs so they can be worked on individually. It's important to pay close attention to the APIs between each component to reduce the amount of work required during integration. Also give me a clear dependency graph on the work so I know how to coordinate the work.

Here's a list of things that I will need from you.
- Create a `specs/` folder to store all the spec,design,progress tracking related files while working on them.
- A top level status tracker document (TODOs). While working on individual components, please update this document with your progress. We'll also keep this doc up to date as we progress and make changes to our technical plan.
- A dedicated spec folder for each component. This should include a detailed description of the component's purpose, inputs, outputs, and any dependencies on other components.
- Try to be concise, don't repeat yourself too much when writing these specs.
- Spawn sub-agents as necessary.
- While working on each component, we must go through the process of spec, review-spec, approve-spec, code, local-test-code, code-review, pull-request, and merge.

## Git

I started a new empty repo at git@github.com:xorvo/ipa.git

You can clone it and start working on it. You can of course clone multiple copies of it if you want to work on things in parallel.

Make sure you open pull requests when you think it's ready for code review. I will approve them and merge them if they look good.

Make sure you include the specs in the pull request so I know what you did.

## Tools

- Use the `gh` command line for interacting with GitHub during the development of this project.
- Use the `git` command line for version control.
- Use hex.pm website for documentation on the elixir libraries if you are not sure about the usage.

## Tech Stack

- **Backend Framework**: Elixir/Phoenix with LiveView
- **UI**: Phoenix LiveView (per-pod + centralized dashboard)
- **Agent Runtime**: Elixir Claude Code SDK (https://hexdocs.pm/claude_code/readme.html)
- **State Architecture**: Event Sourcing (immutable event log + snapshots, persisted per pod), we may use
- **Concurrency**: Elixir supervision trees (pod = supervisor with child components)
- **Persistence**: Postgres or file-based event store (survives pod restart)

---

## Architecture Overview: Pod-Based Task Isolation

### Core Concept

Each **task** runs in an isolated **pod**. A pod is an Elixir supervisor that owns:
- Task state (event store + projections)
- Scheduler (state machine logic + agent orchestration)
- LiveView UI (real-time dashboard for task)
- External sync engine (JIRA, GitHub integration)
- Workspace manager + child workspaces for agents

**Benefits**:
- Task isolation: pod crash doesn't affect other tasks
- Independent lifecycles: pod created/destroyed on task create/complete
- Supervision: Elixir supervisor tree handles restarts gracefully
- Persistence: state survives pod restart (loaded from disk)
- Scalability: pods can run on different machines (future)

### Pod Lifecycle

```
User creates task (via Central UI)
  ↓
Central manager spawns pod (via DynamicSupervisor)
  ↓
Pod starts: loads state from disk, initializes scheduler, opens LiveView
  ↓
Scheduler drives task through phases (agents run, state updates)
  ↓
User completes/cancels task (via pod UI)
  ↓
Pod gracefully shuts down (flushes state to disk)
  ↓
Central manager tears down pod
```

---

## Layer 1: Persistence & State (Shared, Not Pod-Local)

### 1.0 Event Sourcing via Ash Framework + AshEvents

Purpose: Unified framework for domain modeling, state management, and event sourcing
Scope: Shared across all pods
Owns: Event persistence, state projections, task resource modeling

#### Why Ash + AshEvents:

- AshEvents is an Event Sourcing tool for Ash Framework apps, just released (May 2025)
- AshEvents provides event sourcing capabilities with comprehensive tracking, event versioning, and replay functionality
- Ash Framework has comprehensive tools for integrating with LLMs, enabling AI agents to securely interact with endpoints
- Single coherent framework for data modeling + events + LLM integration
Declarative resource-oriented design (natural fit for tasks, agents, workspaces)

#### Ash Resources for IPA:

Task resource: represents a task (spec, plan, phase, status)
TaskEvent resource: event log (tracks all state changes)
Agent resource: represents agent runs (status, logs, workspace)
Workspace resource: agent workspaces (location, files, git state)

AshEvents Integration:
```elixir
# Example Task resource with event sourcing
defmodule IPA.Tasks.Task do
  use Ash.Resource,
    otp_app: :ipa,
    data_layer: AshPostgres.DataLayer

  # Event sourced attributes
  attributes do
    uuid_primary_key :id
    attribute :title, :string
    attribute :phase, :string  # spec_clarification, planning, development, etc.
    attribute :spec, :map
    attribute :plan, :map
  end

  # AshEvents integration
  actions do
    create :create_task do
      primary? true
      change AshEvents.Changes.Record, action: :task_created
    end

    update :approve_transition do
      change AshEvents.Changes.Record, action: :transition_approved
    end
  end

  # Event definitions
  events do
    event :task_created, [:title]
    event :transition_approved, [:new_phase, :approved_by]
    event :agent_started, [:agent_id, :agent_type]
    event :agent_completed, [:agent_id, :result]
  end
end
```

#### Advantages:

- Automatic event recording (no manual event appending)
- Event versioning + replay built-in
- Actor attribution (who made the change)
- Metadata support (timestamps, context)
- Integrates with Ash's authorization + policies
- Works with Ash's GraphQL + JSON:API for external queries

Testing: Resource events, event replay, version conflicts

---

### 1.1 Persisted Event Store (via Ash + AshEvents)

Purpose: Durable, append-only log of all state changes
Scope: Shared across all pods (Postgres backend)
Owns: Event persistence, snapshots, replay

#### Implementation:

Postgres (recommended with AshEvents):

AshEvents manages event table (task_events, etc.)
Automatic schema generation via Ash migrations
Event log per resource: events table with: id, resource_id, event_type, data, version, timestamp, actor_id, metadata
On pod startup: AshEvents handles replay to current state

#### Sub-components:

Event Append (via Ash):

Pod's State module calls Ash actions (e.g., Task.approve_transition(...))
Ash + AshEvents automatically record event
Return new version + publish to pod's internal pub-sub


Event Load (via Ash):

On pod startup, Ash loads task resource
AshEvents replays events to reconstruct state
Return current state to pod


Snapshot Management (AshEvents):

AshEvents handles snapshotting automatically
Periodic snapshots reduce replay time
Configurable snapshot frequency



Key Interfaces:
```elixir
# Via Ash actions (not raw EventStore calls)
{:ok, task} = Task.create_task(%{title: "My Task"})
  # AshEvents records :task_created event automatically

{:ok, updated_task} = Task.approve_transition(task, %{new_phase: :planning})
  # AshEvents records :transition_approved event automatically

# Query current state (Ash handles replay internally)
task = Task.get!(task_id)
```

Testing: Resource events, event replay consistency, version conflicts

---

## Layer 2: Pod Infrastructure (Spawned Per Task)

### 2.1 Task Pod Supervisor
**Purpose**: Root supervisor for a single task
**Scope**: One instance per active task
**Owns**: Spawning, supervising, terminating pod components

**Elixir Module**: `Ipa.Pod.Supervisor`

**Structure**:
```elixir
defmodule Ipa.Pod.Supervisor do
  use DynamicSupervisor

  def start_link(task_id) do
    DynamicSupervisor.start_link(__MODULE__, task_id, name: via_tuple(task_id))
  end

  def init(task_id) do
    # Spawn child processes for this pod
    children = [
      {Ipa.Pod.State, task_id},           # Load + manage state
      {Ipa.Pod.Scheduler, task_id},       # Drive task forward
      {Ipa.Pod.ExternalSync, task_id},    # Sync to JIRA, GitHub
      {Ipa.Pod.WorkspaceManager, task_id} # Manage workspaces
    ]

    DynamicSupervisor.init(strategy: :one_for_all, children: children)
  end

  def via_tuple(task_id) do
    {:via, Registry, {Ipa.Pod.Registry, task_id}}
  end
end
```

**Lifecycle**:
- Created: when user creates task (central manager calls `start_pod(task_id)`)
- Running: pod drives task through phases, handles user interactions
- Shutdown: user completes/cancels task, central manager calls `stop_pod(task_id)`
- On crash: Elixir supervisor restarts failed children (configurable strategy)

**Persistence on Shutdown**:
- Before terminating, pod flushes current state to disk
- On restart, pod reloads state from disk
- Users can manually restart pods if something goes wrong

---

### 2.2 Pod State Manager
**Purpose**: Load persisted state, manage in-memory projections, handle writes
**Scope**: One instance per pod
**Owns**: State lifecycle within pod, pub-sub for pod-internal updates

**Elixir Module**: `Ipa.Pod.State`

**Responsibilities**:

- **On Startup**:
  - Load events from persisted EventStore (via shared Layer 1)
  - Reconstruct current state by replaying events
  - Start GenServer with state in memory
  - Emit `pod_started` event for scheduler to react to

- **Event Append** (within pod):
  - Scheduler/External Sync want to append events
  - Check version conflict (optimistic concurrency)
  - Append to persisted EventStore
  - Update in-memory projection
  - Publish to pod's internal pub-sub: `pod:{task_id}:state`
  - Return result to caller

- **State Query**:
  - Scheduler/Sync/LiveView query current state
  - Return in-memory projection (fast)
  - Example: `get_current_phase(task_id)`, `get_task_state(task_id)`

- **Pod-Local Pub-Sub**:
  - Topic: `pod:{task_id}:state`
  - Published after successful event append
  - Subscribers: Scheduler, ExternalSync, LiveView (all within this pod)
  - Fast local communication, no cross-pod traffic

**Key Interfaces**:
```elixir
# GenServer callbacks
Ipa.Pod.State.start_link(task_id)
  → {:ok, pid}

# Calls (synchronous)
Ipa.Pod.State.append_event(task_id, event_type, data, expected_version)
  → {:ok, new_version} | {:error, :version_conflict}

Ipa.Pod.State.get_state(task_id)
  → {:ok, current_state_map}

# Subscriptions (asynchronous)
GenServer.cast(Ipa.Pod.State, {:subscribe, self()})
  → receives {:state_updated, new_state} messages
```

**Testing**: State loading, event replay, conflict detection, pub-sub delivery

---

### 2.3 Pod-Local LiveView UI
**Purpose**: Real-time dashboard for a single task
**Scope**: One instance per pod (mounted when user navigates to pod URL)
**Owns**: Rendering task state, human interactions

**Phoenix Route & Module**: `IpaWeb.Pod.TaskLive`

**Features**:
- **Task Detail View**:
  - Display task state (spec, plan, phase, active agents, etc.)
  - Real-time updates via pod-local pub-sub
  - Approval buttons (approve transition, interrupt agent, etc.)
  - Workspace file browser (optional: inline code review)

- **Agent Monitoring**:
  - Show active agents + their streaming logs
  - Agent logs streamed from Claude Code SDK
  - Real-time as agent executes

- **External Sync Status**:
  - Show pending GitHub/JIRA updates
  - Approve before sync (human gate)
  - Display sync history

**Implementation**:
```elixir
defmodule IpaWeb.Pod.TaskLive do
  use Phoenix.LiveView

  def mount(%{"task_id" => task_id}, _session, socket) do
    # Subscribe to pod's state updates
    Phoenix.PubSub.subscribe(Ipa.PubSub, "pod:#{task_id}:state")

    # Load current state
    {:ok, state} = Ipa.Pod.State.get_state(task_id)

    {:ok, assign(socket, task_id: task_id, state: state)}
  end

  def handle_info({:state_updated, new_state}, socket) do
    {:noreply, assign(socket, state: new_state)}
  end

  def handle_event("approve_transition", _, socket) do
    Ipa.Pod.State.append_event(
      socket.assigns.task_id,
      :state_transition_approved,
      %{approved_by: socket.assigns.user_id},
      socket.assigns.state.version
    )
    {:noreply, socket}
  end
end
```

**Testing**: LiveView mount, state updates, user interactions

---

### 2.4 Pod Scheduler
**Purpose**: Drive task through phases, spawn agents, react to state changes
**Scope**: One instance per pod
**Owns**: State machine logic, agent orchestration, phase transitions

**Elixir Module**: `Ipa.Pod.Scheduler`

**Responsibilities**:

- **Main Loop** (GenServer):
  - Subscribe to pod-local pub-sub: `pod:{task_id}:state`
  - On state change: evaluate current phase + state
  - Determine next action (spawn agent, wait for human, move to next phase, etc.)
  - Respect cooldowns (don't spam agent spawning)

- **Action Dispatcher**:
  - `phase = spec_clarification` + `spec_complete?` → emit `state_transition_requested`
  - `phase = spec_clarification` + `human_approval_given?` → move to `planning`
  - `phase = planning` + `approved?` → spawn planning agent
  - `phase = development` + `no_active_agents?` → spawn dev agent
  - etc.

- **Agent Spawner**:
  - When dispatcher says "spawn planning agent":
    - Create workspace via PodWorkspaceManager
    - Prepare task context (spec, plan, etc.)
    - Spawn Claude Code agent via SDK:
      ```elixir
      {:ok, stream} = ClaudeCode.run_task(
        prompt: task_prompt,
        cwd: workspace_path,
        allowed_tools: [:read, :bash],
        stream: true
      )

      # Emit agent logs to pod-local pub-sub
      Task.start(fn -> stream_agent_logs(stream, task_id) end)
      ```
    - Record agent spawn event
    - Monitor agent for completion

- **Interruption Handling**:
  - On user interrupt signal (via UI): cancel agent task
  - Emit `agent_interrupted` event
  - Scheduler determines next action (retry or escalate)

**Key Interfaces**:
```elixir
Ipa.Pod.Scheduler.start_link(task_id)
  → {:ok, pid}

Ipa.Pod.Scheduler.interrupt_agent(task_id, agent_id)
  → :ok
```

**Testing**: State machine logic, agent spawning, action dispatcher

---

### 2.5 Pod External Sync Engine
**Purpose**: Keep JIRA, GitHub in sync with pod state
**Scope**: One instance per pod
**Owns**: Polling external systems, pushing updates, conflict resolution

**Elixir Module**: `Ipa.Pod.ExternalSync`

**Responsibilities**:

- **Sync Loop** (GenServer):
  - Subscribe to pod-local pub-sub: `pod:{task_id}:state`
  - On state change: determine which external systems care
  - Format state for external system (JIRA, GitHub)
  - Queue update with deduplication

- **External Connectors** (same as Layer 2.2 in original spec):
  - GitHub Connector: create/update PR, fetch comments
  - JIRA Connector: update ticket status, post comments
  - Each handles authentication, rate limiting, retries

- **Update Queue**:
  - Batch rapid updates (500ms-1s window)
  - Deduplicate (don't send same update twice)
  - Optional human approval gate before publishing

- **External Change Detection**:
  - Periodically poll external systems for incoming changes
  - If external state changed (e.g., PR approved), emit event to pod state
  - Pod state reacts (may advance task)

**Key Interfaces**:
```elixir
Ipa.Pod.ExternalSync.start_link(task_id)
  → {:ok, pid}

Ipa.Pod.ExternalSync.sync_now(task_id)
  → :ok | {:error, reason}
```

**Testing**: State → external format mapping, sync triggering

---

### 2.6 Pod Workspace Manager
**Purpose**: Manage workspaces (directories) where agents do work
**Scope**: One instance per pod
**Owns**: Workspace creation, cleanup, file access, git operations

**Elixir Module**: `Ipa.Pod.WorkspaceManager`

**Responsibilities**:

- **Workspace Provisioning**:
  - Create workspace: `/ipa/workspaces/{task_id}/{agent_id}`
  - Git clone relevant repo(s)
  - Write config files (env vars, k8s access, etc.)
  - Record workspace location in pod state

- **Workspace Registry** (pod-local):
  - Track active workspaces
  - Map: `{agent_id} → workspace_path`
  - Cleanup on agent completion or timeout

- **File Operations**:
  - Read/write files within workspace
  - Git operations (diff, commit, push)
  - Exposed to agents + scheduler

- **Future: Multi-Workspace Support**:
  - Current: one workspace per agent
  - Future question: should pods spawn child pods for parallelization, or multiplex workspaces?
  - **Design consideration**:
    - **Option A (Child Pods)**: Each workspace runs independently in a child pod, with its own scheduler/state. Allows true isolation + independent failure domains.
    - **Option B (Multiplexing)**: Multiple workspaces under one pod, scheduler coordinates. Simpler but shared fate.
    - **TBD**: For v1, assume one workspace per task. Design future support by: (1) making workspace lifecycle clear, (2) allowing workspace ID in events, (3) planning for pod-spawning-pods pattern.

**Key Interfaces**:
```elixir
Ipa.Pod.WorkspaceManager.create_workspace(task_id, agent_id, config)
  → {:ok, workspace_path}

Ipa.Pod.WorkspaceManager.cleanup_workspace(task_id, agent_id)
  → :ok

Ipa.Pod.WorkspaceManager.read_file(task_id, workspace_id, relative_path)
  → {:ok, contents} | {:error, :not_found}
```

**Testing**: Workspace creation/deletion, git operations, cleanup

---

## Layer 3: Central Management (Runs Once)

### 3.1 Central Task Manager
**Purpose**: Manage pod lifecycle, central UI routing
**Scope**: Single instance for entire system
**Owns**: Creating/destroying pods, task list

**Elixir Module**: `Ipa.CentralManager`

**Responsibilities**:

- **Pod Lifecycle Management**:
  - On task creation (from central UI): spawn pod via DynamicSupervisor
  - On task completion/cancellation: gracefully shutdown pod
  - Track all active pods + their task_ids
  - Handle pod crashes (log, notify user, allow manual restart/cleanup)

- **Registry**:
  - Maintain registry of active pods
  - Map: `task_id → pod_pid` (via Elixir Registry)
  - Allow querying "is task X running?"

**Key Interfaces**:
```elixir
Ipa.CentralManager.start_pod(task_id)
  → {:ok, pod_pid}

Ipa.CentralManager.stop_pod(task_id)
  → :ok

Ipa.CentralManager.get_active_pods()
  → [task_id1, task_id2, ...]
```

**Testing**: Pod lifecycle, registry

---

### 3.2 Central Dashboard
**Purpose**: High-level view of all tasks, navigation to pods
**Scope**: Single centralized UI
**Owns**: Task listing, filtering, routing to pod UIs

**Phoenix Route & Module**: `IpaWeb.Dashboard.TasksLive`

**Features**:
- **Task List**:
  - Display all tasks (in progress, completed, etc.)
  - Status badges, timestamps
  - Not real-time (queries central manager on load)

- **Task Detail Navigation**:
  - Click task → navigate to pod's LiveView
  - Pod UI is the source of truth for real-time task details

- **Task Creation**:
  - Form to create new task
  - Central manager spawns pod

- **Task Completion/Cancellation**:
  - Buttons to mark task complete/canceled
  - Central manager shuts down pod

**Implementation**:
```elixir
defmodule IpaWeb.Dashboard.TasksLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    # Not subscribed to real-time updates (pods have their own)
    # Just load task list on demand
    tasks = Ipa.CentralManager.list_tasks()
    {:ok, assign(socket, tasks: tasks)}
  end

  def handle_event("create_task", params, socket) do
    {:ok, _pod_pid} = Ipa.CentralManager.start_pod(params["task_id"])
    {:noreply, socket}
  end

  def handle_event("navigate_to_pod", %{"task_id" => task_id}, socket) do
    {:noreply, push_navigate(socket, to: "/pods/#{task_id}")}
  end
end
```

**Testing**: Task listing, navigation

---

## Data Flow Diagrams

### Pod Lifecycle
```
User clicks "Create Task" (Central UI)
  ↓
Central Manager spawns Pod Supervisor
  ↓
Pod Supervisor starts children:
  - State Manager (loads persisted events)
  - Scheduler (starts main loop)
  - ExternalSync (polls external systems)
  - WorkspaceManager (ready for agents)
  - LiveView (registers route, awaits user navigation)
  ↓
User navigates to pod URL
  ↓
Pod LiveView connects, subscribes to pod-local pub-sub
  ↓
Scheduler evaluates state, spawns agents as needed
  ↓
Agent executes, emits logs to pod-local pub-sub
  ↓
LiveView receives logs, renders in real-time
  ↓
User approves/completes task
  ↓
Pod LiveView emits event to Pod State
  ↓
Pod State appends event, publishes to pod-local pub-sub
  ↓
Scheduler reacts, moves task forward
  ↓
(repeat until task complete)
  ↓
User clicks "Complete Task" (Pod UI)
  ↓
Pod flushes final state to persisted EventStore
  ↓
Central Manager terminates Pod Supervisor
  ↓
Pod is gone (but events persist on disk)
```

### Event Flow Within Pod
```
Scheduler emits event: "state_transition_approved"
  ↓
Calls: Pod.State.append_event(:state_transition_approved, ...)
  ↓
Pod.State:
  1. Validate version (optimistic concurrency)
  2. Append to persisted EventStore (disk/DB)
  3. Update in-memory projection
  4. Publish to pod-local pub-sub
  ↓
Pod-local pub-sub delivers to subscribers:
  - Scheduler (reacts to state change)
  - ExternalSync (may need to update JIRA/GitHub)
  - LiveView (re-renders UI)
  ↓
Each reacts independently (no inter-component dependencies)
```

---

## Development Sequencing (Pod-Based)

**Phase 1: Shared Persistence + Pod Infrastructure** (Weeks 1-2)
1. Persisted EventStore (Layer 1.1) - file or DB
2. Pod Supervisor (Layer 2.1) - basic structure
3. Pod State Manager (Layer 2.2) - load + in-memory projections
4. Manual test: create task, create pod, load state

**Phase 2: Pod UI + Central Dashboard** (Weeks 2-3)
1. Pod LiveView (Layer 2.3) - real-time task detail view
2. Central Dashboard (Layer 3.2) - task listing
3. Central Manager (Layer 3.1) - pod lifecycle
4. Integration test: create task → pod spawns → navigate to pod UI → see state

**Phase 3: Pod Scheduler + Agents** (Weeks 3-5)
1. Pod Scheduler (Layer 2.4) - state machine logic
2. Elixir Claude Code SDK integration - spawn agents
3. Pod WorkspaceManager (Layer 2.6) - workspaces for agents
4. End-to-end test: create task → scheduler drives → agent runs → state updates

**Phase 4: External Sync** (Weeks 5-6)
1. Pod ExternalSync (Layer 2.5) - JIRA/GitHub connectors
2. External Change Detection - poll for incoming changes
3. Sync approval gates (optional)

**Phase 5: Polish & Scale** (Week 7+)
1. Error handling, logging, observability
2. State snapshots for faster startup
3. Future: pod-spawning-pods or workspace multiplexing

---

## Multi-Workspace Design Considerations (TBD)

**Current (v1)**: One workspace per agent, all within single pod.

**Future Options**:

### Option A: Pod-Spawning-Pods (Recommended for True Isolation)
- Parent pod manages task lifecycle
- Child pods manage individual workspaces/parallel work
- Each child pod has its own scheduler, state, LiveView
- Benefits: True isolation, independent failure domains, natural scaling
- Trade-offs: More complexity, more supervision overhead
- Implementation: Parent pod spawns child pod supervisors

### Option B: Workspace Multiplexing (Simpler)
- Single pod manages multiple workspaces
- Scheduler coordinates which agent runs in which workspace
- Shared state across workspaces
- Benefits: Simpler, less overhead
- Trade-offs: Coupled state, harder to reason about, shared failure domain

**For v1**: Assume Option B (one workspace). Make sure design allows future migration to Option A:
- Keep workspace ID in events
- Make agent spawn logic workspace-aware
- Design pod architecture so child pods can adopt parent's state if needed

---

## Key Architectural Properties

### Isolation
- Each pod is independent: crash/restart doesn't affect other tasks
- Pod-local pub-sub: no cross-pod traffic (scalable)
- Shared persistence: events on disk/DB (durable)

### Observability
- Each pod has real-time LiveView: see task progress in real-time
- Centralized task list: see all tasks at a glance
- Event log: complete audit trail per task (survives restart)

### Resilience
- Pod crash: restart pod, reload state from disk (automatic or manual)
- Agent failure: scheduler detects, retries or escalates
- External system failure: ExternalSync retries, user approves manual retry

### Scalability
- Pods can run on different machines (future)
- Each pod is independently resource-bounded
- Event store can be shared DB (multi-pod support)

---

## Summary of Changes from v2

- **Pod-based isolation**: Each task gets its own pod (supervisor + children)
- **Distributed state**: Event store shared, but state projections pod-local
- **Pod-local pub-sub**: Fast internal communication, no cross-pod coupling
- **Central manager**: Manages pod lifecycle, routes to pod UIs
- **Central dashboard**: Task listing + navigation (not real-time)
- **Persistence**: Hard requirement; events survive pod restart
- **Multi-workspace TBD**: Design supports future child pods or multiplexing
