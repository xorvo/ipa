# Component 2.2: Pod State Manager - Architecture Refactor Plan

**Created**: 2025-11-06
**Status**: Refactor Required
**Effort**: +1 week (from 1.5 weeks to 2.5 weeks total)

## Overview

The Pod State Manager spec is currently approved and comprehensive (1434 lines). However, the architecture refactor requires adding workstream and message management capabilities. This document outlines the required changes.

## Required Changes

### 1. State Schema Updates

**Add to state schema** (around line 322-397):

```elixir
%{
  # ... existing fields (task_id, version, created_at, updated_at, phase, title, spec, plan, agents, external_sync, pending_transitions) ...

  # NEW: Workstreams (parallel work execution)
  workstreams: %{
    "ws-1" => %{
      workstream_id: String.t(),          # Workstream UUID
      spec: String.t(),                   # Workstream specification
      status: atom(),                     # :pending | :in_progress | :blocked | :completed | :failed
      agent_id: String.t() | nil,         # Assigned agent UUID
      dependencies: [String.t()],         # List of workstream IDs that must complete first
      blocking_on: [String.t()],          # Subset of dependencies not yet complete
      workspace: String.t() | nil,        # Workspace path
      started_at: integer() | nil,
      completed_at: integer() | nil,
      result: map() | nil,
      error: String.t() | nil
    }
  },

  # NEW: Concurrency control
  max_workstream_concurrency: integer(),  # Default: 3
  active_workstream_count: integer(),     # Number of workstreams currently in_progress

  # NEW: Communications (human-agent and agent-agent coordination)
  messages: [
    %{
      message_id: String.t(),             # Message UUID
      type: atom(),                       # :question | :approval | :update | :blocker
      content: String.t(),
      author: String.t(),                 # "agent-123" or "user-456"
      thread_id: String.t() | nil,        # Parent message ID for threading
      workstream_id: String.t() | nil,    # Associated workstream
      posted_at: integer(),
      read_by: [String.t()],              # List of user IDs who have read this message

      # Approval-specific fields (nil for non-approval messages)
      approval_options: [String.t()] | nil,      # Choices for approval
      approval_choice: String.t() | nil,         # Selected choice
      approval_given_by: String.t() | nil,       # Who approved
      approval_given_at: integer() | nil,        # When approved
      blocking?: boolean() | nil                 # Whether agent is blocked waiting
    }
  ],

  # NEW: Inbox/Notifications
  inbox: [
    %{
      notification_id: String.t(),        # Notification UUID
      recipient: String.t(),              # "agent-123" or "user-456"
      message_id: String.t(),             # Reference to message
      type: atom(),                       # :needs_approval | :question_asked | :workstream_completed
      message_preview: String.t(),        # First 100 chars of message content (for UI)
      read?: boolean(),
      created_at: integer()
    }
  ]
}
```

### 2. New API Functions

**Add these functions to the public API** (around line 144):

```elixir
# Workstream queries
@spec get_workstream(task_id :: String.t(), workstream_id :: String.t()) ::
  {:ok, workstream :: map()} | {:error, :not_found}

@spec list_workstreams(task_id :: String.t()) ::
  {:ok, workstreams :: map()}

@spec get_active_workstreams(task_id :: String.t()) ::
  {:ok, active_workstreams :: [map()]}

# Message queries
@spec get_messages(task_id :: String.t(), opts :: keyword()) ::
  {:ok, messages :: [map()]}
  # opts: [thread_id: string, workstream_id: string, type: atom]

@spec get_inbox(task_id :: String.t(), opts :: keyword()) ::
  {:ok, inbox :: [map()]}
  # opts: [unread_only?: boolean, recipient: string]
```

**API Function Implementations** (around line 200):

```elixir
# get_workstream/2 implementation
def get_workstream(task_id, workstream_id) do
  GenServer.call(via_tuple(task_id), {:get_workstream, workstream_id})
end

# GenServer handler
def handle_call({:get_workstream, workstream_id}, _from, state) do
  case Map.get(state.current_state.workstreams, workstream_id) do
    nil -> {:reply, {:error, :not_found}, state}
    workstream -> {:reply, {:ok, workstream}, state}
  end
end

# list_workstreams/1 implementation
def list_workstreams(task_id) do
  GenServer.call(via_tuple(task_id), :list_workstreams)
end

def handle_call(:list_workstreams, _from, state) do
  {:reply, {:ok, state.current_state.workstreams}, state}
end

# get_active_workstreams/1 implementation
def get_active_workstreams(task_id) do
  GenServer.call(via_tuple(task_id), :get_active_workstreams)
end

def handle_call(:get_active_workstreams, _from, state) do
  active = state.current_state.workstreams
    |> Map.values()
    |> Enum.filter(fn ws -> ws.status == :in_progress end)

  {:reply, {:ok, active}, state}
end

# get_messages/2 implementation
def get_messages(task_id, opts \\ []) do
  GenServer.call(via_tuple(task_id), {:get_messages, opts})
end

def handle_call({:get_messages, opts}, _from, state) do
  messages = state.current_state.messages
    |> maybe_filter_by_thread_id(opts[:thread_id])
    |> maybe_filter_by_workstream_id(opts[:workstream_id])
    |> maybe_filter_by_type(opts[:type])
    |> maybe_limit(opts[:limit])
    |> Enum.sort_by(& &1.posted_at, :desc)

  {:reply, {:ok, messages}, state}
end

defp maybe_filter_by_thread_id(messages, nil), do: messages
defp maybe_filter_by_thread_id(messages, thread_id) do
  # Return root message and all replies
  Enum.filter(messages, fn msg ->
    msg.thread_id == thread_id || msg.message_id == thread_id
  end)
end

defp maybe_filter_by_workstream_id(messages, nil), do: messages
defp maybe_filter_by_workstream_id(messages, workstream_id) do
  Enum.filter(messages, fn msg -> msg.workstream_id == workstream_id end)
end

defp maybe_filter_by_type(messages, nil), do: messages
defp maybe_filter_by_type(messages, type) do
  Enum.filter(messages, fn msg -> msg.type == type end)
end

defp maybe_limit(messages, nil), do: messages
defp maybe_limit(messages, limit) when is_integer(limit) and limit > 0 do
  Enum.take(messages, limit)
end

# get_inbox/2 implementation
def get_inbox(task_id, opts \\ []) do
  GenServer.call(via_tuple(task_id), {:get_inbox, opts})
end

def handle_call({:get_inbox, opts}, _from, state) do
  inbox = state.current_state.inbox
    |> maybe_filter_unread_only(opts[:unread_only?])
    |> maybe_filter_by_recipient(opts[:recipient])
    |> Enum.sort_by(& &1.created_at, :desc)

  {:reply, {:ok, inbox}, state}
end

defp maybe_filter_unread_only(inbox, true), do: Enum.filter(inbox, & !&1.read?)
defp maybe_filter_unread_only(inbox, _), do: inbox

defp maybe_filter_by_recipient(inbox, nil), do: inbox
defp maybe_filter_by_recipient(inbox, recipient) do
  Enum.filter(inbox, fn notif -> notif.recipient == recipient end)
end
```

### 3. New Event Types

**Add event projection logic for these new event types** (around line 428):

#### Workstream Events
- `workstream_created` - Initialize workstream in state
- `workstream_spec_generated` - Update workstream spec
- `workstream_agent_started` - Mark workstream as in_progress, link agent
- `workstream_completed` - Mark as completed, update blocking_on for dependent workstreams
- `workstream_failed` - Mark as failed, record error
- `workstream_blocked` - Mark as blocked, record blocking dependency

#### Communication Events
- `message_posted` - Add message to messages list
- `reply_posted` - Add reply to messages list with thread_id
- `approval_requested` - Add approval message and create notification
- `approval_given` - Update message with approval, clear notification
- `notification_created` - Add notification to inbox
- `notification_read` - Mark notification as read

### 4. Event Validation Updates

**Extend event validation** (around line 900) to include:

```elixir
# Workstream event validation
defp validate_event("workstream_created", %{workstream_id: ws_id, spec: spec, dependencies: deps}, state) do
  # Validate workstream_id is unique
  # Validate dependencies exist
  # Validate max_concurrency not exceeded
end

defp validate_event("workstream_agent_started", %{workstream_id: ws_id, agent_id: agent_id}, state) do
  # Validate workstream exists
  # Validate workstream is pending or blocked (not already in_progress)
  # Validate dependencies are satisfied (blocking_on is empty)
  # Validate agent_id is unique
end

# Communication event validation
defp validate_event("message_posted", %{message_id: msg_id, type: type, content: content, author: author}, state) do
  # Validate message_id is unique
  # Validate type is valid (:question | :approval | :update | :blocker)
  # Validate author exists
  # Validate content is non-empty
end

# ... more validation for other event types
```

### 5. State Projection Logic Updates

**Add projection logic for new events** (around line 428):

```elixir
defp apply_event(%{
  event_type: "workstream_created",
  data: %{workstream_id: ws_id, spec: spec, dependencies: deps},
  version: version,
  inserted_at: timestamp
}, state) do
  new_workstream = %{
    workstream_id: ws_id,
    spec: spec,
    status: :pending,
    agent_id: nil,
    dependencies: deps,
    # FIX P0#2: Defensive nil-checking to prevent crashes
    blocking_on: Enum.filter(deps, fn dep_id ->
      case Map.get(state.workstreams, dep_id) do
        nil -> true  # Dependency not created yet, treat as blocking
        dep -> dep.status != :completed
      end
    end),
    workspace: nil,
    started_at: nil,
    completed_at: nil,
    result: nil,
    error: nil
  }

  %{state |
    workstreams: Map.put(state.workstreams, ws_id, new_workstream),
    version: version,
    updated_at: timestamp
  }
end

defp apply_event(%{
  event_type: "workstream_completed",
  data: %{workstream_id: ws_id, result: result},
  version: version,
  inserted_at: timestamp
}, state) do
  # Update completed workstream
  updated_workstream = state.workstreams[ws_id]
    |> Map.put(:status, :completed)
    |> Map.put(:completed_at, timestamp)
    |> Map.put(:result, result)

  # Update blocking_on for dependent workstreams
  # FIX P0#2: Check blocking_on instead of dependencies
  updated_workstreams =
    state.workstreams
    |> Map.put(ws_id, updated_workstream)
    |> Enum.map(fn {id, ws} ->
      # CRITICAL: Check if ws_id is in blocking_on, not dependencies
      if ws_id in ws.blocking_on do
        {id, %{ws | blocking_on: List.delete(ws.blocking_on, ws_id)}}
      else
        {id, ws}
      end
    end)
    |> Map.new()

  %{state |
    workstreams: updated_workstreams,
    active_workstream_count: max(0, state.active_workstream_count - 1),  # Safety check
    version: version,
    updated_at: timestamp
  }
end

# Workstream agent started projection
defp apply_event(%{
  event_type: "workstream_agent_started",
  data: %{workstream_id: ws_id, agent_id: agent_id, workspace: workspace},
  version: version,
  inserted_at: timestamp
}, state) do
  # Update workstream status
  updated_workstream = state.workstreams[ws_id]
    |> Map.put(:status, :in_progress)
    |> Map.put(:agent_id, agent_id)
    |> Map.put(:workspace, workspace)
    |> Map.put(:started_at, timestamp)

  # Also add agent to agents list with workstream_id
  new_agent = %{
    agent_id: agent_id,
    phase: :workstream_execution,
    workstream_id: ws_id,           # CRITICAL: Track workstream for UI grouping
    status: :running,
    started_at: timestamp,
    completed_at: nil,
    result: nil,
    error: nil
  }

  %{state |
    workstreams: Map.put(state.workstreams, ws_id, updated_workstream),
    agents: [new_agent | state.agents],
    active_workstream_count: state.active_workstream_count + 1,  # INCREMENT count
    version: version,
    updated_at: timestamp
  }
end

# Workstream failed projection
defp apply_event(%{
  event_type: "workstream_failed",
  data: %{workstream_id: ws_id, agent_id: agent_id, error: error},
  version: version,
  inserted_at: timestamp
}, state) do
  updated_workstream = state.workstreams[ws_id]
    |> Map.put(:status, :failed)
    |> Map.put(:completed_at, timestamp)
    |> Map.put(:error, error)

  %{state |
    workstreams: Map.put(state.workstreams, ws_id, updated_workstream),
    active_workstream_count: max(0, state.active_workstream_count - 1),  # DECREMENT with safety check
    version: version,
    updated_at: timestamp
  }
end

# Workstream spec generated projection
defp apply_event(%{
  event_type: "workstream_spec_generated",
  data: %{workstream_id: ws_id, spec: spec},
  version: version,
  inserted_at: timestamp
}, state) do
  updated_workstream = Map.update!(state.workstreams, ws_id, fn ws ->
    %{ws | spec: spec}
  end)

  %{state |
    workstreams: updated_workstream,
    version: version,
    updated_at: timestamp
  }
end

# Workstream blocked projection
defp apply_event(%{
  event_type: "workstream_blocked",
  data: %{workstream_id: ws_id, blocked_by: dep_ids},
  version: version,
  inserted_at: timestamp
}, state) do
  updated_workstream = Map.update!(state.workstreams, ws_id, fn ws ->
    %{ws |
      status: :blocked,
      blocking_on: dep_ids
    }
  end)

  %{state |
    workstreams: updated_workstream,
    version: version,
    updated_at: timestamp
  }
end

# Message posted projection
defp apply_event(%{
  event_type: "message_posted",
  data: %{message_id: msg_id, type: type, content: content, author: author, thread_id: thread_id, workstream_id: ws_id},
  version: version,
  inserted_at: timestamp
}, state) do
  new_message = %{
    message_id: msg_id,
    type: type,
    content: content,
    author: author,
    thread_id: thread_id,
    workstream_id: ws_id,
    posted_at: timestamp,
    read_by: [],
    # Approval-specific fields (nil for non-approval messages)
    approval_options: nil,
    approval_choice: nil,
    approval_given_by: nil,
    approval_given_at: nil,
    blocking?: nil
  }

  %{state |
    messages: [new_message | state.messages],
    version: version,
    updated_at: timestamp
  }
end

# Approval requested projection
defp apply_event(%{
  event_type: "approval_requested",
  data: %{message_id: msg_id, question: question, options: options, author: author, workstream_id: ws_id, blocking?: blocking},
  version: version,
  inserted_at: timestamp
}, state) do
  # Create approval message
  new_message = %{
    message_id: msg_id,
    type: :approval,
    content: question,
    author: author,
    thread_id: nil,
    workstream_id: ws_id,
    posted_at: timestamp,
    read_by: [],
    # Approval-specific fields
    approval_options: options,
    approval_choice: nil,
    approval_given_by: nil,
    approval_given_at: nil,
    blocking?: blocking
  }

  %{state |
    messages: [new_message | state.messages],
    version: version,
    updated_at: timestamp
  }
end

# Approval given projection
defp apply_event(%{
  event_type: "approval_given",
  data: %{message_id: msg_id, approved_by: user_id, choice: choice, comment: _comment},
  version: version,
  inserted_at: timestamp
}, state) do
  # Update approval message
  updated_messages = Enum.map(state.messages, fn msg ->
    if msg.message_id == msg_id do
      %{msg |
        approval_choice: choice,
        approval_given_by: user_id,
        approval_given_at: timestamp
      }
    else
      msg
    end
  end)

  # Remove notification from inbox
  updated_inbox = Enum.reject(state.inbox, fn notif ->
    notif.message_id == msg_id && notif.type == :needs_approval
  end)

  %{state |
    messages: updated_messages,
    inbox: updated_inbox,
    version: version,
    updated_at: timestamp
  }
end

# Notification created projection
defp apply_event(%{
  event_type: "notification_created",
  data: %{notification_id: notif_id, recipient: recipient, message_id: msg_id, type: type, message_preview: preview},
  version: version,
  inserted_at: timestamp
}, state) do
  new_notification = %{
    notification_id: notif_id,
    recipient: recipient,
    message_id: msg_id,
    type: type,
    message_preview: preview,  # Include preview for UI
    read?: false,
    created_at: timestamp
  }

  %{state |
    inbox: [new_notification | state.inbox],
    version: version,
    updated_at: timestamp
  }
end

# Notification read projection
defp apply_event(%{
  event_type: "notification_read",
  data: %{notification_id: notif_id, read_by: _user_id},
  version: version,
  inserted_at: timestamp
}, state) do
  updated_inbox = Enum.map(state.inbox, fn notif ->
    if notif.notification_id == notif_id do
      %{notif | read?: true}
    else
      notif
    end
  end)

  %{state |
    inbox: updated_inbox,
    version: version,
    updated_at: timestamp
  }
end

# Notification cleared projection (for when approval is given or notification dismissed)
defp apply_event(%{
  event_type: "notification_cleared",
  data: %{notification_id: notif_id},
  version: version,
  inserted_at: timestamp
}, state) do
  updated_inbox = Enum.reject(state.inbox, fn notif ->
    notif.notification_id == notif_id
  end)

  %{state |
    inbox: updated_inbox,
    version: version,
    updated_at: timestamp
  }
end
```

### 6. Initial State Updates

**Update initial state** (around line 400) to include:

```elixir
%{
  # ... existing initial state ...
  workstreams: %{},
  max_workstream_concurrency: 3,
  active_workstream_count: 0,
  messages: [],
  inbox: []
}
```

## Testing Updates

### New Unit Tests Required

1. **Workstream State Projection Tests**:
   - Test workstream_created adds workstream to state
   - Test workstream_agent_started updates status and agent_id
   - Test workstream_completed updates status and unblocks dependent workstreams
   - Test workstream_failed records error
   - Test dependency resolution (blocking_on logic)

2. **Message State Projection Tests**:
   - Test message_posted adds message to messages list
   - Test reply_posted with thread_id
   - Test approval_requested creates notification
   - Test approval_given clears notification
   - Test notification_read updates inbox

3. **Concurrency Control Tests**:
   - Test max_workstream_concurrency enforcement
   - Test active_workstream_count tracking

4. **Query Function Tests**:
   - Test get_workstream/2
   - Test list_workstreams/1
   - Test get_messages/2 with filtering
   - Test get_inbox/2 with unread_only

### Integration Tests

1. Test full workstream lifecycle (create → start → complete)
2. Test dependent workstream unblocking
3. Test message thread creation and replies
4. Test approval workflow with inbox notifications

## Migration Notes

**IMPORTANT**: This is a breaking change to the state schema. Existing tasks will need migration:

1. Add empty workstreams map to existing task states
2. Add concurrency fields (max_workstream_concurrency, active_workstream_count)
3. Add empty messages and inbox lists

Migration can be done via:
- Schema versioning in state
- Migration script that reads all task streams and adds new fields
- Default values in state projection logic

## Implementation Checklist

- [ ] Update State Schema documentation
- [ ] Add new API functions (get_workstream, get_messages, get_inbox)
- [ ] Add event projection logic for workstream events
- [ ] Add event projection logic for communication events
- [ ] Update event validation for new event types
- [ ] Update initial state
- [ ] Write unit tests for workstream projections
- [ ] Write unit tests for message projections
- [ ] Write integration tests
- [ ] Update tracker.md with refactor progress
- [ ] Get spec review from architecture-strategist

## Estimated Effort

**Original**: 1.5 weeks
**Additional**: 1 week (workstream/message projections)
**Total**: 2.5 weeks

## Dependencies

This component blocks:
- 2.3 Pod Scheduler (needs workstream queries)
- 2.6 Pod LiveView UI (needs message queries)
- 2.7 Communications Manager (needs message state)
- 2.8 CLAUDE.md Templates (needs workstream state)

## Notes

- The core architecture (GenServer, event sourcing, pub-sub) remains the same
- Only adding new state fields and projection logic
- No breaking changes to existing API functions
- Backward compatible: old events still work, new fields have defaults
