defmodule IpaWeb.Pod.AgentDetailLive do
  @moduledoc """
  Nested LiveView for displaying detailed agent execution view.

  This view maintains focus on a single agent even when its status changes,
  solving the issue of output collapsing when agents complete.

  ## Usage

  This view is rendered as a modal from the AgentPanelLive when a user
  clicks to view agent details.
  """

  use IpaWeb, :live_view

  require Logger

  @impl true
  def mount(_params, session, socket) do
    task_id = session["task_id"]
    agent_id = session["agent_id"]

    socket =
      socket
      |> assign(task_id: task_id)
      |> assign(agent_id: agent_id)
      |> assign(agent: nil)
      |> assign(streaming_output: "")

    if connected?(socket) && task_id && agent_id do
      Logger.info("AgentDetailLive mounted for agent #{agent_id}")

      # Subscribe to this agent's stream for live updates
      Phoenix.PubSub.subscribe(Ipa.PubSub, "agent:#{agent_id}:stream")

      # Subscribe to EventStore for agent events
      Ipa.EventStore.subscribe(task_id)

      # Load initial agent state
      case Ipa.Pod.Manager.get_state_from_events(task_id) do
        {:ok, state} ->
          agent = Enum.find(state.agents || [], fn a -> a.agent_id == agent_id end)

          # Initialize streaming_output with persisted output if agent has completed
          streaming_output =
            if agent && agent.status in [:completed, :failed] && agent.output do
              agent.output
            else
              ""
            end

          {:ok, assign(socket, agent: agent, streaming_output: streaming_output)}

        {:error, _} ->
          {:ok, socket}
      end
    else
      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <%= if @agent do %>
        <!-- Header -->
        <div class="flex items-center justify-between p-4 border-b border-base-300 bg-base-200">
          <div class="flex items-center gap-3">
            <.agent_status_indicator status={@agent.status} />
            <div>
              <div class="flex items-center gap-2">
                <span class="font-semibold text-lg"><%= format_agent_type(@agent.agent_type) %></span>
                <%= if @agent.status == :running do %>
                  <span class="loading loading-spinner loading-sm text-info"></span>
                  <span class="badge badge-info badge-sm">LIVE</span>
                <% else %>
                  <span class={"badge badge-sm #{status_badge_class(@agent.status)}"}>
                    <%= format_status(@agent.status) %>
                  </span>
                <% end %>
              </div>
              <%= if @agent.workstream_id do %>
                <span class="text-sm text-base-content/60 font-mono">
                  Workstream: <%= @agent.workstream_id %>
                </span>
              <% end %>
            </div>
          </div>

          <div class="flex items-center gap-2">
            <%= if @agent.status == :running && Ipa.Agent.Instance.alive?(@agent.agent_id) do %>
              <button
                phx-click="interrupt_agent"
                class="btn btn-sm btn-error gap-1"
              >
                <.icon name="hero-stop" class="w-4 h-4" />
                Stop Agent
              </button>
            <% end %>
          </div>
        </div>

        <!-- Metadata bar -->
        <div class="flex items-center gap-6 px-4 py-2 bg-base-100 border-b border-base-300 text-sm text-base-content/60 font-mono">
          <span class="flex items-center gap-1">
            <.icon name="hero-finger-print" class="w-4 h-4" />
            <%= @agent.agent_id %>
          </span>
          <%= if @agent.started_at do %>
            <span class="flex items-center gap-1">
              <.icon name="hero-play" class="w-4 h-4" />
              Started: <%= format_time(@agent.started_at) %>
            </span>
          <% end %>
          <%= if @agent.completed_at do %>
            <span class="flex items-center gap-1">
              <.icon name="hero-check" class="w-4 h-4" />
              Completed: <%= format_time(@agent.completed_at) %>
            </span>
          <% end %>
        </div>

        <!-- Main content - Output panel -->
        <div class="flex-1 overflow-hidden flex flex-col">
          <!-- Header bar -->
          <div class="px-4 py-2 flex items-center justify-between border-b border-base-300 bg-base-100">
            <span class="text-sm font-medium text-base-content/70">Agent Output</span>
            <div class="flex items-center gap-3">
              <% char_count = String.length(@streaming_output) %>
              <%= if char_count > 0 do %>
                <span class="text-xs text-base-content/40"><%= char_count %> chars</span>
              <% end %>
              <%= if @agent.status == :running do %>
                <span class="badge badge-xs badge-info gap-1">
                  <span class="w-1.5 h-1.5 bg-info-content rounded-full animate-pulse"></span>
                  Live
                </span>
              <% end %>
            </div>
          </div>

          <!-- Output content -->
          <div
            class="flex-1 p-4 overflow-y-auto bg-neutral text-neutral-content/90"
            id="agent-detail-terminal"
            phx-hook="AutoScroll"
          >
            <%= if @streaming_output != "" do %>
              <div class="text-xs leading-relaxed whitespace-pre-wrap break-words"><%= @streaming_output %></div>
              <%= if @agent.status == :running do %>
                <span class="inline-block w-1.5 h-3 bg-info animate-pulse ml-0.5"></span>
              <% end %>
            <% else %>
              <div class="text-xs text-neutral-content/50">
                <%= if @agent.status == :running do %>
                  Waiting for agent output...
                <% else %>
                  No output recorded
                <% end %>
              </div>
            <% end %>
          </div>
        </div>

        <!-- Error banner if failed -->
        <%= if @agent.error do %>
          <div class="alert alert-error rounded-none">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <div>
              <h4 class="font-bold">Agent Error</h4>
              <p class="text-sm"><%= @agent.error %></p>
            </div>
          </div>
        <% end %>
      <% else %>
        <div class="flex-1 flex items-center justify-center">
          <div class="text-center">
            <.icon name="hero-cpu-chip" class="w-12 h-12 text-base-content/30 mx-auto mb-4" />
            <p class="text-base-content/50">Agent not found</p>
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
  def handle_event("interrupt_agent", _params, socket) do
    agent_id = socket.assigns.agent_id
    Logger.info("Interrupting agent from detail view", agent_id: agent_id)

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

  @impl true
  def handle_info({:text_delta, agent_id, %{text: text}}, socket)
      when agent_id == socket.assigns.agent_id do
    current = socket.assigns.streaming_output
    {:noreply, assign(socket, streaming_output: current <> text)}
  end

  def handle_info({:tool_start, agent_id, %{tool_name: tool_name}}, socket)
      when agent_id == socket.assigns.agent_id do
    current = socket.assigns.streaming_output
    marker = "\n🔧 Using tool: #{tool_name}...\n"
    {:noreply, assign(socket, streaming_output: current <> marker)}
  end

  def handle_info({:tool_complete, agent_id, %{tool_name: tool_name}}, socket)
      when agent_id == socket.assigns.agent_id do
    current = socket.assigns.streaming_output
    marker = "✓ Tool #{tool_name} complete\n"
    {:noreply, assign(socket, streaming_output: current <> marker)}
  end

  # Handle EventStore broadcasts to update agent state
  def handle_info({:event_appended, task_id, event}, socket)
      when task_id == socket.assigns.task_id do
    case event.event_type do
      type when type in ["agent_started", "agent_completed", "agent_failed", "agent_status_changed"] ->
        # Reload agent from state
        case Ipa.Pod.Manager.get_state_from_events(task_id) do
          {:ok, state} ->
            agent = Enum.find(state.agents || [], fn a -> a.agent_id == socket.assigns.agent_id end)
            {:noreply, assign(socket, agent: agent)}

          {:error, _} ->
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # Catch-all for other messages
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ============================================================================
  # Components
  # ============================================================================

  defp agent_status_indicator(assigns) do
    ~H"""
    <div class={"relative w-4 h-4 rounded-full #{status_color(@status)}"}>
      <%= if @status == :running do %>
        <span class="absolute inset-0 rounded-full animate-ping bg-info/50"></span>
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

  defp status_badge_class(:completed), do: "badge-success"
  defp status_badge_class(:failed), do: "badge-error"
  defp status_badge_class(:interrupted), do: "badge-warning"
  defp status_badge_class(_), do: "badge-ghost"

  defp format_status(:completed), do: "Completed"
  defp format_status(:failed), do: "Failed"
  defp format_status(:interrupted), do: "Interrupted"
  defp format_status(status), do: status |> Atom.to_string() |> String.capitalize()

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
