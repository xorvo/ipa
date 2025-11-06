# Component 2.6: Pod LiveView UI - Architecture Refactor Plan

**Created**: 2025-11-06
**Status**: Refactor Required
**Effort**: +1.5 weeks (from 2-3 days to 2 weeks total)

## Overview

The Pod LiveView UI spec is currently approved and comprehensive (1179 lines). However, the architecture refactor requires adding two major new UI sections:

1. **Workstreams Tab**: Display parallel workstreams with dependencies, progress, and agent assignment
2. **Communications Tab**: Display messages, inbox, threads, and approval workflows

This adds significant UI complexity but provides essential visibility into multi-agent coordination.

## Current UI Structure

**Current Layout**:
- Task Header (phase, status)
- Spec Section (with approval button)
- Plan Section (with approval button)
- Agent Monitor (active agents + logs)
- Workspace Browser (file tree + viewer)
- External Sync Status (GitHub/JIRA)

**Current Navigation**: Single-page view, all sections visible

## New UI Structure

**New Layout with Tab Navigation**:
```
┌─────────────────────────────────────────────────────────┐
│ Task: Implement authentication                           │
│ Phase: [Workstream Execution]  Status: [3 agents running]│
├─────────────────────────────────────────────────────────┤
│ [Overview] [Workstreams] [Communications] [External]     │
├─────────────────────────────────────────────────────────┤
│                                                           │
│ (Tab content area)                                        │
│                                                           │
└─────────────────────────────────────────────────────────┘
```

**New Tabs**:
1. **Overview** - Task header, spec, plan (current home view)
2. **Workstreams** - All workstreams with status, dependencies, agents (NEW)
3. **Communications** - Messages, inbox, threads, approvals (NEW)
4. **External** - GitHub/JIRA sync status (moved from Overview)

## Required Changes

### 1. Add Tab Navigation Component

**New Module**: `IpaWeb.Pod.Components.TabNavigation`

```elixir
defmodule IpaWeb.Pod.Components.TabNavigation do
  use Phoenix.Component

  attr :active_tab, :atom, required: true
  attr :unread_message_count, :integer, default: 0

  def render(assigns) do
    ~H"""
    <div class="border-b border-gray-200">
      <nav class="flex space-x-8 px-6">
        <button
          phx-click="switch_tab"
          phx-value-tab="overview"
          class={tab_class(@active_tab == :overview)}
        >
          Overview
        </button>

        <button
          phx-click="switch_tab"
          phx-value-tab="workstreams"
          class={tab_class(@active_tab == :workstreams)}
        >
          Workstreams
          <span class="ml-2 text-xs text-gray-500">
            <%= active_workstream_count(@workstreams) %>
          </span>
        </button>

        <button
          phx-click="switch_tab"
          phx-value-tab="communications"
          class={tab_class(@active_tab == :communications)}
        >
          Communications
          <%= if @unread_message_count > 0 do %>
            <span class="ml-2 px-2 py-1 text-xs bg-red-500 text-white rounded-full">
              <%= @unread_message_count %>
            </span>
          <% end %>
        </button>

        <button
          phx-click="switch_tab"
          phx-value-tab="external"
          class={tab_class(@active_tab == :external)}
        >
          External Sync
        </button>
      </nav>
    </div>
    """
  end

  defp tab_class(active?) do
    base = "py-4 px-1 border-b-2 font-medium text-sm"
    if active? do
      "#{base} border-blue-500 text-blue-600"
    else
      "#{base} border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300"
    end
  end
end
```

**Handler**:
```elixir
def handle_event("switch_tab", %{"tab" => tab}, socket) do
  tab_atom = String.to_existing_atom(tab)
  {:noreply, assign(socket, active_tab: tab_atom)}
end
```

### 2. Add Workstreams Tab Component

**New Module**: `IpaWeb.Pod.Components.WorkstreamsTab`

**Purpose**: Display all workstreams with status, dependencies, progress

```elixir
defmodule IpaWeb.Pod.Components.WorkstreamsTab do
  use Phoenix.Component

  attr :workstreams, :map, required: true
  attr :task_id, :string, required: true

  def render(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <div class="flex justify-between items-center">
        <h2 class="text-2xl font-bold">Workstreams</h2>
        <div class="text-sm text-gray-600">
          <%= completed_count(@workstreams) %> / <%= map_size(@workstreams) %> completed
        </div>
      </div>

      <!-- Progress Bar -->
      <div class="w-full bg-gray-200 rounded-full h-2">
        <div
          class="bg-green-500 h-2 rounded-full"
          style={"width: #{progress_percentage(@workstreams)}%"}
        >
        </div>
      </div>

      <!-- Workstream Cards -->
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <%= for {ws_id, ws} <- sort_workstreams(@workstreams) do %>
          <.workstream_card workstream={ws} workstream_id={ws_id} task_id={@task_id} />
        <% end %>
      </div>

      <!-- Dependency Graph Visualization (Optional) -->
      <div class="mt-8">
        <h3 class="text-lg font-semibold mb-4">Dependency Graph</h3>
        <.dependency_graph workstreams={@workstreams} />
      </div>
    </div>
    """
  end

  attr :workstream, :map, required: true
  attr :workstream_id, :string, required: true
  attr :task_id, :string, required: true

  def workstream_card(assigns) do
    ~H"""
    <div class={"card border-l-4 #{status_border_color(@workstream.status)}"}>
      <!-- Header -->
      <div class="flex justify-between items-start mb-3">
        <div>
          <h3 class="text-lg font-semibold"><%= @workstream.title || @workstream_id %></h3>
          <span class={status_badge_class(@workstream.status)}>
            <%= humanize_status(@workstream.status) %>
          </span>
        </div>
        <%= if @workstream.agent_id do %>
          <span class="text-xs text-gray-500">
            Agent: <%= String.slice(@workstream.agent_id, 0..7) %>
          </span>
        <% end %>
      </div>

      <!-- Spec Preview -->
      <p class="text-sm text-gray-700 mb-3">
        <%= String.slice(@workstream.spec || "", 0..150) %>...
      </p>

      <!-- Dependencies -->
      <%= if length(@workstream.dependencies) > 0 do %>
        <div class="mb-3">
          <span class="text-xs font-semibold text-gray-600">Dependencies:</span>
          <div class="flex flex-wrap gap-1 mt-1">
            <%= for dep_id <- @workstream.dependencies do %>
              <span class="px-2 py-1 text-xs bg-gray-100 rounded">
                <%= dep_id %>
              </span>
            <% end %>
          </div>
        </div>
      <% end %>

      <!-- Blocking Status -->
      <%= if length(@workstream.blocking_on) > 0 do %>
        <div class="mb-3">
          <span class="text-xs font-semibold text-yellow-600">⚠️ Blocked by:</span>
          <div class="flex flex-wrap gap-1 mt-1">
            <%= for blocking_id <- @workstream.blocking_on do %>
              <span class="px-2 py-1 text-xs bg-yellow-100 text-yellow-800 rounded">
                <%= blocking_id %>
              </span>
            <% end %>
          </div>
        </div>
      <% end %>

      <!-- Timing Info -->
      <div class="flex justify-between text-xs text-gray-500 mt-3 pt-3 border-t">
        <%= if @workstream.started_at do %>
          <span>Started: <%= format_timestamp(@workstream.started_at) %></span>
        <% end %>
        <%= if @workstream.completed_at do %>
          <span>Completed: <%= format_timestamp(@workstream.completed_at) %></span>
        <% end %>
        <%= if @workstream.duration_ms do %>
          <span>Duration: <%= format_duration(@workstream.duration_ms) %></span>
        <% end %>
      </div>

      <!-- Actions -->
      <div class="mt-3 flex gap-2">
        <%= if @workstream.status == :in_progress do %>
          <button
            phx-click="view_workstream_agent"
            phx-value-workstream_id={@workstream_id}
            class="btn-sm btn-secondary"
          >
            View Agent
          </button>
        <% end %>
        <%= if @workstream.error do %>
          <button
            phx-click="view_workstream_error"
            phx-value-workstream_id={@workstream_id}
            class="btn-sm btn-danger"
          >
            View Error
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  # Helper functions
  defp status_border_color(status) do
    case status do
      :pending -> "border-gray-400"
      :in_progress -> "border-blue-500"
      :blocked -> "border-yellow-500"
      :completed -> "border-green-500"
      :failed -> "border-red-500"
    end
  end

  defp status_badge_class(status) do
    base = "px-2 py-1 text-xs font-semibold rounded"
    case status do
      :pending -> "#{base} bg-gray-100 text-gray-800"
      :in_progress -> "#{base} bg-blue-100 text-blue-800"
      :blocked -> "#{base} bg-yellow-100 text-yellow-800"
      :completed -> "#{base} bg-green-100 text-green-800"
      :failed -> "#{base} bg-red-100 text-red-800"
    end
  end

  defp sort_workstreams(workstreams) do
    # Sort by: 1) in_progress first, 2) blocked, 3) pending, 4) completed, 5) failed
    workstreams
    |> Enum.sort_by(fn {_id, ws} ->
      case ws.status do
        :in_progress -> 0
        :blocked -> 1
        :pending -> 2
        :completed -> 3
        :failed -> 4
      end
    end)
  end

  defp completed_count(workstreams) do
    workstreams
    |> Map.values()
    |> Enum.count(fn ws -> ws.status == :completed end)
  end

  defp progress_percentage(workstreams) do
    total = map_size(workstreams)
    if total == 0 do
      0
    else
      completed = completed_count(workstreams)
      trunc(completed / total * 100)
    end
  end
end
```

### 3. Add Communications Tab Component

**New Module**: `IpaWeb.Pod.Components.CommunicationsTab`

**Purpose**: Display messages, inbox, threads, and approval requests

```elixir
defmodule IpaWeb.Pod.Components.CommunicationsTab do
  use Phoenix.Component

  attr :task_id, :string, required: true
  attr :messages, :list, default: []
  attr :inbox, :list, default: []
  attr :selected_thread_id, :string, default: nil

  def render(assigns) do
    ~H"""
    <div class="flex h-[calc(100vh-200px)]">
      <!-- Left Sidebar: Inbox -->
      <div class="w-1/4 border-r border-gray-200 overflow-y-auto">
        <.inbox_panel inbox={@inbox} task_id={@task_id} />
      </div>

      <!-- Main Area: Message Threads -->
      <div class="flex-1 flex flex-col">
        <%= if @selected_thread_id do %>
          <.thread_view
            thread_id={@selected_thread_id}
            messages={@messages}
            task_id={@task_id}
          />
        <% else %>
          <.all_messages_view messages={@messages} task_id={@task_id} />
        <% end %>
      </div>
    </div>
    """
  end

  attr :inbox, :list, required: true
  attr :task_id, :string, required: true

  def inbox_panel(assigns) do
    ~H"""
    <div class="p-4">
      <h3 class="text-lg font-semibold mb-4">Inbox</h3>

      <!-- Unread Count -->
      <div class="mb-4 text-sm text-gray-600">
        <%= unread_count(@inbox) %> unread
      </div>

      <!-- Notification List -->
      <div class="space-y-2">
        <%= for notification <- @inbox do %>
          <.notification_item notification={notification} task_id={@task_id} />
        <% end %>

        <%= if Enum.empty?(@inbox) do %>
          <p class="text-sm text-gray-500 text-center py-8">
            No notifications
          </p>
        <% end %>
      </div>
    </div>
    """
  end

  attr :notification, :map, required: true
  attr :task_id, :string, required: true

  def notification_item(assigns) do
    ~H"""
    <button
      phx-click="select_notification"
      phx-value-notification_id={@notification.notification_id}
      phx-value-message_id={@notification.message_id}
      class={"w-full text-left p-3 rounded hover:bg-gray-50 #{if @notification.read?, do: "bg-white", else: "bg-blue-50"}"}
    >
      <div class="flex items-start justify-between">
        <div class="flex-1">
          <div class="flex items-center gap-2">
            <.notification_icon type={@notification.type} />
            <span class="text-xs font-semibold text-gray-700">
              <%= humanize_notification_type(@notification.type) %>
            </span>
          </div>
          <p class="text-sm text-gray-600 mt-1 line-clamp-2">
            <%= @notification.message_preview || "New message" %>
          </p>
          <span class="text-xs text-gray-400 mt-1">
            <%= format_timestamp(@notification.created_at) %>
          </span>
        </div>
        <%= if !@notification.read? do %>
          <div class="w-2 h-2 bg-blue-500 rounded-full"></div>
        <% end %>
      </div>
    </button>
    """
  end

  attr :messages, :list, required: true
  attr :task_id, :string, required: true

  def all_messages_view(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto p-6">
      <h3 class="text-lg font-semibold mb-4">All Messages</h3>

      <!-- Filter Tabs -->
      <div class="flex gap-4 mb-6 border-b">
        <button
          phx-click="filter_messages"
          phx-value-type="all"
          class="pb-2 px-1 border-b-2 border-blue-500 text-blue-600 font-medium"
        >
          All
        </button>
        <button
          phx-click="filter_messages"
          phx-value-type="approval"
          class="pb-2 px-1 text-gray-600"
        >
          Approvals
        </button>
        <button
          phx-click="filter_messages"
          phx-value-type="question"
          class="pb-2 px-1 text-gray-600"
        >
          Questions
        </button>
        <button
          phx-click="filter_messages"
          phx-value-type="blocker"
          class="pb-2 px-1 text-gray-600"
        >
          Blockers
        </button>
        <button
          phx-click="filter_messages"
          phx-value-type="update"
          class="pb-2 px-1 text-gray-600"
        >
          Updates
        </button>
      </div>

      <!-- Message List -->
      <div class="space-y-4">
        <%= for message <- @messages do %>
          <.message_card message={message} task_id={@task_id} />
        <% end %>
      </div>
    </div>
    """
  end

  attr :message, :map, required: true
  attr :task_id, :string, required: true

  def message_card(assigns) do
    ~H"""
    <div class={"card #{message_card_class(@message.type)}"}>
      <!-- Header -->
      <div class="flex items-start justify-between mb-2">
        <div class="flex items-center gap-2">
          <.message_type_badge type={@message.type} />
          <span class="text-sm font-semibold text-gray-700">
            <%= @message.author %>
          </span>
        </div>
        <span class="text-xs text-gray-400">
          <%= format_timestamp(@message.posted_at) %>
        </span>
      </div>

      <!-- Content -->
      <div class="text-sm text-gray-800 mb-3">
        <%= @message.content %>
      </div>

      <!-- Approval UI (if type == :approval) -->
      <%= if @message.type == :approval && !@message.approved? do %>
        <div class="mt-4 p-3 bg-yellow-50 rounded">
          <p class="text-sm font-semibold mb-2">Approval Required:</p>
          <p class="text-sm mb-3"><%= @message.approval_question %></p>
          <div class="flex flex-wrap gap-2">
            <%= for option <- @message.approval_options do %>
              <button
                phx-click="give_approval"
                phx-value-message_id={@message.message_id}
                phx-value-choice={option}
                class="btn-sm btn-primary"
              >
                <%= option %>
              </button>
            <% end %>
          </div>
        </div>
      <% end %>

      <%= if @message.type == :approval && @message.approved? do %>
        <div class="mt-3 p-2 bg-green-50 rounded text-sm">
          ✓ Approved: <strong><%= @message.approval_choice %></strong>
          by <%= @message.approval_given_by %>
        </div>
      <% end %>

      <!-- Thread Indicator -->
      <%= if @message.thread_id do %>
        <button
          phx-click="view_thread"
          phx-value-thread_id={@message.thread_id}
          class="text-xs text-blue-600 hover:underline mt-2"
        >
          View Thread
        </button>
      <% end %>

      <!-- Reply Button -->
      <button
        phx-click="reply_to_message"
        phx-value-message_id={@message.message_id}
        class="text-xs text-gray-600 hover:text-gray-800 mt-2"
      >
        Reply
      </button>
    </div>
    """
  end

  # Helper functions
  defp message_card_class(type) do
    case type do
      :approval -> "border-l-4 border-yellow-500"
      :question -> "border-l-4 border-blue-500"
      :blocker -> "border-l-4 border-red-500"
      :update -> "border-l-4 border-green-500"
    end
  end

  defp message_type_badge(assigns) do
    ~H"""
    <span class={badge_class(@type)}>
      <%= humanize_message_type(@type) %>
    </span>
    """
  end

  defp badge_class(type) do
    base = "px-2 py-1 text-xs font-semibold rounded"
    case type do
      :approval -> "#{base} bg-yellow-100 text-yellow-800"
      :question -> "#{base} bg-blue-100 text-blue-800"
      :blocker -> "#{base} bg-red-100 text-red-800"
      :update -> "#{base} bg-green-100 text-green-800"
    end
  end
end
```

### 4. Update LiveView Mount

**Add New Assigns**:

```elixir
def mount(%{"task_id" => task_id}, _session, socket) do
  case Ipa.Pod.State.get_state(task_id) do
    {:ok, state} ->
      if connected?(socket) do
        # Subscribe to pod state
        Ipa.Pod.State.subscribe(task_id)

        # Subscribe to communications (NEW)
        Phoenix.PubSub.subscribe(
          Ipa.PubSub,
          "pod:#{task_id}:communications"
        )
      end

      # Load messages and inbox (NEW)
      {:ok, messages} = Ipa.Pod.CommunicationsManager.get_messages(task_id, limit: 100)
      {:ok, inbox} = Ipa.Pod.CommunicationsManager.get_inbox(
        task_id,
        unread_only?: false
      )

      socket =
        socket
        |> assign(task_id: task_id)
        |> assign(state: state)
        |> assign(active_tab: :overview)  # NEW: default tab
        |> assign(messages: messages)     # NEW
        |> assign(inbox: inbox)            # NEW
        |> assign(selected_thread_id: nil) # NEW
        |> assign(message_filter: :all)    # NEW
        # ... existing assigns ...

      {:ok, socket}

    {:error, :not_found} ->
      {:ok,
       socket
       |> put_flash(:error, "Task not found")
       |> push_navigate(to: "/")}
  end
end
```

### 5. Add Communications Event Handlers

**New Handlers**:

```elixir
# Subscribe to communications pub-sub messages
def handle_info({:message_posted, _task_id, message}, socket) do
  messages = [message | socket.assigns.messages]
  {:noreply, assign(socket, messages: messages)}
end

def handle_info({:notification_created, _task_id, notification}, socket) do
  inbox = [notification | socket.assigns.inbox]
  {:noreply, assign(socket, inbox: inbox)}
end

def handle_info({:approval_given, _task_id, message_id, _approval}, socket) do
  # Update message in list to show approved status
  messages = Enum.map(socket.assigns.messages, fn msg ->
    if msg.message_id == message_id do
      Map.put(msg, :approved?, true)
    else
      msg
    end
  end)

  {:noreply, assign(socket, messages: messages)}
end

# Handler for giving approval via Communications UI
def handle_event("give_approval", %{"message_id" => msg_id, "choice" => choice}, socket) do
  user_id = socket.assigns.current_user.id

  case Ipa.Pod.CommunicationsManager.give_approval(
    socket.assigns.task_id,
    msg_id,
    approved_by: user_id,
    choice: choice
  ) do
    {:ok, _approval_id} ->
      {:noreply, put_flash(socket, :info, "Approval given: #{choice}")}

    {:error, reason} ->
      {:noreply, put_flash(socket, :error, "Failed to give approval: #{inspect(reason)}")}
  end
end

# Handler for marking notification as read
def handle_event("select_notification", %{"notification_id" => notif_id, "message_id" => msg_id}, socket) do
  # Mark as read
  :ok = Ipa.Pod.CommunicationsManager.mark_read(socket.assigns.task_id, notif_id)

  # Select the message/thread
  socket =
    socket
    |> assign(selected_thread_id: msg_id)
    |> assign(active_tab: :communications)

  {:noreply, socket}
end

# Handler for viewing thread
def handle_event("view_thread", %{"thread_id" => thread_id}, socket) do
  {:noreply, assign(socket, selected_thread_id: thread_id)}
end

# Handler for filtering messages
def handle_event("filter_messages", %{"type" => type}, socket) do
  type_atom = String.to_existing_atom(type)
  {:noreply, assign(socket, message_filter: type_atom)}
end
```

### 6. Update Plan Section Component

**Modify to Show Workstream Breakdown**:

```elixir
defmodule IpaWeb.Pod.Components.PlanSection do
  use Phoenix.Component

  attr :state, :map, required: true

  def render(assigns) do
    ~H"""
    <div class="card">
      <h2 class="text-xl font-semibold mb-4">Plan</h2>

      <%= if @state.plan do %>
        <!-- Workstream Breakdown -->
        <%= if @state.phase == :workstream_execution || @state.phase == :review do %>
          <div class="mb-4">
            <h3 class="text-lg font-medium mb-2">Workstream Breakdown</h3>
            <p class="text-sm text-gray-600 mb-3">
              Task broken down into <%= map_size(@state.workstreams) %> parallel workstreams:
            </p>
            <div class="space-y-2">
              <%= for {ws_id, ws} <- @state.workstreams do %>
                <div class="flex items-center gap-2 text-sm">
                  <.status_icon status={ws.status} />
                  <span class="font-medium"><%= ws_id %></span>
                  <span class="text-gray-600">- <%= ws.title || ws.spec |> String.slice(0..50) %></span>
                </div>
              <% end %>
            </div>
          </div>
        <% else %>
          <!-- Original Plan View (for planning phase) -->
          <div class="space-y-2">
            <%= for step <- @state.plan.steps do %>
              <div class="flex items-center gap-2">
                <.step_status_icon status={step.status} />
                <span class="text-sm"><%= step.description %></span>
                <span class="text-xs text-gray-500">(<%= step.estimated_hours %>h)</span>
              </div>
            <% end %>
          </div>
        <% end %>

        <!-- Approval Status -->
        <%= if @state.plan.approved? do %>
          <div class="mt-4 p-2 bg-green-50 rounded text-sm">
            ✓ Approved by <%= @state.plan.approved_by %> at <%= format_timestamp(@state.plan.approved_at) %>
          </div>
        <% else %>
          <button
            phx-click="approve_plan"
            disabled={@state.phase != :planning}
            class="btn-primary mt-4"
          >
            Approve Plan
          </button>
        <% end %>
      <% else %>
        <p class="text-gray-500">No plan generated yet</p>
      <% end %>
    </div>
    """
  end
end
```

### 7. Update Agent Monitor Component

**Group Agents by Workstream**:

```elixir
defmodule IpaWeb.Pod.Components.AgentMonitor do
  use Phoenix.Component

  attr :state, :map, required: true
  attr :selected_agent_id, :string, default: nil

  def render(assigns) do
    ~H"""
    <div class="card">
      <h2 class="text-xl font-semibold mb-4">Active Agents</h2>

      <%= if has_active_agents?(@state) do %>
        <!-- Group by Workstream -->
        <%= for {ws_id, agents} <- group_agents_by_workstream(@state) do %>
          <div class="mb-6">
            <h3 class="text-sm font-semibold text-gray-600 mb-2">
              Workstream: <%= ws_id %>
            </h3>
            <%= for agent <- agents do %>
              <.agent_card agent={agent} selected?={@selected_agent_id == agent.agent_id} />
            <% end %>
          </div>
        <% end %>

        <!-- Agents without workstream (old model) -->
        <%= for agent <- agents_without_workstream(@state) do %>
          <.agent_card agent={agent} selected?={@selected_agent_id == agent.agent_id} />
        <% end %>
      <% else %>
        <p class="text-gray-500">No active agents</p>
      <% end %>
    </div>
    """
  end

  defp group_agents_by_workstream(state) do
    # Group agents by their workstream_id
    state.agents
    |> Enum.filter(fn agent -> agent.workstream_id != nil end)
    |> Enum.group_by(fn agent -> agent.workstream_id end)
  end

  defp agents_without_workstream(state) do
    state.agents
    |> Enum.filter(fn agent -> agent.workstream_id == nil end)
  end
end
```

## Testing Updates

### New Unit Tests Required

1. **Tab Navigation Tests**:
   - Test tab switching
   - Test unread message badge display

2. **Workstreams Tab Tests**:
   - Test workstream card rendering
   - Test progress calculation
   - Test dependency display
   - Test blocking status display

3. **Communications Tab Tests**:
   - Test inbox rendering
   - Test unread count
   - Test notification selection
   - Test message filtering
   - Test approval UI rendering
   - Test approval submission

4. **Real-Time Updates Tests**:
   - Test receiving new messages via pub-sub
   - Test notification creation
   - Test approval updates

### Integration Tests

1. Test full workstream visualization flow
2. Test communications approval workflow
3. Test real-time message updates
4. Test tab switching with state preservation

## Migration Notes

**Backward Compatibility**:
- Old UI structure still works for tasks without workstreams
- Tab navigation defaults to Overview tab
- Workstreams tab only shows if `state.workstreams` exists
- Communications tab always visible (shows empty state if no messages)

**Graceful Degradation**:
- If Communications Manager (2.7) not available, show error message in Communications tab
- If workstreams not present in state, show simple plan view

## Implementation Checklist

### Week 1: Tab Navigation & Workstreams Tab
- [ ] Create tab navigation component
- [ ] Create workstreams tab component
- [ ] Create workstream card component
- [ ] Add dependency graph visualization
- [ ] Update mount/3 to load workstreams data
- [ ] Write unit tests for workstreams tab

### Week 2: Communications Tab
- [ ] Create communications tab component
- [ ] Create inbox panel component
- [ ] Create message card component
- [ ] Create thread view component
- [ ] Add approval UI components
- [ ] Subscribe to communications pub-sub
- [ ] Implement communication event handlers
- [ ] Write unit tests for communications tab

### Week 2-3: Integration & Polish
- [ ] Update plan section with workstream breakdown
- [ ] Update agent monitor to group by workstream
- [ ] Update task header with workstream status
- [ ] Add unread message count to badge
- [ ] Write integration tests
- [ ] Update tracker.md with progress
- [ ] Get spec review

## Estimated Effort

**Original**: 2-3 days
**Additional**: ~1.5 weeks (tab navigation + 2 new tabs + integrations)
**Total**: ~2 weeks

**Breakdown**:
- Tab navigation: 1 day
- Workstreams tab: 3 days
- Communications tab: 4 days
- Integration & testing: 2 days

## Dependencies

**Requires**:
- Component 2.2 (Pod State Manager) - refactored with workstream state
- Component 2.7 (Communications Manager) - for messages and inbox API
- Component 2.8 (CLAUDE.md Templates) - not directly used by UI, but referenced

**Blocked By**:
- Cannot implement Communications tab until 2.7 is complete
- Cannot implement Workstreams tab until 2.2 is refactored

## UI/UX Considerations

### Tab Navigation
- Use URL hash for tab state (e.g., `/pods/:task_id#workstreams`)
- Persist active tab in localStorage
- Show notification badges (unread counts)

### Workstreams Tab
- Color-code workstream status (pending, in_progress, blocked, completed, failed)
- Show dependency relationships clearly
- Highlight blocked workstreams
- Show agent assignment prominently

### Communications Tab
- Emphasize unread notifications
- Group messages by thread
- Show approval status clearly
- Make approval actions prominent (large buttons)
- Auto-refresh messages in real-time

### Responsive Design
- Tabs stack vertically on mobile
- Workstream cards single column on mobile
- Communications uses single column layout on mobile

## Performance Considerations

### Message Loading
- Load last 100 messages initially
- Implement pagination for older messages
- Use infinite scroll for message history

### Real-Time Updates
- Use LiveView's built-in diffing for efficient updates
- Only update changed components
- Use `phx-update="stream"` for message lists

### Memory
- Limit in-memory message cache to 100 messages
- Offload older messages to database queries

## Notes

- This is a **significant UI expansion** - adds ~40% more UI complexity
- Tab navigation improves information density
- Workstreams tab provides essential visibility for parallel execution
- Communications tab enables human-in-the-loop for agent coordination
- Real-time updates critical for multi-agent workflow visibility
- Consider accessibility (keyboard navigation, screen readers)
- Test on different screen sizes (mobile, tablet, desktop)
