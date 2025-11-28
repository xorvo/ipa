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

  alias Ipa.Pod.Manager

  require Logger

  @impl true
  def mount(%{"task_id" => task_id}, _session, socket) do
    # Always read state from EventStore - single source of truth
    # This ensures we always see the latest events, whether or not the pod is running
    case Manager.get_state_from_events(task_id) do
      {:ok, state} ->
        # Subscribe to real-time updates when connected
        if connected?(socket) do
          # Subscribe to EventStore broadcasts - this is the primary real-time channel
          # Works regardless of whether the pod is running
          Ipa.EventStore.subscribe(task_id)

          # Subscribe to Pod.Manager for when pod is running
          Manager.subscribe(task_id)

          # Subscribe to UI events from nested LiveViews (agent selection, etc.)
          Phoenix.PubSub.subscribe(Ipa.PubSub, "task:#{task_id}:ui")

          # Auto-start pod if task is in an active phase and pod is not running
          # This ensures the task continues processing when viewed
          maybe_auto_start_pod(task_id, state.phase)
        end

        # Load events for the Events tab
        {:ok, events} = Ipa.EventStore.read_stream(task_id)

        socket =
          socket
          |> assign(task_id: task_id)
          |> assign(state: state)
          |> assign(active_tab: :overview)
          |> assign(selected_workstream_id: nil)
          |> assign(message_input: "")
          |> assign(editing_spec: false)
          |> assign(spec_description: state.spec[:description] || state.spec["description"] || "")
          |> assign(events: Enum.reverse(events))
          |> assign(event_filter: "all")
          |> assign(selected_event: nil)
          |> assign(show_debug_modal: false)

        {:ok, socket}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Task not found")
         |> push_navigate(to: "/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Parse tab from URL params, default to :overview
    tab = parse_tab(params["tab"])

    # Parse selected agent from URL params (for agent detail modal)
    selected_agent_id = params["agent"]

    # Parse selected workstream from URL params
    selected_workstream_id = params["workstream"]

    {:noreply,
     socket
     |> assign(active_tab: tab)
     |> assign(selected_agent_id: selected_agent_id)
     |> assign(selected_workstream_id: selected_workstream_id)}
  end

  @valid_tabs ~w(overview workstreams agents communications events)a
  defp parse_tab(nil), do: :overview

  defp parse_tab(tab_str) when is_binary(tab_str) do
    tab = String.to_existing_atom(tab_str)
    if tab in @valid_tabs, do: tab, else: :overview
  rescue
    _ -> :overview
  end

  # Build URL with query params for state persistence
  defp build_url(socket, updates) do
    task_id = socket.assigns.task_id
    current_tab = socket.assigns.active_tab
    current_agent = socket.assigns[:selected_agent_id]
    current_workstream = socket.assigns[:selected_workstream_id]

    # Apply updates
    tab = Keyword.get(updates, :tab, current_tab)
    agent = Keyword.get(updates, :agent, current_agent)
    workstream = Keyword.get(updates, :workstream, current_workstream)

    # Build query params - only include non-nil values and non-default tab
    params =
      []
      |> then(fn p -> if tab && tab != :overview, do: [{:tab, tab} | p], else: p end)
      |> then(fn p -> if agent, do: [{:agent, agent} | p], else: p end)
      |> then(fn p -> if workstream, do: [{:workstream, workstream} | p], else: p end)

    if Enum.empty?(params) do
      ~p"/pods/#{task_id}"
    else
      query = URI.encode_query(params)
      "/pods/#{task_id}?#{query}"
    end
  end

  # ============================================================================
  # Real-time event handling via PubSub
  # ============================================================================

  # Primary real-time channel: EventStore broadcasts
  # This fires whenever ANY event is appended, regardless of pod state
  @impl true
  def handle_info({:event_appended, task_id, event}, socket)
      when task_id == socket.assigns.task_id do
    # Add the new event to the events list
    events = [event | socket.assigns.events]

    # Rebuild state from the new event
    # For efficiency, we apply the event to the current state instead of replaying all events
    new_state = apply_event_to_state(event, socket.assigns.state)

    {:noreply,
     socket
     |> assign(state: new_state)
     |> assign(events: events)
     |> assign(
       spec_description:
         new_state.spec[:description] || new_state.spec["description"] ||
           socket.assigns.spec_description
     )}
  end

  # Handle agent selection from nested AgentPanelLive
  # Updates URL to persist agent selection across page reloads
  def handle_info({:select_agent, agent_id}, socket) do
    {:noreply, push_patch(socket, to: build_url(socket, agent: agent_id))}
  end

  # State updates from State GenServer (when pod is running)
  # These are still useful for state changes that come through the pod
  def handle_info({:state_updated, _task_id, new_state}, socket) do
    {:noreply,
     socket
     |> assign(state: new_state)
     |> assign(
       spec_description:
         new_state.spec[:description] || new_state.spec["description"] ||
           socket.assigns.spec_description
     )}
  end

  # Message posted event from CommunicationsManager
  def handle_info({:message_posted, _task_id, _message}, socket) do
    reload_state(socket)
  end

  # Approval events from CommunicationsManager
  def handle_info({:approval_requested, _task_id, _data}, socket) do
    reload_state(socket)
  end

  def handle_info({:approval_given, _task_id, _msg_id, _data}, socket) do
    reload_state(socket)
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Apply a single event to the current state for incremental updates
  # This mirrors the State module's apply_event logic but is simplified for common cases
  defp apply_event_to_state(event, state) do
    case event.event_type do
      "spec_updated" ->
        spec_data = event.data[:spec] || event.data

        new_spec = %{
          state.spec
          | description: spec_data[:description] || state.spec[:description],
            requirements: spec_data[:requirements] || state.spec[:requirements] || [],
            acceptance_criteria:
              spec_data[:acceptance_criteria] || state.spec[:acceptance_criteria] || []
        }

        %{state | spec: new_spec, version: event.version, updated_at: event.inserted_at}

      "spec_approved" ->
        new_spec = %{
          state.spec
          | approved?: true,
            approved_by: event.data[:approved_by],
            approved_at: event.inserted_at
        }

        %{state | spec: new_spec, version: event.version, updated_at: event.inserted_at}

      "plan_approved" when state.plan != nil ->
        new_plan =
          state.plan
          |> Map.put(:approved?, true)
          |> Map.put(:approved_by, event.data[:approved_by])
          |> Map.put(:approved_at, event.inserted_at)

        %{state | plan: new_plan, version: event.version, updated_at: event.inserted_at}

      "transition_requested" ->
        to_phase = normalize_phase(event.data[:to_phase])
        transition = %{to_phase: to_phase, reason: event.data[:reason]}
        current_transitions = state.pending_transitions || []

        %{
          state
          | pending_transitions: [transition | current_transitions],
            version: event.version,
            updated_at: event.inserted_at
        }

      "transition_approved" ->
        to_phase = normalize_phase(event.data[:to_phase])

        %{
          state
          | phase: to_phase,
            pending_transitions: [],
            version: event.version,
            updated_at: event.inserted_at
        }

      "phase_changed" ->
        to_phase = normalize_phase(event.data[:to_phase])

        %{
          state
          | phase: to_phase,
            pending_transitions: [],
            version: event.version,
            updated_at: event.inserted_at
        }

      _ ->
        # For other event types, do a full reload to ensure consistency
        # This is safe because we still have the event for the events list
        case Manager.get_state_from_events(state.task_id) do
          {:ok, new_state} -> new_state
          _ -> %{state | version: event.version, updated_at: event.inserted_at}
        end
    end
  end

  @valid_phases ~w(spec_clarification planning workstream_execution review completed cancelled)a
  defp normalize_phase(phase) when phase in @valid_phases, do: phase

  defp normalize_phase(phase) when is_binary(phase) do
    atom = String.to_existing_atom(phase)

    if atom in @valid_phases do
      atom
    else
      raise ArgumentError, "Invalid phase: #{inspect(phase)}"
    end
  end

  defp normalize_phase(other) do
    raise ArgumentError, "Invalid phase type: #{inspect(other)}"
  end

  # Helper to reload state from EventStore
  defp reload_state(socket) do
    task_id = socket.assigns.task_id

    case Manager.get_state_from_events(task_id) do
      {:ok, state} ->
        # Also reload events
        {:ok, events} = Ipa.EventStore.read_stream(task_id)
        {:noreply, socket |> assign(state: state) |> assign(events: Enum.reverse(events))}

      _ ->
        {:noreply, socket}
    end
  end

  # Tab navigation - use push_patch to update URL
  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: build_url(socket, tab: tab))}
  end

  # Spec approval
  def handle_event("approve_spec", _params, socket) do
    %{task_id: task_id} = socket.assigns

    # Route through Manager - ensures consistent event handling
    with :ok <- ensure_pod_running(task_id),
         {:ok, _version} <-
           Manager.execute(task_id, Ipa.Pod.Commands.TaskCommands, :approve_spec, ["user", nil]) do
      {:noreply, put_flash(socket, :info, "Spec approved")}
    else
      {:error, :already_approved} ->
        {:noreply, put_flash(socket, :info, "Spec already approved")}

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
      acceptance_criteria:
        state.spec[:acceptance_criteria] || state.spec["acceptance_criteria"] || []
    }

    # Route through Manager
    with :ok <- ensure_pod_running(task_id),
         {:ok, _version} <-
           Manager.execute(task_id, Ipa.Pod.Commands.TaskCommands, :update_spec, [spec_data]) do
      {:noreply,
       socket
       |> assign(editing_spec: false)
       |> put_flash(:info, "Spec updated")}
    else
      {:error, :spec_already_approved} ->
        {:noreply,
         socket
         |> assign(editing_spec: false)
         |> put_flash(:error, "Cannot edit approved spec")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update spec: #{inspect(reason)}")}
    end
  end

  # Plan approval
  def handle_event("approve_plan", _params, socket) do
    %{task_id: task_id} = socket.assigns

    # Route through Manager
    with :ok <- ensure_pod_running(task_id),
         {:ok, _version} <-
           Manager.execute(task_id, Ipa.Pod.Commands.TaskCommands, :approve_plan, ["user", nil]) do
      {:noreply, put_flash(socket, :info, "Plan approved")}
    else
      {:error, :already_approved} ->
        {:noreply, put_flash(socket, :info, "Plan already approved")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to approve plan: #{inspect(reason)}")}
    end
  end

  # Transition approval
  def handle_event("approve_transition", %{"to_phase" => to_phase}, socket) do
    %{task_id: task_id} = socket.assigns

    # Convert to atom for PhaseCommands
    to_phase_atom =
      if is_binary(to_phase), do: String.to_existing_atom(to_phase), else: to_phase

    # Route through Manager
    with :ok <- ensure_pod_running(task_id),
         {:ok, _version} <-
           Manager.execute(task_id, Ipa.Pod.Commands.PhaseCommands, :approve_transition, [
             to_phase_atom,
             "user"
           ]) do
      {:noreply, put_flash(socket, :info, "Transition to #{to_phase} approved")}
    else
      {:error, :no_pending_transition} ->
        {:noreply, put_flash(socket, :error, "No pending transition to approve")}

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
      # Build params map for the command
      # post_message(state, params) expects params map with :type, :content, :author, :thread_id
      params = %{
        type: type,
        content: content,
        author: "user",
        thread_id: nil
      }

      # Route through Manager
      with :ok <- ensure_pod_running(task_id),
           {:ok, _version} <-
             Manager.execute(task_id, Ipa.Pod.Commands.CommunicationCommands, :post_message, [
               params
             ]) do
        {:noreply, assign(socket, message_input: "")}
      else
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

    # Route through Manager
    with :ok <- ensure_pod_running(task_id),
         {:ok, _version} <-
           Manager.execute(task_id, Ipa.Pod.Commands.CommunicationCommands, :give_approval, [
             msg_id,
             choice,
             "user"
           ]) do
      {:noreply, put_flash(socket, :info, "Approval given")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to give approval: #{inspect(reason)}")}
    end
  end

  # Select workstream - use push_patch to update URL
  def handle_event("select_workstream", %{"id" => id}, socket) do
    workstream_id = if id == "", do: nil, else: id
    {:noreply, push_patch(socket, to: build_url(socket, workstream: workstream_id))}
  end

  # Event filtering
  def handle_event("filter_events", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, event_filter: filter)}
  end

  # Select event for details view
  def handle_event("select_event", %{"version" => version}, socket) do
    version = String.to_integer(version)
    event = Enum.find(socket.assigns.events, fn e -> e.version == version end)
    {:noreply, assign(socket, selected_event: event)}
  end

  # Clear selected event
  def handle_event("clear_selected_event", _params, socket) do
    {:noreply, assign(socket, selected_event: nil)}
  end

  # Start pod
  def handle_event("start_pod", _params, socket) do
    %{task_id: task_id} = socket.assigns

    case Ipa.CentralManager.start_pod(task_id) do
      {:ok, _pid} ->
        {:noreply, put_flash(socket, :info, "Pod started")}

      {:error, {:already_started, _}} ->
        {:noreply, put_flash(socket, :info, "Pod already running")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start pod: #{inspect(reason)}")}
    end
  end

  # Stop pod
  def handle_event("stop_pod", _params, socket) do
    %{task_id: task_id} = socket.assigns

    case Ipa.CentralManager.stop_pod(task_id) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Pod stopped")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to stop pod: #{inspect(reason)}")}
    end
  end

  def handle_event("show_debug_modal", _params, socket) do
    {:noreply, assign(socket, show_debug_modal: true)}
  end

  def handle_event("hide_debug_modal", _params, socket) do
    {:noreply, assign(socket, show_debug_modal: false)}
  end

  # Open workspace in editor
  def handle_event("open_in_editor", %{"path" => path}, socket) do
    case Application.get_env(:ipa, :editor_command) do
      nil ->
        {:noreply, put_flash(socket, :error, "No editor configured. Set :editor_command in config.")}

      editor when is_binary(editor) ->
        # Run editor command in background (don't block LiveView)
        Task.start(fn ->
          case System.cmd(editor, [path], stderr_to_stdout: true) do
            {_output, 0} ->
              Logger.info("Opened #{path} in #{editor}")

            {output, exit_code} ->
              Logger.warning("Failed to open editor: exit code #{exit_code}, output: #{output}")
          end
        end)

        {:noreply, put_flash(socket, :info, "Opening in #{editor}...")}
    end
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
                  {@state.title || "Untitled Task"}
                </h1>
                <.pod_status_badge task_id={@task_id} />
              </div>
              <p class="text-sm text-base-content/60 mt-1">
                Task ID: <code class="bg-base-200 px-1 rounded">{@task_id}</code>
              </p>
            </div>
            <div class="flex items-center gap-2">
              <button
                phx-click="show_debug_modal"
                class="btn btn-sm btn-outline gap-1"
                title="View raw pod state"
              >
                <.icon name="hero-code-bracket" class="w-4 h-4" /> Debug
              </button>
              <.pod_control_button task_id={@task_id} />
            </div>
          </div>
        </div>
      </header>
      
    <!-- Phase Progress Indicator -->
      <div class="bg-base-100 border-b border-base-300 px-8 py-3">
        <.phase_progress_indicator current_phase={@state.phase} />
      </div>
      
    <!-- Tab Navigation -->
      <div class="bg-base-100 border-b border-base-300">
        <div class="max-w-7xl mx-auto px-4">
          <nav class="flex gap-4">
            <.tab_button tab={:overview} active={@active_tab} label="Overview" />
            <.tab_button
              tab={:workstreams}
              active={@active_tab}
              label="Workstreams"
              count={workstream_count(@state)}
            />
            <.tab_button
              tab={:agents}
              active={@active_tab}
              label="Agents"
              count={agent_count(@state)}
            />
            <.tab_button
              tab={:communications}
              active={@active_tab}
              label="Communications"
              count={unread_count(@state)}
            />
            <.tab_button tab={:events} active={@active_tab} label="Events" count={length(@events)} />
          </nav>
        </div>
      </div>
      
    <!-- Main Content -->
      <main class="max-w-7xl mx-auto px-4 py-6">
        <%= case @active_tab do %>
          <% :overview -> %>
            <.overview_tab
              state={@state}
              task_id={@task_id}
              editing_spec={@editing_spec}
              spec_description={@spec_description}
            />
          <% :workstreams -> %>
            <.workstreams_tab state={@state} selected_id={@selected_workstream_id} />
          <% :agents -> %>
            {live_render(@socket, IpaWeb.Pod.AgentPanelLive,
              id: "agent-panel",
              session: %{"task_id" => @task_id, "selected_agent_id" => @selected_agent_id}
            )}
          <% :communications -> %>
            <.communications_tab state={@state} task_id={@task_id} message_input={@message_input} />
          <% :events -> %>
            <.events_tab
              events={@events}
              event_filter={@event_filter}
              selected_event={@selected_event}
            />
        <% end %>
      </main>
      
    <!-- Debug Modal -->
      <%= if @show_debug_modal do %>
        <div class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/50">
          <!-- Backdrop click handler -->
          <div class="absolute inset-0" phx-click="hide_debug_modal"></div>
          <!-- Modal content -->
          <div class="relative bg-base-100 rounded-lg shadow-xl w-full max-w-4xl max-h-[80vh] flex flex-col">
            <div class="flex items-center justify-between p-4 border-b border-base-300">
              <h3 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-code-bracket" class="w-5 h-5" /> Raw Pod State
              </h3>
              <button phx-click="hide_debug_modal" class="btn btn-ghost btn-sm btn-circle">
                <.icon name="hero-x-mark" class="w-5 h-5" />
              </button>
            </div>
            <div class="flex-1 overflow-auto p-4">
              <pre class="text-xs font-mono bg-base-200 p-4 rounded whitespace-pre-wrap break-all"><%= inspect(@state, pretty: true, limit: :infinity, printable_limit: :infinity) %></pre>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # Components

  # Pod status badge (shown next to title)
  defp pod_status_badge(assigns) do
    assigns = assign(assigns, :running, Ipa.PodSupervisor.pod_running?(assigns.task_id))

    ~H"""
    <%= if @running do %>
      <span class="badge badge-success gap-1">
        <span class="w-2 h-2 bg-success-content rounded-full animate-pulse"></span> Running
      </span>
    <% else %>
      <span class="badge badge-ghost">Stopped</span>
    <% end %>
    """
  end

  # Pod control button (Start/Stop)
  defp pod_control_button(assigns) do
    assigns = assign(assigns, :running, Ipa.PodSupervisor.pod_running?(assigns.task_id))

    ~H"""
    <%= if @running do %>
      <button phx-click="stop_pod" class="btn btn-sm btn-outline btn-error gap-1">
        <.icon name="hero-stop" class="w-4 h-4" /> Stop
      </button>
    <% else %>
      <button phx-click="start_pod" class="btn btn-sm btn-outline btn-success gap-1">
        <.icon name="hero-play" class="w-4 h-4" /> Start
      </button>
    <% end %>
    """
  end

  # Phase progress indicator showing all stages
  defp phase_progress_indicator(assigns) do
    phases = [:spec_clarification, :planning, :workstream_execution, :review, :completed]
    current_index = Enum.find_index(phases, &(&1 == assigns.current_phase)) || 0

    assigns =
      assigns
      |> assign(:phases, phases)
      |> assign(:current_index, current_index)

    ~H"""
    <div class="flex gap-1">
      <%= for {phase, index} <- Enum.with_index(@phases) do %>
        <div class="flex-1 flex flex-col gap-1">
          <!-- Progress segment -->
          <div class={[
            "h-2 rounded transition-all",
            cond do
              index < @current_index -> "bg-success"
              index == @current_index -> "bg-primary"
              true -> "bg-base-300"
            end
          ]} />
          <!-- Label -->
          <span class={[
            "text-xs text-center",
            cond do
              index < @current_index -> "text-success font-medium"
              index == @current_index -> "text-primary font-semibold"
              true -> "text-base-content/50"
            end
          ]}>
            {format_phase_short(phase)}
          </span>
        </div>
      <% end %>
    </div>
    """
  end

  defp tab_button(assigns) do
    active_class =
      if assigns.tab == assigns.active,
        do: "border-primary text-primary",
        else: "border-transparent text-base-content/60 hover:text-base-content"

    assigns = assign(assigns, :active_class, active_class)

    ~H"""
    <button
      phx-click="switch_tab"
      phx-value-tab={@tab}
      class={"px-4 py-3 border-b-2 font-medium text-sm #{@active_class}"}
    >
      {@label}
      <%= if assigns[:count] && @count > 0 do %>
        <span class="ml-2 badge badge-sm badge-primary">{@count}</span>
      <% end %>
    </button>
    """
  end

  # Overview Tab
  defp overview_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Pending Transition Banner -->
      <%= if pending_transition = get_pending_transition(@state) do %>
        <div class="flex items-center justify-between p-4 bg-warning/10 rounded-lg border border-warning/30">
          <div class="flex items-center gap-3">
            <div class="bg-warning/20 p-2 rounded-lg">
              <.icon name="hero-arrow-right-circle" class="w-5 h-5 text-warning" />
            </div>
            <div>
              <span class="text-sm text-base-content/70">Ready to move to</span>
              <span class="font-medium ml-1">{format_phase(pending_transition.to_phase)}</span>
            </div>
          </div>
          <button
            phx-click="approve_transition"
            phx-value-to_phase={pending_transition.to_phase}
            class="btn btn-sm btn-warning"
          >
            Continue
          </button>
        </div>
      <% end %>

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
              <p>{@state.spec[:description] || @state.spec["description"] || "No description"}</p>
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
                <.icon name="hero-check-circle" class="w-5 h-5" /> Spec Approved
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
          <!-- Display workstreams from planning agent -->
          <%= if workstreams = @state.plan[:workstreams] || @state.plan["workstreams"] do %>
            <div class="space-y-4">
              <h4 class="font-medium text-base-content/80">Workstreams</h4>
              <div class="space-y-3">
                <%= for ws <- List.wrap(workstreams) do %>
                  <div class="bg-base-200 rounded-lg p-4">
                    <div class="flex items-start justify-between">
                      <div class="flex-1">
                        <div class="flex items-center gap-2">
                          <span class="badge badge-sm badge-outline font-mono">
                            {ws[:id] || ws["id"]}
                          </span>
                          <h5 class="font-semibold">{ws[:title] || ws["title"]}</h5>
                        </div>
                        <p class="text-sm text-base-content/70 mt-2">
                          {ws[:description] || ws["description"]}
                        </p>
                        <div class="flex items-center gap-4 mt-3 text-xs text-base-content/60">
                          <%= if deps = ws[:dependencies] || ws["dependencies"] do %>
                            <%= if length(deps) > 0 do %>
                              <span class="flex items-center gap-1">
                                <.icon name="hero-link" class="w-3 h-3" />
                                Depends on: {Enum.join(deps, ", ")}
                              </span>
                            <% else %>
                              <span class="flex items-center gap-1 text-success">
                                <.icon name="hero-check" class="w-3 h-3" /> No dependencies
                              </span>
                            <% end %>
                          <% end %>
                          <%= if hours = ws[:estimated_hours] || ws["estimated_hours"] do %>
                            <span class="flex items-center gap-1">
                              <.icon name="hero-clock" class="w-3 h-3" />
                              {hours} hour(s)
                            </span>
                          <% end %>
                        </div>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
          <!-- Also display steps if present (for backwards compatibility) -->
          <%= if steps = @state.plan[:steps] || @state.plan["steps"] do %>
            <%= if length(List.wrap(steps)) > 0 do %>
              <div class="mt-4">
                <h4 class="font-medium text-base-content/80 mb-2">Steps</h4>
                <ol class="list-decimal list-inside space-y-2">
                  <%= for step <- List.wrap(steps) do %>
                    <li class="text-base-content">{format_step(step)}</li>
                  <% end %>
                </ol>
              </div>
            <% end %>
          <% end %>
          <%= if !(@state.plan[:approved?] || @state.plan["approved?"]) do %>
            <div class="mt-4">
              <button phx-click="approve_plan" class="btn btn-primary btn-sm">
                Approve Plan
              </button>
            </div>
          <% else %>
            <div class="mt-4 text-success flex items-center gap-2">
              <.icon name="hero-check-circle" class="w-5 h-5" /> Plan Approved
            </div>
          <% end %>
        <% else %>
          <p class="text-base-content/60">No plan yet.</p>
        <% end %>
      </.card>
    </div>
    """
  end

  # Workstreams Tab
  defp workstreams_tab(assigns) do
    workstreams = Map.values(assigns.state.workstreams || %{})

    selected_ws =
      if assigns.selected_id do
        Enum.find(workstreams, fn ws -> ws.workstream_id == assigns.selected_id end)
      end

    # Find the agent for this workstream
    selected_agent =
      if selected_ws do
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
            <h3 class="font-medium truncate">{@workstream.title || @workstream.workstream_id}</h3>
            <%= if @workstream.spec do %>
              <p class="text-sm text-base-content/60 mt-1 line-clamp-2">{@workstream.spec}</p>
            <% end %>
          </div>
          <span class={"badge #{@status_color} ml-2 flex-shrink-0"}>
            {format_status(@workstream.status)}
          </span>
        </div>

        <%= if deps = @workstream.dependencies do %>
          <%= if length(deps) > 0 do %>
            <div class="mt-3 flex items-center gap-2 text-sm text-base-content/60">
              <.icon name="hero-link" class="w-4 h-4" />
              <span>Depends on: {Enum.join(deps, ", ")}</span>
            </div>
          <% end %>
        <% end %>

        <%= if blocking = @workstream.blocking_on do %>
          <%= if length(blocking) > 0 do %>
            <div class="mt-2 text-sm text-warning flex items-center gap-2">
              <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
              <span>Blocked by: {Enum.join(blocking, ", ")}</span>
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
              <.icon name="hero-queue-list" class="w-5 h-5" /> Workstream Details
            </h2>
            <p class="text-sm text-base-content/60 mt-1">
              <code class="bg-base-200 px-1 rounded">{@workstream.workstream_id}</code>
            </p>
          </div>
          <button
            phx-click="select_workstream"
            phx-value-id=""
            class="btn btn-ghost btn-sm btn-circle"
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>
        
    <!-- Status Badge -->
        <div class="flex items-center gap-2 mb-4">
          <span class="text-sm font-medium">Status:</span>
          <span class={"badge #{workstream_status_color(@workstream.status)}"}>
            {format_status(@workstream.status)}
          </span>
        </div>
        
    <!-- Specification -->
        <%= if @workstream.spec do %>
          <div class="mb-4">
            <h3 class="font-medium text-sm mb-2 flex items-center gap-2">
              <.icon name="hero-document-text" class="w-4 h-4" /> Specification
            </h3>
            <div class="bg-base-200 rounded-lg p-3 text-sm">
              {@workstream.spec}
            </div>
          </div>
        <% end %>
        
    <!-- Workspace Information -->
        <%= if @workstream.workspace_path do %>
          <div class="mb-4">
            <h3 class="font-medium text-sm mb-2 flex items-center gap-2">
              <.icon name="hero-folder" class="w-4 h-4" /> Workspace
            </h3>
            <.copyable_path path={@workstream.workspace_path} label="Workspace Path" />
          </div>
        <% else %>
          <!-- Try to construct workspace path from task_id and agent_id -->
          <%= if @agent && @agent.workspace_path do %>
            <div class="mb-4">
              <h3 class="font-medium text-sm mb-2 flex items-center gap-2">
                <.icon name="hero-folder" class="w-4 h-4" /> Workspace
              </h3>
              <.copyable_path path={@agent.workspace_path} label="Workspace Path" />
            </div>
          <% else %>
            <div class="mb-4">
              <h3 class="font-medium text-sm mb-2 flex items-center gap-2 text-base-content/60">
                <.icon name="hero-folder" class="w-4 h-4" /> Workspace
              </h3>
              <p class="text-sm text-base-content/60">No workspace created yet</p>
            </div>
          <% end %>
        <% end %>
        
    <!-- Agent Information -->
        <%= if @agent do %>
          <div class="mb-4">
            <h3 class="font-medium text-sm mb-2 flex items-center gap-2">
              <.icon name="hero-cpu-chip" class="w-4 h-4" /> Agent
            </h3>
            <div class="bg-base-200 rounded-lg p-3 space-y-2">
              <div class="flex items-center justify-between">
                <span class="text-sm text-base-content/60">Agent ID:</span>
                <code class="text-xs bg-base-300 px-2 py-0.5 rounded">{@agent.agent_id}</code>
              </div>
              <div class="flex items-center justify-between">
                <span class="text-sm text-base-content/60">Type:</span>
                <span class="text-sm">{@agent.agent_type}</span>
              </div>
              <div class="flex items-center justify-between">
                <span class="text-sm text-base-content/60">Status:</span>
                <span class={"badge badge-sm #{agent_status_color(@agent.status)}"}>
                  {format_status(@agent.status)}
                </span>
              </div>
              <%= if @agent.started_at do %>
                <div class="flex items-center justify-between">
                  <span class="text-sm text-base-content/60">Started:</span>
                  <span class="text-sm">{format_timestamp(@agent.started_at)}</span>
                </div>
              <% end %>
              <%= if @agent.completed_at do %>
                <div class="flex items-center justify-between">
                  <span class="text-sm text-base-content/60">Completed:</span>
                  <span class="text-sm">{format_timestamp(@agent.completed_at)}</span>
                </div>
              <% end %>
              <%= if @agent.error do %>
                <div class="mt-2 text-error text-sm">
                  <span class="font-medium">Error:</span> {@agent.error}
                </div>
              <% end %>
            </div>
          </div>
        <% else %>
          <div class="mb-4">
            <h3 class="font-medium text-sm mb-2 flex items-center gap-2 text-base-content/60">
              <.icon name="hero-cpu-chip" class="w-4 h-4" /> Agent
            </h3>
            <p class="text-sm text-base-content/60">No agent assigned yet</p>
          </div>
        <% end %>
        
    <!-- Dependencies -->
        <div class="mb-4">
          <h3 class="font-medium text-sm mb-2 flex items-center gap-2">
            <.icon name="hero-link" class="w-4 h-4" /> Dependencies
          </h3>
          <%= if deps = @workstream.dependencies do %>
            <%= if length(deps) > 0 do %>
              <div class="flex flex-wrap gap-2">
                <%= for dep <- deps do %>
                  <span class="badge badge-outline">{dep}</span>
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
                <.icon name="hero-exclamation-triangle" class="w-4 h-4" /> Blocked By
              </h3>
              <div class="flex flex-wrap gap-2">
                <%= for b <- blocking do %>
                  <span class="badge badge-warning badge-outline">{b}</span>
                <% end %>
              </div>
            </div>
          <% end %>
        <% end %>
        
    <!-- Timestamps -->
        <div class="border-t border-base-300 pt-4 mt-4">
          <h3 class="font-medium text-sm mb-2 flex items-center gap-2">
            <.icon name="hero-clock" class="w-4 h-4" /> Timeline
          </h3>
          <div class="space-y-1 text-sm">
            <%= if @workstream.started_at do %>
              <div class="flex items-center justify-between">
                <span class="text-base-content/60">Started:</span>
                <span>{format_timestamp(@workstream.started_at)}</span>
              </div>
            <% end %>
            <%= if @workstream.completed_at do %>
              <div class="flex items-center justify-between">
                <span class="text-base-content/60">Completed:</span>
                <span>{format_timestamp(@workstream.completed_at)}</span>
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

  # Copyable path component with click-to-copy and open in editor
  defp copyable_path(assigns) do
    editor = Application.get_env(:ipa, :editor_command)
    assigns = assign(assigns, :editor, editor)

    ~H"""
    <div class="bg-base-200 rounded-lg p-3">
      <div class="flex items-center justify-between gap-2">
        <code class="text-xs break-all flex-1">{@path}</code>
        <div class="flex items-center gap-1">
          <%= if @editor do %>
            <button
              phx-click="open_in_editor"
              phx-value-path={@path}
              class="btn btn-ghost btn-xs tooltip tooltip-left"
              data-tip={"Open in #{@editor}"}
            >
              <.icon name="hero-code-bracket" class="w-4 h-4" />
            </button>
          <% end %>
          <button
            phx-click={JS.dispatch("phx:copy", to: "#path-#{hash_path(@path)}")}
            class="btn btn-ghost btn-xs tooltip tooltip-left"
            data-tip="Copy path"
          >
            <.icon name="hero-clipboard-document" class="w-4 h-4" />
          </button>
        </div>
      </div>
      <input type="hidden" id={"path-#{hash_path(@path)}"} value={@path} />
      <p class="text-xs text-base-content/60 mt-2">{@label}</p>
    </div>
    """
  end

  defp hash_path(path) do
    :crypto.hash(:md5, path) |> Base.encode16(case: :lower) |> String.slice(0, 8)
  end

  # Events Tab - Agent Transactions History
  defp events_tab(assigns) do
    # Filter events based on selected filter
    filtered_events = filter_events_by_type(assigns.events, assigns.event_filter)

    # Get unique event types for filter dropdown
    event_types = assigns.events |> Enum.map(& &1.event_type) |> Enum.uniq() |> Enum.sort()

    assigns =
      assigns
      |> assign(:filtered_events, filtered_events)
      |> assign(:event_types, event_types)

    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
      <!-- Events List -->
      <div class={if @selected_event, do: "lg:col-span-2", else: "lg:col-span-3"}>
        <.card title="Event History">
          <!-- Filter Controls -->
          <div class="mb-4 flex flex-wrap items-center gap-3">
            <label class="text-sm font-medium text-base-content/70">Filter by type:</label>
            <select
              class="select select-bordered select-sm"
              phx-change="filter_events"
              name="filter"
            >
              <option value="all" selected={@event_filter == "all"}>All Events</option>
              <option value="agent" selected={@event_filter == "agent"}>Agent Events</option>
              <option value="workstream" selected={@event_filter == "workstream"}>
                Workstream Events
              </option>
              <option value="task" selected={@event_filter == "task"}>Task Events</option>
              <option value="message" selected={@event_filter == "message"}>Message Events</option>
              <option value="transition" selected={@event_filter == "transition"}>
                Transition Events
              </option>
              <%= for event_type <- @event_types do %>
                <option value={event_type} selected={@event_filter == event_type}>
                  {format_event_type(event_type)}
                </option>
              <% end %>
            </select>
            <span class="text-sm text-base-content/60">
              Showing {length(@filtered_events)} of {length(@events)} events
            </span>
          </div>
          
    <!-- Events Timeline -->
          <div class="space-y-2 max-h-[600px] overflow-y-auto">
            <%= if Enum.empty?(@filtered_events) do %>
              <div class="text-center py-8 text-base-content/60">
                <.icon name="hero-document-text" class="w-12 h-12 mx-auto mb-4 opacity-50" />
                <p>No events found.</p>
              </div>
            <% else %>
              <%= for event <- @filtered_events do %>
                <.event_item
                  event={event}
                  selected={@selected_event && @selected_event.version == event.version}
                />
              <% end %>
            <% end %>
          </div>
        </.card>
      </div>
      
    <!-- Event Details Panel -->
      <%= if @selected_event do %>
        <div class="lg:col-span-1">
          <.event_details_panel event={@selected_event} />
        </div>
      <% end %>
    </div>
    """
  end

  # Event item in the timeline
  defp event_item(assigns) do
    assigns = assign(assigns, :event_color, event_type_color(assigns.event.event_type))
    assigns = assign(assigns, :event_icon, event_type_icon(assigns.event.event_type))

    ~H"""
    <div
      class={"flex items-start gap-3 p-3 rounded-lg cursor-pointer hover:bg-base-200 transition-colors #{if @selected, do: "bg-primary/10 ring-2 ring-primary/20", else: "bg-base-100 border border-base-300"}"}
      phx-click="select_event"
      phx-value-version={@event.version}
    >
      <!-- Event Type Icon -->
      <div class={"w-10 h-10 rounded-full flex items-center justify-center flex-shrink-0 #{@event_color}"}>
        <.icon name={@event_icon} class="w-5 h-5" />
      </div>
      
    <!-- Event Info -->
      <div class="flex-1 min-w-0">
        <div class="flex items-center justify-between gap-2">
          <span class="font-medium text-sm truncate">
            {format_event_type(@event.event_type)}
          </span>
          <span class="text-xs text-base-content/60 flex-shrink-0">
            v{@event.version}
          </span>
        </div>
        
    <!-- Event Summary -->
        <p class="text-xs text-base-content/60 mt-1 line-clamp-1">
          {event_summary(@event)}
        </p>
        
    <!-- Metadata -->
        <div class="flex items-center gap-3 mt-2 text-xs text-base-content/50">
          <%= if @event.actor_id do %>
            <span class="flex items-center gap-1">
              <.icon name="hero-user" class="w-3 h-3" />
              {@event.actor_id}
            </span>
          <% end %>
          <span class="flex items-center gap-1">
            <.icon name="hero-clock" class="w-3 h-3" />
            {format_timestamp(@event.inserted_at)}
          </span>
        </div>
      </div>
    </div>
    """
  end

  # Event details panel
  defp event_details_panel(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm border border-base-300 sticky top-4">
      <div class="card-body">
        <!-- Header -->
        <div class="flex items-start justify-between mb-4">
          <div>
            <h2 class="card-title text-lg flex items-center gap-2">
              <.icon name="hero-document-magnifying-glass" class="w-5 h-5" /> Event Details
            </h2>
            <p class="text-sm text-base-content/60 mt-1">
              Version <span class="badge badge-sm badge-ghost">{@event.version}</span>
            </p>
          </div>
          <button phx-click="clear_selected_event" class="btn btn-ghost btn-sm btn-circle">
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>
        
    <!-- Event Type -->
        <div class="mb-4">
          <h3 class="font-medium text-sm mb-2 flex items-center gap-2">
            <.icon name="hero-tag" class="w-4 h-4" /> Event Type
          </h3>
          <span class={"badge #{event_type_badge_color(@event.event_type)}"}>
            {@event.event_type}
          </span>
        </div>
        
    <!-- Timestamp -->
        <div class="mb-4">
          <h3 class="font-medium text-sm mb-2 flex items-center gap-2">
            <.icon name="hero-clock" class="w-4 h-4" /> Timestamp
          </h3>
          <p class="text-sm">{format_timestamp_full(@event.inserted_at)}</p>
        </div>
        
    <!-- Actor -->
        <%= if @event.actor_id do %>
          <div class="mb-4">
            <h3 class="font-medium text-sm mb-2 flex items-center gap-2">
              <.icon name="hero-user" class="w-4 h-4" /> Actor
            </h3>
            <code class="text-xs bg-base-200 px-2 py-1 rounded">{@event.actor_id}</code>
          </div>
        <% end %>
        
    <!-- Correlation ID -->
        <%= if @event.correlation_id do %>
          <div class="mb-4">
            <h3 class="font-medium text-sm mb-2 flex items-center gap-2">
              <.icon name="hero-link" class="w-4 h-4" /> Correlation ID
            </h3>
            <code class="text-xs bg-base-200 px-2 py-1 rounded break-all">
              {@event.correlation_id}
            </code>
          </div>
        <% end %>
        
    <!-- Event Data -->
        <div class="mb-4">
          <h3 class="font-medium text-sm mb-2 flex items-center gap-2">
            <.icon name="hero-code-bracket" class="w-4 h-4" /> Event Data
          </h3>
          <div class="bg-base-200 rounded-lg p-3 overflow-x-auto">
            <pre class="text-xs whitespace-pre-wrap break-all"><%= format_event_data(@event.data) %></pre>
          </div>
        </div>
        
    <!-- Metadata -->
        <%= if @event.metadata do %>
          <div class="mb-4">
            <h3 class="font-medium text-sm mb-2 flex items-center gap-2">
              <.icon name="hero-information-circle" class="w-4 h-4" /> Metadata
            </h3>
            <div class="bg-base-200 rounded-lg p-3 overflow-x-auto">
              <pre class="text-xs whitespace-pre-wrap break-all"><%= format_event_data(@event.metadata) %></pre>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Communications Tab
  defp communications_tab(assigns) do
    # Messages is a map in the new state structure
    messages =
      case assigns.state.messages do
        msgs when is_map(msgs) -> Map.values(msgs)
        msgs when is_list(msgs) -> msgs
        _ -> []
      end

    # Use notifications instead of inbox
    inbox = assigns.state.notifications || []

    assigns =
      assigns
      |> assign(:messages, Enum.sort_by(messages, &(&1.posted_at || 0), :desc))
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
          <% pending =
            Enum.filter(@messages, fn m ->
              (Map.get(m, :message_type) || Map.get(m, :type)) == :approval && !m.approved?
            end) %>
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
    # Handle both old :type and new :message_type field names
    msg_type =
      Map.get(assigns.message, :message_type) || Map.get(assigns.message, :type) || :update

    assigns = assign(assigns, :type_badge, message_type_badge(msg_type))
    assigns = assign(assigns, :msg_type, msg_type)

    ~H"""
    <div class="bg-base-200 rounded-lg p-3">
      <div class="flex items-start justify-between">
        <div class="flex items-center gap-2">
          <span class={"badge badge-sm #{@type_badge}"}>{@msg_type}</span>
          <span class="text-sm font-medium">{@message.author}</span>
        </div>
        <span class="text-xs text-base-content/60">
          {format_timestamp(@message.posted_at)}
        </span>
      </div>
      <p class="mt-2 text-sm">{@message.content}</p>
    </div>
    """
  end

  defp inbox_item(assigns) do
    msg = Enum.find(assigns.messages, fn m -> m.message_id == assigns.notification.message_id end)
    assigns = assign(assigns, :message, msg)
    # Handle both old :type and new :notification_type field names
    notif_type =
      Map.get(assigns.notification, :notification_type) || Map.get(assigns.notification, :type) ||
        :update

    assigns = assign(assigns, :notif_type, notif_type)

    ~H"""
    <div class={"p-2 rounded border #{if @notification.read?, do: "border-base-300 bg-base-100", else: "border-warning bg-warning/10"}"}>
      <div class="flex items-center gap-2">
        <.icon name={notification_icon(@notif_type)} class="w-4 h-4" />
        <span class="text-sm font-medium">{format_notification_type(@notif_type)}</span>
      </div>
      <%= if @message do %>
        <p class="text-xs text-base-content/60 mt-1 line-clamp-1">{@message.content}</p>
      <% end %>
    </div>
    """
  end

  defp approval_item(assigns) do
    ~H"""
    <div class="border border-warning rounded-lg p-3 bg-warning/5">
      <p class="font-medium text-sm">{@approval.content}</p>
      <p class="text-xs text-base-content/60 mt-1">From: {@approval.author}</p>
      <%= if options = @approval.approval_options do %>
        <div class="flex gap-2 mt-3">
          <%= for option <- options do %>
            <button
              phx-click="give_approval"
              phx-value-message_id={@approval.message_id}
              phx-value-choice={option}
              class="btn btn-sm btn-outline"
            >
              {option}
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
          <h2 class="card-title text-lg">{@title}</h2>
        <% end %>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # Helper Functions

  defp format_phase(phase) do
    phase
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp format_phase_short(phase) do
    case phase do
      :spec_clarification -> "Spec"
      :planning -> "Planning"
      :workstream_execution -> "Execution"
      :review -> "Review"
      :completed -> "Done"
      :cancelled -> "Cancelled"
      _ -> format_phase(phase)
    end
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

  defp workstream_count(%{workstreams: workstreams}) when is_map(workstreams) do
    map_size(workstreams)
  end

  defp workstream_count(_state), do: 0

  defp agent_count(%{agents: agents}) when is_list(agents), do: length(agents)
  defp agent_count(_state), do: 0

  defp unread_count(%{notifications: notifications}) when is_list(notifications) do
    Enum.count(notifications, fn n -> !n.read? end)
  end

  defp unread_count(_state), do: 0

  defp get_pending_transition(%{pending_transitions: [first | _]}), do: first
  defp get_pending_transition(_state), do: nil

  # Event filtering helpers
  defp filter_events_by_type(events, "all"), do: events

  defp filter_events_by_type(events, "agent") do
    Enum.filter(events, fn e ->
      String.contains?(e.event_type, "agent")
    end)
  end

  defp filter_events_by_type(events, "workstream") do
    Enum.filter(events, fn e ->
      String.contains?(e.event_type, "workstream")
    end)
  end

  defp filter_events_by_type(events, "task") do
    Enum.filter(events, fn e ->
      String.starts_with?(e.event_type, "task_")
    end)
  end

  defp filter_events_by_type(events, "message") do
    Enum.filter(events, fn e ->
      String.contains?(e.event_type, "message") or
        String.contains?(e.event_type, "approval") or
        String.contains?(e.event_type, "notification")
    end)
  end

  defp filter_events_by_type(events, "transition") do
    Enum.filter(events, fn e ->
      String.contains?(e.event_type, "transition") or
        String.contains?(e.event_type, "phase")
    end)
  end

  defp filter_events_by_type(events, specific_type) do
    Enum.filter(events, fn e -> e.event_type == specific_type end)
  end

  # Event type formatting
  defp format_event_type(event_type) do
    event_type
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  # Event type colors for timeline
  defp event_type_color(event_type) do
    cond do
      String.contains?(event_type, "agent") ->
        "bg-purple-100 text-purple-600"

      String.contains?(event_type, "workstream") ->
        "bg-blue-100 text-blue-600"

      String.starts_with?(event_type, "task_") ->
        "bg-green-100 text-green-600"

      String.contains?(event_type, "spec") ->
        "bg-yellow-100 text-yellow-600"

      String.contains?(event_type, "plan") ->
        "bg-orange-100 text-orange-600"

      String.contains?(event_type, "transition") or String.contains?(event_type, "phase") ->
        "bg-pink-100 text-pink-600"

      String.contains?(event_type, "message") or String.contains?(event_type, "approval") ->
        "bg-cyan-100 text-cyan-600"

      String.contains?(event_type, "github") or String.contains?(event_type, "jira") ->
        "bg-gray-100 text-gray-600"

      true ->
        "bg-base-200 text-base-content"
    end
  end

  # Event type icons
  defp event_type_icon(event_type) do
    cond do
      String.contains?(event_type, "agent_started") ->
        "hero-play"

      String.contains?(event_type, "agent_completed") ->
        "hero-check-circle"

      String.contains?(event_type, "agent_failed") ->
        "hero-x-circle"

      String.contains?(event_type, "agent") ->
        "hero-cpu-chip"

      String.contains?(event_type, "workstream_created") ->
        "hero-plus-circle"

      String.contains?(event_type, "workstream_completed") ->
        "hero-check-circle"

      String.contains?(event_type, "workstream_failed") ->
        "hero-x-circle"

      String.contains?(event_type, "workstream") ->
        "hero-queue-list"

      String.contains?(event_type, "task_created") ->
        "hero-document-plus"

      String.contains?(event_type, "task_completed") ->
        "hero-check-badge"

      String.contains?(event_type, "task_cancelled") ->
        "hero-x-mark"

      String.starts_with?(event_type, "task_") ->
        "hero-document"

      String.contains?(event_type, "spec") ->
        "hero-document-text"

      String.contains?(event_type, "plan") ->
        "hero-clipboard-document-list"

      String.contains?(event_type, "transition") or String.contains?(event_type, "phase") ->
        "hero-arrow-right-circle"

      String.contains?(event_type, "approval") ->
        "hero-hand-thumb-up"

      String.contains?(event_type, "message") ->
        "hero-chat-bubble-left"

      String.contains?(event_type, "notification") ->
        "hero-bell"

      String.contains?(event_type, "github") ->
        "hero-code-bracket"

      String.contains?(event_type, "jira") ->
        "hero-ticket"

      String.contains?(event_type, "workspace") ->
        "hero-folder"

      true ->
        "hero-bolt"
    end
  end

  # Event type badge colors
  defp event_type_badge_color(event_type) do
    cond do
      String.contains?(event_type, "agent") ->
        "badge-secondary"

      String.contains?(event_type, "workstream") ->
        "badge-info"

      String.starts_with?(event_type, "task_") ->
        "badge-success"

      String.contains?(event_type, "spec") or String.contains?(event_type, "plan") ->
        "badge-warning"

      String.contains?(event_type, "transition") or String.contains?(event_type, "phase") ->
        "badge-accent"

      String.contains?(event_type, "failed") or String.contains?(event_type, "cancelled") ->
        "badge-error"

      String.contains?(event_type, "completed") or String.contains?(event_type, "approved") ->
        "badge-success"

      true ->
        "badge-ghost"
    end
  end

  # Event summary - creates a brief description of the event
  defp event_summary(event) do
    data = event.data

    case event.event_type do
      "task_created" ->
        "Created task: #{data[:title] || "Untitled"}"

      "task_completed" ->
        "Task completed"

      "task_cancelled" ->
        "Task cancelled"

      "spec_updated" ->
        "Specification updated"

      "spec_approved" ->
        "Spec approved by #{data[:approved_by] || "user"}"

      "plan_updated" ->
        "Plan updated with #{length(data[:steps] || data[:plan][:steps] || [])} steps"

      "plan_approved" ->
        "Plan approved by #{data[:approved_by] || "user"}"

      "transition_requested" ->
        "Transition to #{data[:to_phase]} requested"

      "transition_approved" ->
        "Transition to #{data[:to_phase]} approved"

      "agent_started" ->
        "Agent #{data[:agent_id]} started (#{data[:agent_type]})"

      "agent_completed" ->
        "Agent #{data[:agent_id]} completed"

      "agent_failed" ->
        "Agent #{data[:agent_id]} failed: #{String.slice(data[:error] || "", 0, 50)}"

      "workstream_created" ->
        "Created workstream: #{data[:workstream_id]}"

      "workstream_agent_started" ->
        "Agent #{data[:agent_id]} started for #{data[:workstream_id]}"

      "workstream_completed" ->
        "Workstream #{data[:workstream_id]} completed"

      "workstream_failed" ->
        "Workstream #{data[:workstream_id]} failed"

      "message_posted" ->
        "#{data[:author]}: #{String.slice(data[:content] || "", 0, 50)}"

      "approval_requested" ->
        "Approval requested: #{String.slice(data[:question] || "", 0, 50)}"

      "approval_given" ->
        "Approval given: #{data[:choice]}"

      "workspace_created" ->
        "Workspace created for agent #{data[:agent_id]}"

      "github_pr_created" ->
        "PR ##{data[:pr_number]} created"

      "github_pr_merged" ->
        "PR merged"

      "jira_ticket_updated" ->
        "JIRA #{data[:ticket_id]} updated"

      _ ->
        inspect_data_summary(data)
    end
  end

  defp inspect_data_summary(data) when is_map(data) do
    keys = Map.keys(data) |> Enum.take(3) |> Enum.join(", ")
    "Data: #{keys}..."
  end

  defp inspect_data_summary(_), do: ""

  # Format event data as pretty JSON
  defp format_event_data(nil), do: "null"

  defp format_event_data(data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(data, pretty: true)
    end
  end

  # Full timestamp formatting
  defp format_timestamp_full(unix) when is_integer(unix) do
    unix
    |> DateTime.from_unix!()
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_timestamp_full(_), do: "Unknown"

  # Auto-start pod for active tasks that don't have a running pod
  # This ensures tasks continue processing when viewed in the UI
  defp maybe_auto_start_pod(task_id, phase)
       when phase in [:spec_clarification, :planning, :workstream_execution, :review] do
    unless Ipa.PodSupervisor.pod_running?(task_id) do
      case Ipa.CentralManager.start_pod(task_id) do
        {:ok, _pid} ->
          Logger.info("Auto-started pod for task #{task_id} in phase #{phase}")

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to auto-start pod for task #{task_id}: #{inspect(reason)}")
      end
    end
  end

  defp maybe_auto_start_pod(_task_id, _phase), do: :ok

  # Helper to ensure pod is running before executing commands
  # Returns :ok if pod is running or was started successfully
  defp ensure_pod_running(task_id) do
    if Ipa.PodSupervisor.pod_running?(task_id) do
      :ok
    else
      case Ipa.CentralManager.start_pod(task_id) do
        {:ok, _pid} ->
          Logger.info("Started pod for task #{task_id} before command execution")
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          Logger.error("Failed to start pod for task #{task_id}: #{inspect(reason)}")
          {:error, {:pod_start_failed, reason}}
      end
    end
  end
end
