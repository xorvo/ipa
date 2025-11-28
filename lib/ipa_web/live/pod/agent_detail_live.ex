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
      |> assign(plan: nil)
      |> assign(show_plan_preview: false)
      |> assign(streaming_output: "")
      |> assign(message_input: "")
      |> assign(batch_messages: [])
      |> assign(batch_mode: false)

    if connected?(socket) && task_id && agent_id do
      Logger.info("AgentDetailLive mounted for agent #{agent_id}, pid=#{inspect(self())}")

      # Subscribe to this agent's stream for live updates (text deltas, tool events)
      stream_topic = "agent:#{agent_id}:stream"
      Logger.info("AgentDetailLive subscribing to #{stream_topic}, pid=#{inspect(self())}")
      Phoenix.PubSub.subscribe(Ipa.PubSub, stream_topic)

      # Subscribe to state update topic (signals state has changed)
      state_topic = "agent:#{agent_id}:state"
      Logger.info("AgentDetailLive subscribing to #{state_topic}")
      Phoenix.PubSub.subscribe(Ipa.PubSub, state_topic)

      # Subscribe to EventStore for agent events (for plan updates and lifecycle)
      Ipa.EventStore.subscribe(task_id)

      # Load initial agent state - prefer live Instance state if agent is running
      socket = load_agent_state(socket, task_id, agent_id)

      {:ok, socket}
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
            <%= if @agent.status == :running && !Ipa.Agent.Instance.alive?(@agent.agent_id) do %>
              <span class="badge badge-warning gap-1">
                <.icon name="hero-exclamation-triangle" class="w-3 h-3" /> Process Dead
              </span>
              <button
                phx-click="mark_agent_failed"
                class="btn btn-sm btn-error gap-1"
              >
                <.icon name="hero-x-circle" class="w-4 h-4" /> Mark Failed
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
            class="flex-1 p-4 overflow-y-auto bg-neutral text-neutral-content/90 font-mono"
            id="agent-detail-conversation"
            phx-hook="AutoScroll"
          >
            <% conversation = @agent.conversation_history || [] %>
            <div class="space-y-1">
              <!-- Conversation history with interleaved responses -->
              <%= for {msg, idx} <- Enum.with_index(conversation) do %>
                <.conversation_bubble
                  role={msg.role || :user}
                  content={msg.content}
                  label={get_message_label(msg)}
                  timestamp={Map.get(msg, :timestamp)}
                  batch_id={Map.get(msg, :batch_id)}
                />

    <!-- Show streaming agent response after the last message -->
                <%= if idx == length(conversation) - 1 && @streaming_output != "" do %>
                  <.conversation_bubble
                    role={:assistant}
                    content={@streaming_output}
                    label="Agent"
                    is_streaming={Ipa.Agent.Instance.alive?(@agent.agent_id)}
                  />
                <% end %>
              <% end %>

    <!-- If no conversation but we have output, show it -->
              <%= if Enum.empty?(conversation) && @streaming_output != "" do %>
                <.conversation_bubble
                  role={:assistant}
                  content={@streaming_output}
                  label="Agent"
                  is_streaming={Ipa.Agent.Instance.alive?(@agent.agent_id)}
                />
              <% end %>

    <!-- Empty state -->
              <%= if Enum.empty?(conversation) && @streaming_output == "" do %>
                <div class="text-center py-8 text-neutral-content/50">
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
                <div class="flex items-center gap-3">
                  <label class="flex items-center gap-2 cursor-pointer">
                    <span class="text-sm text-base-content/70">Batch</span>
                    <input
                      type="checkbox"
                      class="toggle toggle-sm toggle-primary"
                      checked={@batch_mode}
                      phx-click="toggle_batch_mode"
                    />
                  </label>
                  <%= if @batch_mode do %>
                    <span class="text-xs text-base-content/50">
                      Queue multiple messages
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
                  <%= if @plan && is_planning_agent?(@agent) do %>
                    <button
                      type="button"
                      phx-click="show_plan_preview"
                      class="btn btn-outline btn-sm gap-1"
                    >
                      <.icon name="hero-document-text" class="w-4 h-4" /> Preview Plan
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

    <!-- Plan Preview Modal -->
        <%= if @show_plan_preview && @plan do %>
          <div class="modal modal-open">
            <div class="modal-box max-w-4xl max-h-[80vh]">
              <div class="flex items-center justify-between mb-4">
                <h3 class="font-bold text-lg">Plan Preview</h3>
                <button phx-click="hide_plan_preview" class="btn btn-sm btn-ghost btn-circle">
                  <.icon name="hero-x-mark" class="w-5 h-5" />
                </button>
              </div>

              <%= if @plan[:summary] || @plan["summary"] do %>
                <div class="mb-4">
                  <h4 class="text-sm font-medium text-base-content/70 mb-2">Summary</h4>
                  <div class="text-sm whitespace-pre-wrap bg-base-200 p-3 rounded-lg">
                    {@plan[:summary] || @plan["summary"]}
                  </div>
                </div>
              <% end %>

              <% workstreams = @plan[:workstreams] || @plan["workstreams"] || [] %>
              <%= if length(workstreams) > 0 do %>
                <div>
                  <h4 class="text-sm font-medium text-base-content/70 mb-2">
                    Workstreams ({length(workstreams)})
                  </h4>
                  <div class="space-y-3 max-h-[400px] overflow-y-auto">
                    <%= for {ws, idx} <- Enum.with_index(workstreams) do %>
                      <div class="bg-base-200 p-3 rounded-lg">
                        <div class="flex items-start gap-2">
                          <span class="badge badge-sm badge-primary">{idx + 1}</span>
                          <div class="flex-1">
                            <div class="font-medium text-sm">
                              {ws[:title] || ws["title"] || "Untitled Workstream"}
                            </div>
                            <%= if ws[:spec] || ws["spec"] do %>
                              <div class="text-xs text-base-content/70 mt-1 whitespace-pre-wrap">
                                {ws[:spec] || ws["spec"]}
                              </div>
                            <% end %>
                            <%= if (ws[:dependencies] || ws["dependencies"] || []) != [] do %>
                              <div class="text-xs text-base-content/50 mt-2">
                                Dependencies: {Enum.join(ws[:dependencies] || ws["dependencies"], ", ")}
                              </div>
                            <% end %>
                          </div>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% else %>
                <div class="text-center py-4 text-base-content/50">
                  <p class="text-sm">No workstreams defined yet</p>
                </div>
              <% end %>

              <div class="modal-action">
                <button phx-click="hide_plan_preview" class="btn">Close</button>
              </div>
            </div>
            <div class="modal-backdrop" phx-click="hide_plan_preview"></div>
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
  def handle_event("show_plan_preview", _params, socket) do
    {:noreply, assign(socket, show_plan_preview: true)}
  end

  def handle_event("hide_plan_preview", _params, socket) do
    {:noreply, assign(socket, show_plan_preview: false)}
  end

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

  def handle_event("mark_agent_failed", _params, socket) do
    agent_id = socket.assigns.agent_id
    task_id = socket.assigns.task_id
    Logger.info("Marking dead agent as failed from detail view", agent_id: agent_id)

    # Emit a failed event for the agent since the process died without proper cleanup
    case Ipa.Pod.Manager.fail_agent(task_id, agent_id, "Process crashed or was killed", "system") do
      {:ok, _version} ->
        {:noreply, put_flash(socket, :info, "Agent marked as failed")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to mark agent as failed: #{inspect(reason)}")}
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
    Logger.debug("AgentDetailLive received text_delta for #{agent_id}: #{String.slice(text, 0, 30)}...")
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
             "agent_message_sent",
             "plan_created",
             "plan_updated"
           ] ->
        # Reload agent and plan from state
        case Ipa.Pod.Manager.get_state_from_events(task_id) do
          {:ok, state} ->
            agent =
              Enum.find(state.agents || [], fn a -> a.agent_id == socket.assigns.agent_id end)

            # Clear streaming output when response is received (it's now in conversation_history)
            socket =
              if type == "agent_response_received" do
                assign(socket, streaming_output: "")
              else
                socket
              end

            {:noreply, assign(socket, agent: agent, plan: state.plan)}

          {:error, _} ->
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # Handle state update signal from Agent.Instance
  def handle_info({:state_updated, agent_id}, socket)
      when agent_id == socket.assigns.agent_id do
    Logger.debug("AgentDetailLive received state_updated for #{agent_id}")
    socket = load_agent_state(socket, socket.assigns.task_id, agent_id)
    {:noreply, socket}
  end

  # Catch-all for other messages
  def handle_info(msg, socket) do
    Logger.debug("AgentDetailLive catch-all received: #{inspect(msg, limit: 100)}")
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

  # Claude Code style message display - stream of text with user messages highlighted
  defp conversation_bubble(assigns) do
    assigns =
      assigns
      |> Map.put_new(:timestamp, nil)
      |> Map.put_new(:batch_id, nil)
      |> Map.put_new(:is_streaming, false)

    ~H"""
    <div class={message_container_class(@role)}>
      <%= if is_user_message?(@role) do %>
        <!-- User message - highlighted with border -->
        <div class="pl-3 border-l-2 border-primary">
          <div class="flex items-center gap-2 mb-1">
            <span class="text-xs font-medium text-primary">{@label}</span>
            <%= if @timestamp do %>
              <span class="text-xs text-neutral-content/50">{format_timestamp(@timestamp)}</span>
            <% end %>
            <%= if @batch_id do %>
              <span class="badge badge-xs badge-ghost">batch</span>
            <% end %>
          </div>
          <div class="text-sm whitespace-pre-wrap break-words text-neutral-content">{@content}</div>
        </div>
      <% else %>
        <!-- System/Assistant message - plain text stream -->
        <div class={if @role == :system, do: "text-neutral-content/60 text-xs", else: ""}>
          <%= if @role == :system do %>
            <div class="flex items-center gap-2 mb-1">
              <span class="text-xs text-neutral-content/40">{@label}</span>
            </div>
          <% end %>
          <div class="text-xs whitespace-pre-wrap font-mono text-neutral-content">{@content}<%= if @is_streaming do %><span class="inline-block w-1.5 h-4 bg-info animate-pulse ml-0.5 align-middle"></span><% end %></div>
        </div>
      <% end %>
    </div>
    """
  end

  defp message_container_class(:user), do: "py-2"
  defp message_container_class(:system), do: "py-1 opacity-70"
  defp message_container_class(_), do: "py-1"

  defp is_user_message?(:user), do: true
  defp is_user_message?("user"), do: true
  defp is_user_message?(_), do: false

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

  # Check if agent is a planning agent
  defp is_planning_agent?(%{agent_type: :planning}), do: true
  defp is_planning_agent?(%{agent_type: :planning_agent}), do: true
  defp is_planning_agent?(%{agent_type: "planning"}), do: true
  defp is_planning_agent?(%{agent_type: "planning_agent"}), do: true
  defp is_planning_agent?(_), do: false

  # Load agent state - prefer live Instance state if agent is running
  defp load_agent_state(socket, task_id, agent_id) do
    # First try to get live state from Agent.Instance
    instance_state =
      case Ipa.Agent.Instance.get_state(agent_id) do
        {:ok, state} -> state
        {:error, :not_found} -> nil
      end

    # Get persisted state from EventStore
    persisted_state =
      case Ipa.Pod.Manager.get_state_from_events(task_id) do
        {:ok, state} ->
          agent = Enum.find(state.agents || [], fn a -> a.agent_id == agent_id end)
          %{agent: agent, plan: state.plan}

        {:error, _} ->
          %{agent: nil, plan: nil}
      end

    # Merge the states - prefer Instance state for live data
    agent =
      if instance_state do
        # Agent process is alive - build agent map from Instance state
        # but keep any fields from persisted state that Instance doesn't track
        base_agent = persisted_state.agent || %{}

        # Convert Instance state to agent-like map, merging with persisted fields
        %{
          agent_id: instance_state.agent_id,
          agent_type: instance_state.agent_type,
          workstream_id: instance_state.workstream_id,
          workspace_path: instance_state.workspace_path,
          status: instance_state.status,
          started_at: instance_state.started_at,
          completed_at: instance_state.completed_at,
          error: instance_state.error,
          # Use Instance's unified conversation history
          conversation_history: convert_to_ui_format(instance_state.conversation_history || []),
          # Use Instance's streaming text for current turn
          output: instance_state.current_turn_text,
          interactive: instance_state.interactive
        }
        |> Map.merge(Map.take(base_agent, [:prompt]))
      else
        # Agent process not alive - use persisted state
        # Convert old format to new format if needed
        if persisted_state.agent do
          agent = persisted_state.agent
          # Ensure conversation_history is in the new format
          history = agent.conversation_history || []
          converted_history = convert_to_ui_format(history)
          Map.put(agent, :conversation_history, converted_history)
        else
          nil
        end
      end

    # Determine streaming output - only for live agents with current turn text
    streaming_output =
      if instance_state && instance_state.current_turn_text != "" do
        instance_state.current_turn_text
      else
        ""
      end

    Logger.info("AgentDetailLive loaded agent state",
      agent_id: agent_id,
      from_instance: instance_state != nil,
      status: agent && agent.status,
      history_length: length((agent && agent.conversation_history) || [])
    )

    socket
    |> assign(agent: agent, plan: persisted_state.plan)
    |> assign(streaming_output: streaming_output)
  end

  # Convert unified conversation history to UI format
  # The new format has :type instead of :role, so we convert for display
  defp convert_to_ui_format(history) when is_list(history) do
    Enum.map(history, fn entry ->
      type = entry[:type] || entry["type"]

      case type do
        t when t in [:system, "system"] ->
          %{role: :system, content: entry[:content] || entry["content"], timestamp: entry[:timestamp] || entry["timestamp"]}

        t when t in [:user, "user"] ->
          %{role: :user, content: entry[:content] || entry["content"], sent_by: entry[:sent_by] || entry["sent_by"], timestamp: entry[:timestamp] || entry["timestamp"]}

        t when t in [:assistant, "assistant"] ->
          %{role: :assistant, content: entry[:content] || entry["content"], timestamp: entry[:timestamp] || entry["timestamp"]}

        t when t in [:tool_call, "tool_call"] ->
          # Display tool calls as assistant messages
          tool_name = entry[:name] || entry["name"]
          args = entry[:args] || entry["args"] || %{}
          content = "🔧 Using tool: #{tool_name}\nArgs: #{inspect(args, pretty: true, limit: 500)}"
          %{role: :assistant, content: content, timestamp: entry[:timestamp] || entry["timestamp"]}

        t when t in [:tool_result, "tool_result"] ->
          # Display tool results as assistant messages
          tool_name = entry[:name] || entry["name"]
          result = entry[:result] || entry["result"]
          content = "✓ Tool #{tool_name} complete\nResult: #{truncate_for_display(result)}"
          %{role: :assistant, content: content, timestamp: entry[:timestamp] || entry["timestamp"]}

        _ ->
          # Old format with :role key - pass through
          entry
      end
    end)
  end

  defp convert_to_ui_format(nil), do: []

  defp truncate_for_display(nil), do: "(no output)"
  defp truncate_for_display(result) when is_binary(result) do
    if String.length(result) > 500 do
      String.slice(result, 0, 500) <> "..."
    else
      result
    end
  end
  defp truncate_for_display(result), do: inspect(result, limit: 500)
end
