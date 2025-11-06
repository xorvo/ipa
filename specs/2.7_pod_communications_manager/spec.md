# Component Spec: 2.7 Pod Communications Manager

**Status**: Spec Complete (Ready for Review)
**Dependencies**: 1.1 (Event Store), 2.1 (Pod Supervisor), 2.2 (Pod State Manager)
**Estimated Effort**: 2.5 weeks

## Overview

The Pod Communications Manager provides a structured communication system for human-agent and agent-agent coordination within a pod. It enables threaded conversations, typed messages, inbox/notification management, and human approval workflows - essential for multi-agent collaboration.

## Purpose

- Enable agents to ask questions and request clarification
- Facilitate human approval workflows for critical decisions
- Allow agents to post progress updates
- Signal blockers that need attention
- Organize conversations in threads (like Slack)
- Maintain an inbox of notifications for humans and agents
- Provide real-time message visibility via LiveView

## Dependencies

- **External**: Phoenix.PubSub, Elixir GenServer
- **Internal**: Ipa.Pod.State (for event append and state queries), Ipa.EventStore
- **Used By**: Ipa.Pod.Scheduler, Agents (via SDK), IpaWeb.Pod.TaskLive

## Module Structure

```
lib/ipa/pod/
  └── communications_manager.ex    # Main GenServer for message management
```

## Core Concepts

### Message Types

**1. Question** (`:question`)
- Agent asks for clarification or guidance
- Non-blocking (agent can continue working)
- Creates notification for humans

**2. Approval** (`:approval`)
- Agent requests human approval to proceed
- **Blocking** (agent should pause until approved)
- Creates high-priority notification
- Includes options for human to choose from

**3. Update** (`:update`)
- Agent posts progress update
- Non-blocking
- Informational only

**4. Blocker** (`:blocker`)
- Agent signals critical issue needing immediate attention
- Creates urgent notification
- May block workstream progress

### Threading Model

Messages can be organized in threads:
- **Root message**: Top-level message (thread_id = nil)
- **Reply**: Message with thread_id pointing to parent message
- Threads keep conversations organized
- All messages in a thread are related to the same topic

### Inbox/Notifications

- **Inbox**: List of notifications for a recipient
- **Notification**: Pointer to a message that needs attention
- **Read tracking**: Notifications can be marked as read
- **Types**: `:needs_approval`, `:question_asked`, `:blocker_raised`, `:workstream_completed`

### Approval Workflow

1. Agent calls `request_approval/2` with question and options
2. System creates approval message
3. System creates notification for human
4. Human sees notification in inbox (via LiveView)
5. Human reviews question and selects option
6. System appends `approval_given` event
7. Notification cleared from inbox
8. Agent receives approval via state subscription or polling

## API Specification

### Public Functions

#### `post_message/2`

```elixir
@spec post_message(
  task_id :: String.t(),
  opts :: keyword()
) :: {:ok, message_id :: String.t()} | {:error, term()}
```

Posts a new message to the pod communications.

**Parameters**:
- `task_id` - Task UUID
- `opts`:
  - `type` (required) - Message type (`:question | :update | :blocker`)
  - `content` (required) - Message content (string)
  - `author` (required) - Author ID ("agent-123" or "user-456")
  - `thread_id` (optional) - Parent message ID for replies
  - `workstream_id` (optional) - Associated workstream

**Returns**:
- `{:ok, message_id}` - Message successfully posted
- `{:error, :invalid_type}` - Invalid message type
- `{:error, :empty_content}` - Content is empty
- `{:error, :thread_not_found}` - Thread ID doesn't exist

**Example**:
```elixir
{:ok, msg_id} = Ipa.Pod.CommunicationsManager.post_message(
  task_id,
  type: :question,
  content: "Should we use PostgreSQL or SQLite for this feature?",
  author: "agent-dev-1",
  workstream_id: "ws-2"
)
```

**Behavior**:
1. Validates message type and content
2. Generates message UUID
3. Appends `message_posted` event to Pod State
4. Creates notification if needed (questions, blockers)
5. Broadcasts message via pub-sub
6. Returns message ID

#### `request_approval/2`

```elixir
@spec request_approval(
  task_id :: String.t(),
  opts :: keyword()
) :: {:ok, message_id :: String.t()} | {:error, term()}
```

Requests human approval with specific options.

**Parameters**:
- `task_id` - Task UUID
- `opts`:
  - `question` (required) - Approval question (string)
  - `options` (required) - List of options for human to choose (list of strings)
  - `author` (required) - Author ID (usually agent)
  - `workstream_id` (optional) - Associated workstream
  - `blocking?` (optional) - Whether agent is blocked waiting (default: true)

**Returns**:
- `{:ok, message_id}` - Approval request created
- `{:error, :invalid_options}` - Options list is empty or invalid
- `{:error, :empty_question}` - Question is empty

**Example**:
```elixir
{:ok, msg_id} = Ipa.Pod.CommunicationsManager.request_approval(
  task_id,
  question: "Ready to merge PR #123 to main?",
  options: ["Yes, merge it", "No, needs changes", "Need to review first"],
  author: "agent-dev-1",
  workstream_id: "ws-1",
  blocking?: true
)
```

**Behavior**:
1. Validates question and options
2. Generates message UUID
3. Appends `approval_requested` event
4. Creates high-priority notification with `:needs_approval` type
5. Broadcasts message via pub-sub
6. Returns message ID

**Note**: Agent should poll or subscribe to state to detect when approval is given.

#### `give_approval/3`

```elixir
@spec give_approval(
  task_id :: String.t(),
  message_id :: String.t(),
  opts :: keyword()
) :: {:ok, approval_id :: String.t()} | {:error, term()}
```

Provides approval for a pending approval request.

**Parameters**:
- `task_id` - Task UUID
- `message_id` - Approval request message ID
- `opts`:
  - `approved_by` (required) - User ID providing approval
  - `choice` (required) - Selected option from the original options list
  - `comment` (optional) - Additional comment/explanation

**Returns**:
- `{:ok, approval_id}` - Approval recorded
- `{:error, :message_not_found}` - Message doesn't exist
- `{:error, :not_approval_request}` - Message is not an approval request
- `{:error, :invalid_choice}` - Choice not in original options
- `{:error, :already_approved}` - Approval already given

**Example**:
```elixir
{:ok, approval_id} = Ipa.Pod.CommunicationsManager.give_approval(
  task_id,
  msg_id,
  approved_by: "user-456",
  choice: "Yes, merge it",
  comment: "Looks good to me!"
)
```

**Behavior**:
1. Validates message exists and is an approval request
2. Validates choice is one of the original options
3. Appends `approval_given` event
4. Clears notification from inbox
5. Broadcasts approval via pub-sub
6. Returns approval ID

#### `mark_read/2`

```elixir
@spec mark_read(
  task_id :: String.t(),
  notification_id :: String.t()
) :: :ok | {:error, term()}
```

Marks a notification as read.

**Parameters**:
- `task_id` - Task UUID
- `notification_id` - Notification UUID

**Returns**:
- `:ok` - Notification marked as read
- `{:error, :notification_not_found}` - Notification doesn't exist

**Example**:
```elixir
:ok = Ipa.Pod.CommunicationsManager.mark_read(task_id, notification_id)
```

**Behavior**:
1. Appends `notification_read` event
2. Updates notification in state
3. Broadcasts state change

#### `get_inbox/2`

```elixir
@spec get_inbox(
  task_id :: String.t(),
  opts :: keyword()
) :: {:ok, notifications :: [map()]} | {:error, term()}
```

Retrieves inbox notifications.

**Parameters**:
- `task_id` - Task UUID
- `opts`:
  - `unread_only?` (optional) - Only return unread notifications (default: false)
  - `recipient` (optional) - Filter by recipient ("user-456" or "agent-123")

**Returns**:
- `{:ok, notifications}` - List of notification maps
- `{:error, :task_not_found}` - Task doesn't exist

**Example**:
```elixir
{:ok, inbox} = Ipa.Pod.CommunicationsManager.get_inbox(
  task_id,
  unread_only?: true,
  recipient: "user-456"
)

# Returns:
# [
#   %{
#     notification_id: "notif-1",
#     recipient: "user-456",
#     message_id: "msg-5",
#     type: :needs_approval,
#     read?: false,
#     created_at: ~U[2025-11-06 10:00:00Z]
#   }
# ]
```

**Behavior**:
- Queries Pod State for inbox
- Filters by unread_only and recipient if specified
- Returns sorted by created_at (most recent first)

#### `get_thread/2`

```elixir
@spec get_thread(
  task_id :: String.t(),
  thread_id :: String.t()
) :: {:ok, messages :: [map()]} | {:error, term()}
```

Retrieves all messages in a thread.

**Parameters**:
- `task_id` - Task UUID
- `thread_id` - Root message ID

**Returns**:
- `{:ok, messages}` - List of messages in thread (sorted chronologically)
- `{:error, :thread_not_found}` - Thread doesn't exist

**Example**:
```elixir
{:ok, thread} = Ipa.Pod.CommunicationsManager.get_thread(task_id, root_msg_id)

# Returns:
# [
#   %{message_id: "msg-1", content: "Should we...", thread_id: nil, ...},
#   %{message_id: "msg-2", content: "I think...", thread_id: "msg-1", ...},
#   %{message_id: "msg-3", content: "Agreed...", thread_id: "msg-1", ...}
# ]
```

**Behavior**:
- Queries Pod State for all messages
- Filters messages where thread_id == given thread_id OR message_id == thread_id (root)
- Returns sorted by posted_at

#### `get_messages/2`

```elixir
@spec get_messages(
  task_id :: String.t(),
  opts :: keyword()
) :: {:ok, messages :: [map()]} | {:error, term()}
```

Retrieves messages with optional filtering.

**Parameters**:
- `task_id` - Task UUID
- `opts`:
  - `type` (optional) - Filter by message type
  - `workstream_id` (optional) - Filter by workstream
  - `author` (optional) - Filter by author
  - `limit` (optional) - Limit number of results (default: 50)

**Returns**:
- `{:ok, messages}` - List of message maps
- `{:error, :task_not_found}` - Task doesn't exist

**Example**:
```elixir
{:ok, questions} = Ipa.Pod.CommunicationsManager.get_messages(
  task_id,
  type: :question,
  workstream_id: "ws-1",
  limit: 10
)
```

**Behavior**:
- Queries Pod State for messages
- Applies filters
- Returns sorted by posted_at (most recent first)

#### `subscribe/1`

```elixir
@spec subscribe(task_id :: String.t()) :: :ok
```

Subscribes to message notifications.

**Pub-Sub Topic**: `"pod:#{task_id}:communications"`

**Messages Received**:
```elixir
{:message_posted, task_id, message}
{:approval_requested, task_id, message}
{:approval_given, task_id, message_id, approval}
{:notification_created, task_id, notification}
```

**Example**:
```elixir
def init(task_id) do
  Ipa.Pod.CommunicationsManager.subscribe(task_id)
  {:ok, %{task_id: task_id}}
end

def handle_info({:message_posted, task_id, message}, state) do
  # Update UI with new message
  {:noreply, state}
end
```

## Message Model

### Message Structure

```elixir
%{
  message_id: String.t(),        # UUID
  type: atom(),                  # :question | :approval | :update | :blocker
  content: String.t(),           # Message content
  author: String.t(),            # "agent-123" or "user-456"
  thread_id: String.t() | nil,   # Parent message ID (nil for root messages)
  workstream_id: String.t() | nil,  # Associated workstream
  posted_at: DateTime.t(),
  read_by: [String.t()],         # List of user IDs who have read this

  # For approval messages only
  approval_options: [String.t()] | nil,
  approval_choice: String.t() | nil,
  approval_given_by: String.t() | nil,
  approval_given_at: DateTime.t() | nil,
  approved?: boolean()
}
```

### Notification Structure

```elixir
%{
  notification_id: String.t(),   # UUID
  recipient: String.t(),         # "agent-123" or "user-456"
  message_id: String.t(),        # Reference to message
  type: atom(),                  # :needs_approval | :question_asked | :blocker_raised | :workstream_completed
  read?: boolean(),
  created_at: DateTime.t()
}
```

## Event Schema

### Events Emitted

All events are appended to Pod State via `Ipa.Pod.State.append_event/3`.

#### `message_posted`

```elixir
%{
  message_id: String.t(),
  type: atom(),                  # :question | :update | :blocker
  content: String.t(),
  author: String.t(),
  thread_id: String.t() | nil,
  workstream_id: String.t() | nil
}
```

#### `approval_requested`

```elixir
%{
  message_id: String.t(),
  question: String.t(),
  options: [String.t()],
  author: String.t(),
  workstream_id: String.t() | nil,
  blocking?: boolean()
}
```

#### `approval_given`

```elixir
%{
  message_id: String.t(),          # Original approval request message
  approved_by: String.t(),
  choice: String.t(),
  comment: String.t() | nil
}
```

#### `notification_created`

```elixir
%{
  notification_id: String.t(),
  recipient: String.t(),
  message_id: String.t(),
  type: atom()
}
```

#### `notification_read`

```elixir
%{
  notification_id: String.t(),
  read_by: String.t()
}
```

## Implementation Details

### GenServer State

The Communications Manager is a GenServer registered per pod:

```elixir
defmodule Ipa.Pod.CommunicationsManager do
  use GenServer

  # FIX P0#5: Cache messages in GenServer state to avoid circular queries
  defstruct [
    :task_id,
    messages: %{},  # message_id => message (cached from Pod State)
    inbox: []        # notifications (cached from Pod State)
  ]

  # Started by Pod Supervisor
  def start_link(task_id) do
    GenServer.start_link(__MODULE__, task_id, name: via_tuple(task_id))
  end

  defp via_tuple(task_id) do
    {:via, Registry, {Ipa.PodRegistry, {:communications, task_id}}}
  end

  @impl true
  def init(task_id) do
    # Subscribe to pod state changes (to react to approvals, etc.)
    Ipa.Pod.State.subscribe(task_id)

    # FIX P0#5: Load initial messages from state to cache them locally
    {:ok, pod_state} = Ipa.Pod.State.get_state(task_id)
    messages = Map.new(pod_state.messages || [], fn msg -> {msg.message_id, msg} end)
    inbox = pod_state.inbox || []

    {:ok, %__MODULE__{task_id: task_id, messages: messages, inbox: inbox}}
  end

  # FIX P0#5: Handle state updates to keep message cache fresh
  @impl true
  def handle_info({:state_updated, _task_id, new_state}, state) do
    # Update cached messages when state changes
    messages = Map.new(new_state.messages || [], fn msg -> {msg.message_id, msg} end)
    inbox = new_state.inbox || []
    {:noreply, %{state | messages: messages, inbox: inbox}}
  end

  # Public API calls GenServer
  def post_message(task_id, opts) do
    GenServer.call(via_tuple(task_id), {:post_message, opts})
  end

  @impl true
  def handle_call({:post_message, opts}, _from, state) do
    with :ok <- validate_message(opts, state),
         message_id <- generate_message_id(),
         {:ok, _version} <- append_message_event(state.task_id, message_id, opts),
         :ok <- maybe_create_notification(state.task_id, message_id, opts),
         :ok <- broadcast_message(state.task_id, message_id, opts) do
      {:reply, {:ok, message_id}, state}
    else
      error -> {:reply, error, state}
    end
  end

  # FIX P0#2, P0#6: Complete give_approval handler with version checking and validation
  def give_approval(task_id, message_id, opts) do
    GenServer.call(via_tuple(task_id), {:give_approval, message_id, opts})
  end

  @impl true
  def handle_call({:give_approval, message_id, opts}, _from, state) do
    # FIX P0#2: Get current state with version for optimistic concurrency
    {:ok, current_state} = Ipa.Pod.State.get_state(state.task_id)

    # FIX P0#6: Validate approval using cached messages
    with {:ok, message} <- validate_message_exists(message_id, state.messages),
         :ok <- validate_is_approval(message),
         :ok <- validate_not_already_approved(message),
         :ok <- validate_choice_in_options(opts[:choice], message.approval_options),
         approval_id <- generate_approval_id(),
         # FIX P0#2: Use version checking for this critical operation
         {:ok, _version} <- Ipa.Pod.State.append_event(
           state.task_id,
           "approval_given",
           %{
             message_id: message_id,
             approved_by: opts[:approved_by],
             choice: opts[:choice],
             comment: opts[:comment]
           },
           current_state.version,  # CHECK VERSION to prevent concurrent approvals!
           actor_id: opts[:approved_by]  # FIX P0#1: Add actor_id
         ),
         :ok <- broadcast_approval(state.task_id, message_id, opts) do
      {:reply, {:ok, approval_id}, state}
    else
      {:error, :version_conflict} ->
        # Retry or inform user that state changed
        {:reply, {:error, :version_conflict}, state}
      error ->
        {:reply, error, state}
    end
  end

  # FIX P0#6: Validation helpers for approval
  defp validate_message_exists(message_id, messages) do
    case Map.get(messages, message_id) do
      nil -> {:error, :message_not_found}
      message -> {:ok, message}
    end
  end

  defp validate_is_approval(message) do
    if message.type == :approval do
      :ok
    else
      {:error, :not_approval_request}
    end
  end

  defp validate_not_already_approved(message) do
    if message.approved? do
      {:error, :already_approved}
    else
      :ok
    end
  end

  defp validate_choice_in_options(choice, options) do
    if choice in options do
      :ok
    else
      {:error, :invalid_choice}
    end
  end

  # ... more handlers
end
```

### Message Validation

```elixir
defp validate_message(opts, state) do
  with {:ok, type} <- validate_type(opts[:type]),
       {:ok, content} <- validate_content(opts[:content]),
       {:ok, author} <- validate_author(opts[:author]),
       :ok <- validate_thread(opts[:thread_id], state) do
    :ok
  end
end

defp validate_type(type) when type in [:question, :update, :blocker, :approval], do: {:ok, type}
defp validate_type(_), do: {:error, :invalid_type}

defp validate_content(content) when is_binary(content) and byte_size(content) > 0 do
  {:ok, content}
end
defp validate_content(_), do: {:error, :empty_content}

defp validate_author(author) when is_binary(author) and byte_size(author) > 0 do
  {:ok, author}
end
defp validate_author(_), do: {:error, :invalid_author}

defp validate_thread(nil, _state), do: :ok
defp validate_thread(thread_id, state) when is_binary(thread_id) do
  # FIX P2: Check if thread exists in cached messages
  if Map.has_key?(state.messages, thread_id) do
    :ok
  else
    {:error, :thread_not_found}
  end
end

# FIX P0#1: Event append helper with actor_id
defp append_message_event(task_id, message_id, opts) do
  Ipa.Pod.State.append_event(
    task_id,
    "message_posted",
    %{
      message_id: message_id,
      type: opts[:type],
      content: opts[:content],
      author: opts[:author],
      thread_id: opts[:thread_id],
      workstream_id: opts[:workstream_id]
    },
    nil,  # expected_version (nil for regular messages - not critical)
    actor_id: opts[:author]  # Author is the actor
  )
end
```

### Notification Creation Rules

**Automatic notifications created for**:

1. **Questions** (`:question`):
   - Creates notification for all humans
   - Type: `:question_asked`

2. **Approval Requests** (`:approval`):
   - Creates notification for all humans
   - Type: `:needs_approval`
   - High priority

3. **Blockers** (`:blocker`):
   - Creates notification for all humans
   - Type: `:blocker_raised`
   - Urgent priority

4. **Updates** (`:update`):
   - No automatic notifications
   - Informational only

**Implementation**:
```elixir
defp maybe_create_notification(task_id, message_id, opts) do
  case opts[:type] do
    :question ->
      create_notifications_for_humans(task_id, message_id, :question_asked)
    :approval ->
      create_notifications_for_humans(task_id, message_id, :needs_approval)
    :blocker ->
      create_notifications_for_humans(task_id, message_id, :blocker_raised)
    :update ->
      :ok  # No notifications for updates
  end
end

defp create_notifications_for_humans(task_id, message_id, type) do
  # Get list of human users from Pod State or config
  humans = get_human_recipients(task_id)

  Enum.each(humans, fn human_id ->
    notification_id = generate_notification_id()

    # FIX P0#1: Add actor_id for audit trail
    Ipa.Pod.State.append_event(
      task_id,
      "notification_created",
      %{
        notification_id: notification_id,
        recipient: human_id,
        message_id: message_id,
        type: type
      },
      nil,  # expected_version (nil for notifications - not critical)
      actor_id: "system"  # System generates notifications
    )
  end)

  :ok
end

# FIX P0#4: Define recipient resolution strategy
defp get_human_recipients(task_id) do
  # Get notification recipients from config
  config = Application.get_env(:ipa, Ipa.Pod.CommunicationsManager, [])
  default_recipients = Keyword.get(config, :notification_recipients, [])

  # Option: Could also check task state for assigned users
  # {:ok, state} = Ipa.Pod.State.get_state(task_id)
  # assigned_users = state.assigned_users || default_recipients

  # For now, use config-based recipients
  # If no recipients configured, return empty list (notifications won't be created)
  case default_recipients do
    [] ->
      require Logger
      Logger.warning("No human recipients configured for task #{task_id}, notifications will not be created")
      []
    recipients ->
      recipients
  end
end
```

### Pub-Sub Broadcasting

Messages are broadcast via Phoenix.PubSub to notify LiveView and other subscribers:

```elixir
defp broadcast_message(task_id, message_id, message_data) do
  Phoenix.PubSub.broadcast(
    Ipa.PubSub,
    "pod:#{task_id}:communications",
    {:message_posted, task_id, %{message_id: message_id, data: message_data}}
  )
end

defp broadcast_approval(task_id, message_id, approval_data) do
  Phoenix.PubSub.broadcast(
    Ipa.PubSub,
    "pod:#{task_id}:communications",
    {:approval_given, task_id, message_id, approval_data}
  )
end
```

## Integration with Other Components

### With Pod State Manager

**FIX P0#3: State Projection and Event Application Rules**

Communications Manager requires the following additions to Pod State Manager's state schema and event projection logic.

#### State Schema Additions

Pod State Manager (Component 2.2) must include these fields in its state:

```elixir
%{
  # ... existing fields (task_id, version, phase, title, spec, plan, agents, etc.) ...

  # NEW: Communications state (added by this component)
  messages: [
    %{
      message_id: String.t(),
      type: atom(),  # :question | :approval | :update | :blocker
      content: String.t(),
      author: String.t(),
      thread_id: String.t() | nil,
      workstream_id: String.t() | nil,
      posted_at: integer(),
      read_by: [String.t()],
      # Approval-specific fields (nil for non-approval messages)
      approval_options: [String.t()] | nil,
      approval_choice: String.t() | nil,
      approval_given_by: String.t() | nil,
      approval_given_at: integer() | nil,
      approved?: boolean()
    }
  ],

  inbox: [
    %{
      notification_id: String.t(),
      recipient: String.t(),
      message_id: String.t(),
      type: atom(),  # :needs_approval | :question_asked | :blocker_raised | :workstream_completed
      read?: boolean(),
      created_at: integer()
    }
  ]
}
```

#### Event Application Rules

Pod State Manager must project these communications events:

**1. message_posted**

```elixir
defp apply_event(%{
  event_type: "message_posted",
  data: %{message_id: id, type: type, content: content, author: author, thread_id: thread_id, workstream_id: ws_id},
  version: version,
  inserted_at: timestamp
}, state) do
  new_message = %{
    message_id: id,
    type: type,
    content: content,
    author: author,
    thread_id: thread_id,
    workstream_id: ws_id,
    posted_at: timestamp,
    read_by: [],
    # Approval fields nil for regular messages
    approval_options: nil,
    approval_choice: nil,
    approval_given_by: nil,
    approval_given_at: nil,
    approved?: false
  }

  %{state |
    messages: [new_message | state.messages],
    version: version,
    updated_at: timestamp
  }
end
```

**2. approval_requested**

```elixir
defp apply_event(%{
  event_type: "approval_requested",
  data: %{message_id: id, question: question, options: options, author: author, workstream_id: ws_id, blocking?: blocking},
  version: version,
  inserted_at: timestamp
}, state) do
  new_message = %{
    message_id: id,
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
    approved?: false
  }

  %{state |
    messages: [new_message | state.messages],
    version: version,
    updated_at: timestamp
  }
end
```

**3. approval_given**

```elixir
defp apply_event(%{
  event_type: "approval_given",
  data: %{message_id: msg_id, approved_by: user_id, choice: choice, comment: _comment},
  version: version,
  inserted_at: timestamp
}, state) do
  updated_messages = Enum.map(state.messages, fn msg ->
    if msg.message_id == msg_id do
      %{msg |
        approval_choice: choice,
        approval_given_by: user_id,
        approval_given_at: timestamp,
        approved?: true
      }
    else
      msg
    end
  end)

  # Remove corresponding notification
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
```

**4. notification_created**

```elixir
defp apply_event(%{
  event_type: "notification_created",
  data: %{notification_id: id, recipient: recipient, message_id: msg_id, type: type},
  version: version,
  inserted_at: timestamp
}, state) do
  new_notification = %{
    notification_id: id,
    recipient: recipient,
    message_id: msg_id,
    type: type,
    read?: false,
    created_at: timestamp
  }

  %{state |
    inbox: [new_notification | state.inbox],
    version: version,
    updated_at: timestamp
  }
end
```

**5. notification_read**

```elixir
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
```

#### Usage Pattern

Communications Manager **uses** Pod State:
```elixir
# Append message event with actor_id
Ipa.Pod.State.append_event(
  task_id,
  "message_posted",
  message_data,
  nil,  # expected_version (or actual version for critical ops)
  actor_id: author_id
)

# Query messages for rendering
{:ok, state} = Ipa.Pod.State.get_state(task_id)
messages = state.messages  # List of all messages
inbox = state.inbox        # List of notifications
```

**Important**: All communications events MUST be handled by Pod State Manager's projections. If these projections are not implemented, message state cannot be reconstructed after pod restart.

### With Pod Scheduler

Scheduler **uses** Communications Manager:
```elixir
# Agent asks a question
Ipa.Pod.CommunicationsManager.post_message(
  task_id,
  type: :question,
  content: "Should we use approach A or B?",
  author: agent_id,
  workstream_id: workstream_id
)

# Agent requests approval before proceeding
{:ok, msg_id} = Ipa.Pod.CommunicationsManager.request_approval(
  task_id,
  question: "Ready to deploy to production?",
  options: ["Yes, deploy", "No, hold off"],
  author: agent_id,
  workstream_id: workstream_id,
  blocking?: true
)

# Scheduler pauses workstream until approval received
# (subscribes to state or polls for approval_given event)
```

### With LiveView UI

LiveView **subscribes** to communications:
```elixir
def mount(_params, _session, socket) do
  task_id = socket.assigns.task_id

  # Subscribe to communications
  Ipa.Pod.CommunicationsManager.subscribe(task_id)

  # Load initial messages and inbox
  {:ok, messages} = Ipa.Pod.CommunicationsManager.get_messages(task_id)
  {:ok, inbox} = Ipa.Pod.CommunicationsManager.get_inbox(task_id, unread_only?: true)

  {:ok, assign(socket, messages: messages, inbox: inbox)}
end

def handle_info({:message_posted, _task_id, message}, socket) do
  # Update UI with new message
  {:noreply, update(socket, :messages, fn msgs -> [message | msgs] end)}
end

def handle_info({:notification_created, _task_id, notification}, socket) do
  # Update inbox
  {:noreply, update(socket, :inbox, fn inbox -> [notification | inbox] end)}
end
```

### With Agents (via Claude Code SDK)

Agents can post messages programmatically:

**Future Enhancement**: Agents could use a helper module that wraps the Communications Manager API:

```elixir
# In agent workspace (future)
IpaAgent.ask_question(
  "Should we use PostgreSQL or MySQL for this feature?",
  workstream_id: current_workstream_id
)

IpaAgent.request_approval(
  question: "Ready to merge PR #45?",
  options: ["Yes", "No", "Need review"],
  blocking?: true
)
```

## Testing Strategy

### Unit Tests

**Message Posting**:
```elixir
test "post_message creates message event" do
  {:ok, msg_id} = CommunicationsManager.post_message(
    task_id,
    type: :question,
    content: "Test question?",
    author: "agent-1"
  )

  # Verify event was appended
  {:ok, state} = Ipa.Pod.State.get_state(task_id)
  assert Enum.any?(state.messages, fn msg -> msg.message_id == msg_id end)
end

test "post_message with invalid type returns error" do
  assert {:error, :invalid_type} = CommunicationsManager.post_message(
    task_id,
    type: :invalid,
    content: "Test",
    author: "agent-1"
  )
end
```

**Threading**:
```elixir
test "reply message references parent thread" do
  {:ok, root_id} = CommunicationsManager.post_message(
    task_id,
    type: :question,
    content: "Root message",
    author: "agent-1"
  )

  {:ok, reply_id} = CommunicationsManager.post_message(
    task_id,
    type: :update,
    content: "Reply message",
    author: "agent-2",
    thread_id: root_id
  )

  {:ok, thread} = CommunicationsManager.get_thread(task_id, root_id)
  assert length(thread) == 2
  assert Enum.any?(thread, fn msg -> msg.message_id == reply_id and msg.thread_id == root_id end)
end
```

**Approval Workflow**:
```elixir
test "approval workflow creates notification and allows approval" do
  # Request approval
  {:ok, msg_id} = CommunicationsManager.request_approval(
    task_id,
    question: "Deploy to prod?",
    options: ["Yes", "No"],
    author: "agent-1"
  )

  # Verify notification created
  {:ok, inbox} = CommunicationsManager.get_inbox(task_id, unread_only?: true)
  assert Enum.any?(inbox, fn n -> n.message_id == msg_id and n.type == :needs_approval end)

  # Give approval
  {:ok, _approval_id} = CommunicationsManager.give_approval(
    task_id,
    msg_id,
    approved_by: "user-1",
    choice: "Yes"
  )

  # Verify approval recorded
  {:ok, state} = Ipa.Pod.State.get_state(task_id)
  message = Enum.find(state.messages, fn m -> m.message_id == msg_id end)
  assert message.approved? == true
  assert message.approval_choice == "Yes"

  # Verify notification cleared
  {:ok, inbox} = CommunicationsManager.get_inbox(task_id, unread_only?: true)
  refute Enum.any?(inbox, fn n -> n.message_id == msg_id end)
end
```

**Inbox Management**:
```elixir
test "mark_read updates notification" do
  # Create notification
  {:ok, msg_id} = CommunicationsManager.post_message(
    task_id,
    type: :question,
    content: "Question?",
    author: "agent-1"
  )

  {:ok, inbox} = CommunicationsManager.get_inbox(task_id, unread_only?: true)
  notification = Enum.find(inbox, fn n -> n.message_id == msg_id end)

  # Mark as read
  :ok = CommunicationsManager.mark_read(task_id, notification.notification_id)

  # Verify no longer in unread inbox
  {:ok, inbox} = CommunicationsManager.get_inbox(task_id, unread_only?: true)
  refute Enum.any?(inbox, fn n -> n.notification_id == notification.notification_id end)
end
```

### Integration Tests

**With Pod State Manager**:
```elixir
test "messages are persisted and queryable after pod restart" do
  # Post messages
  {:ok, msg1} = CommunicationsManager.post_message(task_id, ...)
  {:ok, msg2} = CommunicationsManager.post_message(task_id, ...)

  # Stop pod
  Ipa.CentralManager.stop_pod(task_id)

  # Restart pod
  Ipa.CentralManager.start_pod(task_id)

  # Verify messages are still there
  {:ok, messages} = CommunicationsManager.get_messages(task_id)
  assert length(messages) == 2
end
```

**With LiveView**:
```elixir
test "LiveView receives real-time message notifications" do
  # Subscribe to communications
  CommunicationsManager.subscribe(task_id)

  # Post message
  {:ok, msg_id} = CommunicationsManager.post_message(task_id, ...)

  # Verify pub-sub message received
  assert_receive {:message_posted, ^task_id, %{message_id: ^msg_id}}
end
```

## Performance Considerations

1. **Event Append**: Each message = 1 event append (~1-5ms)
2. **Pub-Sub Broadcast**: Fast (<1ms per subscriber)
3. **State Queries**: In-memory reads, very fast (<1ms)
4. **Message Filtering**: Consider indexing if message volume is high

**Expected Performance**:
- `post_message/2`: <10ms (event append + broadcast)
- `request_approval/2`: <15ms (2 events: message + notification)
- `get_inbox/2`: <1ms (in-memory query)
- `get_thread/2`: <5ms (in-memory filter + sort)

## Configuration

Add to `config/config.exs`:

```elixir
config :ipa, Ipa.Pod.CommunicationsManager,
  max_message_length: 10_000,           # Characters
  max_thread_depth: 50,                 # Max replies in thread
  notification_recipients: ["user-1"],  # Default human recipients
  pub_sub_enabled: true
```

## Implementation Checklist

- [ ] Create `lib/ipa/pod/communications_manager.ex` GenServer
- [ ] Implement `post_message/2`
- [ ] Implement `request_approval/2`
- [ ] Implement `give_approval/3`
- [ ] Implement `mark_read/2`
- [ ] Implement `get_inbox/2`
- [ ] Implement `get_thread/2`
- [ ] Implement `get_messages/2`
- [ ] Implement `subscribe/1`
- [ ] Implement message validation
- [ ] Implement notification creation logic
- [ ] Implement pub-sub broadcasting
- [ ] Write unit tests for all API functions
- [ ] Write unit tests for threading
- [ ] Write unit tests for approval workflow
- [ ] Write unit tests for inbox management
- [ ] Write integration tests with Pod State
- [ ] Write integration tests with LiveView
- [ ] Update tracker.md with progress
- [ ] Get spec review from architecture-strategist

## Future Enhancements

1. **Message Search**: Full-text search across messages
2. **Message Reactions**: Emoji reactions to messages (👍, ❤️, etc.)
3. **Message Editing**: Allow authors to edit their messages
4. **Message Deletion**: Soft-delete messages
5. **Attachments**: Support file attachments in messages
6. **@Mentions**: Mention specific users/agents
7. **Rich Formatting**: Markdown support in messages
8. **Scheduled Messages**: Post messages at specific times
9. **Message Templates**: Pre-defined message templates for common scenarios
10. **Analytics**: Track message volume, response times, approval rates

## Notes

- Communications Manager is a GenServer (one per pod)
- All state is persisted via Pod State Manager (event sourcing)
- Real-time updates via Phoenix.PubSub
- Designed for human-agent and agent-agent coordination
- Inbox notifications drive human attention to important messages
- Approval workflow is blocking (agents should pause and wait)
- Threading keeps conversations organized
- All messages are immutable once posted (no editing in v1)
