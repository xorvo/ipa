# Architectural Review: Pod Workspace Manager (2.4)

**Date:** 2025-11-05
**Reviewer:** System Architecture Expert
**Component:** 2.4 Pod Workspace Manager
**Status:** NEEDS REVISION

---

## Executive Summary

The Pod Workspace Manager specification shows a solid foundation but has **several critical architectural issues** that must be addressed before implementation. The primary concerns are:

1. **State Management Inconsistency**: GenServer state contradicts event sourcing principles
2. **Event Schema Issues**: Missing critical events and metadata
3. **Integration Gaps**: Unclear coordination with Pod.Scheduler and Pod.State
4. **Security Concerns**: Path validation is insufficient
5. **Missing Error Handling**: Several failure scenarios not addressed
6. **Supervision Lifecycle**: Incomplete crash recovery strategy

**Recommendation:** REVISE specification before implementation begins.

---

## 1. Architecture Overview

### 1.1 Position in System

The Pod Workspace Manager sits within Layer 2 (Pod Infrastructure) and is responsible for:
- Creating isolated filesystem workspaces for agent execution
- Managing workspace lifecycle (create, cleanup)
- Providing safe file operations within workspace boundaries
- Recording workspace events to the event store

### 1.2 Key Dependencies

**Correct Dependencies:**
- Event Store (1.1) - for recording workspace events
- Pod State (2.2) - for appending events and state coordination
- File System - for workspace operations

**Integration Points:**
- Pod Scheduler (2.3) - creates workspaces before spawning agents
- Claude Code SDK - receives workspace path for agent execution

---

## 2. Critical Architectural Issues

### 2.1 State Management Anti-Pattern ⚠️ CRITICAL

**Issue:** The spec defines GenServer state that duplicates event store data, creating a dual-source-of-truth problem.

**Current Spec (Lines 268-283):**
```elixir
%{
  task_id: "task-123",
  base_path: "/ipa/workspaces",
  workspaces: %{
    "agent-456" => %{
      path: "/ipa/workspaces/task-123/agent-456",
      created_at: ~U[2025-01-01 00:00:00Z],
      config: %{...}
    }
  }
}
```

**Problem:**
- Workspace metadata is stored in BOTH GenServer state AND event store
- Event store is the source of truth in this architecture (event sourcing)
- On crash/restart, how is this state rebuilt? The spec says "State is reloaded from event store" (line 403) but doesn't show HOW
- This violates the event sourcing principle: state should be derived from events, not maintained separately

**Recommendation:**

**Option A (Preferred): Stateless WorkspaceManager**
- GenServer maintains ONLY `task_id` and `base_path` (configuration)
- Workspace existence is checked via filesystem (`File.exists?/1`)
- Workspace metadata is derived from events when needed
- Simpler implementation, no state synchronization issues

```elixir
# GenServer state
%{
  task_id: "task-123",
  base_path: "/ipa/workspaces"
}

# Check workspace exists
defp workspace_exists?(task_id, agent_id) do
  workspace_path = build_workspace_path(task_id, agent_id)
  File.exists?(workspace_path)
end

# Get workspace metadata from events
defp get_workspace_metadata(task_id, agent_id) do
  {:ok, events} = Ipa.EventStore.read_stream(
    task_id,
    event_types: ["workspace_created", "workspace_cleanup"]
  )
  # Filter events for this agent_id and build metadata
end
```

**Option B: Event-Sourced State**
- If you need cached state, rebuild it from events on init
- Implement `apply_event/2` pattern like Pod.State (2.2)
- Subscribe to own events and update state accordingly

```elixir
def init(opts) do
  task_id = Keyword.fetch!(opts, :task_id)

  # Load workspace events and rebuild state
  {:ok, events} = Ipa.EventStore.read_stream(
    task_id,
    event_types: ["workspace_created", "workspace_cleanup"]
  )

  workspaces = Enum.reduce(events, %{}, &apply_workspace_event/2)

  {:ok, %{task_id: task_id, base_path: base_path(), workspaces: workspaces}}
end

defp apply_workspace_event(%{event_type: "workspace_created", data: data}, workspaces) do
  Map.put(workspaces, data.agent_id, %{
    path: data.workspace_path,
    created_at: data.created_at,
    config: data.config
  })
end

defp apply_workspace_event(%{event_type: "workspace_cleanup", data: data}, workspaces) do
  Map.delete(workspaces, data.agent_id)
end
```

**Action Required:** Choose one approach and document it clearly in the spec.

---

### 2.2 Event Schema Issues ⚠️ HIGH PRIORITY

#### 2.2.1 Missing Stream Context

**Issue:** The spec says "Append workspace_created event to event store" (line 126) but doesn't specify WHICH stream.

**Question:** Are workspace events appended to:
- A) The task's stream (`stream_id = task_id`)?
- B) A separate workspace stream (`stream_id = workspace_id`)?
- C) An agent stream (`stream_id = agent_id`)?

**Recommendation:** Use the **task's stream** (Option A).

**Reasoning:**
- Workspaces are scoped to a task (path: `/ipa/workspaces/{task_id}/{agent_id}`)
- Pod.State needs to know about all task-related events
- Scheduler needs to react to workspace events
- Simpler querying (one stream per task)

**Update Required:** Add to spec:
```elixir
# In create_workspace/3
Ipa.Pod.State.append_event(
  task_id,  # Events go to task stream
  "workspace_created",
  %{
    agent_id: agent_id,
    workspace_path: workspace_path,
    config: config
  },
  nil,  # No version check for workspace creation
  actor_id: "system"
)
```

#### 2.2.2 Missing Workspace Event in Pod.State Event Handlers

**Issue:** Pod.State (2.2) spec doesn't have event handlers for `workspace_created` and `workspace_cleanup`.

**Impact:** Pod.State won't track workspace lifecycle, breaking the event sourcing pattern.

**Cross-Component Fix Required:**
1. Add workspace events to Pod.State (2.2) event handlers
2. Update Pod.State schema to track workspaces:
   ```elixir
   %{
     # ... existing fields
     workspaces: [
       %{
         agent_id: String.t(),
         workspace_path: String.t(),
         created_at: integer(),
         cleaned_up_at: integer() | nil
       }
     ]
   }
   ```

#### 2.2.3 Missing Event Metadata

**Issue:** Event examples (lines 327-351) don't include all standard metadata fields defined in Event Store spec.

**Current:**
```elixir
%{
  event_type: "workspace_created",
  event_data: %{
    agent_id: "agent-456",
    workspace_path: "/ipa/workspaces/task-123/agent-456",
    config: %{...}
  },
  actor_id: "system",
  metadata: %{}
}
```

**Missing:**
- `correlation_id` - for tracing workspace operations across components
- `causation_id` - the event that triggered workspace creation (e.g., `agent_started`)
- `schema_version` - for event schema evolution (per Event Store best practices)

**Recommendation:**
```elixir
%{
  event_type: "workspace_created",
  event_data: %{
    agent_id: "agent-456",
    workspace_path: "/ipa/workspaces/task-123/agent-456",
    config: %{...}
  },
  actor_id: "system",
  causation_id: agent_started_event_id,  # Event that triggered this
  correlation_id: request_id,  # For distributed tracing
  metadata: %{
    schema_version: 1,
    operation_type: "workspace_creation"
  }
}
```

---

### 2.3 Integration Issues ⚠️ HIGH PRIORITY

#### 2.3.1 Unclear Scheduler Coordination

**Issue:** The spec shows Scheduler calling WorkspaceManager directly (line 411):
```elixir
{:ok, workspace_path} = WorkspaceManager.create_workspace(task_id, agent_id, config)
ClaudeCode.run_task(prompt: prompt, cwd: workspace_path, ...)
```

**Problem:** What happens if workspace creation fails?
- Does the agent spawn anyway?
- Does Scheduler retry?
- Is an error event recorded?

**Recommendation:** Define explicit error handling protocol:

```elixir
# In Scheduler
case WorkspaceManager.create_workspace(task_id, agent_id, config) do
  {:ok, workspace_path} ->
    # Record agent_started event with workspace path
    Ipa.Pod.State.append_event(
      task_id,
      "agent_started",
      %{agent_id: agent_id, workspace: workspace_path, ...},
      current_version
    )

    # Spawn agent
    ClaudeCode.run_task(prompt: prompt, cwd: workspace_path, ...)

  {:error, :workspace_exists} ->
    # Workspace already exists - should we reuse or fail?
    Logger.warning("Workspace already exists for agent #{agent_id}")
    # Decision: Reuse existing workspace or fail?

  {:error, reason} ->
    # Record agent_failed event
    Ipa.Pod.State.append_event(
      task_id,
      "agent_failed",
      %{agent_id: agent_id, error: "workspace_creation_failed", reason: reason},
      current_version
    )
    {:error, reason}
end
```

**Action Required:** Add "Integration with Pod.Scheduler" section with detailed error handling protocol.

#### 2.3.2 Missing Workspace Initialization Events

**Issue:** Spec says "Write `.ipa/task_spec.json` with task specification" (line 306) but doesn't say WHERE this data comes from.

**Questions:**
- Does WorkspaceManager call `Pod.State.get_state/1` to fetch task spec?
- Is task spec passed as part of `config` parameter?
- What if task spec changes after workspace is created?

**Recommendation:**
```elixir
# Option 1: WorkspaceManager fetches task spec
def create_workspace(task_id, agent_id, config) do
  # Fetch current task state
  {:ok, task_state} = Ipa.Pod.State.get_state(task_id)

  # Create workspace with task context
  workspace_path = build_workspace_path(task_id, agent_id)
  File.mkdir_p!(workspace_path)

  # Write task context to .ipa/
  write_task_context(workspace_path, task_state, config)

  # Record event
  append_workspace_event(...)
end

# Option 2: Pass task spec in config
WorkspaceManager.create_workspace(
  task_id,
  agent_id,
  %{
    task_spec: task_state.spec,  # From Scheduler
    max_size_mb: 500,
    git_config: %{enabled: true}
  }
)
```

**Action Required:** Clarify data flow in "Workspace Initialization" section.

---

### 2.4 Security Concerns ⚠️ MEDIUM PRIORITY

#### 2.4.1 Path Validation Insufficient

**Issue:** Path validation (lines 288-299) only checks `String.starts_with?/2`, which can be bypassed.

**Current Implementation:**
```elixir
defp validate_path(workspace_path, relative_path) do
  full_path = Path.join(workspace_path, relative_path)
  absolute_full = Path.expand(full_path)
  absolute_workspace = Path.expand(workspace_path)

  if String.starts_with?(absolute_full, absolute_workspace) do
    {:ok, absolute_full}
  else
    {:error, :path_outside_workspace}
  end
end
```

**Vulnerabilities:**
1. **Symlink attacks**: Agent creates symlink to `/etc/passwd`, passes validation
2. **Special characters**: Null bytes, newlines in filenames
3. **Reserved names**: Windows reserved names (CON, PRN, AUX)
4. **Path equivalence**: `/workspace/./file` vs `/workspace/file`

**Recommendation:** Enhance validation:

```elixir
defp validate_path(workspace_path, relative_path) do
  with :ok <- validate_relative_path(relative_path),
       {:ok, full_path} <- build_safe_path(workspace_path, relative_path),
       :ok <- check_path_boundaries(full_path, workspace_path),
       :ok <- check_symlinks(full_path, workspace_path) do
    {:ok, full_path}
  end
end

defp validate_relative_path(path) do
  cond do
    String.contains?(path, "\0") ->
      {:error, :invalid_path_characters}
    String.starts_with?(path, "/") ->
      {:error, :absolute_path_not_allowed}
    String.contains?(path, "..") ->
      {:error, :path_traversal_attempt}
    true ->
      :ok
  end
end

defp check_symlinks(full_path, workspace_path) do
  # Resolve all symlinks in the path
  case File.read_link_all(full_path) do
    {:ok, resolved_path} ->
      if String.starts_with?(resolved_path, workspace_path) do
        :ok
      else
        {:error, :symlink_outside_workspace}
      end
    {:error, :enoent} ->
      # File doesn't exist yet (e.g., for write operations)
      :ok
    {:error, _} ->
      # Not a symlink or error reading link
      :ok
  end
end
```

**Action Required:** Update "Path Validation" section with enhanced security checks.

#### 2.4.2 Missing File Size Limits

**Issue:** Spec mentions `max_size_mb` in config (line 91) but never enforces it.

**Impact:** Agent could fill disk, crash pod or entire system.

**Recommendation:** Add size checking to `write_file/4`:

```elixir
def write_file(task_id, agent_id, relative_path, content) do
  with {:ok, workspace_path} <- get_workspace_path(task_id, agent_id),
       {:ok, full_path} <- validate_path(workspace_path, relative_path),
       :ok <- check_workspace_size(workspace_path, byte_size(content)) do
    File.write(full_path, content)
  end
end

defp check_workspace_size(workspace_path, additional_bytes) do
  {:ok, config} = get_workspace_config(workspace_path)
  max_bytes = config.max_size_mb * 1024 * 1024

  current_size = du_recursive(workspace_path)

  if current_size + additional_bytes > max_bytes do
    {:error, :workspace_size_limit_exceeded}
  else
    :ok
  end
end

defp du_recursive(path) do
  # Calculate total size of directory recursively
  case File.ls(path) do
    {:ok, files} ->
      Enum.reduce(files, 0, fn file, acc ->
        full_path = Path.join(path, file)
        case File.stat(full_path) do
          {:ok, %{type: :directory}} -> acc + du_recursive(full_path)
          {:ok, %{size: size}} -> acc + size
          _ -> acc
        end
      end)
    _ -> 0
  end
end
```

**Action Required:** Add size limit enforcement to spec.

---

### 2.5 Supervision and Lifecycle Issues ⚠️ MEDIUM PRIORITY

#### 2.5.1 Missing `terminate/2` Implementation

**Issue:** Spec mentions crash recovery (lines 401-404) but doesn't define `terminate/2` callback.

**Problem:** Pod Supervisor (2.1) requires all children to implement `terminate/2` for graceful shutdown (see 2.1 lines 239-263).

**Required Implementation:**
```elixir
@impl true
def terminate(reason, state) do
  require Logger
  Logger.info("WorkspaceManager shutting down for task #{state.task_id}, reason: #{inspect(reason)}")

  # Check configuration
  config = Application.get_env(:ipa, Ipa.Pod.WorkspaceManager, [])
  cleanup_on_shutdown = Keyword.get(config, :cleanup_on_pod_shutdown, true)

  if cleanup_on_shutdown do
    # Clean up all workspaces for this task
    workspaces = list_workspaces(state.task_id)
    Enum.each(workspaces, fn agent_id ->
      case cleanup_workspace(state.task_id, agent_id) do
        :ok ->
          Logger.info("Cleaned up workspace for agent #{agent_id}")
        {:error, reason} ->
          Logger.error("Failed to cleanup workspace for agent #{agent_id}: #{inspect(reason)}")
      end
    end)
  else
    Logger.info("Skipping workspace cleanup (cleanup_on_pod_shutdown: false)")
  end

  :ok
end
```

**Action Required:** Add "Graceful Shutdown" section with `terminate/2` implementation.

#### 2.5.2 Unclear State Reconstruction After Crash

**Issue:** Spec says "State is reloaded from event store" (line 403) but provides no implementation.

**Questions:**
- How are active workspaces identified after crash?
- What if workspace directory exists but no `workspace_created` event?
- What if `workspace_created` event exists but directory is missing?

**Recommendation:** Add state reconstruction logic:

```elixir
def init(opts) do
  task_id = Keyword.fetch!(opts, :task_id)
  base_path = Application.get_env(:ipa, Ipa.Pod.WorkspaceManager, [])
                |> Keyword.get(:base_path, "/ipa/workspaces")

  # Reconcile filesystem state with event store
  state = reconcile_workspaces(task_id, base_path)

  {:ok, state}
end

defp reconcile_workspaces(task_id, base_path) do
  # Get workspaces from events
  {:ok, events} = Ipa.EventStore.read_stream(
    task_id,
    event_types: ["workspace_created", "workspace_cleanup"]
  )

  event_workspaces = build_workspace_state_from_events(events)

  # Get workspaces from filesystem
  task_workspace_dir = Path.join(base_path, task_id)
  fs_workspaces = case File.ls(task_workspace_dir) do
    {:ok, dirs} -> MapSet.new(dirs)
    {:error, :enoent} -> MapSet.new()
  end

  # Find inconsistencies
  event_agent_ids = MapSet.new(Map.keys(event_workspaces))

  # Workspaces in filesystem but not in events (orphaned)
  orphaned = MapSet.difference(fs_workspaces, event_agent_ids)
  if MapSet.size(orphaned) > 0 do
    Logger.warning("Found orphaned workspaces: #{inspect(orphaned)}")
    # Decision: clean up orphaned workspaces or leave them?
  end

  # Workspaces in events but not in filesystem (missing)
  missing = MapSet.difference(event_agent_ids, fs_workspaces)
  if MapSet.size(missing) > 0 do
    Logger.error("Workspaces missing from filesystem: #{inspect(missing)}")
    # Decision: recreate or mark as failed?
  end

  %{task_id: task_id, base_path: base_path, workspaces: event_workspaces}
end
```

**Action Required:** Add "State Reconstruction" section to spec.

---

### 2.6 Missing Error Scenarios ⚠️ MEDIUM PRIORITY

#### 2.6.1 Concurrent Workspace Creation

**Issue:** What happens if Scheduler calls `create_workspace/3` twice concurrently for the same agent?

**Current behavior:** Race condition - both might succeed, or one might fail with `workspace_exists`.

**Recommendation:** Use workspace path as synchronization point:

```elixir
def create_workspace(task_id, agent_id, config) do
  workspace_path = build_workspace_path(task_id, agent_id)

  # Atomic directory creation
  case File.mkdir(workspace_path) do
    :ok ->
      # Directory created successfully - we won the race
      initialize_workspace(workspace_path, task_id, agent_id, config)

    {:error, :eexist} ->
      # Another process created the directory first
      {:error, :workspace_exists}

    {:error, reason} ->
      {:error, reason}
  end
end
```

**Note:** `File.mkdir/1` is atomic on most filesystems.

#### 2.6.2 Cleanup Failures

**Issue:** Spec says "Handle cleanup failures gracefully - log error but don't crash" (line 322).

**Problem:** What about partially cleaned workspaces?

**Scenario:**
1. Workspace has 1000 files
2. Cleanup starts with `File.rm_rf!/1`
3. Halfway through, permission error occurs
4. Workspace is in inconsistent state (partially deleted)

**Recommendation:**

```elixir
def cleanup_workspace(task_id, agent_id) do
  with {:ok, workspace_path} <- get_workspace_path(task_id, agent_id),
       :ok <- validate_workspace_path(workspace_path),
       :ok <- perform_cleanup(workspace_path) do

    # Record cleanup event
    Ipa.Pod.State.append_event(
      task_id,
      "workspace_cleanup",
      %{
        agent_id: agent_id,
        workspace_path: workspace_path,
        cleanup_reason: "normal_completion",
        cleanup_status: "success"
      },
      nil,
      actor_id: "system"
    )

    :ok
  else
    {:error, reason} ->
      # Log but don't crash
      Logger.error("Failed to cleanup workspace #{workspace_path}: #{inspect(reason)}")

      # Record failed cleanup event
      Ipa.Pod.State.append_event(
        task_id,
        "workspace_cleanup_failed",
        %{
          agent_id: agent_id,
          error: inspect(reason),
          cleanup_status: "partial_failure"
        },
        nil,
        actor_id: "system"
      )

      {:error, reason}
  end
end

defp perform_cleanup(workspace_path) do
  case File.rm_rf(workspace_path) do
    {:ok, _deleted_paths} -> :ok
    {:error, reason, _remaining_path} -> {:error, reason}
  end
end
```

**Action Required:** Add "Cleanup Failure Recovery" section.

---

### 2.7 Performance Concerns ⚠️ LOW PRIORITY

#### 2.7.1 `list_workspaces/1` Implementation

**Issue:** Spec defines `list_workspaces/1` (line 237) but no implementation details.

**Question:** Should this:
- A) List directories from filesystem?
- B) Query events from event store?
- C) Return cached GenServer state?

**Recommendation:** Depends on state management approach chosen in 2.1.

**If stateless (Option A from 2.1):**
```elixir
def list_workspaces(task_id) do
  workspace_base = Path.join(base_path(), task_id)

  case File.ls(workspace_base) do
    {:ok, dirs} -> dirs
    {:error, :enoent} -> []
  end
end
```

**If event-sourced (Option B from 2.1):**
```elixir
def list_workspaces(task_id) do
  GenServer.call(via_tuple(task_id), :list_workspaces)
end

def handle_call(:list_workspaces, _from, state) do
  agent_ids = Map.keys(state.workspaces)
  {:reply, agent_ids, state}
end
```

---

## 3. Compliance Check

### 3.1 Event Sourcing Principles

| Principle | Status | Notes |
|-----------|--------|-------|
| Events are source of truth | ⚠️ PARTIAL | GenServer state creates dual source |
| State derived from events | ❌ MISSING | No event replay implementation |
| Events are immutable | ✅ PASS | Events appended to event store |
| Optimistic concurrency | ⚠️ N/A | Workspace creation doesn't need versions |

### 3.2 Pod Architecture Principles

| Principle | Status | Notes |
|-----------|--------|-------|
| Pod-local pub-sub usage | ❌ MISSING | Workspace events not broadcast |
| Supervised by Pod Supervisor | ✅ PASS | Correctly supervised |
| Graceful shutdown | ❌ MISSING | No `terminate/2` callback |
| State persistence | ⚠️ PARTIAL | Events persisted, state reconstruction unclear |
| Registry-based addressing | ✅ PASS | Uses `{:pod_workspace, task_id}` key |

### 3.3 SOLID Principles

| Principle | Status | Notes |
|-----------|--------|-------|
| Single Responsibility | ✅ PASS | Focused on workspace management only |
| Open/Closed | ✅ PASS | Extensible via config |
| Liskov Substitution | N/A | No inheritance used |
| Interface Segregation | ✅ PASS | Clean public API |
| Dependency Inversion | ✅ PASS | Depends on abstractions (Event Store) |

### 3.4 Security Principles

| Principle | Status | Notes |
|-----------|--------|-------|
| Path validation | ⚠️ WEAK | Insufficient symlink/special char checks |
| Resource limits | ❌ MISSING | Size limits not enforced |
| Least privilege | ✅ PASS | Workspaces isolated |
| Input validation | ⚠️ PARTIAL | Config validation not specified |

---

## 4. Risk Analysis

### 4.1 High-Risk Issues

1. **State Synchronization (P0)**
   - **Risk:** GenServer state diverges from event store after crash
   - **Impact:** Workspace operations fail, agents can't execute
   - **Mitigation:** Implement event-sourced state OR go stateless

2. **Path Traversal (P0)**
   - **Risk:** Agent escapes workspace, reads sensitive files
   - **Impact:** Security breach, data exposure
   - **Mitigation:** Enhanced path validation with symlink checks

3. **Missing Graceful Shutdown (P1)**
   - **Risk:** Workspaces not cleaned up on pod shutdown
   - **Impact:** Disk space exhaustion, orphaned workspaces
   - **Mitigation:** Implement `terminate/2` callback

### 4.2 Medium-Risk Issues

4. **Workspace Size Limits Not Enforced (P2)**
   - **Risk:** Agent fills disk
   - **Impact:** System crash, other pods affected
   - **Mitigation:** Implement size checking in write operations

5. **Unclear Error Handling (P2)**
   - **Risk:** Scheduler doesn't handle workspace creation failures
   - **Impact:** Agent spawn fails silently
   - **Mitigation:** Define error handling protocol

6. **State Reconstruction Unclear (P2)**
   - **Risk:** Inconsistent state after crash
   - **Impact:** Workspaces out of sync with events
   - **Mitigation:** Implement reconciliation logic

### 4.3 Low-Risk Issues

7. **Missing Pub-Sub Broadcasts (P3)**
   - **Risk:** Other components don't react to workspace events
   - **Impact:** UI out of sync, scheduler unaware
   - **Mitigation:** Broadcast workspace events to pod pub-sub

8. **Concurrent Creation Race (P3)**
   - **Risk:** Double workspace creation
   - **Impact:** Confusing errors, wasted resources
   - **Mitigation:** Use atomic directory creation

---

## 5. Recommendations

### 5.1 Critical Changes (Must Fix Before Implementation)

1. **Resolve State Management Approach**
   - Choose: Stateless OR event-sourced state
   - Document state reconstruction logic
   - Implement `init/1` with event replay

2. **Add Graceful Shutdown**
   - Implement `terminate/2` callback
   - Handle cleanup_on_pod_shutdown config
   - Define timeout handling

3. **Enhance Path Security**
   - Add symlink resolution checks
   - Validate against special characters
   - Add comprehensive path validation tests

4. **Define Scheduler Integration Protocol**
   - Document workspace creation error handling
   - Specify data flow for task context
   - Define retry logic

### 5.2 High-Priority Changes (Should Fix Before Implementation)

5. **Implement Size Limit Enforcement**
   - Add size checking to write_file/4
   - Define behavior when limit exceeded
   - Add size monitoring to workspace config

6. **Add Cross-Component Event Handlers**
   - Update Pod.State (2.2) to handle workspace events
   - Update Pod.State schema to track workspaces
   - Ensure event consistency across components

7. **Improve Event Schema**
   - Add correlation_id and causation_id to all events
   - Add schema_version for future evolution
   - Document event metadata requirements

### 5.3 Recommended Changes (Good to Have)

8. **Add Pub-Sub Broadcasting**
   - Broadcast workspace_created to pod pub-sub
   - Broadcast workspace_cleanup to pod pub-sub
   - Document pub-sub message format

9. **Add State Reconciliation**
   - Implement filesystem vs event store reconciliation
   - Define orphaned workspace handling
   - Define missing workspace handling

10. **Improve Error Recovery**
    - Add workspace_cleanup_failed event
    - Define partial cleanup handling
    - Add retry logic for transient failures

---

## 6. Specific Code Changes Required

### 6.1 Update Event Store Stream (High Priority)

**File:** `specs/2.4_pod_workspace_manager/spec.md`
**Section:** "Integration Points → With Pod.State"

**Change:**
```elixir
# FROM (ambiguous):
Ipa.Pod.State.append_event(task_id, :workspace_created, event_data, version)

# TO (explicit):
Ipa.Pod.State.append_event(
  task_id,  # Events appended to task stream
  "workspace_created",
  %{
    agent_id: agent_id,
    workspace_path: workspace_path,
    config: config
  },
  nil,  # No version check needed
  actor_id: "system",
  correlation_id: request_id,
  metadata: %{schema_version: 1}
)
```

### 6.2 Add GenServer State Section (Critical)

**File:** `specs/2.4_pod_workspace_manager/spec.md`
**Section:** "Internal Implementation → State Management"

**Add:**
```markdown
### State Management Strategy

The WorkspaceManager uses a **stateless** approach:

- GenServer maintains only configuration (task_id, base_path)
- Workspace existence is checked via filesystem
- Workspace metadata is derived from events when needed
- No in-memory caching of workspace state

This approach:
- Eliminates state synchronization issues
- Simplifies crash recovery
- Ensures filesystem is source of truth for existence
- Events are source of truth for metadata

#### GenServer State

\```elixir
defmodule Ipa.Pod.WorkspaceManager do
  use GenServer

  defstruct [:task_id, :base_path]
end

def init(opts) do
  task_id = Keyword.fetch!(opts, :task_id)
  base_path = Application.get_env(:ipa, __MODULE__, [])
                |> Keyword.get(:base_path, "/ipa/workspaces")

  {:ok, %__MODULE__{task_id: task_id, base_path: base_path}}
end
\```

#### Workspace Existence Check

\```elixir
defp workspace_exists?(state, agent_id) do
  workspace_path = build_workspace_path(state.task_id, agent_id)
  File.exists?(workspace_path)
end
\```
```

### 6.3 Add Terminate Callback (Critical)

**File:** `specs/2.4_pod_workspace_manager/spec.md`
**Section:** "Internal Implementation" (new section)

**Add:**
```markdown
### Graceful Shutdown

The WorkspaceManager implements `terminate/2` for graceful shutdown:

\```elixir
@impl true
def terminate(reason, state) do
  require Logger
  Logger.info("WorkspaceManager shutting down for task #{state.task_id}, reason: #{inspect(reason)}")

  config = Application.get_env(:ipa, Ipa.Pod.WorkspaceManager, [])

  if Keyword.get(config, :cleanup_on_pod_shutdown, true) do
    # Clean up all workspaces for this task
    task_workspace_dir = Path.join(state.base_path, state.task_id)

    case File.ls(task_workspace_dir) do
      {:ok, agent_dirs} ->
        Enum.each(agent_dirs, fn agent_id ->
          Logger.info("Cleaning up workspace for agent #{agent_id}")
          workspace_path = Path.join(task_workspace_dir, agent_id)
          File.rm_rf(workspace_path)

          # Best effort event recording (may fail if Pod.State already down)
          try do
            Ipa.Pod.State.append_event(
              state.task_id,
              "workspace_cleanup",
              %{
                agent_id: agent_id,
                workspace_path: workspace_path,
                cleanup_reason: "pod_shutdown"
              },
              nil,
              actor_id: "system"
            )
          rescue
            _ -> Logger.warning("Could not record workspace_cleanup event for #{agent_id}")
          end
        end)

      {:error, :enoent} ->
        Logger.info("No workspaces to clean up")

      {:error, reason} ->
        Logger.error("Failed to list workspaces: #{inspect(reason)}")
    end
  end

  :ok
end
\```

**Shutdown Timeout:** 5 seconds (configured in child_spec)

**Shutdown Behavior:**
- If cleanup completes within timeout → graceful shutdown
- If cleanup exceeds timeout → process killed with :kill signal
- Events recorded on best-effort basis (Pod.State may already be down)
```

### 6.4 Enhanced Path Validation (High Priority)

**File:** `specs/2.4_pod_workspace_manager/spec.md`
**Section:** "Internal Implementation → Path Validation"

**Replace entire section with:**
```markdown
### Path Validation

All file operations use comprehensive path validation to prevent directory traversal and symlink attacks:

\```elixir
defp validate_path(workspace_path, relative_path) do
  with :ok <- validate_relative_path_format(relative_path),
       {:ok, full_path} <- build_safe_path(workspace_path, relative_path),
       :ok <- check_path_boundaries(full_path, workspace_path),
       :ok <- check_symlinks(full_path, workspace_path) do
    {:ok, full_path}
  end
end

defp validate_relative_path_format(path) do
  cond do
    String.contains?(path, "\0") ->
      {:error, :invalid_path_null_byte}

    String.starts_with?(path, "/") ->
      {:error, :absolute_path_not_allowed}

    String.contains?(path, "..") ->
      {:error, :path_traversal_attempt}

    String.length(path) > 4096 ->
      {:error, :path_too_long}

    true ->
      :ok
  end
end

defp build_safe_path(workspace_path, relative_path) do
  full_path = Path.join(workspace_path, relative_path)
  absolute_full = Path.expand(full_path)
  {:ok, absolute_full}
end

defp check_path_boundaries(full_path, workspace_path) do
  absolute_workspace = Path.expand(workspace_path)

  if String.starts_with?(full_path, absolute_workspace <> "/") or full_path == absolute_workspace do
    :ok
  else
    {:error, :path_outside_workspace}
  end
end

defp check_symlinks(full_path, workspace_path) do
  # Check all path components for symlinks that escape workspace
  absolute_workspace = Path.expand(workspace_path)

  case resolve_symlinks_in_path(full_path) do
    {:ok, resolved_path} ->
      if String.starts_with?(resolved_path, absolute_workspace <> "/") do
        :ok
      else
        {:error, :symlink_outside_workspace}
      end

    {:error, :enoent} ->
      # File doesn't exist yet (e.g., for write operations) - check parent dirs
      parent_dir = Path.dirname(full_path)
      if parent_dir == full_path do
        # Reached root
        :ok
      else
        check_symlinks(parent_dir, workspace_path)
      end

    {:error, _reason} ->
      # Can't resolve symlinks - be conservative
      {:error, :cannot_resolve_symlinks}
  end
end

defp resolve_symlinks_in_path(path) do
  case File.read_link_all(path) do
    {:ok, resolved} -> {:ok, resolved}
    {:error, reason} -> {:error, reason}
  end
end
\```

**Security Properties:**
- Prevents directory traversal (../ sequences)
- Detects symlinks pointing outside workspace
- Rejects absolute paths
- Rejects null bytes and special characters
- Validates path length
- Checks all path components recursively
```

---

## 7. Cross-Component Changes Required

### 7.1 Pod State Manager (2.2) Updates

**File:** `specs/2.2_pod_state_manager/spec.md`

**Add to State Schema (around line 381):**
```elixir
# Workspaces
workspaces: [
  %{
    agent_id: String.t(),
    workspace_path: String.t(),
    created_at: integer(),
    config: map(),
    cleaned_up?: boolean(),
    cleaned_up_at: integer() | nil
  }
]
```

**Add Event Handlers (new section):**
```markdown
### Workspace Events

#### `workspace_created`
\```elixir
defp apply_event(%{
  event_type: "workspace_created",
  data: %{agent_id: agent_id, workspace_path: path, config: config},
  inserted_at: timestamp
}, state) do
  workspace = %{
    agent_id: agent_id,
    workspace_path: path,
    created_at: timestamp,
    config: config,
    cleaned_up?: false,
    cleaned_up_at: nil
  }

  %{state |
    workspaces: [workspace | state.workspaces],
    version: state.version + 1,
    updated_at: timestamp
  }
end
\```

#### `workspace_cleanup`
\```elixir
defp apply_event(%{
  event_type: "workspace_cleanup",
  data: %{agent_id: agent_id},
  inserted_at: timestamp
}, state) do
  workspaces = Enum.map(state.workspaces, fn ws ->
    if ws.agent_id == agent_id do
      %{ws | cleaned_up?: true, cleaned_up_at: timestamp}
    else
      ws
    end
  end)

  %{state |
    workspaces: workspaces,
    version: state.version + 1,
    updated_at: timestamp
  }
end
\```
```

### 7.2 Pod Scheduler (2.3) Updates

**Note:** Pod Scheduler spec doesn't exist yet, but when created, it must include:

1. **Workspace creation error handling**
2. **Coordination with WorkspaceManager**
3. **Retry logic for transient failures**

Example:
```elixir
defp spawn_agent(task_id, agent_id, agent_type) do
  # Create workspace first
  case create_agent_workspace(task_id, agent_id) do
    {:ok, workspace_path} ->
      # Record agent started
      {:ok, _version} = Ipa.Pod.State.append_event(
        task_id,
        "agent_started",
        %{agent_id: agent_id, agent_type: agent_type, workspace: workspace_path},
        nil,
        actor_id: "scheduler"
      )

      # Spawn agent via Claude Code SDK
      spawn_claude_agent(workspace_path, agent_type)

    {:error, reason} ->
      # Record agent failed
      Ipa.Pod.State.append_event(
        task_id,
        "agent_failed",
        %{agent_id: agent_id, error: "workspace_creation_failed", reason: inspect(reason)},
        nil,
        actor_id: "scheduler"
      )
      {:error, reason}
  end
end

defp create_agent_workspace(task_id, agent_id) do
  # Get current task state for context
  {:ok, task_state} = Ipa.Pod.State.get_state(task_id)

  # Create workspace with task context
  Ipa.Pod.WorkspaceManager.create_workspace(
    task_id,
    agent_id,
    %{
      task_spec: task_state.spec,
      max_size_mb: 1000,
      git_config: %{enabled: true}
    }
  )
end
```

---

## 8. Testing Gaps

### 8.1 Missing Test Scenarios

The spec has good coverage but is missing:

1. **Symlink Attack Tests**
   ```elixir
   test "rejects symlink to /etc/passwd" do
     # Create workspace
     # Create symlink inside workspace to /etc/passwd
     # Attempt to read via WorkspaceManager.read_file
     # Should return {:error, :symlink_outside_workspace}
   end
   ```

2. **Concurrent Creation Tests**
   ```elixir
   test "concurrent workspace creation returns workspace_exists" do
     # Spawn 10 tasks that create same workspace
     # Exactly 1 should succeed
     # Others should return {:error, :workspace_exists}
   end
   ```

3. **Crash Recovery Tests**
   ```elixir
   test "workspaces persist after WorkspaceManager crash" do
     # Create workspace
     # Crash WorkspaceManager
     # Wait for supervisor to restart
     # Verify workspace still exists
     # Verify workspace_exists? returns true
   end
   ```

4. **Size Limit Tests**
   ```elixir
   test "write_file rejects when size limit exceeded" do
     # Create workspace with max_size_mb: 1
     # Write 1.5MB of data
     # Should return {:error, :workspace_size_limit_exceeded}
   end
   ```

5. **Partial Cleanup Tests**
   ```elixir
   test "handles partial cleanup gracefully" do
     # Create workspace with protected files
     # Attempt cleanup
     # Should record workspace_cleanup_failed event
     # Should not crash WorkspaceManager
   end
   ```

---

## 9. Documentation Improvements

### 9.1 Missing Sections

1. **Pub-Sub Messages Section**
   - What messages are broadcast?
   - Who subscribes to workspace events?
   - Message format and examples

2. **State Reconstruction Section**
   - How state is rebuilt after crash
   - Reconciliation logic
   - Orphaned workspace handling

3. **Error Recovery Section**
   - Retry strategies
   - Partial failure handling
   - Escalation paths

4. **Configuration Reference**
   - All available config options
   - Default values
   - Environment-specific configs

### 9.2 Unclear Sections

1. **"Integration with Pod.State" (line 415)**
   - Shows append_event but no full context
   - Should show complete flow with error handling

2. **"Workspace Initialization" (line 302)**
   - Doesn't specify where task spec comes from
   - Should clarify data flow

3. **"Events" section (line 324)**
   - Missing correlation_id and causation_id
   - Should include full metadata examples

---

## 10. Summary and Action Plan

### 10.1 Severity Summary

| Severity | Count | Issues |
|----------|-------|--------|
| Critical (P0) | 3 | State management, path security, graceful shutdown |
| High (P1) | 4 | Size limits, event handlers, event schema, scheduler integration |
| Medium (P2) | 3 | State reconstruction, error handling, concurrent creation |
| Low (P3) | 2 | Pub-sub, performance |

### 10.2 Required Actions Before Implementation

**Phase 1: Critical Fixes (Block Implementation)**
1. Decide on state management approach (stateless vs event-sourced)
2. Implement `terminate/2` callback
3. Enhance path validation security
4. Define scheduler integration protocol

**Phase 2: High Priority Fixes (Implement Alongside)**
5. Add size limit enforcement
6. Update Pod.State event handlers
7. Improve event schema metadata
8. Document data flow for workspace initialization

**Phase 3: Medium Priority Fixes (Can Defer)**
9. Add state reconciliation logic
10. Improve error recovery
11. Handle concurrent creation

**Phase 4: Low Priority Improvements (Post-Implementation)**
12. Add pub-sub broadcasting
13. Optimize list_workspaces/1
14. Add workspace archiving

### 10.3 Estimated Impact

**Implementation Timeline:**
- With current spec: 3-5 days + 2-3 days rework = **5-8 days total**
- With revised spec: 4-6 days clean implementation = **4-6 days total**

**Risk Reduction:**
- Current spec: **HIGH** risk of state inconsistencies, security issues
- Revised spec: **LOW** risk, follows event sourcing best practices

**Recommendation:** **REVISE SPEC FIRST** before implementation begins. The time investment (4-6 hours of spec revision) will save 2-3 days of rework and prevent production bugs.

---

## 11. Conclusion

The Pod Workspace Manager spec demonstrates good understanding of the problem domain and provides a solid foundation. However, **critical architectural issues must be addressed before implementation**:

1. **State management violates event sourcing principles** - needs redesign
2. **Security vulnerabilities in path validation** - needs enhancement
3. **Missing graceful shutdown** - required by Pod Supervisor contract
4. **Integration gaps with Scheduler** - needs clarification

These issues are **fixable with targeted specification updates**. The recommendations provided maintain architectural consistency with the existing IPA system while addressing the identified concerns.

**Final Recommendation:** **PAUSE implementation until spec is revised** to address critical issues (P0 and P1). This will result in cleaner code, fewer bugs, and faster overall delivery.

---

## Appendix: Key Architecture Documents Referenced

1. **CLAUDE.md** - Project overview and architecture principles
2. **Event Store (1.1)** - Generic event sourcing foundation
3. **Pod Supervisor (2.1)** - Supervision tree and lifecycle requirements
4. **Pod State Manager (2.2)** - Event sourcing patterns and state management

---

**Review Complete**
**Date:** 2025-11-05
**Next Step:** Update specification based on recommendations, then schedule implementation review
