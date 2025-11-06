# Component 3.1 Central Task Manager - Progress Tracker

**Component**: 3.1 Central Task Manager
**Status**: Spec Revised (v2.0)
**Last Updated**: 2025-11-06

## Overview

This document tracks the progress of implementing the Central Task Manager component. Use this file to log work progress, track todos, and document decisions made during implementation.

## Current Status

- [x] Spec created (`spec.md` v1.0)
- [x] Spec reviewed by architecture-strategist (Score: 6.5/10, needs revision)
- [x] Spec revised to v2.0 (all P0 and P1 issues addressed)
- [ ] Spec approved (ready for second review)
- [ ] Implementation started
- [ ] Implementation completed
- [ ] Tests written
- [ ] Tests passing
- [ ] Code review
- [ ] Merged to main

## Implementation Todos

### Phase 1: Core GenServer Setup
- [ ] Create `lib/ipa/central/` directory
- [ ] Create `lib/ipa/central/task_manager.ex` GenServer module
- [ ] Create `lib/ipa/central_manager.ex` facade module
- [ ] Define GenServer state structure
- [ ] Implement `start_link/1` and `init/1`
- [ ] Add to application supervision tree
- [ ] Write basic GenServer tests

### Phase 2: Task Creation
- [ ] Implement `create_task/2` function
- [ ] Generate UUID for task_id
- [ ] Create stream in Event Store
- [ ] Append `:task_created` event
- [ ] Handle auto_start option
- [ ] Write task creation tests
- [ ] Test concurrent task creation

### Phase 3: Pod Lifecycle Coordination
- [ ] Implement `start_pod/1` function
- [ ] Verify task exists in Event Store
- [ ] Call `Ipa.PodSupervisor.start_pod/1`
- [ ] Add process monitoring for pod
- [ ] Implement `stop_pod/1` function
- [ ] Implement `restart_pod/1` function
- [ ] Write pod lifecycle tests

### Phase 4: Pod Monitoring & Crash Recovery
- [ ] Implement `handle_info/2` for `:DOWN` messages
- [ ] Log pod crashes
- [ ] Record crash history
- [ ] Implement `should_auto_restart?/2` logic
- [ ] Implement auto-restart if configured
- [ ] Test pod crash detection
- [ ] Test auto-restart logic
- [ ] Test max restart attempts

### Phase 5: Task Querying
- [ ] Implement `get_task/1` function
- [ ] Build task metadata from events
- [ ] Combine Event Store + Pod Supervisor data
- [ ] Implement `list_tasks/1` function
- [ ] Implement filtering (status, phase, created_after)
- [ ] Implement pagination (limit, offset)
- [ ] Implement `count_tasks/1` function
- [ ] Write querying tests

### Phase 6: Task Completion/Cancellation
- [ ] Implement `complete_task/1` function
- [ ] Append `:task_completed` event
- [ ] Stop pod if running
- [ ] Implement `cancel_task/2` function
- [ ] Append `:task_cancelled` event
- [ ] Validate task not already completed/cancelled
- [ ] Write completion/cancellation tests

### Phase 7: Helper Functions
- [ ] Implement `get_active_pods/0`
- [ ] Implement `pod_running?/1`
- [ ] Implement `build_task_from_events/1`
- [ ] Implement `infer_phase_from_events/1`
- [ ] Implement `infer_status_from_events/1`
- [ ] Implement `apply_filters/2`

### Phase 8: Configuration & Integration
- [ ] Add configuration options to `config.exs`
- [ ] Test configuration loading
- [ ] Integration test with Event Store
- [ ] Integration test with Pod Supervisor
- [ ] End-to-end test: create → start → stop → complete

### Phase 9: Performance & Polish
- [ ] Performance test: list_tasks with 100 tasks
- [ ] Performance test: list_tasks with 1000 tasks
- [ ] Performance test: concurrent task creation
- [ ] Add logging statements
- [ ] Add telemetry events
- [ ] Code review
- [ ] Address review feedback

## Revision History

### Version 2.0 (2025-11-06)

**Major revision addressing architectural review feedback**

**All P0 (Critical) Issues Resolved:**
- ✅ P0-1: Removed all direct event interpretation logic; now queries Pod State Manager for active pods and metadata table for inactive
- ✅ P0-2: Added tasks metadata table schema; fixed Event Store API usage to use correct `start_stream/2`
- ✅ P0-3: Added idempotency check in `start_pod/1` to prevent race conditions
- ✅ P0-4: Made API consistent with opts-based pattern; added actor_id and correlation_id tracking throughout
- ✅ P0-5: Defined `find_task_by_monitor_ref/2` helper; added nil handling in crash detection

**All P1 (Major) Issues Resolved:**
- ✅ P1-1: State aggregation now properly queries Pod State Manager for active pods
- ✅ P1-2: Added tasks metadata table for efficient listing (O(n) instead of O(n×m))
- ✅ P1-3: Added title validation (empty check, length limit)
- ✅ P1-4: Fixed supervision tree integration with proper child_spec
- ✅ P1-5: Added demonitor logic in `stop_pod/1` to prevent memory leaks
- ✅ P1-6: Added Pod Supervisor monitoring and reconnection logic
- ✅ P1-7: Added 30-second timeouts for GenServer calls
- ✅ P1-8: Added periodic crash history cleanup (every hour, keep 24h)

**Key Architectural Changes:**
1. Added `tasks` metadata table for efficient querying
2. Central Manager now delegates to Pod State Manager (Layer 2) for active task state
3. API now consistently tracks audit trail (actor_id, correlation_id)
4. All race conditions and memory leaks fixed
5. Resilience improvements: Pod Supervisor monitoring, graceful degradation

**Database Schema Added:**
- `tasks` table with indexes on status, phase, created_at, updated_at, created_by
- Foreign key to streams table with cascade delete

### Version 1.0 (2025-11-06)

Initial spec with architectural issues identified in review.

## Blockers

### Current Blockers
- Component 1.1 (Event Store) must be implemented first
- Component 2.1 (Pod Supervisor) must be implemented first
- Component 2.2 (Pod State Manager) must be accessible via Registry

### Resolved Blockers
None yet

## Design Decisions

### Decision Log

#### Decision 1: Pod Monitoring Strategy
**Date**: TBD
**Decision**: Monitor pods using Process.monitor/1 for crash detection
**Rationale**: Native Elixir process monitoring provides reliable crash detection with minimal overhead
**Alternatives Considered**: Polling, Registry tracking
**Trade-offs**: Process monitoring creates monitor refs that must be cleaned up

#### Decision 2: Auto-Restart Default
**Date**: TBD
**Decision**: Auto-restart on crash is disabled by default
**Rationale**: Explicit recovery is safer than automatic restarts; prevents cascading failures
**Alternatives Considered**: Always auto-restart, configurable per task
**Trade-offs**: Requires manual intervention for recovery

#### Decision 3: State Aggregation Strategy
**Date**: TBD
**Decision**: Combine Event Store + Pod Supervisor data in `get_task/1`
**Rationale**: Provides complete task view; Event Store has history, Pod Supervisor has runtime status
**Alternatives Considered**: Separate APIs for history and runtime, cache combined state
**Trade-offs**: Slightly slower queries, but more accurate and consistent

## Issues & Questions

### Open Questions
1. Should `list_tasks/1` cache results? (Answer: No, query Event Store directly for accuracy)
2. Should we track task ownership/permissions? (Answer: Future enhancement)
3. Should we support task search/filtering by title? (Answer: Future enhancement)

### Resolved Questions
None yet

## Testing Notes

### Test Coverage Goals
- Unit test coverage: 90%+
- Integration test coverage: All major flows
- Performance tests: All listing operations

### Test Data
- Create test tasks with various states
- Create test tasks with different phases
- Test with 1, 10, 100, 1000 tasks

### Known Test Issues
None yet

## Performance Notes

### Expected Performance
- `create_task/2`: < 50ms
- `start_pod/1`: < 100ms
- `get_task/1`: < 10ms
- `list_tasks/1` (100 tasks): < 100ms
- `list_tasks/1` (1000 tasks): < 500ms

### Actual Performance
TBD after implementation

## Integration Notes

### Event Store Integration
- Requires `start_stream/2` function
- Requires `stream_exists?/1` function
- Requires `list_streams/1` function
- Requires `read_stream/2` function
- Requires `append/4` function

### Pod Supervisor Integration
- Requires `start_pod/1` function
- Requires `stop_pod/1` function
- Requires `pod_running?/1` function
- Requires `get_pod_pid/1` function
- Requires `list_pods/0` function

## Deployment Notes

### Pre-Deployment Checklist
- [ ] All tests passing
- [ ] Performance tests passing
- [ ] Configuration documented
- [ ] Monitoring metrics defined
- [ ] Code reviewed and approved
- [ ] Migration guide written (if needed)

### Post-Deployment Monitoring
- Track task creation rate
- Track pod crash rate
- Track restart success rate
- Track average task duration

## References

- Event Store spec: `specs/1.1_event_store/spec.md`
- Pod Supervisor spec: `specs/2.1_pod_supervisor/spec.md`
- Project overview: `specs/00_overview.md`
- Status tracker: `specs/STATUS.md`
