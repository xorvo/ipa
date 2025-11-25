# Pod Workspace Manager Specification

## Component ID
`2.4 Pod Workspace Manager`

## Phase
Phase 3: Pod Scheduler + Agents (Weeks 3-5)

## Overview

The Pod Workspace Manager is responsible for managing isolated filesystem workspaces for agents executing within a pod. It handles workspace lifecycle operations (create, destroy, list) using native Elixir file operations.

Each agent is spawned by the Pod Scheduler with its workspace path as the working directory (`cwd`). The agent then works directly in that workspace through the Claude Code SDK, using standard file operations.

## Purpose

- **Primary**: Manage workspace lifecycle using native Elixir file operations
- Provide isolated execution environments for agents
- Track workspace metadata and lifecycle events
- Record workspace operations to the event store
- Support future multi-workspace architectures
- Provide file operation utilities for pod-level workspace inspection

## Architecture Context

**Position in System**: Layer 2 - Pod Infrastructure

**Parent**: `Ipa.Pod.Supervisor`

**Siblings**:
- `Ipa.Pod.State` - Manages pod state and events
- `Ipa.Pod.Scheduler` - Orchestrates agent execution
- `Ipa.Pod.ExternalSync` - Synchronizes with external systems
- `IpaWeb.Pod.TaskLive` - Real-time UI for task

**Dependencies**:
- Event Store (for workspace lifecycle events)
- Pod State (for reading task context)
- Elixir `File` module (for all file operations)

## Key Responsibilities

1. **Workspace Lifecycle Management (PRIMARY)**
   - Create isolated workspace directories for agents using `File.mkdir_p`
   - Set up workspace structure (.ipa/, work/, output/ directories)
   - Write workspace metadata files (task_spec.json, workspace_config.json, context.json)
   - Inject CLAUDE.md files with agent context
   - Clean up workspaces after agent completion using `File.rm_rf`
   - Record workspace lifecycle events to event store

2. **Agent Execution Coordination**
   - Provide workspace path to Pod Scheduler for agent spawning
   - Agents execute in workspace via Claude Code SDK (with `cwd` set to workspace path)
   - Agents use standard file operations within their workspace
   - WorkspaceManager does NOT intercept agent file operations

3. **Workspace State Tracking**
   - Track active workspaces per pod in GenServer state
   - Rebuild state from events on restart (event-sourced)
   - Maintain workspace metadata (path, created_at, config)
   - Record workspace events (creation, cleanup)

4. **File Operation Utilities**
   - Provide Elixir file read/write operations for pod-level inspection
   - Path validation utilities (security checks for path traversal, symlinks)
   - File tree listing capabilities
   - These are for pod infrastructure to inspect workspace contents if needed

## Workspace Structure

### Base Path
All workspaces are created under a configurable base directory:
```
/ipa/workspaces/{task_id}/{agent_id}/
```

### Directory Layout
Each workspace contains:
```
/ipa/workspaces/{task_id}/{agent_id}/
├── .ipa/                      # IPA metadata (read-only for agent)
│   ├── task_spec.json         # Task specification
│   ├── workspace_config.json  # Workspace configuration
│   └── context.json           # Additional task context
├── work/                      # Agent working directory (read-write)
└── output/                    # Agent output artifacts (read-write)
```

### Workspace Configuration
Each workspace is created with a configuration:
```elixir
%{
  task_id: "uuid",
  agent_id: "uuid",
  workspace_path: "/ipa/workspaces/{task_id}/{agent_id}",
  created_at: ~U[2025-01-01 00:00:00Z],
  max_size_mb: 1000,           # Optional size limit
  allowed_operations: [:read, :write, :execute],
  git_config: %{               # Optional: initialize git repo
    enabled: true,
    user_name: "IPA Agent",
    user_email: "agent@ipa.local"
  }
}
```

## Implementation Approach

The WorkspaceManager uses native Elixir file operations to manage workspace lifecycle:

### Workspace Creation

Uses `File.mkdir_p/1` to create the workspace directory structure:

```elixir
defp create_workspace_structure(workspace_path, task_id, agent_id, config) do
  # Create main workspace directory
  File.mkdir_p!(workspace_path)

  # Create subdirectories
  File.mkdir_p!(Path.join(workspace_path, ".ipa"))
  File.mkdir_p!(Path.join(workspace_path, "work"))
  File.mkdir_p!(Path.join(workspace_path, "output"))

  # Write metadata files
  task_spec_path = Path.join([workspace_path, ".ipa", "task_spec.json"])
  File.write!(task_spec_path, Jason.encode!(%{task_id: task_id, agent_id: agent_id}, pretty: true))

  workspace_config_path = Path.join([workspace_path, ".ipa", "workspace_config.json"])
  File.write!(workspace_config_path, Jason.encode!(config, pretty: true))

  context_path = Path.join([workspace_path, ".ipa", "context.json"])
  File.write!(context_path, Jason.encode!(%{
    created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
    workspace_path: workspace_path
  }, pretty: true))

  :ok
end
```

### CLAUDE.md Injection

When creating a workspace, optionally inject a CLAUDE.md file:

```elixir
if claude_md = config[:claude_md] do
  claude_md_path = Path.join(workspace_path, "CLAUDE.md")
  File.write(claude_md_path, claude_md)
end
```

### Workspace Cleanup

Uses `File.rm_rf/1` to recursively delete the workspace:

```elixir
defp cleanup_workspace_files(workspace_path) do
  case File.rm_rf(workspace_path) do
    {:ok, _} ->
      Logger.info("Deleted workspace: #{workspace_path}")
      :ok

    {:error, reason, _} ->
      Logger.error("Failed to delete workspace: #{workspace_path}, reason: #{inspect(reason)}")
      {:error, {:cleanup_failed, reason}}
  end
end
```

### Path Security

All file operations include security checks:
- Validate relative paths (no `..`, no absolute paths)
- Check path boundaries (ensure within workspace)
- Detect and reject symlinks that escape workspace
- Validate against null bytes and overly long paths

## Public API

### Module: `Ipa.Pod.WorkspaceManager`

#### `create_workspace/3`
Creates a new workspace for an agent using native Elixir file operations.

```elixir
@spec create_workspace(task_id :: String.t(), agent_id :: String.t(), config :: map()) ::
  {:ok, workspace_path :: String.t()} | {:error, reason :: term()}
```

**Parameters:**
- `task_id` - UUID of the task
- `agent_id` - UUID of the agent
- `config` - Workspace configuration map (optional fields):
  - `:max_size_mb` - Maximum workspace size in MB
  - `:git_config` - Git configuration
  - `:claude_md` - CLAUDE.md content to inject

**Returns:**
- `{:ok, workspace_path}` - Workspace created successfully
- `{:error, :workspace_exists}` - Workspace already exists
- `{:error, reason}` - Creation failed

**Implementation:**
1. Construct workspace path: `/ipa/workspaces/{task_id}/{agent_id}`
2. Create directory structure using `File.mkdir_p!`
3. Write metadata files (.ipa/task_spec.json, etc.)
4. Inject CLAUDE.md if provided
5. Add workspace to GenServer state
6. Append `workspace_created` event to event store
7. Broadcast to pod pub-sub: `{:workspace_created, task_id, agent_id, workspace_path}`

**Example:**
```elixir
{:ok, path} = Ipa.Pod.WorkspaceManager.create_workspace(
  "task-123",
  "agent-456",
  %{max_size_mb: 500, git_config: %{enabled: true}, claude_md: "# Task Context..."}
)
# => {:ok, "/ipa/workspaces/task-123/agent-456"}
```

#### `cleanup_workspace/2`
Removes a workspace and all its contents using `File.rm_rf`.

```elixir
@spec cleanup_workspace(task_id :: String.t(), agent_id :: String.t(), opts :: keyword()) ::
  :ok | {:error, reason :: term()}
```

**Parameters:**
- `task_id` - UUID of the task
- `agent_id` - UUID of the agent
- `opts` - Options keyword list
  - `:force` - Force deletion even if files are in use (default: false)

**Returns:**
- `:ok` - Workspace cleaned up successfully
- `{:error, :workspace_not_found}` - Workspace doesn't exist
- `{:error, {:cleanup_failed, reason}}` - Cleanup failed
- `{:error, reason}` - Other errors

**Implementation:**
1. Get workspace path from GenServer state
2. Delete workspace directory using `File.rm_rf`
3. Remove workspace from GenServer state
4. Append `workspace_cleanup` event to event store
5. Broadcast to pod pub-sub: `{:workspace_cleanup, task_id, agent_id}`

**Example:**
```elixir
:ok = Ipa.Pod.WorkspaceManager.cleanup_workspace("task-123", "agent-456")
```

#### `read_file/3`
Reads a file from within a workspace (with path validation).

```elixir
@spec read_file(task_id :: String.t(), agent_id :: String.t(), relative_path :: String.t()) ::
  {:ok, content :: String.t()} | {:error, reason :: term()}
```

**Parameters:**
- `task_id` - UUID of the task
- `agent_id` - UUID of the agent
- `relative_path` - Path relative to workspace root

**Returns:**
- `{:ok, content}` - File content as string
- `{:error, :path_outside_workspace}` - Path escapes workspace
- `{:error, :file_not_found}` - File doesn't exist
- `{:error, reason}` - Read failed

**Example:**
```elixir
{:ok, content} = Ipa.Pod.WorkspaceManager.read_file(
  "task-123",
  "agent-456",
  "work/output.txt"
)
```

#### `write_file/4`
Writes content to a file within a workspace (with path validation).

```elixir
@spec write_file(task_id :: String.t(), agent_id :: String.t(), relative_path :: String.t(), content :: String.t()) ::
  :ok | {:error, reason :: term()}
```

**Parameters:**
- `task_id` - UUID of the task
- `agent_id` - UUID of the agent
- `relative_path` - Path relative to workspace root
- `content` - Content to write

**Returns:**
- `:ok` - File written successfully
- `{:error, :path_outside_workspace}` - Path escapes workspace
- `{:error, reason}` - Write failed

**Example:**
```elixir
:ok = Ipa.Pod.WorkspaceManager.write_file(
  "task-123",
  "agent-456",
  "work/results.json",
  Jason.encode!(%{status: "complete"})
)
```

**Note on File Operations:**
The `read_file/3` and `write_file/4` functions are **optional utilities** for pod-level workspace inspection. Agents do NOT use these functions - agents work directly in their workspace directory via the Claude Code SDK, using standard file operations. These utilities are provided for:
- Pod infrastructure to inspect workspace contents
- Debugging and monitoring
- External integrations that need to read workspace artifacts

#### `list_files/2`
Lists all files and directories within a workspace as a nested tree structure.

```elixir
@spec list_files(task_id :: String.t(), agent_id :: String.t()) ::
  {:ok, file_tree :: map()} | {:error, :workspace_not_found | term()}
```

**Parameters:**
- `task_id` - UUID of the task
- `agent_id` - UUID of the agent

**Returns:**
- `{:ok, file_tree}` - Nested map representing directory structure
- `{:error, :workspace_not_found}` - Workspace doesn't exist
- `{:error, reason}` - Listing failed

**File Tree Format:**
The returned map uses directory names as keys, with values being either:
- `:file` - Indicates a file
- `%{...}` - Nested map for subdirectories

**Example:**
```elixir
{:ok, tree} = Ipa.Pod.WorkspaceManager.list_files("task-123", "agent-456")
# => {:ok, %{
#   ".ipa" => %{
#     "task_spec.json" => :file,
#     "workspace_config.json" => :file
#   },
#   "work" => %{
#     "lib" => %{
#       "auth" => %{
#         "controller.ex" => :file,
#         "tokens.ex" => :file
#       }
#     },
#     "test" => %{
#       "auth_test.exs" => :file
#     }
#   },
#   "output" => %{
#     "results.json" => :file
#   }
# }}
```

**Implementation:**
```elixir
def list_files(task_id, agent_id) do
  case get_workspace_path(task_id, agent_id) do
    {:ok, workspace_path} ->
      case build_file_tree(workspace_path, workspace_path) do
        {:ok, tree} -> {:ok, tree}
        {:error, reason} -> {:error, reason}
      end

    {:error, reason} ->
      {:error, reason}
  end
end

defp build_file_tree(base_path, current_path) do
  relative_path = Path.relative_to(current_path, base_path)

  case File.ls(current_path) do
    {:ok, entries} ->
      tree = Enum.reduce(entries, %{}, fn entry, acc ->
        entry_path = Path.join(current_path, entry)

        case File.stat(entry_path) do
          {:ok, %File.Stat{type: :directory}} ->
            # Recursively build tree for subdirectories
            case build_file_tree(base_path, entry_path) do
              {:ok, subtree} -> Map.put(acc, entry, subtree)
              {:error, _} -> acc  # Skip directories we can't read
            end

          {:ok, %File.Stat{type: :regular}} ->
            # Mark as file
            Map.put(acc, entry, :file)

          _ ->
            # Skip other types (symlinks, devices, etc.)
            acc
        end
      end)

      {:ok, tree}

    {:error, :enoent} ->
      {:error, :workspace_not_found}

    {:error, reason} ->
      {:error, {:filesystem_error, reason}}
  end
end
```

**Performance Considerations:**
- File tree is built recursively by traversing the workspace directory
- Large workspaces (1000+ files) may take 100-500ms to scan
- Consider caching the tree if called frequently
- No size limit on returned tree (caller should handle large responses)

**Security:**
- Only lists files within the workspace directory
- Skips symlinks to prevent traversal attacks
- Follows same security principles as `read_file/3`

**Use Cases:**
- LiveView workspace browser component
- Debugging and monitoring tools
- External integrations that need workspace file listings

#### `get_workspace_path/2`
Returns the absolute path to a workspace.

```elixir
@spec get_workspace_path(task_id :: String.t(), agent_id :: String.t()) ::
  {:ok, path :: String.t()} | {:error, :workspace_not_found}
```

**Example:**
```elixir
{:ok, path} = Ipa.Pod.WorkspaceManager.get_workspace_path("task-123", "agent-456")
# => {:ok, "/ipa/workspaces/task-123/agent-456"}
```

#### `list_workspaces/1`
Lists all workspaces for a task by executing `aw list`.

```elixir
@spec list_workspaces(task_id :: String.t()) ::
  {:ok, list(String.t())} | {:error, reason :: term()}
```

**Returns:**
- `{:ok, agent_ids}` - List of agent IDs that have workspaces
- `{:error, {:aw_command_failed, exit_code, message}}` - `aw list` command failed
- `{:error, reason}` - List operation failed

**Implementation:**
1. Execute `aw list --task-id <task_id> --format json`
2. Parse JSON output
3. Extract agent IDs from workspace_id field

**Example:**
```elixir
{:ok, agent_ids} = Ipa.Pod.WorkspaceManager.list_workspaces("task-123")
# => {:ok, ["agent-456", "agent-789"]}
```

#### `workspace_exists?/2`
Checks if a workspace exists.

```elixir
@spec workspace_exists?(task_id :: String.t(), agent_id :: String.t()) :: boolean()
```

**Example:**
```elixir
Ipa.Pod.WorkspaceManager.workspace_exists?("task-123", "agent-456")
# => true
```

## Internal Implementation

### State Management

The WorkspaceManager uses an **event-sourced state** approach, rebuilding state from events on initialization:

**GenServer State:**
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

**State Reconstruction:**

On GenServer initialization, state is rebuilt from events in the event store:

```elixir
def init(opts) do
  task_id = Keyword.fetch!(opts, :task_id)
  base_path = Application.get_env(:ipa, Ipa.Pod.WorkspaceManager, [])
                |> Keyword.get(:base_path, "/ipa/workspaces")

  # Load workspace events from event store
  {:ok, events} = Ipa.EventStore.read_stream(
    task_id,
    event_types: ["workspace_created", "workspace_cleanup"]
  )

  # Rebuild workspace state by applying events
  workspaces = Enum.reduce(events, %{}, &apply_workspace_event/2)

  {:ok, %{task_id: task_id, base_path: base_path, workspaces: workspaces}}
end
```

**Event Application Pattern:**

```elixir
defp apply_workspace_event(
  %{event_type: "workspace_created", event_data: data},
  workspaces
) do
  Map.put(workspaces, data["agent_id"], %{
    path: data["workspace_path"],
    created_at: data["created_at"],
    config: data["config"]
  })
end

defp apply_workspace_event(
  %{event_type: "workspace_cleanup", event_data: data},
  workspaces
) do
  Map.delete(workspaces, data["agent_id"])
end
```

**Benefits:**
- State is always consistent with event store (single source of truth)
- Crash recovery is automatic (state rebuilt from events)
- No state synchronization issues
- Follows event sourcing best practices

### Path Validation

All file operations use comprehensive path validation to prevent directory traversal and symlink attacks:

```elixir
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
```

**Security Properties:**
- Prevents directory traversal (../ sequences)
- Detects symlinks pointing outside workspace
- Rejects absolute paths
- Rejects null bytes and special characters
- Validates path length
- Checks all path components recursively

### Workspace Initialization
When creating a workspace via `create_workspace/3`:

1. **Execute `aw create`**: Run `aw create --id {task_id}/{agent_id} [--config <json>]`
2. **Parse output**: Extract workspace path from `aw` stdout
3. **Add to state**: Add workspace metadata to GenServer state
4. **Record event**: Append `workspace_created` event to event store
5. **Broadcast**: Send `{:workspace_created, task_id, agent_id, workspace_path}` to pod pub-sub

**Note**: The `aw create` command handles:
- Directory structure creation (root, .ipa/, work/, output/)
- Writing `.ipa/task_spec.json` with task specification
- Writing `.ipa/workspace_config.json` with configuration
- Initializing git repo if configured
- Setting appropriate permissions

**WorkspaceManager does NOT create directories directly** - it delegates to `aw create`.

### Workspace Cleanup
When cleaning up a workspace via `cleanup_workspace/2`:

1. **Execute `aw destroy`**: Run `aw destroy --id {task_id}/{agent_id} [--force]`
2. **Remove from state**: Remove workspace from GenServer state
3. **Record event**: Append `workspace_cleanup` event to event store
4. **Broadcast**: Send `{:workspace_cleanup, task_id, agent_id}` to pod pub-sub

**Note**: The `aw destroy` command handles:
- Removing workspace directory recursively
- Handling file locks and permissions
- Cleanup failure handling

Handle `aw destroy` failures gracefully - log error but don't crash the GenServer.

### Graceful Shutdown

The WorkspaceManager implements `terminate/2` for graceful shutdown when the pod stops:

```elixir
@impl true
def terminate(reason, state) do
  require Logger
  Logger.info("WorkspaceManager shutting down for task #{state.task_id}, reason: #{inspect(reason)}")

  config = Application.get_env(:ipa, Ipa.Pod.WorkspaceManager, [])

  if Keyword.get(config, :cleanup_on_pod_shutdown, true) do
    # List all workspaces for this task via aw list
    case execute_aw_list(state.task_id) do
      {:ok, agent_ids} ->
        Enum.each(agent_ids, fn agent_id ->
          Logger.info("Cleaning up workspace for agent #{agent_id}")

          # Destroy workspace via aw destroy
          workspace_id = "#{state.task_id}/#{agent_id}"
          case execute_aw_destroy(workspace_id, force: true) do
            :ok ->
              Logger.info("Successfully destroyed workspace for agent #{agent_id}")

              # Best effort event recording (may fail if Pod.State already down)
              try do
                Ipa.Pod.State.append_event(
                  state.task_id,
                  "workspace_cleanup",
                  %{
                    agent_id: agent_id,
                    workspace_id: workspace_id,
                    cleanup_reason: "pod_shutdown"
                  },
                  nil,
                  actor_id: "system"
                )
              rescue
                error ->
                  Logger.warning("Could not record workspace_cleanup event for #{agent_id}: #{inspect(error)}")
              end

            {:error, reason} ->
              Logger.error("Failed to destroy workspace for agent #{agent_id}: #{inspect(reason)}")
          end
        end)

      {:error, reason} ->
        Logger.error("Failed to list workspaces: #{inspect(reason)}")
    end
  else
    Logger.info("Skipping workspace cleanup (cleanup_on_pod_shutdown: false)")
  end

  :ok
end
```

**Shutdown Behavior:**
- **Timeout**: 5 seconds (configured in Pod Supervisor child_spec)
- **Graceful**: If cleanup completes within timeout → graceful shutdown
- **Forced**: If cleanup exceeds timeout → process killed with `:kill` signal
- **Best Effort**: Events recorded on best-effort basis (Pod.State may already be down during shutdown sequence)

**Configuration:**
The `cleanup_on_pod_shutdown` config option (default: `true`) controls whether workspaces are cleaned up when the pod stops. Set to `false` to preserve workspaces for debugging.

## Events

### Event: `workspace_created`
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

### Event: `workspace_cleanup`
```elixir
%{
  event_type: "workspace_cleanup",
  event_data: %{
    agent_id: "agent-456",
    workspace_path: "/ipa/workspaces/task-123/agent-456",
    cleanup_reason: "agent_completed"
  },
  actor_id: "system",
  metadata: %{}
}
```

## Pod Pub-Sub Messages

### Message: `{:workspace_created, task_id, agent_id, workspace_path}`
Broadcast when a workspace is created.

### Message: `{:workspace_cleanup, task_id, agent_id}`
Broadcast when a workspace is cleaned up.

## Configuration

Application configuration in `config/config.exs`:

```elixir
config :ipa, Ipa.Pod.WorkspaceManager,
  base_path: "/ipa/workspaces",          # Base directory for all workspaces
  default_max_size_mb: 1000,             # Default max size per workspace
  cleanup_on_pod_shutdown: true,         # Clean up workspaces when pod stops
  archive_workspaces: false              # Archive before cleanup (future)
```

## Error Handling

### Workspace Creation Failures
- Directory creation fails → return `{:error, :filesystem_error}`
- Workspace already exists → return `{:error, :workspace_exists}`
- Disk full → return `{:error, :disk_full}`

### Path Validation Failures
- Path escapes workspace → return `{:error, :path_outside_workspace}`
- Invalid path characters → return `{:error, :invalid_path}`

### Cleanup Failures
- Workspace not found → return `{:error, :workspace_not_found}`
- Permission denied → log error, return `{:error, :permission_denied}`
- Files locked → log error, return `{:error, :cleanup_failed}`

## Supervision

The WorkspaceManager is supervised by `Ipa.Pod.Supervisor`:

```elixir
children = [
  {Ipa.Pod.WorkspaceManager, task_id: task_id},
  # ... other pod components
]
```

If WorkspaceManager crashes:
- Supervisor restarts it
- State is reloaded from event store (list of active workspaces)
- Workspaces remain on disk (persistent)

## Integration Points

### With Pod.Scheduler
The Scheduler orchestrates the full agent lifecycle:

1. **Create Workspace**: Scheduler calls WorkspaceManager to create workspace via `aw create`
2. **Spawn Agent**: Scheduler spawns agent with `cwd` set to workspace path
3. **Agent Execution**: Agent works directly in workspace using standard file operations
4. **Cleanup**: Scheduler calls WorkspaceManager to destroy workspace via `aw destroy`

```elixir
# In Pod.Scheduler

# Step 1: Create workspace
{:ok, workspace_path} = Ipa.Pod.WorkspaceManager.create_workspace(
  task_id,
  agent_id,
  %{max_size_mb: 1000, git_config: %{enabled: true}}
)
# => Executes: aw create --id task-123/agent-456
# => Returns: {:ok, "/ipa/workspaces/task-123/agent-456"}

# Step 2: Spawn agent with workspace as cwd
{:ok, stream} = ClaudeCode.run_task(
  prompt: "Complete the task according to spec",
  cwd: workspace_path,  # Agent starts in workspace directory
  allowed_tools: [:read, :write, :bash, :edit]
)

# Agent now executes in workspace:
# - Reads files with standard File operations
# - Writes files with standard File operations
# - Executes bash commands in workspace directory
# - WorkspaceManager does NOT intercept these operations

# Step 3: Wait for agent completion
# ... handle agent execution ...

# Step 4: Cleanup workspace
:ok = Ipa.Pod.WorkspaceManager.cleanup_workspace(task_id, agent_id)
# => Executes: aw destroy --id task-123/agent-456
```

**Key Points:**
- WorkspaceManager creates/destroys workspaces, but does NOT manage agent file operations
- Agents use standard file operations within their workspace
- The Claude Code SDK handles agent execution with `cwd` set to workspace path

### With Pod.State
WorkspaceManager appends lifecycle events to task stream:
```elixir
# Workspace created
Ipa.Pod.State.append_event(
  task_id,  # Events go to task stream
  "workspace_created",
  %{
    agent_id: agent_id,
    workspace_path: workspace_path,
    config: config
  },
  nil,
  actor_id: "system"
)

# Workspace cleanup
Ipa.Pod.State.append_event(
  task_id,
  "workspace_cleanup",
  %{
    agent_id: agent_id,
    workspace_path: workspace_path,
    cleanup_reason: "agent_completed"
  },
  nil,
  actor_id: "system"
)
```

### With `aw` CLI Tool
WorkspaceManager is a thin wrapper around `aw` CLI:

- **Create**: `aw create` handles workspace directory creation and initialization
- **Destroy**: `aw destroy` handles workspace deletion
- **List**: `aw list` queries active workspaces
- **Error Handling**: Parse `aw` exit codes and output

## Testing Strategy

### Unit Tests
- **`aw` CLI Integration**:
  - Mock `System.cmd/3` to test `aw create`, `aw destroy`, `aw list` calls
  - Test parsing of `aw` CLI output (JSON and text formats)
  - Test error handling for `aw` command failures
  - Test `aw` CLI availability check on init
- **Path Validation Logic** (for optional file utilities):
  - Symlink detection and prevention
  - Path traversal prevention
  - Special character handling
- **Event Integration**:
  - Workspace events are appended correctly
  - Event metadata includes correlation_id, causation_id
- **State Management**:
  - Event-sourced state reconstruction
  - `apply_workspace_event/2` pattern

### Integration Tests
- **End-to-End Workspace Lifecycle**:
  - Create workspace via `create_workspace/3` (calls `aw create`)
  - Verify workspace exists on filesystem
  - Spawn agent with `cwd` set to workspace path
  - Agent performs file operations in workspace
  - Cleanup workspace via `cleanup_workspace/2` (calls `aw destroy`)
  - Verify workspace removed from filesystem
- **Multiple Workspaces per Task**:
  - Create multiple agent workspaces for same task
  - Verify isolation between workspaces
  - List workspaces via `list_workspaces/1`
- **Event Store Integration**:
  - Workspace events are persisted correctly
  - State can be reconstructed from events after crash
- **Graceful Shutdown**:
  - Pod shutdown triggers workspace cleanup
  - `terminate/2` calls `aw destroy` for all workspaces

### Property Tests
- `aw` CLI workspace IDs are unique per task+agent pair
- Workspace paths match expected format
- All workspaces can be listed via `aw list`
- All workspaces can be destroyed via `aw destroy`

### `aw` CLI Mocking for Tests
For unit tests, mock `System.cmd/3`:
```elixir
# In test helper
defmodule AwCliMock do
  def mock_aw_create(workspace_id, path) do
    Mox.expect(SystemCmdMock, :cmd, fn "aw", ["create", "--id", ^workspace_id | _], _ ->
      {path, 0}
    end)
  end

  def mock_aw_destroy(workspace_id) do
    Mox.expect(SystemCmdMock, :cmd, fn "aw", ["destroy", "--id", ^workspace_id | _], _ ->
      {"Workspace destroyed", 0}
    end)
  end

  def mock_aw_list(task_id, workspaces) do
    json = Jason.encode!(workspaces)
    Mox.expect(SystemCmdMock, :cmd, fn "aw", ["list", "--task-id", ^task_id, "--format", "json"], _ ->
      {json, 0}
    end)
  end
end
```

## Security Considerations

1. **Path Traversal Prevention**: All file operations must validate paths
2. **Workspace Isolation**: Agents cannot access other workspaces
3. **Resource Limits**: Track disk usage (future enhancement)
4. **Permission Management**: Workspaces have appropriate file permissions

## Performance Considerations

1. **Lazy Initialization**: Create workspaces only when needed
2. **Async Cleanup**: Clean up workspaces asynchronously
3. **Bulk Operations**: Support batch cleanup (future enhancement)
4. **Disk Space**: Monitor available disk space before creation

## Future Enhancements

### Phase 1 (Current Scope)
- Basic workspace creation/cleanup
- Path validation
- File read/write operations
- Event integration

### Phase 2 (Future)
- Workspace archiving before cleanup
- Disk usage monitoring and limits
- Workspace snapshots
- Workspace cloning (for parallel agents)

### Phase 3 (Multi-Workspace)
- Support for workspace multiplexing
- Workspace-to-workspace communication
- Shared workspace areas
- Workspace templates

## Dependencies

### Elixir Standard Library
- `File` - File system operations
- `Path` - Path manipulation and validation
- `GenServer` - State management

### Internal Dependencies
- `Ipa.Pod.State` - Event appending
- `Ipa.EventStore` - Event persistence

### External Dependencies
- None (uses standard file system)

## Success Criteria

1. Workspaces can be created for agents
2. Agents can read/write files within workspace
3. Workspaces are isolated (no cross-access)
4. Path validation prevents directory traversal
5. Cleanup removes all workspace files
6. Events are properly recorded
7. Integration with Scheduler works seamlessly
8. Tests cover all critical paths

## Open Questions

1. Should we support workspace templates (pre-populated files)?
2. Should workspace size limits be enforced proactively?
3. How long should archived workspaces be retained?
4. Should we support workspace sharing between agents?
5. Should we track detailed file operation metrics?

## References

- Elixir File module: https://hexdocs.pm/elixir/File.html
- Path security: https://owasp.org/www-community/attacks/Path_Traversal
- Claude Code SDK: https://hexdocs.pm/claude_code/readme.html
