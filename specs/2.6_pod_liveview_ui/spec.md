# Component Spec: 2.6 Pod LiveView UI

## Overview

The Pod LiveView UI is the **real-time web interface** for an individual task pod. It provides a live dashboard for monitoring and interacting with a task's execution, including viewing task state, monitoring active agents, approving transitions, browsing workspaces, and tracking external sync status.

This is **Layer 2** (Pod Infrastructure) - it consumes the Pod State Manager API and provides a user-facing interface for task management.

## Purpose

- Provide real-time visualization of task state and progress
- Enable human-in-the-loop interactions (approvals, interruptions)
- Display agent activity with streaming logs
- Browse and view workspace files
- Show external sync status (GitHub PRs, JIRA tickets)
- Maintain responsiveness with Phoenix LiveView's real-time updates

## Dependencies

- **External**: Phoenix LiveView, Phoenix.PubSub, TailwindCSS
- **Internal**:
  - Ipa.Pod.State (Layer 2.2) - State queries and pub-sub
  - Ipa.Pod.Scheduler (Layer 2.3) - Agent interruption
  - Ipa.Pod.WorkspaceManager (Layer 2.4) - File browsing
  - Ipa.EventStore (Layer 1.1) - Direct event queries (optional, for event log display)
- **Used By**: End users via web browser

## Module Structure

```
lib/ipa_web/
  └── live/
      └── pod/
          ├── task_live.ex                 # Main LiveView module
          ├── components/
          │   ├── task_header.ex          # Task title, phase, status badge
          │   ├── spec_section.ex         # Spec display + approval
          │   ├── plan_section.ex         # Plan display + approval
          │   ├── agent_monitor.ex        # Active agents with logs
          │   ├── workspace_browser.ex    # File tree + file viewer
          │   └── external_sync_status.ex # GitHub/JIRA sync status
          └── task_live.html.heex          # Main template (if not using ~H)
```

## Route

```elixir
# lib/ipa_web/router.ex
scope "/", IpaWeb do
  pipe_through :browser

  live "/pods/:task_id", Pod.TaskLive, :show
end
```

**URL Pattern**: `/pods/:task_id`

**Example**: `/pods/550e8400-e29b-41d4-a716-446655440000`

## User Authentication

### Session Management

The LiveView requires an authenticated user for all approval operations. User authentication is handled via Phoenix session and loaded through an `on_mount` hook.

**Setup**:
```elixir
defmodule IpaWeb.Pod.TaskLive do
  use IpaWeb, :live_view

  # Ensure user is authenticated before mounting
  on_mount {IpaWeb.UserAuth, :ensure_authenticated}

  def mount(%{"task_id" => task_id}, _session, socket) do
    # socket.assigns.current_user is populated by UserAuth hook
    # Structure: %{id: uuid, email: string, name: string, ...}
    user = socket.assigns.current_user
    # ...
  end
end
```

### User Structure

The `current_user` assign contains:
```elixir
%{
  id: String.t(),           # User UUID
  email: String.t(),        # User email
  name: String.t(),         # Display name
  inserted_at: DateTime.t() # Account creation timestamp
}
```

### Authorization

**Current Implementation (MVP)**: All authenticated users can approve tasks.

**Event Attribution**: All approval events include the user ID:
```elixir
Ipa.Pod.State.append_event(
  task_id,
  "spec_approved",
  %{approved_by: user.id},
  expected_version,
  actor_id: user.id  # For audit trail
)
```

### Unauthenticated Access

If user is not authenticated, the `on_mount` hook will:
1. Redirect to login page
2. Store return URL in session
3. Redirect back to task page after login

### Future Enhancements

- **Task-level permissions**: Only task creator or assigned users can approve
- **Role-based access**: Different permissions for developers, reviewers, admins
- **Read-only mode**: Allow unauthenticated users to view tasks (no approvals)

## Public API

### Module: `IpaWeb.Pod.TaskLive`

This is a **Phoenix LiveView** that manages the UI for a single task pod.

#### LiveView Lifecycle

##### `mount/3`
```elixir
@impl true
def mount(%{"task_id" => task_id}, _session, socket) do
  # Verify task exists
  case Ipa.Pod.State.get_state(task_id) do
    {:ok, state} ->
      # Subscribe to real-time updates
      if connected?(socket) do
        Ipa.Pod.State.subscribe(task_id)
      end

      socket =
        socket
        |> assign(task_id: task_id)
        |> assign(state: state)
        |> assign(selected_agent_id: nil)
        |> assign(selected_file_path: nil)
        |> assign(file_contents: nil)
        |> assign(workspace_expanded: false)
        |> assign(agent_logs: [])  # In-memory agent logs (not persisted)

      {:ok, socket}

    {:error, :not_found} ->
      {:ok,
       socket
       |> put_flash(:error, "Task not found")
       |> push_navigate(to: "/")}
  end
end
```

**Behavior**:
1. Extract `task_id` from URL params
2. Verify task exists by fetching state
3. Subscribe to `"pod:#{task_id}:state"` for real-time updates (only if WebSocket connected)
4. Initialize socket assigns
5. Return mounted socket

**Socket Assigns**:
- `task_id` - UUID of the task
- `state` - Current task state (from Pod State Manager)
- `selected_agent_id` - Currently selected agent (for log viewing)
- `selected_file_path` - Currently selected file (for file viewing)
- `file_contents` - Contents of selected file
- `workspace_expanded` - Whether workspace browser is expanded
- `agent_logs` - List of agent log entries (in-memory, not persisted)
- `current_user` - Authenticated user (populated by on_mount hook)

##### `handle_info/2` - State Updates
```elixir
@impl true
def handle_info({:state_updated, _task_id, new_state}, socket) do
  socket = assign(socket, state: new_state)
  {:noreply, socket}
end
```

**Behavior**:
1. Receive pub-sub message from Pod State Manager
2. Update `state` assign
3. LiveView automatically re-renders with new state

**Performance**: This happens on **every** state change. Keep rendering lightweight.

#### Event Handlers

##### Spec Approval
```elixir
@impl true
def handle_event("approve_spec", _params, socket) do
  state = socket.assigns.state
  user_id = socket.assigns.current_user.id  # From session

  case Ipa.Pod.State.append_event(
    socket.assigns.task_id,
    "spec_approved",
    %{approved_by: user_id},
    state.version,  # Optimistic concurrency
    actor_id: user_id
  ) do
    {:ok, _version} ->
      {:noreply, put_flash(socket, :info, "Spec approved")}

    {:error, :version_conflict} ->
      # Reload state and notify user
      {:ok, new_state} = Ipa.Pod.State.get_state(socket.assigns.task_id)
      {:noreply,
       socket
       |> assign(state: new_state)
       |> put_flash(:warning, "State changed, please review and try again")}

    {:error, {:validation_failed, reason}} ->
      {:noreply, put_flash(socket, :error, "Cannot approve: #{reason}")}
  end
end
```

**Trigger**: User clicks "Approve Spec" button

**Behavior**:
1. Extract current state version
2. Append `spec_approved` event with optimistic concurrency
3. Handle success (show flash)
4. Handle version conflict (reload state, show warning)
5. Handle validation error (show error message)

##### Plan Approval
```elixir
@impl true
def handle_event("approve_plan", _params, socket) do
  state = socket.assigns.state
  user_id = socket.assigns.current_user.id

  case Ipa.Pod.State.append_event(
    socket.assigns.task_id,
    "plan_approved",
    %{approved_by: user_id},
    state.version,
    actor_id: user_id
  ) do
    {:ok, _version} ->
      {:noreply, put_flash(socket, :info, "Plan approved")}

    {:error, :version_conflict} ->
      {:ok, new_state} = Ipa.Pod.State.get_state(socket.assigns.task_id)
      {:noreply,
       socket
       |> assign(state: new_state)
       |> put_flash(:warning, "State changed, please review and try again")}

    {:error, {:validation_failed, reason}} ->
      {:noreply, put_flash(socket, :error, "Cannot approve: #{reason}")}
  end
end
```

**Trigger**: User clicks "Approve Plan" button

##### Phase Transition Approval
```elixir
@impl true
def handle_event("approve_transition", %{"to_phase" => to_phase}, socket) do
  state = socket.assigns.state
  user_id = socket.assigns.current_user.id

  case Ipa.Pod.State.append_event(
    socket.assigns.task_id,
    "transition_approved",
    %{to_phase: String.to_existing_atom(to_phase), approved_by: user_id},
    state.version,
    actor_id: user_id
  ) do
    {:ok, _version} ->
      {:noreply, put_flash(socket, :info, "Transition approved to #{to_phase}")}

    {:error, :version_conflict} ->
      {:ok, new_state} = Ipa.Pod.State.get_state(socket.assigns.task_id)
      {:noreply,
       socket
       |> assign(state: new_state)
       |> put_flash(:warning, "State changed, please review and try again")}

    {:error, {:validation_failed, reason}} ->
      {:noreply, put_flash(socket, :error, "Cannot transition: #{reason}")}
  end
end
```

**Trigger**: User clicks "Approve Transition" button (appears when `pending_transitions` is not empty)

**Behavior**: Similar to spec/plan approval, but transitions task phase

##### Agent Interruption
```elixir
@impl true
def handle_event("interrupt_agent", %{"agent_id" => agent_id}, socket) do
  case Ipa.Pod.Scheduler.interrupt_agent(socket.assigns.task_id, agent_id) do
    :ok ->
      {:noreply, put_flash(socket, :info, "Agent interrupted")}

    {:error, :not_found} ->
      {:noreply, put_flash(socket, :error, "Agent not found")}

    {:error, :not_running} ->
      {:noreply, put_flash(socket, :error, "Agent is not running")}
  end
end
```

**Trigger**: User clicks "Interrupt" button next to running agent

**Behavior**:
1. Call `Ipa.Pod.Scheduler.interrupt_agent/2`
2. Scheduler will append `agent_interrupted` event
3. State update will propagate via pub-sub
4. UI will update to show interrupted status

##### File Selection
```elixir
@impl true
def handle_event("select_file", %{"agent_id" => agent_id, "path" => path}, socket) do
  case Ipa.Pod.WorkspaceManager.read_file(
    socket.assigns.task_id,
    agent_id,
    path
  ) do
    {:ok, contents} ->
      socket =
        socket
        |> assign(selected_agent_id: agent_id)
        |> assign(selected_file_path: path)
        |> assign(file_contents: contents)
      {:noreply, socket}

    {:error, :file_not_found} ->
      {:noreply, put_flash(socket, :error, "File not found")}

    {:error, :workspace_not_found} ->
      {:noreply, put_flash(socket, :error, "Workspace not found")}

    {:error, reason} ->
      {:noreply, put_flash(socket, :error, "Failed to read file: #{inspect(reason)}")}
  end
end
```

**Trigger**: User clicks file in workspace browser

**Behavior**:
1. Read file from workspace
2. Update `selected_file_path` and `file_contents`
3. UI re-renders to display file contents

##### Workspace Toggle
```elixir
@impl true
def handle_event("toggle_workspace", _params, socket) do
  socket = assign(socket, workspace_expanded: !socket.assigns.workspace_expanded)
  {:noreply, socket}
end
```

**Trigger**: User clicks "Show Workspace" / "Hide Workspace" button

##### Agent Selection (for log viewing)
```elixir
@impl true
def handle_event("select_agent", %{"agent_id" => agent_id}, socket) do
  socket = assign(socket, selected_agent_id: agent_id)
  {:noreply, socket}
end
```

**Trigger**: User clicks agent in agent list

**Behavior**: Updates `selected_agent_id` to show that agent's logs

## UI Layout

### Page Structure

```
┌─────────────────────────────────────────────────────────────┐
│ IPA - Task Pod Dashboard                                     │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│ ┌─── Task Header ───────────────────────────────────────┐   │
│ │ Task: Implement authentication system                  │   │
│ │ Phase: [Development]  Status: [Agent Running]          │   │
│ │ Created: 2 hours ago  Updated: 30 seconds ago          │   │
│ └─────────────────────────────────────────────────────────┘   │
│                                                               │
│ ┌─── Spec Section ──────────────────────────────────────┐   │
│ │ Description: Add JWT-based authentication...           │   │
│ │ Requirements:                                           │   │
│ │   - User login/logout                                   │   │
│ │   - Token refresh                                       │   │
│ │ [✓ Approved by user-123 at 1:23 PM]                   │   │
│ └─────────────────────────────────────────────────────────┘   │
│                                                               │
│ ┌─── Plan Section ──────────────────────────────────────┐   │
│ │ Steps:                                                  │   │
│ │   1. Create User model (2h) [Completed]                │   │
│ │   2. Add auth routes (1h) [In Progress]                │   │
│ │   3. Write tests (2h) [Pending]                        │   │
│ │ [✓ Approved by user-123 at 1:25 PM]                   │   │
│ └─────────────────────────────────────────────────────────┘   │
│                                                               │
│ ┌─── Active Agents ─────────────────────────────────────┐   │
│ │ Development Agent (agent-456) [Running]                │   │
│ │   Started: 15 minutes ago                               │   │
│ │   [Interrupt]                                           │   │
│ │   Logs:                                                 │   │
│ │     > Creating auth controller...                       │   │
│ │     > Running tests...                                  │   │
│ │     > Tests passing ✓                                   │   │
│ └─────────────────────────────────────────────────────────┘   │
│                                                               │
│ ┌─── Workspace Browser ────────────────────────────────┐   │
│ │ Agent: agent-456  [Show/Hide]                          │   │
│ │ lib/                                                    │   │
│ │   ├─ ipa/                                              │   │
│ │   │  └─ auth/                                          │   │
│ │   │     ├─ controller.ex                               │   │
│ │   │     └─ tokens.ex                                   │   │
│ │                                                         │   │
│ │ File: lib/ipa/auth/controller.ex                       │   │
│ │ ┌───────────────────────────────────────────────────┐ │   │
│ │ │ defmodule Ipa.Auth.Controller do                  │ │   │
│ │ │   def login(conn, params) do                      │ │   │
│ │ │     ...                                           │ │   │
│ │ │   end                                             │ │   │
│ │ └───────────────────────────────────────────────────┘ │   │
│ └─────────────────────────────────────────────────────────┘   │
│                                                               │
│ ┌─── External Sync ─────────────────────────────────────┐   │
│ │ GitHub: PR #42 [Open] - Last synced 1 min ago          │   │
│ │ JIRA: PROJ-123 [In Progress] - Last synced 2 min ago   │   │
│ └─────────────────────────────────────────────────────────┘   │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

### UI Components

#### 1. Task Header Component

**Module**: `IpaWeb.Pod.Components.TaskHeader`

**Purpose**: Display task metadata and high-level status

**Props**:
- `state` - Task state map

**Rendered Info**:
- Task title
- Current phase (with color-coded badge)
- Overall status (idle, agent running, waiting for approval, etc.)
- Created timestamp (relative, e.g., "2 hours ago")
- Last updated timestamp

**Phase Colors**:
- `spec_clarification` - Blue
- `planning` - Yellow
- `development` - Orange
- `review` - Purple
- `completed` - Green
- `cancelled` - Gray

**Status Logic**:
```elixir
defp task_status(state) do
  cond do
    state.phase == :completed -> "Completed"
    state.phase == :cancelled -> "Cancelled"
    has_running_agents?(state) -> "Agent Running"
    has_pending_transitions?(state) -> "Waiting for Approval"
    state.phase == :spec_clarification && !state.spec.approved? -> "Awaiting Spec Approval"
    state.phase == :planning && !state.plan -> "Planning"
    true -> "Idle"
  end
end
```

#### 2. Spec Section Component

**Module**: `IpaWeb.Pod.Components.SpecSection`

**Purpose**: Display spec details and approval button

**Props**:
- `state` - Task state map
- `on_approve` - Event handler for approval

**Rendered Info**:
- Spec description (or "No spec yet" if nil)
- Requirements list
- Acceptance criteria list
- Approval status:
  - If approved: "✓ Approved by [user] at [time]"
  - If not approved: [Approve Spec] button (disabled if phase != spec_clarification)

**Approval Button Logic**:
```elixir
<button
  phx-click="approve_spec"
  disabled={@state.phase != :spec_clarification || @state.spec.approved?}
  class="btn-primary"
>
  Approve Spec
</button>
```

#### 3. Plan Section Component

**Module**: `IpaWeb.Pod.Components.PlanSection`

**Purpose**: Display plan details and approval button

**Props**:
- `state` - Task state map
- `on_approve` - Event handler for approval

**Rendered Info**:
- Plan steps with status indicators:
  - Pending: Gray circle
  - In Progress: Spinning blue circle
  - Completed: Green checkmark
- Estimated hours per step
- Total estimated hours
- Approval status (similar to spec section)

**Conditional Rendering**:
```elixir
<%= if @state.plan do %>
  <!-- Render plan details -->
<% else %>
  <p class="text-gray-500">No plan generated yet</p>
<% end %>
```

#### 4. Agent Monitor Component

**Module**: `IpaWeb.Pod.Components.AgentMonitor`

**Purpose**: Display active agents with streaming logs

**Props**:
- `agents` - List of agents from state
- `selected_agent_id` - Currently selected agent (for log viewing)
- `on_select` - Event handler for agent selection
- `on_interrupt` - Event handler for interruption

**Agent List**:
- Agent type (e.g., "Planning Agent", "Development Agent")
- Agent ID (truncated, e.g., "agent-456...")
- Status badge (running, completed, failed, interrupted)
- Started timestamp
- Duration (if completed)
- [Interrupt] button (only if status == :running)
- [View Logs] button

**Log Display**:
- Show logs for selected agent
- **Note**: Agent logs should NOT be stored as events in Event Store (this would cause severe performance issues with event replay and database bloat)

**Implementation**: Use **separate pub-sub stream** for agent logs:

```elixir
# In LiveView mount, subscribe to agent log streams
def mount(%{"task_id" => task_id}, _session, socket) do
  # ... existing code ...

  if connected?(socket) do
    Ipa.Pod.State.subscribe(task_id)

    # Subscribe to logs for each agent
    for agent <- state.agents do
      Phoenix.PubSub.subscribe(
        Ipa.PubSub,
        "pod:#{task_id}:agent:#{agent.agent_id}:logs"
      )
    end
  end

  # ... rest of mount ...
end

# When new agents start, subscribe to their logs
def handle_info({:state_updated, _task_id, new_state}, socket) do
  # Check for new agents and subscribe to their logs
  new_agent_ids = Enum.map(new_state.agents, & &1.agent_id)
  old_agent_ids = Enum.map(socket.assigns.state.agents, & &1.agent_id)

  for agent_id <- new_agent_ids -- old_agent_ids do
    Phoenix.PubSub.subscribe(
      Ipa.PubSub,
      "pod:#{socket.assigns.task_id}:agent:#{agent_id}:logs"
    )
  end

  {:noreply, assign(socket, state: new_state)}
end

# Receive log messages
def handle_info({:agent_log, agent_id, message, level, timestamp}, socket) do
  # Store logs in socket assigns (in-memory, not persisted)
  log_entry = %{
    agent_id: agent_id,
    message: message,
    level: level,
    timestamp: timestamp
  }

  agent_logs = socket.assigns.agent_logs || []
  agent_logs = [log_entry | agent_logs] |> Enum.take(1000)  # Keep last 1000 logs

  {:noreply, assign(socket, agent_logs: agent_logs)}
end
```

**Scheduler publishes logs** (not as events):
```elixir
# In Scheduler, when agent produces output
Phoenix.PubSub.broadcast(
  Ipa.PubSub,
  "pod:#{task_id}:agent:#{agent_id}:logs",
  {:agent_log, agent_id, "Creating auth controller...", :info, System.system_time(:second)}
)
```

**Benefits of this approach**:
- Logs don't pollute event store
- Fast pod startup (no log replay required)
- Real-time log streaming
- Logs are ephemeral (lost on pod restart, but that's acceptable for logs)
- Can implement log retention/rotation easily
- Pub-sub broadcasts only go to interested clients (LiveView instances)

#### 5. Workspace Browser Component

**Module**: `IpaWeb.Pod.Components.WorkspaceBrowser`

**Purpose**: Browse and view files in agent workspaces

**Props**:
- `task_id` - Task UUID
- `agents` - List of agents (to select workspace)
- `selected_agent_id` - Selected agent
- `selected_file_path` - Selected file path
- `file_contents` - File contents to display
- `expanded` - Whether browser is expanded
- `on_toggle` - Toggle expand/collapse
- `on_select_file` - File selection handler

**File Tree**:
- Show directory structure for selected agent's workspace
- Use `Ipa.Pod.WorkspaceManager.list_files(task_id, agent_id)` to get file tree
- Clickable file names trigger `on_select_file`

**File Tree Format** (returned by `list_files/2`):
```elixir
%{
  "lib" => %{
    "ipa" => %{
      "auth" => %{
        "controller.ex" => :file,
        "tokens.ex" => :file
      }
    }
  },
  "work" => %{...},
  "output" => %{...}
}
```

**File Viewer**:
- Display file contents with syntax highlighting
- Use code editor component (e.g., Monaco Editor or simple `<pre>` with syntax highlighting)
- Read-only view (no editing in v1)

**Lazy Loading**:
- File tree loads on demand (when workspace expanded)
- File contents load on demand (when file selected)

**Conditional Rendering**:
```elixir
<%= if @expanded do %>
  <!-- Show file tree and viewer -->
<% else %>
  <button phx-click="toggle_workspace">Show Workspace</button>
<% end %>
```

#### 6. External Sync Status Component

**Module**: `IpaWeb.Pod.Components.ExternalSyncStatus`

**Purpose**: Display GitHub and JIRA sync status

**Props**:
- `external_sync` - External sync state from task state

**GitHub Section**:
- PR number with link (if exists)
- PR status (open, merged, closed)
- Last synced timestamp

**JIRA Section**:
- Ticket ID with link (if exists)
- Ticket status (e.g., "In Progress", "Done")
- Last synced timestamp

**Conditional Rendering**:
```elixir
<%= if @external_sync.github.pr_url do %>
  <a href={@external_sync.github.pr_url} target="_blank" class="link">
    PR #<%= @external_sync.github.pr_number %>
  </a>
<% else %>
  <p class="text-gray-500">No GitHub PR yet</p>
<% end %>
```

### Pending Transitions Display

If `state.pending_transitions` is not empty, show a banner at the top:

```
┌───────────────────────────────────────────────────────────┐
│ ⚠️  Transition Requested: spec_clarification → planning   │
│ Reason: Spec approved, ready to plan                      │
│ [Approve Transition]  [Reject Transition]                 │
└───────────────────────────────────────────────────────────┘
```

**Handler**:
```elixir
def handle_event("approve_transition", %{"to_phase" => to_phase}, socket) do
  # ... (see above)
end

def handle_event("reject_transition", %{"reason" => reason}, socket) do
  state = socket.assigns.state
  user_id = socket.assigns.current_user.id

  case Ipa.Pod.State.append_event(
    socket.assigns.task_id,
    "transition_rejected",
    %{reason: reason, rejected_by: user_id},
    state.version,
    actor_id: user_id
  ) do
    {:ok, _version} ->
      {:noreply, put_flash(socket, :info, "Transition rejected")}
    # ... error handling
  end
end
```

## Real-Time Updates

### Pub-Sub Architecture

**Topic**: `"pod:#{task_id}:state"`

**Subscription**:
```elixir
# In mount/3, only if WebSocket connected
if connected?(socket) do
  Ipa.Pod.State.subscribe(task_id)
end
```

**Message Handling**:
```elixir
def handle_info({:state_updated, _task_id, new_state}, socket) do
  socket = assign(socket, state: new_state)
  {:noreply, socket}
end
```

**What Triggers Re-renders**:
- Any state change (event appended)
- Phase transitions
- Agent starts/completes/fails
- Spec/plan approvals
- External sync updates

**Performance Considerations**:
- Keep rendering lightweight (avoid heavy computations in templates)
- Use LiveView components for isolated updates
- Consider using `phx-update="ignore"` for static sections
- Use `phx-update="stream"` for agent logs (append-only)

### WebSocket Fallback

If WebSocket connection fails, LiveView falls back to long-polling. This is handled automatically by Phoenix LiveView.

## Styling

### CSS Framework

Use **TailwindCSS** (included with Phoenix by default).

### Color Palette

```elixir
# Phase colors
spec_clarification: "bg-blue-100 text-blue-800"
planning: "bg-yellow-100 text-yellow-800"
development: "bg-orange-100 text-orange-800"
review: "bg-purple-100 text-purple-800"
completed: "bg-green-100 text-green-800"
cancelled: "bg-gray-100 text-gray-800"

# Status colors
running: "bg-blue-500 text-white"
completed: "bg-green-500 text-white"
failed: "bg-red-500 text-white"
interrupted: "bg-gray-500 text-white"
```

### Layout Utilities

```css
/* Responsive grid */
.grid-layout {
  @apply grid grid-cols-1 lg:grid-cols-2 gap-6;
}

/* Card component */
.card {
  @apply bg-white rounded-lg shadow-md p-6;
}

/* Button styles */
.btn-primary {
  @apply bg-blue-500 hover:bg-blue-600 text-white font-semibold py-2 px-4 rounded;
}

.btn-danger {
  @apply bg-red-500 hover:bg-red-600 text-white font-semibold py-2 px-4 rounded;
}
```

## Error Handling

### Common Errors

**Task Not Found**:
```elixir
# In mount/3
{:error, :not_found} ->
  {:ok,
   socket
   |> put_flash(:error, "Task not found")
   |> push_navigate(to: "/")}
```

**Version Conflict** (on approval):
```elixir
{:error, :version_conflict} ->
  {:ok, new_state} = Ipa.Pod.State.get_state(socket.assigns.task_id)
  {:noreply,
   socket
   |> assign(state: new_state)
   |> put_flash(:warning, "State changed, please review and try again")}
```

**File Read Error**:
```elixir
{:error, :file_not_found} ->
  {:noreply, put_flash(socket, :error, "File not found")}

{:error, :workspace_not_found} ->
  {:noreply, put_flash(socket, :error, "Workspace not found")}
```

**Agent Interrupt Error**:
```elixir
{:error, :not_running} ->
  {:noreply, put_flash(socket, :error, "Agent is not running")}
```

### Error Display

Use Phoenix Flash messages:
```elixir
<.flash kind={:info} title="Success" flash={@flash} />
<.flash kind={:error} title="Error" flash={@flash} />
<.flash kind={:warning} title="Warning" flash={@flash} />
```

## Testing Requirements

### Unit Tests

**LiveView Mount**:
```elixir
test "mounts successfully with valid task_id", %{conn: conn} do
  task_id = create_task()
  {:ok, _view, html} = live(conn, "/pods/#{task_id}")
  assert html =~ "Task Pod Dashboard"
end

test "redirects when task_id not found", %{conn: conn} do
  {:error, {:redirect, %{to: "/"}}} = live(conn, "/pods/invalid-uuid")
end
```

**Event Handlers**:
```elixir
test "approve_spec appends event and updates UI", %{conn: conn} do
  task_id = create_task_with_spec()
  {:ok, view, _html} = live(conn, "/pods/#{task_id}")

  # Click approve button
  view |> element("button", "Approve Spec") |> render_click()

  # Assert event was appended
  {:ok, state} = Ipa.Pod.State.get_state(task_id)
  assert state.spec.approved? == true
end

test "approve_spec handles version conflict", %{conn: conn} do
  task_id = create_task_with_spec()
  {:ok, view, _html} = live(conn, "/pods/#{task_id}")

  # Simulate concurrent update
  Ipa.Pod.State.append_event(task_id, "spec_updated", %{spec: %{...}}, nil)

  # Try to approve with stale version
  view |> element("button", "Approve Spec") |> render_click()

  # Assert warning flash
  assert render(view) =~ "State changed, please review and try again"
end
```

**Real-Time Updates**:
```elixir
test "receives state updates via pub-sub", %{conn: conn} do
  task_id = create_task()
  {:ok, view, _html} = live(conn, "/pods/#{task_id}")

  # Trigger state change externally
  Ipa.Pod.State.append_event(task_id, "spec_approved", %{approved_by: "user-123"}, nil)

  # Wait for pub-sub message
  :timer.sleep(50)

  # Assert UI updated
  assert render(view) =~ "Approved by user-123"
end
```

### Integration Tests

**End-to-End Task Flow**:
```elixir
test "full task flow: spec → plan → development", %{conn: conn} do
  task_id = create_task()
  {:ok, view, _html} = live(conn, "/pods/#{task_id}")

  # Approve spec
  view |> element("button", "Approve Spec") |> render_click()
  assert render(view) =~ "Spec approved"

  # Wait for transition to planning phase
  :timer.sleep(100)
  assert render(view) =~ "Phase: planning"

  # Approve plan
  view |> element("button", "Approve Plan") |> render_click()
  assert render(view) =~ "Plan approved"

  # Wait for transition to development
  :timer.sleep(100)
  assert render(view) =~ "Phase: development"
end
```

**Agent Monitoring**:
```elixir
test "displays running agent and receives log via pub-sub", %{conn: conn} do
  task_id = create_task_with_running_agent()
  {:ok, view, _html} = live(conn, "/pods/#{task_id}")

  # Assert agent displayed
  assert render(view) =~ "Development Agent"
  assert render(view) =~ "[Running]"

  # Simulate log broadcast via separate pub-sub stream (NOT as event)
  Phoenix.PubSub.broadcast(
    Ipa.PubSub,
    "pod:#{task_id}:agent:#{agent_id}:logs",
    {:agent_log, agent_id, "Test log message", :info, System.system_time(:second)}
  )

  # Wait for pub-sub
  :timer.sleep(50)

  # Assert log displayed
  assert render(view) =~ "Test log message"
end
```

**Workspace Browser**:
```elixir
test "loads and displays file contents", %{conn: conn} do
  task_id = create_task_with_workspace()
  {:ok, view, _html} = live(conn, "/pods/#{task_id}")

  # Expand workspace
  view |> element("button", "Show Workspace") |> render_click()
  assert render(view) =~ "lib/"

  # Select file
  view
  |> element("a", "controller.ex")
  |> render_click(%{"agent_id" => agent_id, "path" => "lib/controller.ex"})

  # Assert file contents displayed
  assert render(view) =~ "defmodule Ipa.Controller"
end
```

### Manual Testing Checklist

- [ ] Task loads correctly from URL
- [ ] Real-time updates work (approve spec, see update immediately)
- [ ] Phase transitions trigger correctly
- [ ] Agent logs stream in real-time
- [ ] Workspace browser loads files correctly
- [ ] File viewer displays code with correct formatting
- [ ] External sync status displays correctly
- [ ] Interrupt agent button works
- [ ] Version conflict handling works (approve on stale state)
- [ ] Error messages display correctly
- [ ] Responsive layout works on mobile/tablet/desktop
- [ ] Back button navigates to dashboard

## Performance Considerations

### Rendering Performance

**Target**: Re-render entire page in < 50ms

**Optimizations**:
1. Use LiveView components for isolated updates
2. Avoid heavy computations in templates
3. Use `assigns_to_attributes/2` for component props
4. Keep agent logs in memory (don't replay all log events on every render)

### Memory Usage

**State Size**: ~10KB per task (typical)

**Agent Logs**: Stored in LiveView socket assigns (in-memory only, not persisted):
- Each LiveView process maintains its own copy of recent logs
- Log rotation: Keep last 1,000 messages total (all agents combined)
- Implemented in `handle_info/2` when receiving `:agent_log` messages
- Memory usage: ~100KB per LiveView connection for logs (1,000 messages × ~100 bytes/message)
- Logs are lost on LiveView disconnect/reconnect (acceptable trade-off for performance)

**Log Cleanup Strategy**:
```elixir
# Automatic rotation in handle_info/2
def handle_info({:agent_log, agent_id, message, level, timestamp}, socket) do
  log_entry = %{
    agent_id: agent_id,
    message: message,
    level: level,
    timestamp: timestamp
  }

  agent_logs = socket.assigns.agent_logs || []
  agent_logs = [log_entry | agent_logs] |> Enum.take(1000)  # Keep last 1000 total

  {:noreply, assign(socket, agent_logs: agent_logs)}
end
```

**Memory Per LiveView Process**:
- Base state: ~10KB
- Agent logs: ~100KB (with 1,000 messages)
- File contents (if browsing): Up to 1MB (enforced limit)
- **Total**: ~1.1MB max per LiveView connection

### Network Performance

**WebSocket Messages**: State updates broadcast to all connected clients

**Optimization**: Use LiveView's built-in diffing - only changed assigns are sent to client

**Large Files**: Don't load entire file into memory. For files > 1MB, show warning and offer download link instead of inline display.

## Configuration

```elixir
# config/config.exs
config :ipa, IpaWeb.Pod.TaskLive,
  # Maximum file size to display inline (bytes)
  max_inline_file_size: 1_048_576,  # 1MB

  # Maximum agent logs to keep in memory per agent
  max_agent_logs: 1000,

  # Enable file syntax highlighting
  syntax_highlighting: true,

  # File extensions to syntax highlight
  highlighted_extensions: [".ex", ".exs", ".js", ".jsx", ".ts", ".tsx", ".html", ".css"]
```

## Acceptance Criteria

- [ ] Pod LiveView mounts and loads task state correctly
- [ ] Real-time state updates work via pub-sub
- [ ] Spec approval button works and appends event
- [ ] Plan approval button works and appends event
- [ ] Phase transition approval works
- [ ] Agent list displays correctly with status badges
- [ ] Agent interrupt button works
- [ ] Agent logs display in real-time (if implemented)
- [ ] Workspace browser loads file tree
- [ ] File viewer displays file contents
- [ ] External sync status displays GitHub PR and JIRA ticket
- [ ] Version conflict handling works (reload state on conflict)
- [ ] Error messages display correctly via flash
- [ ] Responsive layout works on all screen sizes
- [ ] All unit tests pass
- [ ] Integration tests pass

## Future Enhancements

### Phase 1 (MVP)
- Basic task display
- Spec/plan approval
- Agent status monitoring
- Simple workspace browser

### Phase 2 (Enhanced)
- Agent log streaming (real-time)
- File syntax highlighting
- File search in workspace
- Event log viewer (show all events for debugging)

### Phase 3 (Advanced)
- Agent log filtering (by level, search)
- Workspace file editing (inline editor)
- Multi-agent parallel execution view
- Time-travel debugging (replay state at specific version)
- Performance metrics (agent duration, event throughput)
- Notifications (browser notifications for completed agents)

## Notes

- Keep UI simple and functional for MVP - focus on core workflows
- Optimize for real-time updates - this is the main value of LiveView
- Don't over-engineer agent logs in v1 - simple list of messages is fine
- Consider accessibility (keyboard navigation, screen readers)
- Test on different browsers (Chrome, Firefox, Safari)
- Use semantic HTML for better accessibility
- Keep component hierarchy shallow for better performance
