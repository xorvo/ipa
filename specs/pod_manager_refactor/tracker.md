# Pod.Manager Refactor Tracker

## Status: COMPLETED

## Summary

Successfully merged `Pod.State` and `Pod.Scheduler` functionality into a single unified `Pod.Manager` GenServer. The new architecture simplifies the pod infrastructure by:

- Holding state directly in GenServer memory (no external projections at runtime)
- Running scheduler evaluation as an internal handler
- Recording events to EventStore as an audit log (write-through, not read-back)
- Broadcasting state changes via single PubSub topic

## Completed Tasks

### 1. Created Pod.Manager Module ✓
- **File**: `lib/ipa/pod/manager.ex`
- Combined state management and scheduling into single GenServer
- Implemented state struct with all necessary fields
- Added event replay for state recovery on startup
- Implemented scheduler evaluation loop (handle_info(:evaluate, state))
- Added workstream dependency management
- Added agent lifecycle notifications

### 2. Updated Pod Supervisor ✓
- **File**: `lib/ipa/pod/pod.ex`
- Changed `build_children/1` to include Pod.Manager instead of Pod.State + Pod.Scheduler
- Child processes now: Agent.Supervisor, WorkspaceManager, Manager, CommunicationsManager

### 3. Updated TaskLive ✓
- **File**: `lib/ipa_web/live/pod/task_live.ex`
- Changed alias from State to Manager
- Updated all `State.get_state_from_events` calls to `Manager.get_state_from_events`
- Updated subscribe call to `Manager.subscribe`

### 4. Updated CommunicationsManager ✓
- **File**: `lib/ipa/pod/communications_manager.ex`
- Changed init to use `Pod.Manager.subscribe` and `Pod.Manager.get_state`
- Updated all `append_event` calls to use `Ipa.Pod.Manager.append_event`
- Added error handling for when Manager not running yet

### 5. Updated Agent.Instance ✓
- **File**: `lib/ipa/agent/instance.ex`
- Changed `record_lifecycle_event` to use `Pod.Manager.append_event`
- Added `Pod.Manager.notify_agent_completed` and `notify_agent_failed` calls

### 6. Updated Tests ✓
- **File**: `test/ipa/pod/communications_manager_test.exs`
- Changed setup to start Manager instead of State
- Replaced all `State.get_state` with `Manager.get_state`
- Removed `State.reload_state` calls

## Test Results

All tests pass:
```
288 tests, 0 failures, 1 skipped
```

## Key Implementation Details

### State Structure
```elixir
defstruct [
  :task_id,
  :title,
  :version,
  :created_at,
  :updated_at,
  phase: :spec_clarification,
  spec: %{},
  plan: nil,
  workstreams: %{},
  agents: [],
  messages: [],
  inbox: [],
  pending_transitions: [],
  pending_workspaces: %{},  # agent_id => workspace_path (temporary storage)
  config: %{
    max_concurrent_agents: 3,
    evaluation_interval: 5_000
  }
]
```

### Key API Functions
- `get_state/1` - Get current state from running Manager
- `get_state_from_events/1` - Rebuild state from EventStore (for stopped pods)
- `append_event/5` - Append event and update state
- `notify_agent_completed/3` - Notify of agent completion
- `notify_agent_failed/3` - Notify of agent failure
- `subscribe/1` - Subscribe to state changes
- `evaluate/1` - Trigger scheduler evaluation

### Event Handling
Events applied on append:
- task_created, spec_updated, spec_approved
- plan_updated, plan_approved
- phase_changed, transition_requested, transition_approved
- workstream_created, workspace_created, workstream_agent_started
- workstream_completed, workstream_failed
- agent_started, agent_completed, agent_failed
- message_posted, approval_requested, approval_given
- notification_created, notification_read

### Workspace Association
The `pending_workspaces` map solves the problem of associating workspace paths with workstreams:
1. When `workspace_created` event fires, workspace path is stored by agent_id
2. When `workstream_agent_started` event fires, workspace path is retrieved and associated with workstream

## Architecture Notes

### Old vs New
| Old Architecture | New Architecture |
|-----------------|------------------|
| Pod.State (GenServer) | Pod.Manager (GenServer) |
| Pod.Scheduler (GenServer) | (merged into Manager) |
| Two separate pub-sub topics | Single "pod:{task_id}" topic |
| State rebuilt from events on each query | State in memory, events as audit log |

### Legacy Modules
The old `Pod.State` and `Pod.Scheduler` modules are still present in the codebase with their tests. They remain for:
- Backwards compatibility during migration
- Reference implementation
- Test coverage of original design

In a future cleanup, these could be removed once all code paths use Pod.Manager exclusively.

## Issues Encountered and Resolved

1. **Agent.Supervisor.start_agent/4 doesn't exist**: Changed to start_agent/3 (auto-generates agent_id)

2. **Message struct missing `approved?` field**: Added `approved?: false` to build_message function

3. **Map update syntax error**: Changed from `%{msg | key: value}` to `Map.put(msg, :key, value)` for plain maps

4. **Notification not cleared on approval**: Added inbox clearing logic in approval_given handler

5. **workspace_created event not linking to workstream**: Added pending_workspaces mechanism

6. **Agent record missing fields**: Added `completed_at: nil, error: nil` defaults

## Future Considerations

- Remove legacy Pod.State and Pod.Scheduler modules after full migration
- Add snapshot support for faster startup with large event streams
- Consider splitting Manager into smaller modules if it grows too large
- Add metrics/observability for evaluation loop performance
