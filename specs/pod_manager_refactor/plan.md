# Pod.Manager Refactor Plan

## Problem Summary

The current architecture has state fragmented across multiple locations:
- **EventStore (DB)**: Canonical event history
- **Pod.State GenServer**: In-memory projection from events
- **Pod.Scheduler GenServer**: Duplicate phase tracking, agent PIDs, cooldown state
- **LiveView**: Derived view state

This causes synchronization issues, race conditions, and unnecessary complexity for a local-only application.

## Goal

Merge `Pod.State` and `Pod.Scheduler` into a single `Pod.Manager` GenServer that owns all pod-level state. Events become an audit log rather than the runtime source of truth.

## New Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     Pod.Manager                         │
│                                                         │
│  GenServer state:                                       │
│  - task_id                                              │
│  - phase (:spec_clarification, :planning, etc.)         │
│  - spec, plan, title                                    │
│  - workstreams: %{ws_id => workstream_state}            │
│  - active_agents: %{ws_id => %{pid, agent_id}}          │
│  - messages, inbox                                      │
│  - external_sync                                        │
│                                                         │
│  Scheduler logic (evaluate/act loop) runs here          │
│  Events appended to DB for audit/recovery               │
└─────────────────────────────────────────────────────────┘
                         │
                         │ PubSub: "pod:{task_id}"
                         │ (single topic for all updates)
                         ▼
                  ┌──────────────┐
                  │   LiveView   │
                  └──────────────┘
```

## Key Design Decisions

### 1. State Ownership
- `Pod.Manager` owns the runtime state directly in GenServer memory
- No more "projection from events" at runtime
- State changes happen via GenServer calls, not event replay

### 2. Events as Audit Log
- Events are still appended to EventStore for:
  - Startup recovery (rebuild state from events)
  - Debugging/auditing
  - Future features (replay, time-travel debugging)
- Events are written **after** state changes, not as the mechanism for state changes

### 3. Simplified Concurrency
- Remove optimistic locking / version checks
- Single GenServer serializes all state mutations
- No race conditions possible within a pod

### 4. Single PubSub Topic
- One topic per pod: `"pod:{task_id}"`
- Messages: `{:state_updated, state}`, `{:agent_started, agent_id}`, etc.
- LiveView subscribes; no other internal subscribers needed

## Implementation Steps

### Step 1: Create Pod.Manager Module

Create `lib/ipa/pod/manager.ex`:

```elixir
defmodule Ipa.Pod.Manager do
  use GenServer

  defstruct [
    :task_id,
    :phase,
    :title,
    :spec,
    :plan,
    :workstreams,        # %{ws_id => %{status, spec, dependencies, ...}}
    :active_agents,      # %{ws_id => %{pid, agent_id, started_at}}
    :messages,
    :inbox,
    :external_sync,
    :created_at,
    :updated_at,

    # Scheduler state (previously in Pod.Scheduler)
    :pending_action,
    :last_evaluation,
    :cooldown_until
  ]
end
```

### Step 2: Implement Core API

Public functions needed:

```elixir
# Lifecycle
start_link(task_id: task_id)
get_state(task_id) :: {:ok, state}

# Task mutations
update_spec(task_id, spec_data)
approve_spec(task_id, approved_by)
update_plan(task_id, plan_data)
approve_plan(task_id, approved_by)
transition_phase(task_id, to_phase, reason)

# Workstream mutations
create_workstream(task_id, workstream_data)
start_workstream(task_id, workstream_id, agent_id, agent_pid)
complete_workstream(task_id, workstream_id, result)
fail_workstream(task_id, workstream_id, error)

# Agent tracking
register_agent(task_id, workstream_id, agent_id, pid)
unregister_agent(task_id, workstream_id)

# Scheduler control
evaluate_now(task_id)  # Force immediate evaluation
interrupt_agent(task_id, agent_id)
```

### Step 3: Move Scheduler Logic

Move from `Pod.Scheduler` into `Pod.Manager`:

1. **Evaluation loop**: `handle_info(:evaluate, state)` stays, but now operates on direct state
2. **State machine**: `evaluate_state_machine/1` takes `state` directly (no separate task_state)
3. **Action execution**: `execute_action/2` mutates state directly, returns new state
4. **Agent monitoring**: Process.monitor calls happen here

Key simplification - the scheduler no longer needs to:
- Call `Pod.State.get_state()` - it already has the state
- Track `current_phase` separately - it's in the state
- Maintain `active_workstream_agents` separately - it's `state.active_agents`

### Step 4: Simplify Event Recording

Events become fire-and-forget audit entries:

```elixir
defp record_event(state, event_type, event_data) do
  # Async write to EventStore - don't block on it
  Task.start(fn ->
    Ipa.EventStore.append(state.task_id, event_type, event_data, actor_id: "system")
  end)
end
```

Or synchronous but not blocking state changes:

```elixir
defp record_event(state, event_type, event_data) do
  # Write event, ignore result
  Ipa.EventStore.append(state.task_id, event_type, event_data, actor_id: "system")
  :ok
end
```

### Step 5: Startup Recovery

On `init/1`, rebuild state from events:

```elixir
def init(opts) do
  task_id = Keyword.fetch!(opts, :task_id)

  # Load state from events (same logic as current Pod.State)
  state = case Ipa.EventStore.read_stream(task_id) do
    {:ok, events} ->
      Enum.reduce(events, initial_state(task_id), &apply_event/2)
    {:error, _} ->
      initial_state(task_id)
  end

  # Clear any stale active_agents (processes are gone after restart)
  state = %{state | active_agents: %{}}

  # Schedule first evaluation
  send(self(), :evaluate)

  {:ok, state}
end
```

### Step 6: Update Pod Supervisor

Change `lib/ipa/pod/pod.ex` children:

```elixir
defp build_children(task_id) do
  [
    {Ipa.Pod.Manager, task_id: task_id},           # Replaces State + Scheduler
    {Ipa.Pod.CommunicationsManager, task_id},      # Keep as-is
    {Ipa.Pod.WorkspaceManager, task_id: task_id},  # Keep as-is
    {Ipa.Agent.Supervisor, task_id: task_id}       # Keep as-is
  ]
end
```

### Step 7: Update LiveView

Change `TaskLive` to use new API:

```elixir
# Before
def mount(%{"task_id" => task_id}, _session, socket) do
  Ipa.Pod.State.subscribe(task_id)
  {:ok, state} = Ipa.Pod.State.get_state(task_id)
  ...
end

# After
def mount(%{"task_id" => task_id}, _session, socket) do
  Phoenix.PubSub.subscribe(Ipa.PubSub, "pod:#{task_id}")
  {:ok, state} = Ipa.Pod.Manager.get_state(task_id)
  ...
end
```

### Step 8: Delete Old Modules

After migration is complete and tested:
- Delete `lib/ipa/pod/state.ex`
- Delete `lib/ipa/pod/scheduler.ex`

## Files to Modify

| File | Action |
|------|--------|
| `lib/ipa/pod/manager.ex` | **CREATE** - New combined module |
| `lib/ipa/pod/pod.ex` | Modify - Update children list |
| `lib/ipa/pod/state.ex` | **DELETE** after migration |
| `lib/ipa/pod/scheduler.ex` | **DELETE** after migration |
| `lib/ipa_web/live/pod/task_live.ex` | Modify - Use Pod.Manager API |
| `lib/ipa/pod/communications_manager.ex` | Modify - Use Pod.Manager for state |
| `lib/ipa/pod/workspace_manager.ex` | No change (independent) |
| `lib/ipa/agent/supervisor.ex` | No change |
| `lib/ipa/agent/instance.ex` | Modify - Notify Pod.Manager instead of recording events directly |

## Testing Strategy

1. **Unit tests for Pod.Manager**: Test state transitions, workstream lifecycle
2. **Integration test**: Start pod, create workstreams, run to completion
3. **Recovery test**: Kill pod, restart, verify state recovered from events

## Migration Path

1. Create `Pod.Manager` with full API
2. Update `Pod` supervisor to use `Pod.Manager`
3. Update LiveView to use new API
4. Run tests, fix issues
5. Delete `Pod.State` and `Pod.Scheduler`

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Event format changes | Keep same event format; just change when/how they're written |
| Lost events on crash | Write events synchronously before returning from mutations |
| Test coverage gaps | Run existing tests against new implementation first |

## Out of Scope

- EventStore schema changes (keep as-is)
- Agent system changes (keep Agent.Supervisor, Agent.Instance as-is)
- WorkspaceManager changes
- CommunicationsManager internal changes (just update how it gets state)
