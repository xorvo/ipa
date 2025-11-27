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
    end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <h3 class="text-lg font-semibold">Active Agents</h3>
        <span class="badge badge-primary"><%= length(@agents || []) %> agents</span>
      </div>

      <%= if Enum.empty?(@agents || []) do %>
        <div class="text-center py-8 text-base-content/60">
          <.icon name="hero-cpu-chip" class="w-12 h-12 mx-auto mb-2 opacity-50" />
          <p>No agents currently running</p>
          <p class="text-sm">Agents will appear here when workstreams start executing</p>
        </div>
      <% else %>
        <div class="space-y-3">
          <%= for agent <- @agents do %>
            <.agent_card
              agent={agent}
              expanded={MapSet.member?(@expanded_agents, agent.agent_id)}
              streaming_output={Map.get(@streaming_outputs, agent.agent_id, "")}
              myself={@myself}
            />
          <% end %>
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
  def handle_info({:agent_stream, agent_id, {:text_delta, text}}, socket) do
    streaming_outputs = socket.assigns.streaming_outputs
    current = Map.get(streaming_outputs, agent_id, "")
    new_outputs = Map.put(streaming_outputs, agent_id, current <> text)

    {:noreply, assign(socket, streaming_outputs: new_outputs)}
  end

  # Handle tool use events
  def handle_info({:agent_stream, agent_id, {:tool_use_start, tool_name, _args}}, socket) do
    streaming_outputs = socket.assigns.streaming_outputs
    current = Map.get(streaming_outputs, agent_id, "")
    marker = "\n[Using tool: #{tool_name}...]\n"
    new_outputs = Map.put(streaming_outputs, agent_id, current <> marker)

    {:noreply, assign(socket, streaming_outputs: new_outputs)}
  end

  def handle_info({:agent_stream, agent_id, {:tool_complete, tool_name, _result}}, socket) do
    streaming_outputs = socket.assigns.streaming_outputs
    current = Map.get(streaming_outputs, agent_id, "")
    marker = "[Tool #{tool_name} complete]\n"
    new_outputs = Map.put(streaming_outputs, agent_id, current <> marker)

    {:noreply, assign(socket, streaming_outputs: new_outputs)}
  end

  # Handle agent lifecycle events
  def handle_info({:agent_started, agent_id, _data}, socket) do
    Logger.debug("Agent started in panel", agent_id: agent_id)
    # Subscribe to this agent's stream
    Phoenix.PubSub.subscribe(Ipa.PubSub, "agent:#{agent_id}:stream")
    {:noreply, socket}
  end

  def handle_info({:agent_completed, agent_id, _data}, socket) do
    Logger.debug("Agent completed in panel", agent_id: agent_id)
    # Unsubscribe from agent stream
    Phoenix.PubSub.unsubscribe(Ipa.PubSub, "agent:#{agent_id}:stream")
    {:noreply, socket}
  end

  def handle_info({:agent_failed, agent_id, _data}, socket) do
    Logger.debug("Agent failed in panel", agent_id: agent_id)
    Phoenix.PubSub.unsubscribe(Ipa.PubSub, "agent:#{agent_id}:stream")
    {:noreply, socket}
  end

  def handle_info({:agent_interrupted, agent_id, _data}, socket) do
    Logger.debug("Agent interrupted in panel", agent_id: agent_id)
    Phoenix.PubSub.unsubscribe(Ipa.PubSub, "agent:#{agent_id}:stream")
    {:noreply, socket}
  end

  # Catch-all for other stream events
  def handle_info({:agent_stream, _agent_id, _event}, socket) do
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ============================================================================
  # Components
  # ============================================================================

  defp agent_card(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body p-4">
        <!-- Header -->
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-3">
            <.agent_status_indicator status={@agent.status} />
            <div>
              <span class="font-medium"><%= format_agent_type(@agent.agent_type) %></span>
              <%= if @agent.workstream_id do %>
                <span class="text-sm text-base-content/60 ml-2">
                  (<%= @agent.workstream_id %>)
                </span>
              <% end %>
            </div>
          </div>

          <div class="flex items-center gap-2">
            <%= if @agent.status == :running do %>
              <button
                phx-click="interrupt_agent"
                phx-value-agent_id={@agent.agent_id}
                phx-target={@myself}
                class="btn btn-xs btn-error btn-outline"
              >
                <.icon name="hero-stop" class="w-3 h-3" />
                Stop
              </button>
            <% end %>

            <button
              phx-click="toggle_agent"
              phx-value-agent_id={@agent.agent_id}
              phx-target={@myself}
              class="btn btn-xs btn-ghost"
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
        <div class="flex items-center gap-4 text-sm text-base-content/60 mt-2">
          <span>ID: <%= String.slice(@agent.agent_id, 0, 8) %>...</span>
          <%= if @agent.started_at do %>
            <span>Started: <%= format_time(@agent.started_at) %></span>
          <% end %>
          <%= if @agent.completed_at do %>
            <span>Completed: <%= format_time(@agent.completed_at) %></span>
          <% end %>
        </div>

        <!-- Expanded content -->
        <%= if @expanded do %>
          <div class="mt-4 space-y-4">
            <!-- Prompt -->
            <div>
              <h4 class="font-medium text-sm mb-2">Prompt</h4>
              <div class="bg-base-300 rounded p-3 text-sm font-mono whitespace-pre-wrap max-h-48 overflow-y-auto">
                <%= Map.get(@agent, :prompt) || "No prompt available" %>
              </div>
            </div>

            <!-- Streaming output -->
            <%= if @streaming_output != "" or Map.get(@agent, :current_response, "") != "" do %>
              <div>
                <h4 class="font-medium text-sm mb-2 flex items-center gap-2">
                  Response
                  <%= if @agent.status == :running do %>
                    <span class="loading loading-dots loading-xs"></span>
                  <% end %>
                </h4>
                <div class="bg-base-300 rounded p-3 text-sm font-mono whitespace-pre-wrap max-h-96 overflow-y-auto">
                  <%= @streaming_output || Map.get(@agent, :current_response) || "Waiting for response..." %>
                </div>
              </div>
            <% end %>

            <!-- Tool calls -->
            <% tool_calls = Map.get(@agent, :tool_calls, []) %>
            <%= if length(tool_calls) > 0 do %>
              <div>
                <h4 class="font-medium text-sm mb-2">Tool Calls (<%= length(tool_calls) %>)</h4>
                <div class="space-y-2 max-h-64 overflow-y-auto">
                  <%= for {tool, idx} <- Enum.with_index(tool_calls) do %>
                    <div class="bg-base-300 rounded p-2 text-sm">
                      <span class="badge badge-sm badge-outline mr-2"><%= idx + 1 %></span>
                      <span class="font-medium"><%= tool.name %></span>
                      <%= if tool.status == :complete do %>
                        <span class="badge badge-sm badge-success ml-2">Done</span>
                      <% else %>
                        <span class="badge badge-sm badge-warning ml-2">Running</span>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>

            <!-- Error -->
            <%= if @agent.error do %>
              <div class="alert alert-error">
                <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                <span><%= @agent.error %></span>
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
  defp format_agent_type(type) when is_atom(type), do: type |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  defp format_agent_type(type) when is_binary(type), do: String.replace(type, "_", " ") |> String.capitalize()
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
