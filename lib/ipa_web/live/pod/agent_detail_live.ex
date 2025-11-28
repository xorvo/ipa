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
      |> assign(message_input: "")
      |> assign(batch_messages: [])
      |> assign(batch_mode: false)

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

          # Initialize streaming_output with persisted output only if:
          # - Agent is completed/failed AND has output AND has no conversation history
          # This is a fallback for agents that completed before conversation history was implemented
          streaming_output =
            if agent && agent.status in [:completed, :failed] && agent.output &&
                 Enum.empty?(agent.conversation_history || []) do
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
                <span class="font-semibold text-lg">{format_agent_type(@agent.agent_type)}</span>
                <%= if @agent.status == :running do %>
                  <span class="loading loading-spinner loading-sm text-info"></span>
                  <span class="badge badge-info badge-sm">LIVE</span>
                <% else %>
                  <span class={"badge badge-sm #{status_badge_class(@agent.status)}"}>
                    {format_status(@agent.status)}
                  </span>
                <% end %>
              </div>
              <%= if @agent.workstream_id do %>
                <span class="text-sm text-base-content/60 font-mono">
                  Workstream: {@agent.workstream_id}
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
                <.icon name="hero-stop" class="w-4 h-4" /> Stop Agent
              </button>
            <% end %>
            <%= if @agent.status in [:failed, :interrupted] do %>
              <button
                phx-click="restart_agent"
                class="btn btn-sm btn-warning gap-1"
              >
                <.icon name="hero-arrow-path" class="w-4 h-4" /> Restart Agent
              </button>
            <% end %>
          </div>
        </div>
        
    <!-- Metadata bar -->
        <div class="flex items-center gap-6 px-4 py-2 bg-base-100 border-b border-base-300 text-sm text-base-content/60 font-mono">
          <span class="flex items-center gap-1">
            <.icon name="hero-finger-print" class="w-4 h-4" />
            {@agent.agent_id}
          </span>
          <%= if @agent.started_at do %>
            <span class="flex items-center gap-1">
              <.icon name="hero-play" class="w-4 h-4" /> Started: {format_time(@agent.started_at)}
            </span>
          <% end %>
          <%= if @agent.completed_at do %>
            <span class="flex items-center gap-1">
              <.icon name="hero-check" class="w-4 h-4" />
              Completed: {format_time(@agent.completed_at)}
            </span>
          <% end %>
        </div>
        
    <!-- Main content - Conversation panel -->
        <div class="flex-1 overflow-hidden flex flex-col">
          <!-- Header bar -->
          <div class="px-4 py-2 flex items-center justify-between border-b border-base-300 bg-base-100">
            <span class="text-sm font-medium text-base-content/70">Conversation</span>
            <div class="flex items-center gap-3">
              <% conversation = @agent.conversation_history || [] %>
              <%= if length(conversation) > 0 do %>
                <span class="text-xs text-base-content/40">{length(conversation)} messages</span>
              <% end %>
              <%= if @agent.status == :running do %>
                <span class="badge badge-xs badge-info gap-1">
                  <span class="w-1.5 h-1.5 bg-info-content rounded-full animate-pulse"></span> Live
                </span>
              <% end %>
            </div>
          </div>
          
    <!-- Conversation content -->
          <div
            class="flex-1 p-4 overflow-y-auto bg-base-200"
            id="agent-detail-conversation"
            phx-hook="AutoScroll"
          >
            <% conversation = @agent.conversation_history || [] %>
            <div class="space-y-4">
              <!-- Conversation history with interleaved responses -->
              <%= for {msg, idx} <- Enum.with_index(conversation) do %>
                <.conversation_bubble
                  role={msg.role || :user}
                  content={msg.content}
                  label={get_message_label(msg)}
                  timestamp={Map.get(msg, :timestamp)}
                  batch_id={Map.get(msg, :batch_id)}
                />
                
    <!-- Show streaming agent response only while actively running -->
                <%= if idx == length(conversation) - 1 && @streaming_output != "" && @agent.status == :running do %>
                  <.conversation_bubble
                    role={:assistant}
                    content={@streaming_output}
                    label="Agent"
                    is_streaming={true}
                  />
                <% end %>
              <% end %>
              
    <!-- If no conversation but we have output, show it -->
              <%= if Enum.empty?(conversation) && @streaming_output != "" do %>
                <.conversation_bubble
                  role={:assistant}
                  content={@streaming_output}
                  label="Agent"
                  is_streaming={@agent.status == :running}
                />
              <% end %>
              
    <!-- Empty state -->
              <%= if Enum.empty?(conversation) && @streaming_output == "" do %>
                <div class="text-center py-8 text-base-content/50">
                  <.icon name="hero-chat-bubble-left-right" class="w-12 h-12 mx-auto mb-3 opacity-30" />
                  <p class="text-sm">
                    <%= if @agent.status == :running do %>
                      Waiting for agent output...
                    <% else %>
                      No conversation recorded
                    <% end %>
                  </p>
                </div>
              <% end %>
            </div>
          </div>
        </div>
        
    <!-- Error banner if failed -->
        <%= if @agent.error do %>
          <div class="alert alert-error rounded-none">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <div>
              <h4 class="font-bold">Agent Error</h4>
              <p class="text-sm">{@agent.error}</p>
            </div>
          </div>
        <% end %>
        
    <!-- Message input panel for interactive agents -->
        <%= if @agent.status == :awaiting_input do %>
          <div class="border-t border-base-300 bg-base-100 p-4">
            <!-- Batch messages preview -->
            <%= if length(@batch_messages) > 0 do %>
              <div class="mb-3 space-y-2">
                <div class="flex items-center justify-between">
                  <span class="text-sm font-medium text-base-content/70">
                    Pending messages ({length(@batch_messages)})
                  </span>
                  <button
                    phx-click="clear_batch"
                    class="btn btn-xs btn-ghost text-error"
                  >
                    Clear all
                  </button>
                </div>
                <div class="bg-base-200 rounded-lg p-2 max-h-32 overflow-y-auto space-y-1">
                  <%= for {msg, idx} <- Enum.with_index(@batch_messages) do %>
                    <div class="flex items-center gap-2 text-sm">
                      <span class="badge badge-xs badge-primary">{idx + 1}</span>
                      <span class="flex-1 truncate">{msg}</span>
                      <button
                        phx-click="remove_batch_message"
                        phx-value-index={idx}
                        class="btn btn-xs btn-ghost btn-circle text-error"
                      >
                        <.icon name="hero-x-mark" class="w-3 h-3" />
                      </button>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
            
    <!-- Message input form -->
            <form
              phx-submit={if @batch_mode, do: "add_to_batch", else: "send_message"}
              class="flex flex-col gap-3"
            >
              <div class="flex gap-2">
                <textarea
                  name="message"
                  value={@message_input}
                  phx-change="update_message_input"
                  class="textarea textarea-bordered flex-1 min-h-[60px]"
                  placeholder="Type a message to the agent..."
                  rows="2"
                ></textarea>
              </div>
              <div class="flex items-center justify-between">
                <div class="flex items-center gap-2">
                  <label class="label cursor-pointer gap-2">
                    <input
                      type="checkbox"
                      class="checkbox checkbox-sm checkbox-primary"
                      checked={@batch_mode}
                      phx-click="toggle_batch_mode"
                    />
                    <span class="label-text text-sm">Batch mode</span>
                  </label>
                  <%= if @batch_mode do %>
                    <span class="text-xs text-base-content/50">
                      Add multiple messages before sending
                    </span>
                  <% end %>
                </div>
                <div class="flex items-center gap-2">
                  <%= if @batch_mode && length(@batch_messages) > 0 do %>
                    <button
                      type="button"
                      phx-click="send_batch"
                      class="btn btn-primary btn-sm gap-1"
                    >
                      <.icon name="hero-paper-airplane" class="w-4 h-4" />
                      Send {length(@batch_messages)} messages
                    </button>
                  <% end %>
                  <%= if @batch_mode do %>
                    <button
                      type="submit"
                      class="btn btn-sm btn-outline gap-1"
                      disabled={@message_input == ""}
                    >
                      <.icon name="hero-plus" class="w-4 h-4" /> Add to batch
                    </button>
                  <% else %>
                    <button
                      type="submit"
                      class="btn btn-primary btn-sm gap-1"
                      disabled={@message_input == ""}
                    >
                      <.icon name="hero-paper-airplane" class="w-4 h-4" /> Send
                    </button>
                  <% end %>
                  <button
                    type="button"
                    phx-click="mark_done"
                    class="btn btn-success btn-sm gap-1"
                  >
                    <.icon name="hero-check" class="w-4 h-4" /> Mark Done
                  </button>
                </div>
              </div>
            </form>
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

  def handle_event("restart_agent", _params, socket) do
    agent_id = socket.assigns.agent_id
    task_id = socket.assigns.task_id
    Logger.info("Restarting agent from detail view", agent_id: agent_id)

    case Ipa.Pod.Manager.restart_agent(task_id, agent_id, "user") do
      {:ok, new_agent_id, _version} ->
        Logger.info("Agent restarted", old_agent_id: agent_id, new_agent_id: new_agent_id)

        {:noreply,
         put_flash(socket, :info, "Agent restarted - close this view and start the new agent")}

      {:error, :agent_not_found} ->
        {:noreply, put_flash(socket, :error, "Agent not found")}

      {:error, :agent_not_restartable} ->
        {:noreply,
         put_flash(socket, :warning, "Only failed or interrupted agents can be restarted")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to restart agent: #{inspect(reason)}")}
    end
  end

  def handle_event("update_message_input", %{"message" => message}, socket) do
    {:noreply, assign(socket, message_input: message)}
  end

  def handle_event("toggle_batch_mode", _params, socket) do
    {:noreply, assign(socket, batch_mode: !socket.assigns.batch_mode)}
  end

  def handle_event("add_to_batch", %{"message" => message}, socket) do
    if String.trim(message) != "" do
      batch_messages = socket.assigns.batch_messages ++ [message]
      {:noreply, assign(socket, batch_messages: batch_messages, message_input: "")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_batch_message", %{"index" => index}, socket) do
    idx = String.to_integer(index)
    batch_messages = List.delete_at(socket.assigns.batch_messages, idx)
    {:noreply, assign(socket, batch_messages: batch_messages)}
  end

  def handle_event("clear_batch", _params, socket) do
    {:noreply, assign(socket, batch_messages: [], message_input: "")}
  end

  def handle_event("send_message", %{"message" => message}, socket) do
    if String.trim(message) == "" do
      {:noreply, socket}
    else
      agent_id = socket.assigns.agent_id
      Logger.info("Sending message to agent", agent_id: agent_id)

      # First record the message in the event store
      task_id = socket.assigns.task_id
      Ipa.Pod.Manager.send_agent_message(task_id, agent_id, message, %{sent_by: "user"})

      # Then send the message to the agent
      case Ipa.Agent.send_message(agent_id, message) do
        :ok ->
          # Reset streaming output for new response
          {:noreply, assign(socket, message_input: "", streaming_output: "")}

        {:error, :not_awaiting_input} ->
          {:noreply, put_flash(socket, :warning, "Agent is not waiting for input")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to send message: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("send_batch", _params, socket) do
    batch_messages = socket.assigns.batch_messages

    if length(batch_messages) == 0 do
      {:noreply, socket}
    else
      agent_id = socket.assigns.agent_id
      task_id = socket.assigns.task_id

      Logger.info("Sending batch of #{length(batch_messages)} messages to agent",
        agent_id: agent_id
      )

      # Combine all batch messages into one message with clear separation
      combined_message =
        batch_messages
        |> Enum.with_index(1)
        |> Enum.map(fn {msg, idx} -> "Comment #{idx}:\n#{msg}" end)
        |> Enum.join("\n\n---\n\n")

      # Generate a batch_id for tracking
      batch_id = Ecto.UUID.generate()

      # Record the batch message in the event store
      Ipa.Pod.Manager.send_agent_message(task_id, agent_id, combined_message, %{
        sent_by: "user",
        batch_id: batch_id
      })

      # Send the combined message to the agent
      case Ipa.Agent.send_message(agent_id, combined_message) do
        :ok ->
          {:noreply,
           assign(socket,
             batch_messages: [],
             batch_mode: false,
             message_input: "",
             streaming_output: ""
           )}

        {:error, :not_awaiting_input} ->
          {:noreply, put_flash(socket, :warning, "Agent is not waiting for input")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to send batch: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("mark_done", _params, socket) do
    agent_id = socket.assigns.agent_id
    task_id = socket.assigns.task_id
    Logger.info("Marking agent as done", agent_id: agent_id)

    # First record in Pod.Manager (updates event store)
    case Ipa.Pod.Manager.mark_agent_done(task_id, agent_id, %{marked_by: "user"}) do
      {:ok, _version} ->
        # Then mark done on the instance (stops session)
        case Ipa.Agent.mark_done(agent_id, "User marked as done") do
          :ok ->
            {:noreply, put_flash(socket, :info, "Agent marked as done")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to mark done: #{inspect(reason)}")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to mark done: #{inspect(reason)}")}
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
      type
      when type in [
             "agent_started",
             "agent_completed",
             "agent_failed",
             "agent_status_changed",
             "agent_awaiting_input",
             "agent_manually_started",
             "agent_marked_done",
             "agent_response_received",
             "agent_message_sent"
           ] ->
        # Reload agent from state
        case Ipa.Pod.Manager.get_state_from_events(task_id) do
          {:ok, state} ->
            agent =
              Enum.find(state.agents || [], fn a -> a.agent_id == socket.assigns.agent_id end)

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

  defp conversation_bubble(assigns) do
    assigns =
      assigns
      |> Map.put_new(:timestamp, nil)
      |> Map.put_new(:batch_id, nil)
      |> Map.put_new(:is_streaming, false)

    ~H"""
    <div class={bubble_container_class(@role)}>
      <!-- Avatar/Icon -->
      <div class={bubble_avatar_class(@role)}>
        <%= case @role do %>
          <% :system -> %>
            <.icon name="hero-cog-6-tooth" class="w-4 h-4" />
          <% :user -> %>
            <.icon name="hero-user" class="w-4 h-4" />
          <% :assistant -> %>
            <.icon name="hero-cpu-chip" class="w-4 h-4" />
          <% _ -> %>
            <.icon name="hero-chat-bubble-left" class="w-4 h-4" />
        <% end %>
      </div>
      
    <!-- Message content -->
      <div class="flex-1 min-w-0">
        <!-- Header -->
        <div class="flex items-center gap-2 mb-1">
          <span class={bubble_label_class(@role)}>{@label}</span>
          <%= if @timestamp do %>
            <span class="text-xs text-base-content/40">{format_timestamp(@timestamp)}</span>
          <% end %>
          <%= if @batch_id do %>
            <span class="badge badge-xs badge-ghost">batch</span>
          <% end %>
          <%= if @is_streaming do %>
            <span class="badge badge-xs badge-info gap-1">
              <span class="w-1 h-1 bg-info-content rounded-full animate-pulse"></span> typing
            </span>
          <% end %>
        </div>
        
    <!-- Content -->
        <div class={bubble_content_class(@role)}>
          <div class="text-sm whitespace-pre-wrap break-words">{@content}</div>
          <%= if @is_streaming do %>
            <span class="inline-block w-1.5 h-4 bg-info animate-pulse ml-0.5"></span>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp bubble_container_class(:user), do: "flex gap-3 justify-end"
  defp bubble_container_class(_), do: "flex gap-3"

  defp bubble_avatar_class(:system),
    do:
      "w-8 h-8 rounded-full bg-base-300 flex items-center justify-center text-base-content/60 flex-shrink-0"

  defp bubble_avatar_class(:user),
    do:
      "w-8 h-8 rounded-full bg-primary flex items-center justify-center text-primary-content flex-shrink-0 order-last"

  defp bubble_avatar_class(:assistant),
    do:
      "w-8 h-8 rounded-full bg-secondary flex items-center justify-center text-secondary-content flex-shrink-0"

  defp bubble_avatar_class(_),
    do:
      "w-8 h-8 rounded-full bg-base-300 flex items-center justify-center text-base-content/60 flex-shrink-0"

  defp bubble_label_class(:system), do: "text-xs font-medium text-base-content/60"
  defp bubble_label_class(:user), do: "text-xs font-medium text-primary"
  defp bubble_label_class(:assistant), do: "text-xs font-medium text-secondary"
  defp bubble_label_class(_), do: "text-xs font-medium text-base-content/60"

  defp bubble_content_class(:system),
    do:
      "bg-base-300/50 rounded-lg rounded-tl-none p-3 text-base-content/80 max-h-48 overflow-y-auto"

  defp bubble_content_class(:user),
    do: "bg-primary/10 rounded-lg rounded-tr-none p-3 text-base-content"

  defp bubble_content_class(:assistant),
    do:
      "bg-neutral text-neutral-content/90 rounded-lg rounded-tl-none p-3 max-h-[500px] overflow-y-auto"

  defp bubble_content_class(_), do: "bg-base-100 rounded-lg p-3"

  defp format_timestamp(nil), do: ""

  defp format_timestamp(unix) when is_integer(unix) do
    case DateTime.from_unix(unix) do
      {:ok, dt} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> ""
    end
  end

  defp format_timestamp(_), do: ""

  # ============================================================================
  # Helpers
  # ============================================================================

  defp status_color(:initializing), do: "bg-warning"
  defp status_color(:running), do: "bg-info"
  defp status_color(:awaiting_input), do: "bg-accent"
  defp status_color(:pending_start), do: "bg-warning"
  defp status_color(:completed), do: "bg-success"
  defp status_color(:failed), do: "bg-error"
  defp status_color(:interrupted), do: "bg-warning"
  defp status_color(_), do: "bg-base-300"

  defp status_badge_class(:completed), do: "badge-success"
  defp status_badge_class(:failed), do: "badge-error"
  defp status_badge_class(:interrupted), do: "badge-warning"
  defp status_badge_class(:awaiting_input), do: "badge-accent"
  defp status_badge_class(:pending_start), do: "badge-warning"
  defp status_badge_class(_), do: "badge-ghost"

  defp format_status(:completed), do: "Completed"
  defp format_status(:failed), do: "Failed"
  defp format_status(:interrupted), do: "Interrupted"
  defp format_status(:awaiting_input), do: "Awaiting Input"
  defp format_status(:pending_start), do: "Pending Start"
  defp format_status(status), do: status |> Atom.to_string() |> String.capitalize()

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

  # Get the display label for a conversation message
  defp get_message_label(%{role: :assistant}), do: "Agent"
  defp get_message_label(%{role: "assistant"}), do: "Agent"
  defp get_message_label(%{role: :system}), do: "Initial Prompt"
  defp get_message_label(%{role: "system"}), do: "Initial Prompt"

  defp get_message_label(%{sent_by: sent_by}) when is_binary(sent_by) and sent_by != "",
    do: sent_by

  defp get_message_label(%{role: :user}), do: "User"
  defp get_message_label(%{role: "user"}), do: "User"
  defp get_message_label(_), do: "User"
end
