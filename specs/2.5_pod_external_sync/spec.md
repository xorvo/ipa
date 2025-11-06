# Component Spec: 2.5 Pod External Sync

## Spec Alignment Notes

This spec has been aligned with:
- **Event Store (1.1)**: Reads events for sync context, appends sync result events
- **Pod State Manager (2.2)**: Subscribes to state changes, reads external_sync state
- **Pod Supervisor (2.1)**: Uses Registry-based registration `{:pod_sync, task_id}`, implements `terminate/2` callback
- **OTP Best Practices**: Follows GenServer patterns, graceful shutdown, proper error handling

### Architecture Review (Completed 2025-11-05)

**Score**: 8.5/10 - APPROVED for implementation after revisions

**Critical Fixes Implemented**:
- **#1**: Event logging in `terminate/2` - All cancelled operations are now logged as events for audit trail, with proper timeout handling for in-progress operations
- **#2**: Task management in sync queue - Queue processing now uses `Task.start_link/1` with completion messages, preventing orphaned operations and queue deadlock
- **#3**: Atomic operations + event append - Added comprehensive idempotency checks (check_existing_pr), event append retry with exponential backoff, and graceful handling when event append fails after external resource creation
- **#4**: Adaptive polling for rate limits - Polling interval now dynamically adjusts from 1 minute (fast) to 30 minutes (slow) based on GitHub/JIRA rate limit status. Default changed from 60 seconds to 5 minutes (much more conservative)
- **#5**: Idempotency for duplicate events - Polling now tracks seen comment IDs, PR states, and JIRA status to prevent duplicate event append. Each poll checks current state before processing changes

**Additional Improvements**:
- Added `sync_operation_completed` and `sync_operation_failed` events for audit trail
- Added `github_poll_completed` and `jira_poll_completed` events to track polling activity
- Added queue size limit (100 operations) to prevent unbounded growth
- Extended deduplication window from 5 minutes to 10 minutes
- Added comprehensive helper functions for idempotency checking

**Remaining Recommendations** (non-critical, for future iterations):
- Consider circuit breaker pattern for repeated external API failures
- Add observability metrics via telemetry events
- Implement webhook support as alternative to polling (Phase 3)
- Add global rate limit coordinator for multi-pod scenarios

**Ready for Implementation**: All 5 critical issues have been addressed. The spec follows Elixir/OTP best practices and properly integrates with Event Store and Pod State Manager.

## Overview

The Pod External Sync is the **external integration layer** for an individual task pod. It sits alongside Pod State Manager and provides:

1. **Outbound sync** - Pushes task state changes to GitHub and JIRA
2. **Inbound sync** - Polls external systems for changes and reflects them in task state
3. **Approval gates** - Requires human approval for sensitive operations
4. **Sync queue** - Manages pending sync operations with deduplication
5. **Rate limiting** - Respects external API rate limits

This is **Layer 2** (Pod Infrastructure) - it knows about tasks and business logic, and bridges IPA with external project management tools.

## Purpose

- Automatically create GitHub PRs when development phase starts
- Sync code changes to GitHub as agents work
- Update JIRA tickets as task progresses through phases
- Detect external changes (PR comments, JIRA updates) and notify task
- Prevent accidental operations via approval gates
- Handle authentication, rate limiting, and retries

## Separation of Concerns

```
Layer 3: Business Logic (Central Manager, UI)
           ↓ uses
Layer 2: Pod External Sync ← THIS COMPONENT (integration layer)
           ↓ reads state from
Layer 2: Pod State Manager (task state)
           ↓ uses
Layer 1: Event Store (events)
```

**This component** provides:
- GitHub/JIRA connector implementations
- Sync queue management
- Approval gate enforcement
- Rate limiting and retry logic

**This component does NOT**:
- Make scheduling decisions (that's Scheduler's job)
- Manage task state (that's State Manager's job)
- Decide what to sync (reacts to state changes)

## Dependencies

- **External**: GitHub API (via `gh` CLI or Octokit), JIRA REST API, HTTPoison
- **Internal**:
  - Ipa.EventStore (Layer 1) - for appending sync events
  - Ipa.Pod.State (Layer 2) - for reading state and subscribing to changes
  - Ipa.PodRegistry (Layer 2) - for registration
- **Used By**: None (leaf component, publishes events to State Manager)

## Module Structure

```
lib/ipa/pod/
  ├── external_sync.ex              # Main sync manager (GenServer)
  ├── external_sync/
  │   ├── github_connector.ex       # GitHub API client
  │   ├── jira_connector.ex         # JIRA API client
  │   ├── sync_queue.ex             # Queue with deduplication
  │   └── approval_gate.ex          # Human approval logic
```

## External System States

### GitHub State (per task)

```elixir
%{
  pr_number: integer() | nil,           # GitHub PR number
  pr_url: String.t() | nil,             # PR URL
  pr_state: :open | :closed | :merged | nil,
  pr_merged?: boolean(),
  last_synced_at: integer() | nil,      # Unix timestamp
  last_commit_sha: String.t() | nil,    # Last pushed commit
  pending_operations: [atom()]          # [:create_pr, :update_pr, :close_pr]
}
```

### JIRA State (per task)

```elixir
%{
  ticket_id: String.t() | nil,          # JIRA ticket key (e.g., "PROJ-123")
  ticket_url: String.t() | nil,         # JIRA ticket URL
  status: String.t() | nil,             # JIRA status (e.g., "In Progress")
  last_synced_at: integer() | nil,      # Unix timestamp
  pending_operations: [atom()]          # [:create_ticket, :update_status, :add_comment]
}
```

## Sync Lifecycle

### Outbound Sync (IPA → External)

```
1. Pod State Manager appends event (e.g., :transition_approved to :development)
2. State Manager broadcasts {:state_updated, task_id, new_state} via pub-sub
3. External Sync receives message in handle_info/2
4. External Sync evaluates: "Should we sync this change?"
   - If yes: Add operation to sync queue
5. Sync Queue processes operation:
   - Check if approval required
   - If yes: Wait for human approval
   - If no: Execute sync immediately
6. Connector executes sync (e.g., create GitHub PR)
7. On success: Append sync result event to Event Store
8. On failure: Log error, optionally retry
```

### Inbound Sync (External → IPA)

```
1. External Sync polls GitHub/JIRA periodically (every 60 seconds)
2. Detects external change (e.g., PR comment added)
3. Evaluates: "Is this change relevant to task?"
4. If yes: Append event to Event Store (e.g., :github_comment_added)
5. State Manager processes event and broadcasts update
6. Other pod components react (e.g., Scheduler spawns agent to respond)
```

## Public API

### Module: `Ipa.Pod.ExternalSync`

This is a **GenServer** that manages external synchronization for a single task.

#### `start_link/1`

```elixir
@spec start_link(opts :: keyword()) :: GenServer.on_start()
```

Starts the external sync manager for a task. Called by Pod Supervisor.

**Parameters**:
- `opts` - Keyword list with `:task_id` required

**Behavior**:
1. Registers itself via Registry with key `{:pod_sync, task_id}`
2. Subscribes to pod-local pub-sub topic `pod:#{task_id}:state`
3. Loads current task state to determine sync status
4. Schedules periodic poll for external changes
5. Returns `{:ok, pid}`

**Registration Strategy** (aligns with Pod Supervisor 2.1):
```elixir
def start_link(opts) do
  task_id = Keyword.fetch!(opts, :task_id)
  GenServer.start_link(__MODULE__, opts, name: via_tuple(task_id))
end

defp via_tuple(task_id) do
  {:via, Registry, {Ipa.PodRegistry, {:pod_sync, task_id}}}
end
```

**Example**:
```elixir
# Called by Pod Supervisor
{:ok, pid} = Ipa.Pod.ExternalSync.start_link(task_id: task_id)
```

#### `sync_now/2`

```elixir
@spec sync_now(task_id :: String.t(), operation :: atom()) ::
  {:ok, result :: map()} | {:error, :approval_required | term()}
```

Manually triggers a sync operation (for testing or manual intervention).

**Parameters**:
- `task_id` - Task UUID
- `operation` - Operation to perform (`:create_github_pr`, `:update_jira_ticket`, etc.)

**Returns**:
- `{:ok, result}` - Sync successful, result contains details
- `{:error, :approval_required}` - Operation requires human approval
- `{:error, reason}` - Sync failed

**Example**:
```elixir
# Manually create GitHub PR
{:ok, result} = Ipa.Pod.ExternalSync.sync_now(task_id, :create_github_pr)
# => {:ok, %{pr_number: 123, pr_url: "https://github.com/..."}}

# If approval required
{:error, :approval_required} = Ipa.Pod.ExternalSync.sync_now(task_id, :close_github_pr)
```

#### `approve_operation/2`

```elixir
@spec approve_operation(task_id :: String.t(), operation_id :: String.t()) ::
  :ok | {:error, :not_found | term()}
```

Approves a pending sync operation that requires human approval.

**Parameters**:
- `task_id` - Task UUID
- `operation_id` - Unique ID of pending operation

**Example**:
```elixir
# Approve pending PR close operation
:ok = Ipa.Pod.ExternalSync.approve_operation(task_id, "op-uuid-123")
```

#### `reject_operation/2`

```elixir
@spec reject_operation(task_id :: String.t(), operation_id :: String.t()) ::
  :ok | {:error, :not_found | term()}
```

Rejects a pending sync operation.

**Example**:
```elixir
:ok = Ipa.Pod.ExternalSync.reject_operation(task_id, "op-uuid-123")
```

#### `get_pending_approvals/1`

```elixir
@spec get_pending_approvals(task_id :: String.t()) :: {:ok, [approval()]}
```

Returns list of pending operations awaiting approval.

**Returns**: List of approval maps:
```elixir
%{
  operation_id: String.t(),
  operation: atom(),
  requested_at: integer(),
  reason: String.t()
}
```

**Example**:
```elixir
{:ok, approvals} = Ipa.Pod.ExternalSync.get_pending_approvals(task_id)
# => [
#   %{operation_id: "op-1", operation: :close_github_pr, requested_at: 1699564800, reason: "Task completed"},
#   %{operation_id: "op-2", operation: :update_jira_status, requested_at: 1699564805, reason: "Move to Done"}
# ]
```

#### `force_poll/1`

```elixir
@spec force_poll(task_id :: String.t()) :: :ok
```

Forces an immediate poll of external systems (for testing or manual refresh).

**Example**:
```elixir
:ok = Ipa.Pod.ExternalSync.force_poll(task_id)
```

## GitHub Integration

### Operations

#### Create Pull Request

**Trigger**: Task transitions to `:development` phase

**Operation**: `create_github_pr`

**Approval Required**: No (automatic)

**Implementation** (with idempotency):
```elixir
defp create_github_pr(task_id, state) do
  # Get workspace info from state
  workspace = get_primary_workspace(state)

  # Generate PR title and body from task state
  title = "feat: #{state.title}"
  body = generate_pr_body(state.spec, state.plan)

  # IDEMPOTENCY CHECK: Check if PR already exists
  case check_existing_pr(workspace, title) do
    {:ok, existing_pr} ->
      # PR exists (idempotent operation), ensure event is recorded
      Logger.info("PR already exists for task #{task_id}: #{existing_pr.pr_url}")
      ensure_pr_event_recorded(task_id, existing_pr)
      {:ok, existing_pr}

    {:error, :not_found} ->
      # PR doesn't exist, create it
      case System.cmd("gh", ["pr", "create", "--title", title, "--body", body], cd: workspace) do
        {output, 0} ->
          # Parse PR number and URL from output
          pr_number = parse_pr_number(output)
          pr_url = parse_pr_url(output)

          # Append event with retry (critical to record this)
          case append_event_with_retry(
            task_id,
            "github_pr_created",
            %{pr_number: pr_number, pr_url: pr_url},
            max_retries: 5
          ) do
            {:ok, _version} ->
              {:ok, %{pr_number: pr_number, pr_url: pr_url}}

            {:error, reason} ->
              # Event append failed - PR exists but not recorded in IPA
              # Log error but don't fail the operation
              # Next poll will detect the PR and record it
              Logger.error("Failed to append github_pr_created event after #{max_retries} retries: #{inspect(reason)}")
              Logger.error("PR exists at #{pr_url} but not recorded in Event Store - will be detected on next poll")
              {:ok, %{pr_number: pr_number, pr_url: pr_url, event_append_failed: true}}
          end

        {error, _exit_code} ->
          {:error, {:github_api_error, error}}
      end

    {:error, reason} ->
      # Can't determine if PR exists - fail safe
      {:error, {:github_check_failed, reason}}
  end
end

# Helper: Check if PR already exists (idempotency)
defp check_existing_pr(workspace, title) do
  # Use gh CLI to list existing PRs with this title
  case System.cmd("gh", ["pr", "list", "--search", "in:title #{title}", "--json", "number,url,title"], cd: workspace) do
    {output, 0} ->
      case Jason.decode(output) do
        {:ok, []} ->
          {:error, :not_found}

        {:ok, [pr | _]} ->
          {:ok, %{pr_number: pr["number"], pr_url: pr["url"]}}

        {:error, _} ->
          {:error, :parse_failed}
      end

    {_error, _exit_code} ->
      {:error, :gh_command_failed}
  end
end

# Helper: Ensure PR event is recorded (for idempotency)
defp ensure_pr_event_recorded(task_id, pr_info) do
  # Check if event already exists by reading current state
  {:ok, state} = Ipa.Pod.State.get_state(task_id)

  if state.external_sync.github.pr_number == pr_info.pr_number do
    # Event already recorded
    :ok
  else
    # Event not recorded, append it now
    case Ipa.Pod.State.append_event(
      task_id,
      "github_pr_created",
      %{pr_number: pr_info.pr_number, pr_url: pr_info.pr_url},
      actor_id: "external_sync"
    ) do
      {:ok, _version} -> :ok
      {:error, reason} ->
        Logger.error("Failed to record existing PR in Event Store: #{inspect(reason)}")
        {:error, reason}
    end
  end
end

# Helper: Append event with exponential backoff retry
defp append_event_with_retry(task_id, event_type, event_data, opts \\ []) do
  max_retries = Keyword.get(opts, :max_retries, 3)
  actor_id = Keyword.get(opts, :actor_id, "external_sync")

  Enum.reduce_while(1..max_retries, {:error, :no_attempts}, fn attempt, _acc ->
    case Ipa.Pod.State.append_event(task_id, event_type, event_data, actor_id: actor_id) do
      {:ok, version} ->
        {:halt, {:ok, version}}

      {:error, reason} when attempt < max_retries ->
        Logger.warning("Event append attempt #{attempt}/#{max_retries} failed: #{inspect(reason)}")
        # Exponential backoff
        :timer.sleep(:math.pow(2, attempt) * 100)
        {:cont, {:error, reason}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end)
end
```

**Critical Fix**: This implementation now:
1. **Checks for existing PR** before creating (idempotency)
2. **Retries event append** up to 5 times with exponential backoff
3. **Gracefully handles event append failure** - logs error but doesn't fail operation (PR exists, will be detected on next poll)
4. **Ensures event is recorded** if PR already exists

#### Update Pull Request

**Trigger**: New commits pushed to workspace

**Operation**: `update_github_pr`

**Approval Required**: No (automatic)

**Implementation**: Push commits to PR branch, update PR description if needed

#### Close Pull Request

**Trigger**: Task cancelled or PR manually closed externally

**Operation**: `close_github_pr`

**Approval Required**: Yes (prevents accidental closes)

#### Merge Pull Request

**Trigger**: Task transitions to `:completed` phase

**Operation**: `merge_github_pr`

**Approval Required**: Yes (important operation)

### Polling for External Changes

**Poll Interval**: Every 60 seconds

**Detects**:
- New PR comments
- PR status changes (closed, merged)
- New commits from external contributors
- Review approvals/changes requested

**On Detection**:
- Append corresponding event to Event Store
- Example: `github_comment_added`, `github_pr_merged`

## JIRA Integration

### Operations

#### Create Ticket

**Trigger**: Task created

**Operation**: `create_jira_ticket`

**Approval Required**: No (automatic, if JIRA configured)

**Implementation**:
```elixir
defp create_jira_ticket(task_id, state) do
  # Generate ticket summary and description
  summary = state.title
  description = format_jira_description(state.spec)

  # Use JIRA REST API
  body = %{
    fields: %{
      project: %{key: jira_project_key()},
      summary: summary,
      description: description,
      issuetype: %{name: "Task"}
    }
  }

  case HTTPoison.post(jira_api_url(), Jason.encode!(body), jira_headers()) do
    {:ok, %{status_code: 201, body: response_body}} ->
      ticket = Jason.decode!(response_body)
      ticket_id = ticket["key"]
      ticket_url = "#{jira_base_url()}/browse/#{ticket_id}"

      # Append event to Event Store
      Ipa.Pod.State.append_event(
        task_id,
        "jira_ticket_created",
        %{ticket_id: ticket_id, ticket_url: ticket_url},
        actor_id: "external_sync"
      )

      {:ok, %{ticket_id: ticket_id, ticket_url: ticket_url}}

    {:ok, %{status_code: status_code, body: error_body}} ->
      {:error, {:jira_api_error, status_code, error_body}}

    {:error, reason} ->
      {:error, {:jira_connection_error, reason}}
  end
end
```

#### Update Ticket Status

**Trigger**: Task phase transitions

**Operation**: `update_jira_status`

**Approval Required**: No (automatic)

**Phase → Status Mapping**:
```elixir
defp phase_to_jira_status(:spec_clarification), do: "To Do"
defp phase_to_jira_status(:planning), do: "To Do"
defp phase_to_jira_status(:development), do: "In Progress"
defp phase_to_jira_status(:review), do: "In Review"
defp phase_to_jira_status(:completed), do: "Done"
defp phase_to_jira_status(:cancelled), do: "Cancelled"
```

#### Add Comment

**Trigger**: Significant events (agent completed, PR created, errors)

**Operation**: `add_jira_comment`

**Approval Required**: No (automatic)

### Polling for External Changes

**Poll Interval**: Every 60 seconds

**Detects**:
- Status changes (manual updates in JIRA)
- New comments
- Assignment changes
- Priority changes

**On Detection**:
- Append event to Event Store
- Example: `jira_status_changed`, `jira_comment_added`

## Sync Queue

### Queue Structure

```elixir
defmodule Ipa.Pod.ExternalSync.SyncQueue do
  defstruct [
    pending: [],      # List of %SyncOperation{}
    in_progress: nil, # Currently executing operation
    completed: []     # Recently completed (for deduplication)
  ]
end

defmodule Ipa.Pod.ExternalSync.SyncOperation do
  defstruct [
    :operation_id,    # UUID
    :operation,       # Atom (:create_github_pr, :update_jira_status, etc.)
    :task_id,         # Task UUID
    :params,          # Operation parameters
    :requires_approval?, # Boolean
    :approved?,       # Boolean
    :requested_at,    # Unix timestamp
    :retries          # Integer
  ]
end
```

### Deduplication

Prevents duplicate sync operations within a time window:

```elixir
defp deduplicate_operation(queue, new_op) do
  # Check if same operation was completed recently (within 5 minutes)
  recent_completed = Enum.filter(queue.completed, fn completed_op ->
    completed_op.operation == new_op.operation and
    (System.system_time(:second) - completed_op.completed_at) < 300
  end)

  if Enum.any?(recent_completed) do
    {:duplicate, queue}
  else
    {:ok, %{queue | pending: queue.pending ++ [new_op]}}
  end
end
```

### Queue Processing

```elixir
def handle_info(:process_queue, state) do
  case state.sync_queue do
    %{in_progress: nil, pending: [next_op | rest]} ->
      # Start processing next operation
      if next_op.requires_approval? and not next_op.approved? do
        # Wait for approval - keep operation at head of pending queue
        {:noreply, state}
      else
        # Execute operation asynchronously with linked task
        parent_pid = self()
        {:ok, task_pid} = Task.start_link(fn ->
          result = execute_operation(next_op, state)
          send(parent_pid, {:operation_completed, next_op.operation_id, result})
        end)

        # Track task PID so we can monitor/kill it during shutdown
        updated_op = Map.put(next_op, :task_pid, task_pid)
        new_queue = %{state.sync_queue | in_progress: updated_op, pending: rest}
        {:noreply, %{state | sync_queue: new_queue}}
      end

    _ ->
      # Queue empty or operation in progress
      {:noreply, state}
  end
end

# Handle operation completion
def handle_info({:operation_completed, operation_id, result}, state) do
  require Logger

  case result do
    {:ok, operation_result} ->
      Logger.info("Sync operation #{operation_id} completed successfully")

      # Append success event
      case Ipa.Pod.State.append_event(
        state.task_id,
        "sync_operation_completed",
        %{
          operation_id: operation_id,
          operation: state.sync_queue.in_progress.operation,
          result: operation_result
        },
        actor_id: "external_sync"
      ) do
        {:ok, _version} -> :ok
        {:error, reason} ->
          Logger.error("Failed to log completed operation: #{inspect(reason)}")
      end

    {:error, reason} ->
      Logger.error("Sync operation #{operation_id} failed: #{inspect(reason)}")

      # Append failure event
      Ipa.Pod.State.append_event(
        state.task_id,
        "sync_operation_failed",
        %{
          operation_id: operation_id,
          operation: state.sync_queue.in_progress.operation,
          error: inspect(reason),
          retries: state.sync_queue.in_progress.retries
        },
        actor_id: "external_sync"
      )
  end

  # Move completed operation to completed list with timestamp
  completed_op = state.sync_queue.in_progress
    |> Map.put(:completed_at, System.system_time(:second))
    |> Map.put(:result, result)

  # Update queue: clear in_progress, add to completed
  new_queue = %{state.sync_queue |
    in_progress: nil,
    completed: [completed_op | Enum.take(state.sync_queue.completed, 99)] # Keep last 100
  }

  # Process next operation in queue
  send(self(), :process_queue)

  {:noreply, %{state | sync_queue: new_queue}}
end
```

**Critical Fix**: Queue processing now uses `Task.start_link/1` to:
1. Link the task to the GenServer (if task crashes, GenServer is notified)
2. Track task PID for shutdown handling
3. Send completion message back to GenServer
4. Properly handle success and failure cases with event logging
5. Automatically process next operation after completion

## Approval Gates

### Operations Requiring Approval

```elixir
defp requires_approval?(:close_github_pr), do: true
defp requires_approval?(:merge_github_pr), do: true
defp requires_approval?(:delete_jira_ticket), do: true
defp requires_approval?(_operation), do: false
```

### Approval Flow

```
1. Operation added to queue with requires_approval?: true
2. Event appended: :sync_operation_pending_approval
3. User sees approval request in UI (LiveView)
4. User calls approve_operation/2 or reject_operation/2
5. If approved: Operation proceeds
6. If rejected: Operation removed from queue
```

### Configuration

```elixir
# config/config.exs
config :ipa, Ipa.Pod.ExternalSync,
  # Operations requiring approval (can be customized per deployment)
  approval_required: [
    :close_github_pr,
    :merge_github_pr,
    :delete_jira_ticket
  ],

  # Auto-approve if conditions met
  auto_approve_merge_pr_if: fn state ->
    # Auto-approve PR merge if all tests passing and approved
    state.external_sync.github.pr_checks_passing? and
    state.external_sync.github.pr_approved?
  end
```

## Implementation Details

### GenServer State

```elixir
defmodule Ipa.Pod.ExternalSync do
  use GenServer

  defstruct [
    :task_id,
    :sync_queue,          # %SyncQueue{}
    :poll_timer_ref,      # Timer reference for periodic polling
    :github_client,       # GitHub connector state
    :jira_client          # JIRA connector state
  ]
end
```

### GenServer Callbacks

#### `init/1`

```elixir
def init(opts) do
  task_id = Keyword.fetch!(opts, :task_id)

  # Subscribe to state changes
  Ipa.Pod.State.subscribe(task_id)

  # Load current state to determine sync status
  {:ok, current_state} = Ipa.Pod.State.get_state(task_id)

  # Initialize connectors
  github_client = Ipa.Pod.ExternalSync.GitHubConnector.init(current_state.external_sync.github)
  jira_client = Ipa.Pod.ExternalSync.JiraConnector.init(current_state.external_sync.jira)

  # Schedule first poll
  poll_interval = Application.get_env(:ipa, Ipa.Pod.ExternalSync)[:poll_interval] || 60_000
  timer_ref = Process.send_after(self(), :poll_external, poll_interval)

  {:ok, %__MODULE__{
    task_id: task_id,
    sync_queue: %SyncQueue{},
    poll_timer_ref: timer_ref,
    github_client: github_client,
    jira_client: jira_client
  }}
end
```

#### `handle_info/2` - state_updated

```elixir
def handle_info({:state_updated, task_id, new_state}, state) do
  # Evaluate if any sync operations should be triggered
  operations = evaluate_sync_triggers(new_state, state)

  # Add operations to queue
  new_queue = Enum.reduce(operations, state.sync_queue, fn op, queue ->
    case add_to_queue(queue, op) do
      {:ok, updated_queue} -> updated_queue
      {:duplicate, _} -> queue
    end
  end)

  # Process queue
  send(self(), :process_queue)

  {:noreply, %{state | sync_queue: new_queue}}
end
```

#### `handle_info/2` - poll_external

```elixir
def handle_info(:poll_external, state) do
  require Logger

  # Poll GitHub for changes (with idempotency checks)
  case poll_github_with_idempotency(state.task_id, state.github_client) do
    {:ok, events, updated_client} ->
      # Append events to Event Store
      Enum.each(events, fn event ->
        Ipa.Pod.State.append_event(
          state.task_id,
          event.event_type,
          event.data,
          actor_id: "github"
        )
      end)

      state = %{state | github_client: updated_client}

    {:error, reason} ->
      Logger.warning("Failed to poll GitHub for task #{state.task_id}: #{inspect(reason)}")
  end

  # Poll JIRA for changes (with idempotency checks)
  case poll_jira_with_idempotency(state.task_id, state.jira_client) do
    {:ok, events, updated_client} ->
      Enum.each(events, fn event ->
        Ipa.Pod.State.append_event(
          state.task_id,
          event.event_type,
          event.data,
          actor_id: "jira"
        )
      end)

      state = %{state | jira_client: updated_client}

    {:error, reason} ->
      Logger.warning("Failed to poll JIRA for task #{state.task_id}: #{inspect(reason)}")
  end

  # Calculate next poll interval (adaptive based on rate limits)
  next_poll_interval = calculate_adaptive_poll_interval(state)
  timer_ref = Process.send_after(self(), :poll_external, next_poll_interval)

  {:noreply, %{state | poll_timer_ref: timer_ref}}
end

# Poll GitHub with idempotency checks for duplicate events
defp poll_github_with_idempotency(task_id, github_client) do
  # Fetch current state to check what we've already seen
  {:ok, state} = Ipa.Pod.State.get_state(task_id)

  # Get last poll timestamp from state (or default to task creation time)
  last_poll = state.external_sync.github.last_poll_timestamp || state.created_at

  # Fetch changes since last poll
  case fetch_github_changes_since(github_client, state.external_sync.github, last_poll) do
    {:ok, changes, updated_client} ->
      # Filter out changes we've already processed (idempotency)
      new_events = changes
      |> Enum.filter(&is_new_github_change?(&1, state))
      |> Enum.map(&to_github_event/1)

      # Update last poll timestamp in state
      if length(new_events) > 0 do
        Ipa.Pod.State.append_event(
          task_id,
          "github_poll_completed",
          %{timestamp: System.system_time(:second), new_events_count: length(new_events)},
          actor_id: "external_sync"
        )
      end

      {:ok, new_events, updated_client}

    {:error, reason} ->
      {:error, reason}
  end
end

# Check if GitHub change is new (not already processed)
defp is_new_github_change?(change, state) do
  case change.type do
    :pr_comment ->
      # Check if this comment ID was already seen
      comment_id = change.comment_id
      not Enum.any?(state.external_sync.github.seen_comment_ids || [], &(&1 == comment_id))

    :pr_status_changed ->
      # Check if PR state matches what we have recorded
      change.new_state != state.external_sync.github.pr_state

    :pr_merged ->
      # Only process if we haven't recorded merge yet
      not state.external_sync.github.pr_merged?

    :pr_closed ->
      # Only process if PR is still open in our state
      state.external_sync.github.pr_state == :open

    _ ->
      # Unknown change type, process it
      true
  end
end

# Poll JIRA with idempotency checks
defp poll_jira_with_idempotency(task_id, jira_client) do
  {:ok, state} = Ipa.Pod.State.get_state(task_id)
  last_poll = state.external_sync.jira.last_poll_timestamp || state.created_at

  case fetch_jira_changes_since(jira_client, state.external_sync.jira, last_poll) do
    {:ok, changes, updated_client} ->
      new_events = changes
      |> Enum.filter(&is_new_jira_change?(&1, state))
      |> Enum.map(&to_jira_event/1)

      if length(new_events) > 0 do
        Ipa.Pod.State.append_event(
          task_id,
          "jira_poll_completed",
          %{timestamp: System.system_time(:second), new_events_count: length(new_events)},
          actor_id: "external_sync"
        )
      end

      {:ok, new_events, updated_client}

    {:error, reason} ->
      {:error, reason}
  end
end

# Check if JIRA change is new
defp is_new_jira_change?(change, state) do
  case change.type do
    :status_changed ->
      change.new_status != state.external_sync.jira.status

    :comment_added ->
      comment_id = change.comment_id
      not Enum.any?(state.external_sync.jira.seen_comment_ids || [], &(&1 == comment_id))

    _ ->
      true
  end
end

# Calculate adaptive poll interval based on rate limits
defp calculate_adaptive_poll_interval(state) do
  base_interval = Application.get_env(:ipa, Ipa.Pod.ExternalSync)[:poll_interval] || 300_000
  min_interval = Application.get_env(:ipa, Ipa.Pod.ExternalSync)[:min_poll_interval] || 60_000
  max_interval = Application.get_env(:ipa, Ipa.Pod.ExternalSync)[:max_poll_interval] || 1_800_000

  # Check GitHub rate limit
  github_rate_remaining = state.github_client.rate_limit_remaining || 5000
  github_adjustment = cond do
    github_rate_remaining < 50 ->
      # Very low rate limit, slow down significantly
      max_interval

    github_rate_remaining < 200 ->
      # Low rate limit, slow down moderately
      min(base_interval * 3, max_interval)

    github_rate_remaining < 500 ->
      # Moderate rate limit, slow down slightly
      min(base_interval * 2, max_interval)

    true ->
      # Plenty of rate limit, use base interval
      base_interval
  end

  # Check JIRA rate limit (if available)
  jira_adjustment = base_interval # JIRA rate limiting is less strict

  # Use the longer interval (more conservative)
  max(min(max(github_adjustment, jira_adjustment), max_interval), min_interval)
end
```

**Critical Fixes**:
1. **Adaptive polling** - Automatically slows down when rate limits are low (from 1 min to 30 min)
2. **Idempotency checks** - Tracks seen comment IDs and status changes to avoid duplicate events
3. **Conservative defaults** - Base interval increased to 5 minutes (was 60 seconds)
4. **Rate limit updates** - Connectors return updated rate limit info after each poll
5. **Poll completion events** - Records successful polls as events for audit trail

#### `terminate/2` - Graceful Shutdown

```elixir
@impl true
def terminate(reason, state) do
  require Logger
  Logger.info("Pod External Sync shutting down for task #{state.task_id}, reason: #{inspect(reason)}")

  # Log cancelled operations as events (audit trail)
  if not Enum.empty?(state.sync_queue.pending) do
    Logger.warning("Cancelling #{length(state.sync_queue.pending)} pending sync operations for task #{state.task_id}")

    # Append cancellation events for audit trail
    Enum.each(state.sync_queue.pending, fn op ->
      case Ipa.Pod.State.append_event(
        state.task_id,
        "sync_operation_cancelled",
        %{
          operation_id: op.operation_id,
          operation: op.operation,
          reason: "pod_shutdown",
          was_approved: op.approved? || false
        },
        actor_id: "external_sync"
      ) do
        {:ok, _version} -> :ok
        {:error, reason} ->
          Logger.error("Failed to log cancelled operation #{op.operation_id}: #{inspect(reason)}")
      end
    end)
  end

  # Cancel poll timer
  if state.poll_timer_ref do
    Process.cancel_timer(state.poll_timer_ref)
  end

  # Wait for in-progress operation to complete (with timeout)
  if state.sync_queue.in_progress do
    Logger.info("Waiting for in-progress sync operation to complete...")

    case state.sync_queue.in_progress do
      %{task_pid: task_pid} when is_pid(task_pid) ->
        # Wait up to 5 seconds for task to complete
        task_ref = Process.monitor(task_pid)
        receive do
          {:DOWN, ^task_ref, :process, ^task_pid, _reason} ->
            Logger.info("In-progress operation completed during shutdown")
        after
          5_000 ->
            Logger.warning("In-progress operation did not complete within timeout, forcefully terminating")
            Process.exit(task_pid, :kill)
        end
      _ ->
        # No task PID tracked, just log
        Logger.warning("In-progress operation present but no task PID tracked")
    end
  end

  :ok
end
```

**Critical**: This callback is **required** by Pod Supervisor (2.1) for graceful shutdown. It now:
1. Logs cancelled operations as events for audit trail
2. Properly waits for in-progress operations with timeout
3. Forcefully kills stuck operations after timeout

## Sync Triggers

### Automatic Sync Triggers

```elixir
defp evaluate_sync_triggers(new_state, _sync_state) do
  operations = []

  # GitHub PR creation
  operations = if new_state.phase == :development and
                  new_state.external_sync.github.pr_number == nil do
    [%SyncOperation{
      operation_id: UUID.uuid4(),
      operation: :create_github_pr,
      task_id: new_state.task_id,
      requires_approval?: false,
      requested_at: System.system_time(:second)
    } | operations]
  else
    operations
  end

  # JIRA ticket creation
  operations = if new_state.external_sync.jira.ticket_id == nil do
    [%SyncOperation{
      operation_id: UUID.uuid4(),
      operation: :create_jira_ticket,
      task_id: new_state.task_id,
      requires_approval?: false,
      requested_at: System.system_time(:second)
    } | operations]
  else
    operations
  end

  # JIRA status update on phase change
  operations = if phase_changed?(new_state) do
    [%SyncOperation{
      operation_id: UUID.uuid4(),
      operation: :update_jira_status,
      task_id: new_state.task_id,
      params: %{status: phase_to_jira_status(new_state.phase)},
      requires_approval?: false,
      requested_at: System.system_time(:second)
    } | operations]
  else
    operations
  end

  # GitHub PR merge on completion
  operations = if new_state.phase == :completed and
                  new_state.external_sync.github.pr_number != nil and
                  not new_state.external_sync.github.pr_merged? do
    [%SyncOperation{
      operation_id: UUID.uuid4(),
      operation: :merge_github_pr,
      task_id: new_state.task_id,
      requires_approval?: true,
      requested_at: System.system_time(:second)
    } | operations]
  else
    operations
  end

  operations
end
```

## Error Handling

### Common Errors

**GitHub API Errors**:
```elixir
{:error, {:github_api_error, "Repository not found"}}
{:error, {:github_rate_limited, retry_after_seconds}}
{:error, {:github_auth_failed, "Invalid token"}}
```

**JIRA API Errors**:
```elixir
{:error, {:jira_api_error, status_code, error_message}}
{:error, {:jira_connection_error, reason}}
{:error, {:jira_auth_failed, "Invalid credentials"}}
```

### Retry Strategy

```elixir
defp execute_with_retry(operation, max_retries \\ 3) do
  Enum.reduce_while(1..max_retries, {:error, :no_attempts}, fn attempt, _acc ->
    case execute_operation(operation) do
      {:ok, result} ->
        {:halt, {:ok, result}}

      {:error, {:github_rate_limited, retry_after}} ->
        Logger.warning("GitHub rate limited, waiting #{retry_after} seconds...")
        :timer.sleep(retry_after * 1000)
        {:cont, {:error, :rate_limited}}

      {:error, reason} when attempt < max_retries ->
        Logger.warning("Sync operation failed (attempt #{attempt}/#{max_retries}): #{inspect(reason)}")
        # Exponential backoff
        :timer.sleep(:math.pow(2, attempt) * 1000)
        {:cont, {:error, reason}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end)
end
```

## Rate Limiting

### GitHub Rate Limiting

```elixir
defmodule Ipa.Pod.ExternalSync.GitHubConnector do
  use GenServer

  defstruct [
    :rate_limit_remaining,
    :rate_limit_reset_at
  ]

  def execute_request(connector, request_fn) do
    if connector.rate_limit_remaining <= 10 do
      # Close to rate limit, wait until reset
      now = System.system_time(:second)
      wait_seconds = max(0, connector.rate_limit_reset_at - now)

      if wait_seconds > 0 do
        Logger.warning("GitHub rate limit low, waiting #{wait_seconds} seconds...")
        :timer.sleep(wait_seconds * 1000)
      end
    end

    # Execute request
    case request_fn.() do
      {:ok, response} ->
        # Update rate limit info from response headers
        new_connector = update_rate_limit(connector, response.headers)
        {:ok, response, new_connector}

      error ->
        error
    end
  end
end
```

## Configuration

```elixir
# config/config.exs
config :ipa, Ipa.Pod.ExternalSync,
  # Poll interval in milliseconds (conservative to respect rate limits)
  poll_interval: 300_000,  # 5 minutes (default)
  min_poll_interval: 60_000,   # 1 minute (fastest when rate limits are high)
  max_poll_interval: 1_800_000, # 30 minutes (slowest when rate limits are low)

  # Adaptive polling adjusts interval based on rate limits
  adaptive_polling: true,

  # Retry configuration
  max_retries: 3,
  retry_backoff_base: 2,  # Exponential backoff base (seconds)

  # Sync queue configuration
  max_queue_size: 100,  # Maximum pending operations
  deduplication_window_seconds: 600,  # 10 minutes

  # Approval gates
  approval_required: [:close_github_pr, :merge_github_pr, :delete_jira_ticket],

  # GitHub configuration
  github_enabled: true,
  github_token: {:system, "GITHUB_TOKEN"},
  github_default_base_branch: "main",

  # JIRA configuration
  jira_enabled: true,
  jira_base_url: {:system, "JIRA_BASE_URL"},
  jira_username: {:system, "JIRA_USERNAME"},
  jira_api_token: {:system, "JIRA_API_TOKEN"},
  jira_project_key: {:system, "JIRA_PROJECT_KEY"}

# config/test.exs
config :ipa, Ipa.Pod.ExternalSync,
  poll_interval: 1_000,  # Poll more frequently in tests
  min_poll_interval: 500,
  max_poll_interval: 5_000,
  adaptive_polling: false,  # Disable adaptive polling in tests
  github_enabled: false,  # Disable external APIs in tests
  jira_enabled: false
```

## Testing Requirements

### Unit Tests

1. **Sync Queue**
   - Add operation to queue
   - Deduplicate operations
   - Process queue in order
   - Handle approval gates
   - Cancel pending operations

2. **Sync Triggers**
   - Phase change triggers JIRA update
   - Development phase triggers PR creation
   - Completion triggers PR merge request
   - No duplicate triggers

3. **Connector Mocks**
   - Mock GitHub API responses
   - Mock JIRA API responses
   - Test error handling
   - Test rate limiting

### Integration Tests

1. **State Change Reaction**
   - State Manager broadcasts change
   - External Sync receives and evaluates
   - Appropriate operations queued
   - Operations executed in correct order

2. **Approval Gates**
   - Operation added with approval required
   - User approves operation
   - Operation executes after approval
   - User rejects operation
   - Operation removed from queue

3. **Error Recovery**
   - API failure triggers retry
   - Rate limit triggers backoff
   - Auth failure logged and operation fails
   - Max retries reached, operation marked failed

### End-to-End Tests (Optional)

1. **GitHub Integration** (requires sandbox repo)
   - Create PR via IPA
   - Verify PR exists in GitHub
   - Poll detects external PR comment
   - Event appended to Event Store

2. **JIRA Integration** (requires test instance)
   - Create ticket via IPA
   - Verify ticket exists in JIRA
   - Update ticket status
   - Verify status reflected in JIRA

## Acceptance Criteria

- [ ] External Sync starts and subscribes to state changes
- [ ] GitHub PR created when task enters development
- [ ] JIRA ticket created when task is created
- [ ] JIRA status updated on phase transitions
- [ ] Polling detects external changes
- [ ] Approval gates enforce human approval for sensitive operations
- [ ] Rate limiting prevents API abuse
- [ ] Retries handle transient failures
- [ ] Graceful shutdown cancels pending operations
- [ ] All unit tests pass
- [ ] Integration tests with State Manager work
- [ ] Configuration supports multiple environments

## Future Enhancements

### Phase 1 (Minimum Viable)
- Basic GitHub PR creation
- Basic JIRA ticket creation and status updates
- Manual approval gates
- Simple retry logic

### Phase 2 (Polish)
- Automatic PR updates (push commits)
- GitHub PR comment polling
- JIRA comment sync
- Smart rate limiting

### Phase 3 (Advanced)
- Bidirectional sync (external changes trigger IPA actions)
- Multiple GitHub repos per task
- Custom JIRA field mapping
- Slack notifications for approvals
- Webhook support (replace polling)

## Notes

- **Authentication**: Use environment variables for API tokens (never commit secrets)
- **Rate Limits**: GitHub has strict rate limits (5000 requests/hour for authenticated users)
- **Polling vs Webhooks**: Start with polling for simplicity. Webhooks require public endpoint and webhook secret management.
- **Approval UX**: LiveView should show pending approvals prominently
- **Error Visibility**: Failed sync operations should be visible in UI
- **Idempotency**: All sync operations should be idempotent (safe to retry)
