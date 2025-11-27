# Pod State Machine Refactor - Implementation Tracker

## Status: Planning Complete

**Started**: 2025-01-27
**Target**: Clean separation of Events, State, Commands, Machine, Manager

---

## Implementation Checklist

### Phase 1: Create New Modules (Non-Breaking)

#### Events Module
- [ ] Create `lib/ipa/pod/events/event.ex` - Base behavior/protocol
- [ ] Create `lib/ipa/pod/events/task_events.ex`
  - [ ] `TaskCreated`
  - [ ] `SpecUpdated`
  - [ ] `SpecApproved`
- [ ] Create `lib/ipa/pod/events/phase_events.ex`
  - [ ] `TransitionRequested`
  - [ ] `TransitionApproved`
  - [ ] `PhaseChanged`
- [ ] Create `lib/ipa/pod/events/workstream_events.ex`
  - [ ] `WorkstreamCreated`
  - [ ] `WorkstreamStarted`
  - [ ] `WorkstreamCompleted`
  - [ ] `WorkstreamFailed`
- [ ] Create `lib/ipa/pod/events/communication_events.ex`
  - [ ] `MessagePosted`
  - [ ] `ApprovalRequested`
  - [ ] `ApprovalGiven`
  - [ ] `NotificationCreated`
  - [ ] `NotificationRead`

#### State Module
- [ ] Create `lib/ipa/pod/state/state.ex` - Main state struct
- [ ] Create nested structs:
  - [ ] `Ipa.Pod.State.Workstream`
  - [ ] `Ipa.Pod.State.Message`
  - [ ] `Ipa.Pod.State.Notification`
  - [ ] `Ipa.Pod.State.Agent`
- [ ] Create `lib/ipa/pod/state/projector.ex` - Event router
- [ ] Create `lib/ipa/pod/state/projections/task_projection.ex`
- [ ] Create `lib/ipa/pod/state/projections/phase_projection.ex`
- [ ] Create `lib/ipa/pod/state/projections/workstream_projection.ex`
- [ ] Create `lib/ipa/pod/state/projections/communication_projection.ex`

#### Machine Module
- [ ] Create `lib/ipa/pod/machine/machine.ex` - Phase definitions
- [ ] Create `lib/ipa/pod/machine/guards.ex` - Transition guards
- [ ] Create `lib/ipa/pod/machine/evaluator.ex` - Scheduler logic

#### Commands Module
- [ ] Create `lib/ipa/pod/commands/command.ex` - Base behavior
- [ ] Create `lib/ipa/pod/commands/task_commands.ex`
- [ ] Create `lib/ipa/pod/commands/phase_commands.ex`
- [ ] Create `lib/ipa/pod/commands/workstream_commands.ex`
- [ ] Create `lib/ipa/pod/commands/communication_commands.ex`

#### Tests for New Modules
- [ ] `test/ipa/pod/events/` - Event serialization tests
- [ ] `test/ipa/pod/state/` - Projection tests
- [ ] `test/ipa/pod/machine/` - State machine tests
- [ ] `test/ipa/pod/commands/` - Command validation tests

### Phase 2: Parallel Operation
- [ ] Create `Ipa.Pod.ManagerV2` using new architecture
- [ ] Add feature flag to switch between old/new
- [ ] Verify state consistency tests

### Phase 3: Switchover
- [ ] Update `CommunicationsManager` to use new patterns
- [ ] Update `WorkspaceManager` to use new events
- [ ] Update `IpaWeb.Pod.TaskLive` for new state structure
- [ ] Remove old `Pod.Manager`

### Phase 4: Cleanup
- [ ] Remove `CommunicationsManager` local state caching
- [ ] Update all external callers
- [ ] Remove deprecated code
- [ ] Update all tests

---

## Notes & Decisions

### Design Decisions Made

1. **Event Protocol vs Behavior**: Using `@behaviour` for events allows compile-time checking while keeping serialization flexible.

2. **Projections as Separate Modules**: Instead of one giant `apply_event/2`, each domain (task, phase, workstream, communication) has its own projection module.

3. **Commands Return Event Lists**: Commands validate and return events, manager persists them. This separates concerns clearly.

4. **State Machine as Data**: Transitions defined as a simple map, guards as functions. Easy to test and extend.

5. **Manager as Orchestrator**: Manager only routes, persists, and broadcasts. Business logic lives in commands/projections/evaluator.

### Open Questions

1. **Plan Events**: Should plan management have its own event types? Currently folded into task events.

2. **Agent Events**: Should agent lifecycle be separate from workstream events?

3. **Snapshot Strategy**: When to take snapshots? After N events? After phase changes?

---

## Progress Log

**2025-01-27**
- Created initial spec with full module definitions
- Defined all event types, state structs, projections, commands, machine
- Wrote migration plan with 4 phases

---

## Files to Create

```
lib/ipa/pod/
├── events/
│   ├── event.ex
│   ├── task_events.ex
│   ├── phase_events.ex
│   ├── workstream_events.ex
│   └── communication_events.ex
├── state/
│   ├── state.ex
│   ├── projector.ex
│   └── projections/
│       ├── task_projection.ex
│       ├── phase_projection.ex
│       ├── workstream_projection.ex
│       └── communication_projection.ex
├── machine/
│   ├── machine.ex
│   ├── guards.ex
│   └── evaluator.ex
├── commands/
│   ├── command.ex
│   ├── task_commands.ex
│   ├── phase_commands.ex
│   ├── workstream_commands.ex
│   └── communication_commands.ex
└── manager.ex (updated)

test/ipa/pod/
├── events/
│   ├── task_events_test.exs
│   ├── phase_events_test.exs
│   ├── workstream_events_test.exs
│   └── communication_events_test.exs
├── state/
│   ├── projector_test.exs
│   └── projections/
│       ├── task_projection_test.exs
│       ├── phase_projection_test.exs
│       ├── workstream_projection_test.exs
│       └── communication_projection_test.exs
├── machine/
│   ├── machine_test.exs
│   ├── guards_test.exs
│   └── evaluator_test.exs
└── commands/
    ├── task_commands_test.exs
    ├── phase_commands_test.exs
    ├── workstream_commands_test.exs
    └── communication_commands_test.exs
```
