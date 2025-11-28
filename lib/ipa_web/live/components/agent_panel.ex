defmodule IpaWeb.Live.Components.AgentPanel do
  @moduledoc """
  LiveComponent for displaying real-time agent execution status.

  This component provides visibility into running agents:
  - Agent identity (type, workstream association)
  - Current status with visual indicators
  - Streaming response output
  - Tool call history with results

  ## Usage

      <.live_component
        module={IpaWeb.Live.Components.AgentPanel}
        id="agent-panel"
        task_id={@task_id}
        agents={@agents}
      />

  ## PubSub Subscriptions

  When mounted, this component subscribes to:
  - `"task:{task_id}:agents"` - For agent lifecycle events
  - `"agent:{agent_id}:stream"` - For streaming updates (subscribed per-agent)
  """

  use IpaWeb, :live_component

  require Logger

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(expanded_agents: MapSet.new())
     |> assign(streaming_outputs: %{})}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # Subscribe to agent events if connected and task_id is set
    if connected?(socket) && assigns[:task_id] do
      task_id = assigns.task_id

      # Subscribe to task-level agent events
      Phoenix.PubSub.subscribe(Ipa.PubSub, "task:#{task_id}:agents")

      # Subscribe to streaming updates for each active agent
      agents = assigns[:agents] || []

      for agent <- agents, agent.status in [:initializing, :running] do
        Phoenix.PubSub.subscribe(Ipa.PubSub, "agent:#{agent.agent_id}:stream")
      end

      # Initialize streaming_outputs with persisted output for completed agents
      # This ensures output is visible when the component loads
      existing_outputs = socket.assigns[:streaming_outputs] || %{}

      new_outputs =
        agents
        |> Enum.filter(fn a ->
          a.status in [:completed, :failed] && a.output &&
            not Map.has_key?(existing_outputs, a.agent_id)
        end)
        |> Enum.map(fn a -> {a.agent_id, a.output} end)
        |> Map.new()

      merged_outputs = Map.merge(existing_outputs, new_outputs)
      {:ok, assign(socket, streaming_outputs: merged_outputs)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    running_agents = Enum.filter(assigns.agents || [], &(&1.status == :running))

    completed_agents =
      Enum.filter(assigns.agents || [], &(&1.status in [:completed, :failed, :interrupted]))

    assigns =
      assigns
      |> assign(:running_agents, running_agents)
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
          <%= if length(@running_agents) > 0 do %>
            <span class="badge badge-info gap-1">
              <span class="w-2 h-2 bg-info-content rounded-full animate-pulse"></span>
              {length(@running_agents)} running
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
                myself={@myself}
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
                myself={@myself}
              />
            <% end %>
          </div>
        <% end %>
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

  def handle_event("interrupt_agent", %{"agent_id" => agent_id}, socket) do
    Logger.info("Interrupting agent from UI", agent_id: agent_id)

    case Ipa.Agent.interrupt(agent_id) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Agent interrupted")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to interrupt: #{inspect(reason)}")}
    end
  end

  # ============================================================================
  # PubSub Message Handlers
  # ============================================================================

  # Handle streaming text delta from agent
  # Format from Instance: {:text_delta, agent_id, %{text: text}}
  def handle_info({:text_delta, agent_id, %{text: text}}, socket) do
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
  # Format: {:agent_started, agent_id} (just the agent_id, no data)
  def handle_info({:agent_started, agent_id}, socket) do
    Logger.debug("Agent started in panel", agent_id: agent_id)
    # Subscribe to this agent's stream
    Phoenix.PubSub.subscribe(Ipa.PubSub, "agent:#{agent_id}:stream")
    {:noreply, socket}
  end

  def handle_info({:agent_completed, agent_id}, socket) do
    Logger.debug("Agent completed in panel", agent_id: agent_id)
    # Unsubscribe from agent stream
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

  # Catch-all for other messages
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ============================================================================
  # Components
  # ============================================================================

  defp agent_card(assigns) do
    # Determine if running for special styling
    is_running = assigns.agent.status == :running
    # Check if the agent process is actually alive (not just state saying "running")
    process_alive = is_running && Ipa.Agent.Instance.alive?(assigns.agent.agent_id)
    # Use streaming output for running agents, otherwise use persisted output from state
    output = assigns.streaming_output || assigns.agent.output || ""

    assigns =
      assigns
      |> assign(:is_running, is_running)
      |> assign(:process_alive, process_alive)
      |> assign(:output, output)

    ~H"""
    <div class={"card shadow-lg border transition-all duration-300 #{if @is_running, do: "bg-base-100 border-info/50 ring-2 ring-info/20", else: "bg-base-100 border-base-300"}"}>
      <div class="card-body p-4">
        <!-- Header -->
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-3">
            <.agent_status_indicator status={@agent.status} />
            <div>
              <div class="flex items-center gap-2">
                <span class="font-semibold text-base">{format_agent_type(@agent.agent_type)}</span>
                <%= if @is_running do %>
                  <span class="loading loading-spinner loading-xs text-info"></span>
                <% end %>
              </div>
              <%= if @agent.workstream_id do %>
                <span class="text-xs text-base-content/50 font-mono">
                  ws: {String.slice(@agent.workstream_id, 0, 12)}...
                </span>
              <% end %>
            </div>
          </div>

          <div class="flex items-center gap-2">
            <%= if @process_alive do %>
              <button
                phx-click="interrupt_agent"
                phx-value-agent_id={@agent.agent_id}
                phx-target={@myself}
                class="btn btn-xs btn-error gap-1"
              >
                <.icon name="hero-stop" class="w-3 h-3" /> Stop
              </button>
            <% else %>
              <%= if @is_running do %>
                <span class="badge badge-xs badge-warning">Process Dead</span>
              <% end %>
            <% end %>

            <button
              phx-click="toggle_agent"
              phx-value-agent_id={@agent.agent_id}
              phx-target={@myself}
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
            <!-- Terminal-style streaming output -->
            <div class="relative">
              <div class="flex items-center justify-between mb-2">
                <h4 class="font-medium text-sm flex items-center gap-2">
                  <.icon name="hero-command-line" class="w-4 h-4" /> Agent Output
                  <%= if @is_running do %>
                    <span class="badge badge-xs badge-info">LIVE</span>
                  <% end %>
                </h4>
                <% char_count = String.length(@output) %>
                <%= if char_count > 0 do %>
                  <span class="text-xs text-base-content/40">{char_count} chars</span>
                <% end %>
              </div>
              
    <!-- Terminal window -->
              <div class="rounded-lg overflow-hidden border border-base-300 shadow-inner">
                <!-- Terminal header bar -->
                <div class="bg-base-300 px-3 py-1.5 flex items-center gap-2 border-b border-base-content/10">
                  <div class="flex gap-1.5">
                    <span class="w-3 h-3 rounded-full bg-error/60"></span>
                    <span class="w-3 h-3 rounded-full bg-warning/60"></span>
                    <span class="w-3 h-3 rounded-full bg-success/60"></span>
                  </div>
                  <span class="text-xs text-base-content/50 font-mono ml-2">
                    agent@ipa ~ streaming
                  </span>
                </div>
                
    <!-- Terminal content -->
                <div
                  class="p-4 font-mono text-sm min-h-[200px] max-h-[500px] overflow-y-auto scroll-smooth"
                  style="background-color: #1e1e2e; color: #cdd6f4;"
                  id={"terminal-#{@agent.agent_id}"}
                  phx-hook="AutoScroll"
                >
                  <%= if @output != "" do %>
                    <pre class="whitespace-pre-wrap break-words leading-relaxed"><%= @output %></pre>
                    <%= if @is_running do %>
                      <span
                        class="inline-block w-2 h-4 animate-pulse ml-0.5"
                        style="background-color: #89b4fa;"
                      >
                      </span>
                    <% end %>
                  <% else %>
                    <div class="flex items-center gap-2" style="color: #6c7086;">
                      <span style="color: #89b4fa;">$</span>
                      <%= if @is_running do %>
                        <span>Waiting for agent output...</span>
                        <span
                          class="inline-block w-2 h-4 animate-pulse"
                          style="background-color: #89b4fa;"
                        >
                        </span>
                      <% else %>
                        <span>No output recorded</span>
                      <% end %>
                    </div>
                  <% end %>
                </div>
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
            
    <!-- Collapsible prompt -->
            <details class="collapse collapse-arrow bg-base-200 rounded-lg">
              <summary class="collapse-title text-sm font-medium py-2 min-h-0">
                <span class="flex items-center gap-2">
                  <.icon name="hero-document-text" class="w-4 h-4" /> Prompt
                </span>
              </summary>
              <div class="collapse-content">
                <div class="text-sm text-base-content/70 whitespace-pre-wrap font-mono bg-base-300 rounded p-3 max-h-48 overflow-y-auto">
                  {Map.get(@agent, :prompt) || "No prompt available"}
                </div>
              </div>
            </details>
            
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
