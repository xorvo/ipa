# Tracker: 1.1 SQLite Event Store

## Status

**Current Status**: Not Started
**Estimated Effort**: 3-4 days
**Actual Effort**: TBD

## Todo List

### Phase 1: Setup (Day 1)
- [ ] Create `lib/ipa/event_store.ex` module
- [ ] Add dependencies to `mix.exs` (ecto, ecto_sqlite3, jason)
- [ ] Create `lib/ipa/event_store/repo.ex`
- [ ] Configure repo in `config/config.exs`
- [ ] Create migration for tasks table
- [ ] Create migration for events table
- [ ] Create migration for snapshots table
- [ ] Run migrations and verify tables created

### Phase 2: Core Implementation (Day 2)
- [ ] Implement `create_task/1`
- [ ] Implement `append/4` with version increment logic
- [ ] Implement `load_events/1`
- [ ] Implement `load_events_since/2`
- [ ] Implement `get_task/1`
- [ ] Implement `list_tasks/0`
- [ ] Implement `delete_task/1`
- [ ] Add JSON serialization helpers

### Phase 3: Snapshots & Optimistic Concurrency (Day 3)
- [ ] Implement `save_snapshot/3`
- [ ] Implement `load_snapshot/1`
- [ ] Add optimistic concurrency check in `append/4`
- [ ] Add version conflict error handling
- [ ] Test concurrent write scenarios

### Phase 4: Testing (Day 3-4)
- [ ] Write unit tests for task creation
- [ ] Write unit tests for event appending
- [ ] Write unit tests for event loading
- [ ] Write unit tests for optimistic concurrency
- [ ] Write unit tests for snapshots
- [ ] Write integration test for concurrent writes
- [ ] Write integration test for event replay
- [ ] Write integration test for snapshot + replay
- [ ] Run performance benchmarks

### Phase 5: Documentation & Polish (Day 4)
- [ ] Add @doc comments to all public functions
- [ ] Add @spec typespecs
- [ ] Create example usage in module doc
- [ ] Document error cases
- [ ] Review and refactor

## Progress Log

### 2025-11-05
- Spec created
- Folder structure created

## Issues

None yet.

## Notes

- Using `:memory:` database for tests to speed up test suite
- Consider adding `correlation_id` to events table later for tracing
- May need to add indexes if query performance becomes an issue
