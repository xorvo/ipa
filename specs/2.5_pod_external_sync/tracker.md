# Pod External Sync - Implementation Tracker

## Status: COMPLETE (GitHub Only)

## Completed Tasks

### Core Implementation
- [x] ExternalSync GenServer (`lib/ipa/pod/external_sync.ex`)
  - PR creation, update, merge, close operations
  - Polling with adaptive rate limiting
  - Pub-sub integration for state change reactions
  - Approval request integration with Communications Manager

### GitHub Connector
- [x] GitHubConnector (`lib/ipa/pod/external_sync/github_connector.ex`)
  - Uses `gh` CLI for GitHub operations
  - PR CRUD operations (create, update, merge, close)
  - Comment operations
  - Rate limit detection
  - Authentication checking

### Sync Queue
- [x] SyncQueue (`lib/ipa/pod/external_sync/sync_queue.ex`)
  - Queued operation execution
  - Deduplication of identical pending operations
  - Retry with exponential backoff
  - Rate limit awareness

### Integration
- [x] Added ExternalSync as optional child in Pod supervisor
  - Conditionally started when GitHub is configured
  - Configuration via `:github` application env

### Testing
- [x] ExternalSync tests (`test/ipa/pod/external_sync_test.exs`)
  - 13 tests covering all modules
  - All tests passing

## Skipped (Per User Request)
- [ ] JIRA Integration (JiraConnector)
  - User requested to skip to avoid polluting current JIRA instance
  - Module structure defined in spec but not implemented

## Configuration

GitHub sync is enabled per-workstream. Each workstream can target a different repo:

```elixir
# When creating a workstream event:
Ipa.Pod.State.append_event(task_id, "workstream_created", %{
  workstream_id: "ws-1",
  spec: "Implement backend API",
  repo: "myorg/backend-repo",      # GitHub repo for this workstream
  branch: "main",                   # Base branch
  dependencies: []
}, nil, actor_id: "human")

# Another workstream can target a different repo:
Ipa.Pod.State.append_event(task_id, "workstream_created", %{
  workstream_id: "ws-2",
  spec: "Update frontend",
  repo: "myorg/frontend-repo",     # Different repo
  branch: "develop",
  dependencies: ["ws-1"]
}, nil, actor_id: "human")
```

PRs are created per-workstream, targeting the workstream's configured repo.

## Notes

- GitHub operations use `gh` CLI which handles authentication
- ExternalSync auto-creates draft PRs when task enters workstream_execution phase
- Polling interval adapts based on rate limiting (5 min default, 1-30 min range)
- All operations go through sync queue for deduplication and retry handling
