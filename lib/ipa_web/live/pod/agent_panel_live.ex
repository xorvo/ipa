defmodule IpaWeb.Pod.AgentPanelLive do
  @moduledoc """
  Nested LiveView for displaying real-time agent execution status.

  This is a nested LiveView (not a LiveComponent) so it has its own process
  and can receive PubSub messages directly for streaming updates.

  ## Usage

      <%= live_render(@socket, IpaWeb.Pod.AgentPanelLive,
        id: "agent-panel",
        session: %{"task_id" => @task_id}
      ) %>

  ## PubSub Subscriptions

  When mounted, this LiveView subscribes to:
  - `"task:{task_id}:agents"` - For agent lifecycle events
  - `"agent:{agent_id}:stream"` - For streaming updates (subscribed per-agent)
  """

  use IpaWeb, :live_view

  require Logger

  @impl true
  def mount(_params, session, socket) do
    task_id = session["task_id"]

    socket =
      socket
      |> assign(task_id: task_id)
      |> assign(agents: [])
      |> assign(expanded_agents: MapSet.new())
      |> assign(streaming_outputs: %{})
      |> assign(selected_agent_id: nil)

    if connected?(socket) && task_id do
      Logger.info("AgentPanelLive mounted for task #{task_id}")

      # Subscribe to task-level agent events
      Phoenix.PubSub.subscribe(Ipa.PubSub, "task:#{task_id}:agents")
      Logger.debug("Subscribed to task:#{task_id}:agents")

      # Subscribe to EventStore for agent events
      Ipa.EventStore.subscribe(task_id)

      # Load initial agents from state
      case Ipa.Pod.Manager.get_state_from_events(task_id) do
        {:ok, state} ->
          agents = state.agents || []
          Logger.info("AgentPanelLive loaded #{length(agents)} agents")

          # Subscribe to streaming updates for each active agent
          for agent <- agents, agent.status in [:initializing, :running] do
            Logger.info("Subscribing to agent:#{agent.agent_id}:stream (status: #{agent.status})")
            Phoenix.PubSub.subscribe(Ipa.PubSub, "agent:#{agent.agent_id}:stream")
          end

          # Initialize streaming_outputs with persisted output for non-running agents
          # This ensures output is visible when the panel loads
          streaming_outputs =
            agents
            |> Enum.filter(fn a ->
              a.status in [:completed, :failed, :awaiting_input, :interrupted] && a.output
            end)
            |> Enum.map(fn a -> {a.agent_id, a.output} end)
            |> Map.new()

          {:ok, assign(socket, agents: agents, streaming_outputs: streaming_outputs)}

        {:error, _} ->
          {:ok, socket}
      end
    else
      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    # Pending agents waiting for manual start
    pending_agents = Enum.filter(assigns.agents || [], &(&1.status == :pending_start))
    # Running agents (including those running after being started)
    running_agents = Enum.filter(assigns.agents || [], &(&1.status == :running))
    # Agents waiting for user input (interactive mode)
    awaiting_agents = Enum.filter(assigns.agents || [], &(&1.status == :awaiting_input))
    # Completed/failed/interrupted agents
    completed_agents =
      Enum.filter(assigns.agents || [], &(&1.status in [:completed, :failed, :interrupted]))

    assigns =
      assigns
      |> assign(:pending_agents, pending_agents)
      |> assign(:running_agents, running_agents)
      |> assign(:awaiting_agents, awaiting_agents)
      |> assign(:completed_agents, completed_agents)

    ~H"""
    <div class="space-y-6">
      <!-- Header with stats -->
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-4">
          <h3 class="text-xl font-bold flex items-center gap-2">
            <div class="bg-primary p-2 rounded-lg">
              <.icon name="hero-cpu-chip" class="w-5 h-5 text-primary-content" />
            </div>
            Agent Monitor
          </h3>
        </div>
        <div class="flex items-center gap-2">
          <%= if length(@pending_agents) > 0 do %>
            <span class="badge badge-warning gap-1">
              {length(@pending_agents)} pending
            </span>
          <% end %>
          <%= if length(@running_agents) > 0 do %>
            <span class="badge badge-info gap-1">
              <span class="w-2 h-2 bg-info-content rounded-full animate-pulse"></span>
              {length(@running_agents)} running
            </span>
          <% end %>
          <%= if length(@awaiting_agents) > 0 do %>
            <span class="badge badge-accent gap-1">
              {length(@awaiting_agents)} awaiting
            </span>
          <% end %>
          <%= if length(@completed_agents) > 0 do %>
            <span class="badge badge-ghost">{length(@completed_agents)} completed</span>
          <% end %>
        </div>
      </div>

      <%= if Enum.empty?(@agents || []) do %>
        <div class="card bg-base-200/50 border border-base-300 border-dashed">
          <div class="card-body items-center text-center py-12">
            <div class="bg-base-300/50 p-4 rounded-full mb-4">
              <.icon name="hero-cpu-chip" class="w-12 h-12 text-base-content/30" />
            </div>
            <h4 class="text-lg font-medium text-base-content/70">No Active Agents</h4>
            <p class="text-sm text-base-content/50 max-w-sm">
              Agents will appear here when workstreams start executing.
              Each agent runs autonomously and streams its progress in real-time.
            </p>
          </div>
        </div>
      <% else %>
        <!-- Pending agents (waiting for manual start) -->
        <%= if length(@pending_agents) > 0 do %>
          <div class="space-y-4">
            <h4 class="text-sm font-semibold text-base-content/70 uppercase tracking-wider flex items-center gap-2">
              <span class="w-2 h-2 bg-warning rounded-full"></span> Pending Start
            </h4>
            <%= for agent <- @pending_agents do %>
              <.agent_card
                agent={agent}
                expanded={true}
                streaming_output={Map.get(@streaming_outputs, agent.agent_id, "")}
              />
            <% end %>
          </div>
        <% end %>
        
    <!-- Running agents (expanded by default) -->
        <%= if length(@running_agents) > 0 do %>
          <div class="space-y-4">
            <h4 class="text-sm font-semibold text-base-content/70 uppercase tracking-wider flex items-center gap-2">
              <span class="w-2 h-2 bg-info rounded-full animate-pulse"></span> Running
            </h4>
            <%= for agent <- @running_agents do %>
              <.agent_card
                agent={agent}
                expanded={true}
                streaming_output={Map.get(@streaming_outputs, agent.agent_id, "")}
              />
            <% end %>
          </div>
        <% end %>
        
    <!-- Awaiting input agents (interactive mode) -->
        <%= if length(@awaiting_agents) > 0 do %>
          <div class="space-y-4">
            <h4 class="text-sm font-semibold text-base-content/70 uppercase tracking-wider flex items-center gap-2">
              <span class="w-2 h-2 bg-accent rounded-full"></span> Awaiting Input
            </h4>
            <%= for agent <- @awaiting_agents do %>
              <.agent_card
                agent={agent}
                expanded={true}
                streaming_output={Map.get(@streaming_outputs, agent.agent_id, "")}
              />
            <% end %>
          </div>
        <% end %>
        
    <!-- Completed agents (collapsed by default) -->
        <%= if length(@completed_agents) > 0 do %>
          <div class="space-y-3">
            <h4 class="text-sm font-semibold text-base-content/70 uppercase tracking-wider">
              Completed
            </h4>
            <%= for agent <- @completed_agents do %>
              <.agent_card
                agent={agent}
                expanded={MapSet.member?(@expanded_agents, agent.agent_id)}
                streaming_output={Map.get(@streaming_outputs, agent.agent_id, "")}
              />
            <% end %>
          </div>
        <% end %>
      <% end %>
      
    <!-- Agent Detail Modal -->
      <%= if @selected_agent_id do %>
        <div class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/60">
          <!-- Backdrop click handler -->
          <div class="absolute inset-0" phx-click="close_agent_detail"></div>
          <!-- Modal content -->
          <div class="relative bg-base-100 rounded-xl shadow-2xl w-full max-w-5xl h-[85vh] flex flex-col overflow-hidden">
            <!-- Close button -->
            <button
              phx-click="close_agent_detail"
              class="absolute top-4 right-4 z-10 btn btn-sm btn-circle btn-ghost"
            >
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </button>
            <!-- Agent Detail LiveView -->
            {live_render(@socket, IpaWeb.Pod.AgentDetailLive,
              id: "agent-detail-#{@selected_agent_id}",
              session: %{"task_id" => @task_id, "agent_id" => @selected_agent_id}
            )}
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

  @impl true
  def handle_event("toggle_agent", %{"agent_id" => agent_id}, socket) do
    expanded_agents = socket.assigns.expanded_agents

    new_expanded =
      if MapSet.member?(expanded_agents, agent_id) do
        MapSet.delete(expanded_agents, agent_id)
      else
        MapSet.put(expanded_agents, agent_id)
      end

    {:noreply, assign(socket, expanded_agents: new_expanded)}
  end

  def handle_event("view_agent_detail", %{"agent_id" => agent_id}, socket) do
    Logger.debug("Opening agent detail view for #{agent_id}")
    {:noreply, assign(socket, selected_agent_id: agent_id)}
  end

  def handle_event("close_agent_detail", _params, socket) do
    {:noreply, assign(socket, selected_agent_id: nil)}
  end

  # No-op handler to stop click propagation from control buttons
  def handle_event("noop", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("start_agent", %{"agent_id" => agent_id}, socket) do
    Logger.info("Manually starting agent from UI", agent_id: agent_id)
    task_id = socket.assigns.task_id

    case Ipa.Pod.Manager.manually_start_agent(task_id, agent_id, "user") do
      {:ok, _version} ->
        {:noreply, put_flash(socket, :info, "Agent started")}

      {:error, :agent_not_pending} ->
        {:noreply, put_flash(socket, :warning, "Agent is not in pending state")}

      {:error, :agent_not_found} ->
        {:noreply, put_flash(socket, :error, "Agent not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start agent: #{inspect(reason)}")}
    end
  end

  def handle_event("interrupt_agent", %{"agent_id" => agent_id}, socket) do
    Logger.info("Interrupting agent from UI", agent_id: agent_id)

    case Ipa.Agent.interrupt(agent_id) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Agent interrupted")}

      {:error, :not_found} ->
        # Agent process is gone - reload agents to get fresh state
        Logger.warning("Agent #{agent_id} not found - process may have crashed")
        socket = reload_agents(socket)

        {:noreply,
         put_flash(socket, :warning, "Agent process not found - it may have already stopped")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to interrupt: #{inspect(reason)}")}
    end
  end

  def handle_event("restart_agent", %{"agent_id" => agent_id}, socket) do
    Logger.info("Restarting agent from UI", agent_id: agent_id)
    task_id = socket.assigns.task_id

    case Ipa.Pod.Manager.restart_agent(task_id, agent_id, "user") do
      {:ok, new_agent_id, _version} ->
        Logger.info("Agent restarted", old_agent_id: agent_id, new_agent_id: new_agent_id)

        {:noreply,
         put_flash(socket, :info, "Agent restarted - new agent created and ready to start")}

      {:error, :agent_not_found} ->
        {:noreply, put_flash(socket, :error, "Agent not found")}

      {:error, :agent_not_restartable} ->
        {:noreply,
         put_flash(socket, :warning, "Only failed or interrupted agents can be restarted")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to restart agent: #{inspect(reason)}")}
    end
  end

  defp reload_agents(socket) do
    task_id = socket.assigns.task_id

    case Ipa.Pod.Manager.get_state_from_events(task_id) do
      {:ok, state} ->
        agents = state.agents || []
        assign(socket, agents: agents)

      {:error, _} ->
        socket
    end
  end

  # ============================================================================
  # PubSub Message Handlers
  # ============================================================================

  # Handle streaming text delta from agent
  # Format from Instance: {:text_delta, agent_id, %{text: text}}
  @impl true
  def handle_info({:text_delta, agent_id, %{text: text}}, socket) do
    Logger.debug("Received text_delta for agent #{agent_id}: #{String.slice(text, 0, 50)}...")
    streaming_outputs = socket.assigns.streaming_outputs
    current = Map.get(streaming_outputs, agent_id, "")
    new_outputs = Map.put(streaming_outputs, agent_id, current <> text)

    {:noreply, assign(socket, streaming_outputs: new_outputs)}
  end

  # Handle tool use events from agent
  # Format from Instance: {:tool_start, agent_id, %{tool_name: name, args: args}}
  def handle_info({:tool_start, agent_id, %{tool_name: tool_name}}, socket) do
    streaming_outputs = socket.assigns.streaming_outputs
    current = Map.get(streaming_outputs, agent_id, "")
    marker = "\n🔧 Using tool: #{tool_name}...\n"
    new_outputs = Map.put(streaming_outputs, agent_id, current <> marker)

    {:noreply, assign(socket, streaming_outputs: new_outputs)}
  end

  # Format from Instance: {:tool_complete, agent_id, %{tool_name: name, result: result}}
  def handle_info({:tool_complete, agent_id, %{tool_name: tool_name}}, socket) do
    streaming_outputs = socket.assigns.streaming_outputs
    current = Map.get(streaming_outputs, agent_id, "")
    marker = "✓ Tool #{tool_name} complete\n"
    new_outputs = Map.put(streaming_outputs, agent_id, current <> marker)

    {:noreply, assign(socket, streaming_outputs: new_outputs)}
  end

  # Handle agent lifecycle events (from task:task_id:agents topic)
  # Format: {:agent_started, agent_id}
  def handle_info({:agent_started, agent_id}, socket) do
    Logger.debug("Agent started in panel", agent_id: agent_id)
    # Subscribe to this agent's stream
    Phoenix.PubSub.subscribe(Ipa.PubSub, "agent:#{agent_id}:stream")
    {:noreply, socket}
  end

  def handle_info({:agent_completed, agent_id}, socket) do
    Logger.debug("Agent completed in panel", agent_id: agent_id)
    Phoenix.PubSub.unsubscribe(Ipa.PubSub, "agent:#{agent_id}:stream")
    {:noreply, socket}
  end

  def handle_info({:agent_failed, agent_id}, socket) do
    Logger.debug("Agent failed in panel", agent_id: agent_id)
    Phoenix.PubSub.unsubscribe(Ipa.PubSub, "agent:#{agent_id}:stream")
    {:noreply, socket}
  end

  def handle_info({:agent_interrupted, agent_id}, socket) do
    Logger.debug("Agent interrupted in panel", agent_id: agent_id)
    Phoenix.PubSub.unsubscribe(Ipa.PubSub, "agent:#{agent_id}:stream")
    {:noreply, socket}
  end

  # Handle EventStore broadcasts to update agent list
  def handle_info({:event_appended, task_id, event}, socket)
      when task_id == socket.assigns.task_id do
    case event.event_type do
      type
      when type in [
             "agent_started",
             "agent_completed",
             "agent_failed",
             "agent_status_changed",
             "agent_pending_start",
             "agent_manually_started",
             "agent_awaiting_input",
             "agent_marked_done",
             "agent_response_received",
             "agent_message_sent"
           ] ->
        # Reload agents from state
        case Ipa.Pod.Manager.get_state_from_events(task_id) do
          {:ok, state} ->
            agents = state.agents || []

            # Subscribe to new running agents
            for agent <- agents, agent.status in [:initializing, :running] do
              Phoenix.PubSub.subscribe(Ipa.PubSub, "agent:#{agent.agent_id}:stream")
            end

            {:noreply, assign(socket, agents: agents)}

          {:error, _} ->
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # Catch-all for other messages
  def handle_info(msg, socket) do
    Logger.debug("AgentPanelLive received unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ============================================================================
  # Components
  # ============================================================================

  defp agent_card(assigns) do
    # Determine status states for styling
    is_running = assigns.agent.status == :running
    is_pending = assigns.agent.status == :pending_start
    is_awaiting_input = assigns.agent.status == :awaiting_input
    # Check if the agent process is actually alive (not just state saying "running")
    process_alive = is_running && Ipa.Agent.Instance.alive?(assigns.agent.agent_id)
    # Use streaming output for running agents, otherwise use persisted output from state
    output = assigns.streaming_output || assigns.agent.output || ""

    assigns = assign(assigns, :process_alive, process_alive)

    assigns =
      assigns
      |> assign(:is_running, is_running)
      |> assign(:is_pending, is_pending)
      |> assign(:is_awaiting_input, is_awaiting_input)
      |> assign(:output, output)

    ~H"""
    <div
      class={"card shadow-lg border transition-all duration-300 cursor-pointer hover:shadow-xl #{cond do @is_pending -> "bg-base-100 border-warning/50 ring-2 ring-warning/20"; @is_running -> "bg-base-100 border-info/50 ring-2 ring-info/20"; @is_awaiting_input -> "bg-base-100 border-accent/50 ring-2 ring-accent/20"; true -> "bg-base-100 border-base-300 hover:border-primary/30" end}"}
      phx-click="view_agent_detail"
      phx-value-agent_id={@agent.agent_id}
    >
      <div class="card-body p-4">
        <!-- Header -->
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-3">
            <.agent_status_indicator status={@agent.status} />
            <div>
              <div class="flex items-center gap-2">
                <span class="font-semibold text-base">{format_agent_type(@agent.agent_type)}</span>
                <%= if @is_pending do %>
                  <span class="badge badge-xs badge-warning">Awaiting Start</span>
                <% end %>
                <%= if @is_running do %>
                  <span class="loading loading-spinner loading-xs text-info"></span>
                <% end %>
                <%= if @is_awaiting_input do %>
                  <span class="badge badge-xs badge-accent">Awaiting Input</span>
                <% end %>
              </div>
              <%= if @agent.workstream_id do %>
                <span class="text-xs text-base-content/50 font-mono">
                  ws: {String.slice(@agent.workstream_id, 0, 12)}...
                </span>
              <% end %>
            </div>
          </div>
          
    <!-- Control buttons - click events stop propagation to parent -->
          <div class="flex items-center gap-2" phx-click="noop" phx-value-stop="true">
            <%= if @is_pending do %>
              <button
                phx-click="start_agent"
                phx-value-agent_id={@agent.agent_id}
                class="btn btn-xs btn-success gap-1"
              >
                <.icon name="hero-play" class="w-3 h-3" /> Start
              </button>
            <% end %>
            <%= if @process_alive do %>
              <button
                phx-click="interrupt_agent"
                phx-value-agent_id={@agent.agent_id}
                class="btn btn-xs btn-error gap-1"
              >
                <.icon name="hero-stop" class="w-3 h-3" /> Stop
              </button>
            <% else %>
              <%= if @is_running do %>
                <span class="badge badge-xs badge-warning">Process Dead</span>
              <% end %>
            <% end %>
            <%= if @agent.status in [:failed, :interrupted] do %>
              <button
                phx-click="restart_agent"
                phx-value-agent_id={@agent.agent_id}
                class="btn btn-xs btn-warning gap-1"
              >
                <.icon name="hero-arrow-path" class="w-3 h-3" /> Restart
              </button>
            <% end %>

            <button
              phx-click="toggle_agent"
              phx-value-agent_id={@agent.agent_id}
              class="btn btn-xs btn-ghost btn-circle"
            >
              <%= if @expanded do %>
                <.icon name="hero-chevron-up" class="w-4 h-4" />
              <% else %>
                <.icon name="hero-chevron-down" class="w-4 h-4" />
              <% end %>
            </button>
          </div>
        </div>
        
    <!-- Status bar -->
        <div class="flex items-center gap-4 text-xs text-base-content/50 mt-2 font-mono">
          <span class="flex items-center gap-1">
            <.icon name="hero-finger-print" class="w-3 h-3" />
            {String.slice(@agent.agent_id, 0, 8)}
          </span>
          <%= if @agent.started_at do %>
            <span class="flex items-center gap-1">
              <.icon name="hero-clock" class="w-3 h-3" />
              {format_time(@agent.started_at)}
            </span>
          <% end %>
          <%= if @agent.completed_at do %>
            <span class="flex items-center gap-1">
              <.icon name="hero-check-circle" class="w-3 h-3" />
              {format_time(@agent.completed_at)}
            </span>
          <% end %>
        </div>
        
    <!-- Expanded content -->
        <%= if @expanded do %>
          <div class="mt-4 space-y-4">
            <!-- Output panel -->
            <div class="relative">
              <div class="flex items-center justify-between mb-2">
                <h4 class="font-medium text-sm flex items-center gap-2">
                  Agent Output
                  <%= if @is_running do %>
                    <span class="badge badge-xs badge-info">Live</span>
                  <% end %>
                </h4>
                <% char_count = String.length(@output) %>
                <%= if char_count > 0 do %>
                  <span class="text-xs text-base-content/40">{char_count} chars</span>
                <% end %>
              </div>
              
    <!-- Output content -->
              <div
                class="rounded-lg p-3 min-h-[120px] max-h-[300px] overflow-y-auto bg-neutral text-neutral-content/90"
                id={"output-#{@agent.agent_id}"}
                phx-hook="AutoScroll"
              >
                <%= if @output != "" do %>
                  <div class="text-xs leading-relaxed whitespace-pre-wrap break-words">{@output}</div>
                  <%= if @is_running do %>
                    <span class="inline-block w-1.5 h-3 bg-info animate-pulse ml-0.5"></span>
                  <% end %>
                <% else %>
                  <div class="text-xs text-neutral-content/50">
                    <%= if @is_running do %>
                      Waiting for agent output...
                    <% else %>
                      No output recorded
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
            
    <!-- Tool calls (compact view) -->
            <% tool_calls = Map.get(@agent, :tool_calls, []) %>
            <%= if length(tool_calls) > 0 do %>
              <div>
                <h4 class="font-medium text-sm mb-2 flex items-center gap-2">
                  <.icon name="hero-wrench-screwdriver" class="w-4 h-4" /> Tool Calls
                  <span class="badge badge-xs badge-ghost">{length(tool_calls)}</span>
                </h4>
                <div class="flex flex-wrap gap-2">
                  <%= for tool <- Enum.take(tool_calls, 10) do %>
                    <span class={"badge badge-sm gap-1 #{if tool.status == :completed, do: "badge-success", else: "badge-warning"}"}>
                      {tool.name}
                      <%= if tool.status == :running do %>
                        <span class="loading loading-spinner loading-xs"></span>
                      <% end %>
                    </span>
                  <% end %>
                  <%= if length(tool_calls) > 10 do %>
                    <span class="badge badge-sm badge-ghost">+{length(tool_calls) - 10} more</span>
                  <% end %>
                </div>
              </div>
            <% end %>
            
            
    <!-- Error -->
            <%= if @agent.error do %>
              <div class="alert alert-error shadow-lg">
                <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                <div>
                  <h4 class="font-bold">Agent Error</h4>
                  <p class="text-sm">{@agent.error}</p>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp agent_status_indicator(assigns) do
    ~H"""
    <div class={"w-3 h-3 rounded-full #{status_color(@status)}"}>
      <%= if @status == :running do %>
        <span class="absolute w-3 h-3 rounded-full animate-ping bg-info/50"></span>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp status_color(:initializing), do: "bg-warning"
  defp status_color(:running), do: "bg-info"
  defp status_color(:completed), do: "bg-success"
  defp status_color(:failed), do: "bg-error"
  defp status_color(:interrupted), do: "bg-warning"
  defp status_color(_), do: "bg-base-300"

  defp format_agent_type(:planning_agent), do: "Planning Agent"
  defp format_agent_type(:workstream), do: "Workstream Agent"
  defp format_agent_type(:pr_consolidation), do: "PR Consolidation Agent"
  defp format_agent_type(:pr_comment_resolver), do: "PR Comment Resolver"

  defp format_agent_type(type) when is_atom(type),
    do: type |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  defp format_agent_type(type) when is_binary(type),
    do: String.replace(type, "_", " ") |> String.capitalize()

  defp format_agent_type(_), do: "Unknown Agent"

  defp format_time(nil), do: "-"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_time(unix) when is_integer(unix) do
    unix
    |> DateTime.from_unix!()
    |> format_time()
  end

  defp format_time(_), do: "-"
end
