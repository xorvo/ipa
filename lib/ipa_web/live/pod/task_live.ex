defmodule IpaWeb.Pod.TaskLive do
  @moduledoc """
  LiveView for displaying and interacting with a single task pod.

  Provides real-time visualization of:
  - Task state and phase
  - Workstreams with status and dependencies
  - Communications/messages
  - Approval workflows
  """
  use IpaWeb, :live_view

  alias Ipa.Pod.State
  alias Ipa.Pod.CommunicationsManager

  @impl true
  def mount(%{"task_id" => task_id}, _session, socket) do
    # Always read state from EventStore - single source of truth
    # This ensures we always see the latest events, whether or not the pod is running
    case State.get_state_from_events(task_id) do
      {:ok, state} ->
        # Check if pod is running for subscription purposes
        pod_running = State.get_state(task_id) != {:error, :not_found}

        # Subscribe to real-time updates when connected
        if connected?(socket) do
          State.subscribe(task_id)
          if pod_running, do: CommunicationsManager.subscribe(task_id)
        end

        socket =
          socket
          |> assign(task_id: task_id)
          |> assign(state: state)
          |> assign(active_tab: :overview)
          |> assign(selected_workstream_id: nil)
          |> assign(message_input: "")
          |> assign(editing_spec: false)
          |> assign(spec_description: state.spec[:description] || state.spec["description"] || "")

        {:ok, socket}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Task not found")
         |> push_navigate(to: "/")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  # Real-time state updates - always reload from EventStore for consistency
  @impl true
  def handle_info({:state_updated, _task_id, _new_state}, socket) do
    # Reload from EventStore to ensure we have the latest state
    reload_state(socket)
  end

  # Message posted event
  def handle_info({:message_posted, _task_id, _message}, socket) do
    reload_state(socket)
  end

  # Approval events
  def handle_info({:approval_requested, _task_id, _data}, socket) do
    reload_state(socket)
  end

  def handle_info({:approval_given, _task_id, _msg_id, _data}, socket) do
    reload_state(socket)
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Helper to reload state from EventStore
  defp reload_state(socket) do
    case State.get_state_from_events(socket.assigns.task_id) do
      {:ok, state} -> {:noreply, assign(socket, state: state)}
      _ -> {:noreply, socket}
    end
  end

  # Tab navigation
  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: String.to_atom(tab))}
  end

  # Spec approval
  def handle_event("approve_spec", _params, socket) do
    %{task_id: task_id} = socket.assigns

    # Use EventStore directly - works whether pod is running or not
    result = Ipa.EventStore.append(
      task_id,
      "spec_approved",
      %{approved_by: "user", approved_at: System.system_time(:second)},
      actor_id: "user"
    )

    case result do
      {:ok, _version} ->
        # Reload state from events to reflect the change
        case State.get_state_from_events(task_id) do
          {:ok, new_state} ->
            {:noreply,
             socket
             |> assign(state: new_state)
             |> put_flash(:info, "Spec approved")}

          {:error, _} ->
            {:noreply, put_flash(socket, :info, "Spec approved")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to approve spec: #{inspect(reason)}")}
    end
  end

  # Spec editing
  def handle_event("edit_spec", _params, socket) do
    {:noreply, assign(socket, editing_spec: true)}
  end

  def handle_event("cancel_spec_edit", _params, socket) do
    {:noreply, assign(socket, editing_spec: false)}
  end

  def handle_event("update_spec_description", params, socket) do
    # Handle both direct value changes and form changes
    value = params["description"] || params["value"] || ""
    {:noreply, assign(socket, spec_description: value)}
  end

  def handle_event("save_spec", _params, socket) do
    %{task_id: task_id, state: state, spec_description: description} = socket.assigns

    spec_data = %{
      description: description,
      requirements: state.spec[:requirements] || state.spec["requirements"] || [],
      acceptance_criteria: state.spec[:acceptance_criteria] || state.spec["acceptance_criteria"] || []
    }

    # Use EventStore directly - works whether pod is running or not
    result = Ipa.EventStore.append(
      task_id,
      "spec_updated",
      %{spec: spec_data},
      actor_id: "user"
    )

    case result do
      {:ok, _version} ->
        # Reload state from events to reflect the change
        case State.get_state_from_events(task_id) do
          {:ok, new_state} ->
            {:noreply,
             socket
             |> assign(state: new_state)
             |> assign(editing_spec: false)
             |> put_flash(:info, "Spec updated")}

          {:error, _} ->
            {:noreply,
             socket
             |> assign(editing_spec: false)
             |> put_flash(:info, "Spec updated")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update spec: #{inspect(reason)}")}
    end
  end

  # Plan approval
  def handle_event("approve_plan", _params, socket) do
    %{task_id: task_id} = socket.assigns

    # Use EventStore directly - works whether pod is running or not
    result = Ipa.EventStore.append(
      task_id,
      "plan_approved",
      %{approved_by: "user", approved_at: System.system_time(:second)},
      actor_id: "user"
    )

    case result do
      {:ok, _version} ->
        # Reload state from events to reflect the change
        case State.get_state_from_events(task_id) do
          {:ok, new_state} ->
            {:noreply,
             socket
             |> assign(state: new_state)
             |> put_flash(:info, "Plan approved")}

          {:error, _} ->
            {:noreply, put_flash(socket, :info, "Plan approved")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to approve plan: #{inspect(reason)}")}
    end
  end

  # Transition approval
  def handle_event("approve_transition", %{"to_phase" => to_phase}, socket) do
    %{task_id: task_id, state: state} = socket.assigns

    # Use EventStore directly - works whether pod is running or not
    # This avoids GenServer crashes when pod is stopped
    result = Ipa.EventStore.append(
      task_id,
      "transition_approved",
      %{
        from_phase: Atom.to_string(state.phase),
        to_phase: to_phase,
        approved_by: "user"
      },
      actor_id: "user"
    )

    case result do
      {:ok, _version} ->
        # Reload state from events to reflect the change
        case State.get_state_from_events(task_id) do
          {:ok, new_state} ->
            {:noreply,
             socket
             |> assign(state: new_state)
             |> put_flash(:info, "Transition to #{to_phase} approved")}

          {:error, _} ->
            {:noreply, put_flash(socket, :info, "Transition to #{to_phase} approved")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to approve transition: #{inspect(reason)}")}
    end
  end

  # Message input handling
  def handle_event("update_message", %{"value" => value}, socket) do
    {:noreply, assign(socket, message_input: value)}
  end

  # Post a message
  def handle_event("post_message", %{"type" => type}, socket) do
    %{task_id: task_id, message_input: content} = socket.assigns

    if String.trim(content) != "" do
      case CommunicationsManager.post_message(
             task_id,
             type: String.to_atom(type),
             content: content,
             author: "user"
           ) do
        {:ok, _msg_id} ->
          {:noreply, assign(socket, message_input: "")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to post message: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  # Give approval on a message
  def handle_event("give_approval", %{"message_id" => msg_id, "choice" => choice}, socket) do
    %{task_id: task_id} = socket.assigns

    case CommunicationsManager.give_approval(
           task_id,
           msg_id,
           approved_by: "user",
           choice: choice
         ) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Approval given")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to give approval: #{inspect(reason)}")}
    end
  end

  # Select workstream
  def handle_event("select_workstream", %{"id" => id}, socket) do
    {:noreply, assign(socket, selected_workstream_id: id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200">
      <!-- Header -->
      <header class="bg-base-100 shadow-sm border-b border-base-300">
        <div class="max-w-7xl mx-auto px-4 py-4">
          <div class="flex items-center justify-between">
            <div>
              <div class="flex items-center gap-3">
                <a href="/" class="text-base-content/60 hover:text-base-content">
                  <.icon name="hero-arrow-left" class="w-5 h-5" />
                </a>
                <h1 class="text-xl font-semibold text-base-content">
                  <%= @state.title || "Untitled Task" %>
                </h1>
              </div>
              <p class="text-sm text-base-content/60 mt-1">
                Task ID: <code class="bg-base-200 px-1 rounded"><%= @task_id %></code>
              </p>
            </div>
            <div class="flex items-center gap-3">
              <.phase_badge phase={@state.phase} />
              <.pod_status_badge task_id={@task_id} />
            </div>
          </div>
        </div>
      </header>

      <!-- Tab Navigation -->
      <div class="bg-base-100 border-b border-base-300">
        <div class="max-w-7xl mx-auto px-4">
          <nav class="flex gap-4">
            <.tab_button tab={:overview} active={@active_tab} label="Overview" />
            <.tab_button tab={:workstreams} active={@active_tab} label="Workstreams" count={workstream_count(@state)} />
            <.tab_button tab={:communications} active={@active_tab} label="Communications" count={unread_count(@state)} />
          </nav>
        </div>
      </div>

      <!-- Main Content -->
      <main class="max-w-7xl mx-auto px-4 py-6">
        <%= case @active_tab do %>
          <% :overview -> %>
            <.overview_tab state={@state} task_id={@task_id} editing_spec={@editing_spec} spec_description={@spec_description} />
          <% :workstreams -> %>
            <.workstreams_tab state={@state} selected_id={@selected_workstream_id} />
          <% :communications -> %>
            <.communications_tab state={@state} task_id={@task_id} message_input={@message_input} />
        <% end %>
      </main>
    </div>
    """
  end

  # Components

  defp phase_badge(assigns) do
    assigns = assign(assigns, :color, phase_color(assigns.phase))

    ~H"""
    <span class={"badge badge-lg #{@color}"}>
      <%= format_phase(@phase) %>
    </span>
    """
  end

  defp pod_status_badge(assigns) do
    assigns = assign(assigns, :running, Ipa.PodSupervisor.pod_running?(assigns.task_id))

    ~H"""
    <span class={if @running, do: "badge badge-success", else: "badge badge-ghost"}>
      <%= if @running, do: "Pod Running", else: "Pod Stopped" %>
    </span>
    """
  end

  defp tab_button(assigns) do
    active_class = if assigns.tab == assigns.active, do: "border-primary text-primary", else: "border-transparent text-base-content/60 hover:text-base-content"
    assigns = assign(assigns, :active_class, active_class)

    ~H"""
    <button
      phx-click="switch_tab"
      phx-value-tab={@tab}
      class={"px-4 py-3 border-b-2 font-medium text-sm #{@active_class}"}
    >
      <%= @label %>
      <%= if assigns[:count] && @count > 0 do %>
        <span class="ml-2 badge badge-sm badge-primary"><%= @count %></span>
      <% end %>
    </button>
    """
  end

  # Overview Tab
  defp overview_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Spec Section -->
      <.card title="Specification">
        <%= if @editing_spec do %>
          <!-- Edit Mode -->
          <form phx-submit="save_spec" class="space-y-4">
            <div>
              <label class="label">
                <span class="label-text font-medium">Description</span>
              </label>
              <textarea
                name="description"
                class="textarea textarea-bordered w-full h-32"
                placeholder="Describe the task specification..."
                phx-change="update_spec_description"
                phx-debounce="300"
              ><%= @spec_description %></textarea>
            </div>
            <div class="flex gap-2">
              <button type="submit" class="btn btn-primary btn-sm">
                Save Spec
              </button>
              <button type="button" phx-click="cancel_spec_edit" class="btn btn-ghost btn-sm">
                Cancel
              </button>
            </div>
          </form>
        <% else %>
          <!-- View Mode -->
          <%= if @state.spec do %>
            <div class="prose prose-sm max-w-none">
              <p><%= @state.spec[:description] || @state.spec["description"] || "No description" %></p>
              <%= if requirements = @state.spec[:requirements] || @state.spec["requirements"] do %>
                <h4>Requirements</h4>
                <ul>
                  <%= for req <- List.wrap(requirements) do %>
                    <li><%= req %></li>
                  <% end %>
                </ul>
              <% end %>
            </div>
            <%= if !(@state.spec[:approved?] || @state.spec["approved?"]) do %>
              <div class="mt-4 flex gap-2">
                <button phx-click="edit_spec" class="btn btn-outline btn-sm">
                  Edit Spec
                </button>
                <button phx-click="approve_spec" class="btn btn-primary btn-sm">
                  Approve Spec
                </button>
              </div>
            <% else %>
              <div class="mt-4 text-success flex items-center gap-2">
                <.icon name="hero-check-circle" class="w-5 h-5" />
                Spec Approved
              </div>
            <% end %>
          <% else %>
            <p class="text-base-content/60">No specification yet.</p>
            <div class="mt-4">
              <button phx-click="edit_spec" class="btn btn-outline btn-sm">
                Add Specification
              </button>
            </div>
          <% end %>
        <% end %>
      </.card>

      <!-- Plan Section -->
      <.card title="Plan">
        <%= if @state.plan do %>
          <%= if steps = @state.plan[:steps] || @state.plan["steps"] do %>
            <ol class="list-decimal list-inside space-y-2">
              <%= for step <- List.wrap(steps) do %>
                <li class="text-base-content"><%= format_step(step) %></li>
              <% end %>
            </ol>
          <% end %>
          <%= if !(@state.plan[:approved?] || @state.plan["approved?"]) do %>
            <div class="mt-4">
              <button phx-click="approve_plan" class="btn btn-primary btn-sm">
                Approve Plan
              </button>
            </div>
          <% else %>
            <div class="mt-4 text-success flex items-center gap-2">
              <.icon name="hero-check-circle" class="w-5 h-5" />
              Plan Approved
            </div>
          <% end %>
        <% else %>
          <p class="text-base-content/60">No plan yet.</p>
        <% end %>
      </.card>

      <!-- Phase Transitions -->
      <%= if pending_transition = get_pending_transition(@state) do %>
        <.card title="Pending Transition">
          <div class="alert alert-warning">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <span>Transition to <strong><%= pending_transition.to_phase %></strong> requires approval</span>
            <button
              phx-click="approve_transition"
              phx-value-to_phase={pending_transition.to_phase}
              class="btn btn-sm btn-warning"
            >
              Approve
            </button>
          </div>
        </.card>
      <% end %>

      <!-- Quick Stats -->
      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <.stat_card label="Workstreams" value={workstream_count(@state)} icon="hero-queue-list" />
        <.stat_card label="Active Agents" value={active_agent_count(@state)} icon="hero-cpu-chip" />
        <.stat_card label="Messages" value={message_count(@state)} icon="hero-chat-bubble-left-right" />
      </div>
    </div>
    """
  end

  # Workstreams Tab
  defp workstreams_tab(assigns) do
    workstreams = Map.values(assigns.state.workstreams || %{})
    selected_ws = if assigns.selected_id do
      Enum.find(workstreams, fn ws -> ws.workstream_id == assigns.selected_id end)
    end
    # Find the agent for this workstream
    selected_agent = if selected_ws do
      Enum.find(assigns.state.agents || [], fn a ->
        a.workstream_id == assigns.selected_id
      end)
    end

    assigns =
      assigns
      |> assign(:workstreams, workstreams)
      |> assign(:selected_ws, selected_ws)
      |> assign(:selected_agent, selected_agent)

    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
      <!-- Workstreams List -->
      <div class={if @selected_ws, do: "lg:col-span-1", else: "lg:col-span-3"}>
        <%= if Enum.empty?(@workstreams) do %>
          <div class="text-center py-12 text-base-content/60">
            <.icon name="hero-queue-list" class="w-12 h-12 mx-auto mb-4 opacity-50" />
            <p>No workstreams yet.</p>
            <p class="text-sm">Workstreams will be created during the planning phase.</p>
          </div>
        <% else %>
          <div class="space-y-3">
            <%= for ws <- @workstreams do %>
              <.workstream_card workstream={ws} selected={ws.workstream_id == @selected_id} />
            <% end %>
          </div>
        <% end %>
      </div>

      <!-- Workstream Details Panel -->
      <%= if @selected_ws do %>
        <div class="lg:col-span-2">
          <.workstream_details_panel
            workstream={@selected_ws}
            agent={@selected_agent}
            task_id={@state.task_id}
          />
        </div>
      <% end %>
    </div>
    """
  end

  defp workstream_card(assigns) do
    assigns = assign(assigns, :status_color, workstream_status_color(assigns.workstream.status))

    ~H"""
    <div
      class={"card bg-base-100 shadow-sm border cursor-pointer hover:shadow-md transition-shadow #{if @selected, do: "border-primary ring-2 ring-primary/20", else: "border-base-300"}"}
      phx-click="select_workstream"
      phx-value-id={@workstream.workstream_id}
    >
      <div class="card-body p-4">
        <div class="flex items-start justify-between">
          <div class="flex-1 min-w-0">
            <h3 class="font-medium truncate"><%= @workstream[:title] || @workstream.workstream_id %></h3>
            <%= if @workstream.spec do %>
              <p class="text-sm text-base-content/60 mt-1 line-clamp-2"><%= @workstream.spec %></p>
            <% end %>
          </div>
          <span class={"badge #{@status_color} ml-2 flex-shrink-0"}>
            <%= format_status(@workstream.status) %>
          </span>
        </div>

        <%= if deps = @workstream.dependencies do %>
          <%= if length(deps) > 0 do %>
            <div class="mt-3 flex items-center gap-2 text-sm text-base-content/60">
              <.icon name="hero-link" class="w-4 h-4" />
              <span>Depends on: <%= Enum.join(deps, ", ") %></span>
            </div>
          <% end %>
        <% end %>

        <%= if blocking = @workstream.blocking_on do %>
          <%= if length(blocking) > 0 do %>
            <div class="mt-2 text-sm text-warning flex items-center gap-2">
              <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
              <span>Blocked by: <%= Enum.join(blocking, ", ") %></span>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # Workstream Details Panel
  defp workstream_details_panel(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm border border-base-300">
      <div class="card-body">
        <!-- Header with close button -->
        <div class="flex items-start justify-between mb-4">
          <div>
            <h2 class="card-title text-lg flex items-center gap-2">
              <.icon name="hero-queue-list" class="w-5 h-5" />
              Workstream Details
            </h2>
            <p class="text-sm text-base-content/60 mt-1">
              <code class="bg-base-200 px-1 rounded"><%= @workstream.workstream_id %></code>
            </p>
          </div>
          <button phx-click="select_workstream" phx-value-id="" class="btn btn-ghost btn-sm btn-circle">
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>

        <!-- Status Badge -->
        <div class="flex items-center gap-2 mb-4">
          <span class="text-sm font-medium">Status:</span>
          <span class={"badge #{workstream_status_color(@workstream.status)}"}>
            <%= format_status(@workstream.status) %>
          </span>
        </div>

        <!-- Specification -->
        <%= if @workstream.spec do %>
          <div class="mb-4">
            <h3 class="font-medium text-sm mb-2 flex items-center gap-2">
              <.icon name="hero-document-text" class="w-4 h-4" />
              Specification
            </h3>
            <div class="bg-base-200 rounded-lg p-3 text-sm">
              <%= @workstream.spec %>
            </div>
          </div>
        <% end %>

        <!-- Workspace Information -->
        <%= if @workstream.workspace do %>
          <div class="mb-4">
            <h3 class="font-medium text-sm mb-2 flex items-center gap-2">
              <.icon name="hero-folder" class="w-4 h-4" />
              Workspace
            </h3>
            <.copyable_path path={@workstream.workspace} label="Workspace Path" />
          </div>
        <% else %>
          <!-- Try to construct workspace path from task_id and agent_id -->
          <%= if @agent && @agent.workspace do %>
            <div class="mb-4">
              <h3 class="font-medium text-sm mb-2 flex items-center gap-2">
                <.icon name="hero-folder" class="w-4 h-4" />
                Workspace
              </h3>
              <.copyable_path path={@agent.workspace} label="Workspace Path" />
            </div>
          <% else %>
            <div class="mb-4">
              <h3 class="font-medium text-sm mb-2 flex items-center gap-2 text-base-content/60">
                <.icon name="hero-folder" class="w-4 h-4" />
                Workspace
              </h3>
              <p class="text-sm text-base-content/60">No workspace created yet</p>
            </div>
          <% end %>
        <% end %>

        <!-- Agent Information -->
        <%= if @agent do %>
          <div class="mb-4">
            <h3 class="font-medium text-sm mb-2 flex items-center gap-2">
              <.icon name="hero-cpu-chip" class="w-4 h-4" />
              Agent
            </h3>
            <div class="bg-base-200 rounded-lg p-3 space-y-2">
              <div class="flex items-center justify-between">
                <span class="text-sm text-base-content/60">Agent ID:</span>
                <code class="text-xs bg-base-300 px-2 py-0.5 rounded"><%= @agent.agent_id %></code>
              </div>
              <div class="flex items-center justify-between">
                <span class="text-sm text-base-content/60">Type:</span>
                <span class="text-sm"><%= @agent.agent_type %></span>
              </div>
              <div class="flex items-center justify-between">
                <span class="text-sm text-base-content/60">Status:</span>
                <span class={"badge badge-sm #{agent_status_color(@agent.status)}"}>
                  <%= format_status(@agent.status) %>
                </span>
              </div>
              <%= if @agent.started_at do %>
                <div class="flex items-center justify-between">
                  <span class="text-sm text-base-content/60">Started:</span>
                  <span class="text-sm"><%= format_timestamp(@agent.started_at) %></span>
                </div>
              <% end %>
              <%= if @agent.completed_at do %>
                <div class="flex items-center justify-between">
                  <span class="text-sm text-base-content/60">Completed:</span>
                  <span class="text-sm"><%= format_timestamp(@agent.completed_at) %></span>
                </div>
              <% end %>
              <%= if @agent.error do %>
                <div class="mt-2 text-error text-sm">
                  <span class="font-medium">Error:</span> <%= @agent.error %>
                </div>
              <% end %>
            </div>
          </div>
        <% else %>
          <div class="mb-4">
            <h3 class="font-medium text-sm mb-2 flex items-center gap-2 text-base-content/60">
              <.icon name="hero-cpu-chip" class="w-4 h-4" />
              Agent
            </h3>
            <p class="text-sm text-base-content/60">No agent assigned yet</p>
          </div>
        <% end %>

        <!-- Dependencies -->
        <div class="mb-4">
          <h3 class="font-medium text-sm mb-2 flex items-center gap-2">
            <.icon name="hero-link" class="w-4 h-4" />
            Dependencies
          </h3>
          <%= if deps = @workstream.dependencies do %>
            <%= if length(deps) > 0 do %>
              <div class="flex flex-wrap gap-2">
                <%= for dep <- deps do %>
                  <span class="badge badge-outline"><%= dep %></span>
                <% end %>
              </div>
            <% else %>
              <p class="text-sm text-success">No dependencies - can start immediately</p>
            <% end %>
          <% else %>
            <p class="text-sm text-success">No dependencies - can start immediately</p>
          <% end %>
        </div>

        <!-- Blocking On -->
        <%= if blocking = @workstream.blocking_on do %>
          <%= if length(blocking) > 0 do %>
            <div class="mb-4">
              <h3 class="font-medium text-sm mb-2 flex items-center gap-2 text-warning">
                <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
                Blocked By
              </h3>
              <div class="flex flex-wrap gap-2">
                <%= for b <- blocking do %>
                  <span class="badge badge-warning badge-outline"><%= b %></span>
                <% end %>
              </div>
            </div>
          <% end %>
        <% end %>

        <!-- Timestamps -->
        <div class="border-t border-base-300 pt-4 mt-4">
          <h3 class="font-medium text-sm mb-2 flex items-center gap-2">
            <.icon name="hero-clock" class="w-4 h-4" />
            Timeline
          </h3>
          <div class="space-y-1 text-sm">
            <%= if @workstream.started_at do %>
              <div class="flex items-center justify-between">
                <span class="text-base-content/60">Started:</span>
                <span><%= format_timestamp(@workstream.started_at) %></span>
              </div>
            <% end %>
            <%= if @workstream.completed_at do %>
              <div class="flex items-center justify-between">
                <span class="text-base-content/60">Completed:</span>
                <span><%= format_timestamp(@workstream.completed_at) %></span>
              </div>
            <% end %>
            <%= if !@workstream.started_at && !@workstream.completed_at do %>
              <p class="text-base-content/60">Not started yet</p>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Copyable path component with click-to-copy
  defp copyable_path(assigns) do
    ~H"""
    <div class="bg-base-200 rounded-lg p-3">
      <div class="flex items-center justify-between gap-2">
        <code class="text-xs break-all flex-1"><%= @path %></code>
        <button
          phx-click={JS.dispatch("phx:copy", to: "#path-#{hash_path(@path)}")}
          class="btn btn-ghost btn-xs tooltip tooltip-left"
          data-tip="Copy path"
        >
          <.icon name="hero-clipboard-document" class="w-4 h-4" />
        </button>
      </div>
      <input type="hidden" id={"path-#{hash_path(@path)}"} value={@path} />
      <p class="text-xs text-base-content/60 mt-2"><%= @label %></p>
    </div>
    """
  end

  defp hash_path(path) do
    :crypto.hash(:md5, path) |> Base.encode16(case: :lower) |> String.slice(0, 8)
  end

  # Communications Tab
  defp communications_tab(assigns) do
    messages = assigns.state.messages || []
    inbox = assigns.state.inbox || []

    assigns =
      assigns
      |> assign(:messages, Enum.sort_by(messages, & &1.posted_at, :desc))
      |> assign(:inbox, inbox)

    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
      <!-- Messages List -->
      <div class="lg:col-span-2 space-y-4">
        <.card title="Messages">
          <!-- Message Input -->
          <div class="mb-4">
            <textarea
              class="textarea textarea-bordered w-full"
              placeholder="Type a message..."
              rows="2"
              phx-keyup="update_message"
              value={@message_input}
            ><%= @message_input %></textarea>
            <div class="flex gap-2 mt-2">
              <button phx-click="post_message" phx-value-type="update" class="btn btn-sm btn-ghost">
                Post Update
              </button>
              <button phx-click="post_message" phx-value-type="question" class="btn btn-sm btn-info">
                Ask Question
              </button>
            </div>
          </div>

          <!-- Messages -->
          <div class="space-y-3 max-h-96 overflow-y-auto">
            <%= if Enum.empty?(@messages) do %>
              <p class="text-center text-base-content/60 py-4">No messages yet.</p>
            <% else %>
              <%= for msg <- @messages do %>
                <.message_item message={msg} />
              <% end %>
            <% end %>
          </div>
        </.card>
      </div>

      <!-- Inbox / Pending Approvals -->
      <div class="space-y-4">
        <.card title="Inbox">
          <%= if Enum.empty?(@inbox) do %>
            <p class="text-center text-base-content/60 py-4">No notifications.</p>
          <% else %>
            <div class="space-y-2">
              <%= for notification <- @inbox do %>
                <.inbox_item notification={notification} messages={@messages} />
              <% end %>
            </div>
          <% end %>
        </.card>

        <!-- Pending Approvals -->
        <.card title="Pending Approvals">
          <% pending = Enum.filter(@messages, fn m -> m.type == :approval && !m.approved? end) %>
          <%= if Enum.empty?(pending) do %>
            <p class="text-center text-base-content/60 py-4">No pending approvals.</p>
          <% else %>
            <div class="space-y-3">
              <%= for approval <- pending do %>
                <.approval_item approval={approval} />
              <% end %>
            </div>
          <% end %>
        </.card>
      </div>
    </div>
    """
  end

  defp message_item(assigns) do
    assigns = assign(assigns, :type_badge, message_type_badge(assigns.message.type))

    ~H"""
    <div class="bg-base-200 rounded-lg p-3">
      <div class="flex items-start justify-between">
        <div class="flex items-center gap-2">
          <span class={"badge badge-sm #{@type_badge}"}><%= @message.type %></span>
          <span class="text-sm font-medium"><%= @message.author %></span>
        </div>
        <span class="text-xs text-base-content/60">
          <%= format_timestamp(@message.posted_at) %>
        </span>
      </div>
      <p class="mt-2 text-sm"><%= @message.content %></p>
    </div>
    """
  end

  defp inbox_item(assigns) do
    msg = Enum.find(assigns.messages, fn m -> m.message_id == assigns.notification.message_id end)
    assigns = assign(assigns, :message, msg)

    ~H"""
    <div class={"p-2 rounded border #{if @notification.read?, do: "border-base-300 bg-base-100", else: "border-warning bg-warning/10"}"}>
      <div class="flex items-center gap-2">
        <.icon name={notification_icon(@notification.type)} class="w-4 h-4" />
        <span class="text-sm font-medium"><%= format_notification_type(@notification.type) %></span>
      </div>
      <%= if @message do %>
        <p class="text-xs text-base-content/60 mt-1 line-clamp-1"><%= @message.content %></p>
      <% end %>
    </div>
    """
  end

  defp approval_item(assigns) do
    ~H"""
    <div class="border border-warning rounded-lg p-3 bg-warning/5">
      <p class="font-medium text-sm"><%= @approval.content %></p>
      <p class="text-xs text-base-content/60 mt-1">From: <%= @approval.author %></p>
      <%= if options = @approval.approval_options do %>
        <div class="flex gap-2 mt-3">
          <%= for option <- options do %>
            <button
              phx-click="give_approval"
              phx-value-message_id={@approval.message_id}
              phx-value-choice={option}
              class="btn btn-sm btn-outline"
            >
              <%= option %>
            </button>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # Generic Card Component
  defp card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm border border-base-300">
      <div class="card-body">
        <%= if assigns[:title] do %>
          <h2 class="card-title text-lg"><%= @title %></h2>
        <% end %>
        <%= render_slot(@inner_block) %>
      </div>
    </div>
    """
  end

  defp stat_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm border border-base-300">
      <div class="card-body p-4">
        <div class="flex items-center gap-3">
          <div class="bg-primary/10 p-2 rounded-lg">
            <.icon name={@icon} class="w-6 h-6 text-primary" />
          </div>
          <div>
            <p class="text-2xl font-bold"><%= @value %></p>
            <p class="text-sm text-base-content/60"><%= @label %></p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Helper Functions

  defp phase_color(phase) do
    case phase do
      :spec_clarification -> "badge-info"
      :planning -> "badge-warning"
      :workstream_execution -> "badge-accent"
      :executing -> "badge-accent"
      :integration -> "badge-secondary"
      :review -> "badge-primary"
      :completed -> "badge-success"
      :cancelled -> "badge-error"
      _ -> "badge-ghost"
    end
  end

  defp format_phase(phase) do
    phase
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp workstream_status_color(status) do
    case status do
      :pending -> "badge-ghost"
      :in_progress -> "badge-info"
      :blocked -> "badge-warning"
      :completed -> "badge-success"
      :failed -> "badge-error"
      _ -> "badge-ghost"
    end
  end

  defp agent_status_color(status) do
    case status do
      :running -> "badge-info"
      :completed -> "badge-success"
      :failed -> "badge-error"
      :interrupted -> "badge-warning"
      _ -> "badge-ghost"
    end
  end

  defp format_status(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp format_step(step) when is_binary(step), do: step
  defp format_step(%{description: desc}), do: desc
  defp format_step(%{"description" => desc}), do: desc
  defp format_step(step), do: inspect(step)

  defp message_type_badge(type) do
    case type do
      :question -> "badge-info"
      :approval -> "badge-warning"
      :update -> "badge-ghost"
      :blocker -> "badge-error"
      _ -> "badge-ghost"
    end
  end

  defp notification_icon(type) do
    case type do
      :needs_approval -> "hero-exclamation-circle"
      :question_asked -> "hero-question-mark-circle"
      :blocker_raised -> "hero-x-circle"
      _ -> "hero-bell"
    end
  end

  defp format_notification_type(type) do
    case type do
      :needs_approval -> "Needs Approval"
      :question_asked -> "Question Asked"
      :blocker_raised -> "Blocker Raised"
      _ -> to_string(type)
    end
  end

  defp format_timestamp(unix) when is_integer(unix) do
    unix
    |> DateTime.from_unix!()
    |> Calendar.strftime("%b %d, %H:%M")
  end
  defp format_timestamp(_), do: ""

  defp workstream_count(state) do
    state.workstreams |> Map.values() |> length()
  rescue
    _ -> 0
  end

  defp active_agent_count(state) do
    (state.agents || [])
    |> Enum.count(fn a -> a.status == :running end)
  rescue
    _ -> 0
  end

  defp message_count(state) do
    length(state.messages || [])
  end

  defp unread_count(state) do
    (state.inbox || [])
    |> Enum.count(fn n -> !n.read? end)
  rescue
    _ -> 0
  end

  defp get_pending_transition(state) do
    # Get the first pending transition from the list
    case state[:pending_transitions] || state.pending_transitions do
      [first | _] -> first
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
