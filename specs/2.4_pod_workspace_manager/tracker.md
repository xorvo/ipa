# Pod Workspace Manager - Implementation Tracker

## Status
**Phase**: Spec Revision (Critical Fixes Applied)
**Last Updated**: 2025-11-05

## Critical Architectural Fixes (2025-11-05)

Following architectural review, three critical issues were identified and fixed in the spec:

### ✅ P0-1: State Management (FIXED)
**Issue**: GenServer state duplicated event store data, violating event sourcing principles.
**Resolution**: Implemented event-sourced state approach with explicit event replay logic in `init/1`.
**Changes**:
- Added `apply_workspace_event/2` pattern for state reconstruction
- State is now rebuilt from events on GenServer initialization
- Documented benefits: state consistency, automatic crash recovery, follows event sourcing best practices

### ✅ P0-2: Path Validation Security (FIXED)
**Issue**: Path validation was insufficient - vulnerable to symlink attacks, special characters, path traversal.
**Resolution**: Implemented comprehensive security checks with multiple validation layers.
**Changes**:
- Added `validate_relative_path_format/1` - checks for null bytes, absolute paths, `..` sequences, path length
- Added `check_symlinks/3` - recursively checks symlinks don't escape workspace
- Added `resolve_symlinks_in_path/1` - resolves all symlinks in path
- Security properties documented: prevents directory traversal, symlink attacks, special characters

### ✅ P0-3: Graceful Shutdown (FIXED)
**Issue**: Missing `terminate/2` callback required by Pod Supervisor contract.
**Resolution**: Implemented `terminate/2` with configurable workspace cleanup on shutdown.
**Changes**:
- Added graceful shutdown implementation with 5-second timeout
- Cleanup controlled by `cleanup_on_pod_shutdown` config (default: true)
- Best-effort event recording (Pod.State may be down during shutdown)
- Documented shutdown behavior and configuration options

### ✅ MAJOR CLARIFICATION: `aw` CLI Integration (2025-11-05)

**Critical architectural clarification received from stakeholder:**

The WorkspaceManager's **primary role** is integrating with the external `aw` CLI tool, NOT directly managing filesystem operations. Agents work directly in their workspace via Claude Code SDK.

**Changes Made:**
- **Overview Section**: Clarified primary role is `aw` CLI integration
- **Key Responsibilities**: Reorganized to emphasize `aw create`, `aw destroy`, `aw list` operations
- **New Section**: Added comprehensive "`aw` CLI Integration" section with:
  - `aw create` command documentation
  - `aw destroy` command documentation
  - `aw list` command documentation
  - Elixir integration patterns using `System.cmd/3`
  - Error handling for `aw` command failures
  - `aw` CLI availability verification
- **Public API**: Updated `create_workspace/3`, `cleanup_workspace/2`, `list_workspaces/1` to clarify they wrap `aw` commands
- **File Operations**: Clarified `read_file/3` and `write_file/4` are **optional utilities** for pod-level inspection, NOT used by agents
- **Integration Points**: Added detailed agent execution flow showing agents work in workspace via `cwd` parameter
- **Workspace Initialization**: Clarified `aw create` handles directory creation, NOT WorkspaceManager
- **Workspace Cleanup**: Clarified `aw destroy` handles deletion, NOT WorkspaceManager
- **Graceful Shutdown**: Updated to use `aw list` and `aw destroy` commands
- **Testing Strategy**: Added `aw` CLI mocking patterns and integration test scenarios

**Architecture Implications:**
- WorkspaceManager is a thin wrapper around `aw` CLI
- Agents execute in workspace directory via Claude Code SDK with `cwd` parameter
- Agents use standard file operations (NOT WorkspaceManager's read_file/write_file)
- `aw` CLI must be installed and available in system PATH
- WorkspaceManager focuses on lifecycle management (create/destroy/list), NOT file operations

### Remaining High Priority Issues (P1)
These should be addressed before or during implementation:
- [x] Define Scheduler integration protocol with error handling (DONE - see Integration Points section)
- [x] Document workspace initialization data flow (DONE - delegates to `aw create`)
- [x] Clarify which stream workspace events are appended to (DONE - task stream in Integration Points)
- [ ] Update event schema with correlation_id, causation_id, schema_version
- [ ] Add workspace event handlers to Pod.State spec (cross-component change)
- [ ] Add size limit enforcement to write_file/4 (lower priority - optional utility function)

## Implementation Todo List

### Phase 1: Core Module Setup
- [ ] Create `lib/ipa/pod/workspace_manager.ex` module
- [ ] Define GenServer structure and state schema
- [ ] Implement `start_link/1` with task_id parameter
- [ ] Add to Pod.Supervisor child spec
- [ ] Configure application settings in `config/config.exs`

### Phase 2: Workspace Creation
- [ ] Implement `create_workspace/3` function
  - [ ] Generate workspace path from task_id and agent_id
  - [ ] Create directory structure (root, .ipa/, work/, output/)
  - [ ] Write `.ipa/task_spec.json` metadata file
  - [ ] Write `.ipa/workspace_config.json` configuration
  - [ ] Optional: Initialize git repository if configured
  - [ ] Add workspace to GenServer state
- [ ] Implement workspace creation event appending
- [ ] Broadcast workspace creation via pod pub-sub
- [ ] Handle workspace already exists error
- [ ] Handle filesystem errors gracefully

### Phase 3: Path Validation & Security
- [ ] Implement `validate_path/2` private function
  - [ ] Expand paths to absolute paths
  - [ ] Check path is within workspace boundary
  - [ ] Return appropriate error for path traversal attempts
- [ ] Add comprehensive path validation tests
- [ ] Test with various malicious path inputs (../, ../../, symlinks, etc.)

### Phase 4: File Operations
- [ ] Implement `read_file/3` function
  - [ ] Validate path using `validate_path/2`
  - [ ] Read file content
  - [ ] Handle file not found errors
  - [ ] Return content as string
- [ ] Implement `write_file/4` function
  - [ ] Validate path using `validate_path/2`
  - [ ] Create parent directories if needed
  - [ ] Write content to file
  - [ ] Handle write errors

### Phase 5: Workspace Query Functions
- [ ] Implement `get_workspace_path/2`
  - [ ] Query state for workspace path
  - [ ] Return error if workspace not found
- [ ] Implement `list_workspaces/1`
  - [ ] Return list of agent IDs with workspaces
- [ ] Implement `workspace_exists?/2`
  - [ ] Check if workspace exists in state
  - [ ] Optionally verify directory exists on disk

### Phase 6: Workspace Cleanup
- [ ] Implement `cleanup_workspace/2` function
  - [ ] Verify workspace exists
  - [ ] Remove directory recursively with `File.rm_rf/1`
  - [ ] Handle cleanup failures gracefully (log, don't crash)
  - [ ] Remove workspace from GenServer state
- [ ] Implement workspace cleanup event appending
- [ ] Broadcast workspace cleanup via pod pub-sub
- [ ] Handle workspace not found error
- [ ] Handle permission denied errors

### Phase 7: Event Integration
- [ ] Define `workspace_created` event schema
- [ ] Define `workspace_cleanup` event schema
- [ ] Integrate with `Ipa.Pod.State.append_event/4`
- [ ] Ensure proper actor_id tracking
- [ ] Add correlation_id for event tracing

### Phase 8: State Recovery
- [ ] Implement state recovery on GenServer restart
  - [ ] Query event store for workspace events
  - [ ] Rebuild workspace state from events
  - [ ] Verify workspace directories still exist
  - [ ] Clean up orphaned workspaces or state entries
- [ ] Add tests for crash recovery scenarios

### Phase 9: Testing
- [ ] Write unit tests for path validation
- [ ] Write unit tests for workspace creation
- [ ] Write unit tests for file operations
- [ ] Write unit tests for workspace cleanup
- [ ] Write integration tests with Pod.State
- [ ] Write integration tests with event store
- [ ] Write tests for concurrent workspace operations
- [ ] Write property tests for path security
- [ ] Write tests for GenServer crash recovery

### Phase 10: Documentation & Polish
- [ ] Add @doc annotations to all public functions
- [ ] Add @spec type specifications
- [ ] Add usage examples in module documentation
- [ ] Update component spec if implementation deviates
- [ ] Add logging for key operations (creation, cleanup, errors)
- [ ] Review error messages for clarity

### Phase 11: Integration with Pod.Scheduler
- [ ] Verify Scheduler can call `create_workspace/3`
- [ ] Test workspace path is passed to ClaudeCode SDK
- [ ] Test workspace cleanup after agent completion
- [ ] Test error handling when workspace creation fails

## Known Issues
_None yet - implementation not started_

## Design Decisions

### Decision Log
- **2025-01-05**: Initial spec created
  - Workspace structure: task_id/agent_id hierarchy
  - Path validation using absolute path expansion
  - GenServer for state management
  - Event sourcing for workspace lifecycle

## Implementation Notes

### Workspace Path Format
Using `/ipa/workspaces/{task_id}/{agent_id}/` structure for clarity and isolation.

### Path Validation Strategy
Using `Path.expand/1` and `String.starts_with?/2` for security. This prevents:
- Relative path traversal (`../`)
- Symlink attacks (resolved to absolute path)
- Complex path manipulation

### Error Handling Philosophy
- Workspace creation errors: return `{:error, reason}` to caller
- Cleanup failures: log error but don't crash (best effort)
- File operation errors: return `{:error, reason}` to caller

### Future Considerations
- Workspace archiving: save to S3/backup before cleanup
- Disk quota enforcement: track size and reject writes over limit
- Workspace templates: pre-populate workspace with common files
- Multi-workspace: support workspace-to-workspace communication

## Testing Notes

### Critical Test Cases
1. Path traversal prevention (../../etc/passwd)
2. Symlink attacks
3. Concurrent workspace creation (same agent_id)
4. Cleanup of non-existent workspace
5. GenServer crash and state recovery
6. Event replay consistency

### Performance Benchmarks
_To be added during implementation_

## References
- Event Store spec: `specs/1.1_event_store/spec.md`
- Pod State spec: `specs/2.2_pod_state_manager/spec.md`
- Pod Supervisor spec: `specs/2.1_pod_supervisor/spec.md`
- Pod Scheduler spec: `specs/2.3_pod_scheduler/spec.md`
