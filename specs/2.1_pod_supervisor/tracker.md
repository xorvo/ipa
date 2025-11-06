# Tracker: 2.1 Pod Supervisor

## Status

**Current Status**: Not Started
**Estimated Effort**: 2 days
**Actual Effort**: TBD
**Depends On**: 1.1 SQLite Event Store (must be completed first)

## Todo List

### Phase 1: Core Structure (Day 1 - Morning)
- [ ] Create `lib/ipa/pod/` directory structure
- [ ] Implement `Ipa.PodRegistry` module
- [ ] Add PodRegistry to application supervision tree
- [ ] Implement `Ipa.PodSupervisor` as DynamicSupervisor
- [ ] Add PodSupervisor to application supervision tree
- [ ] Write unit tests for registry operations

### Phase 2: Pod Implementation (Day 1 - Afternoon)
- [ ] Implement `Ipa.Pod` module (per-pod Supervisor)
- [ ] Implement `start_link/1` with child specifications
- [ ] Implement `child_spec/1` for DynamicSupervisor
- [ ] Define pod supervision strategy (one_for_one, transient)
- [ ] Test pod starts with mock children

### Phase 3: Lifecycle Management (Day 2 - Morning)
- [ ] Implement `start_pod/1` in PodSupervisor
- [ ] Implement `stop_pod/1` and `stop_pod/2`
- [ ] Implement `restart_pod/1`
- [ ] Implement `get_pod_pid/1`
- [ ] Implement `pod_running?/1`
- [ ] Add stream existence check (integration with Event Store)
- [ ] Add duplicate pod detection

### Phase 4: Query & Management (Day 2 - Afternoon)
- [ ] Implement `list_pods/0`
- [ ] Implement `count_pods/0`
- [ ] Add graceful shutdown logic
- [ ] Add shutdown timeout handling
- [ ] Implement registry metadata tracking

### Phase 5: Testing (Day 2 - Afternoon)
- [ ] Write unit tests for start_pod
- [ ] Write unit tests for stop_pod
- [ ] Write unit tests for restart_pod
- [ ] Write unit tests for query functions
- [ ] Write integration test for child supervision
- [ ] Write integration test for multiple pods
- [ ] Write integration test for graceful shutdown
- [ ] Write performance tests for registry operations

### Phase 6: Documentation & Polish (Day 2 - End)
- [ ] Add @doc comments to all public functions
- [ ] Add @spec typespecs
- [ ] Add module documentation
- [ ] Add usage examples
- [ ] Document configuration options
- [ ] Review and refactor

## Progress Log

### [Date]
- Spec created
- Folder structure created

## Issues

None yet.

## Notes

- Pod Supervisor is a foundation component for Layer 2
- All other pod components (2.2-2.6) depend on this
- Keep it simple - no business logic, just lifecycle management
- Registry is critical for fast lookups
- Graceful shutdown is important for state persistence

## Dependencies Status

- ✅ 1.1 Event Store - Must be completed before starting
- ⏳ Other components will depend on this being finished

## Blocked Components

These components cannot start until Pod Supervisor is complete:
- 2.2 Pod State Manager
- 2.4 Pod Workspace Manager
- 2.5 Pod External Sync
- 2.6 Pod LiveView UI
- 3.1 Central Task Manager
