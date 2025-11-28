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

    editor = Application.get_env(:ipa, :editor_command)

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
      |> assign(editor: editor)

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

    <!-- Main content - Conversation panel -->
        <div class="flex-1 overflow-hidden flex flex-col">
          <!-- Header bar with metadata -->
          <div class="px-2 py-1 flex flex-col gap-1 border-b border-base-300 bg-base-100 text-xs text-base-content/60 font-mono">
            <!-- Row 1: Basic info -->
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-3">
                <span class="flex items-center gap-1">
                  <.icon name="hero-finger-print" class="w-3 h-3" />
                  {@agent.agent_id}
                </span>
                <%= if @agent.started_at do %>
                  <span class="flex items-center gap-1">
                    <.icon name="hero-play" class="w-3 h-3" /> {format_time(@agent.started_at)}
                  </span>
                <% end %>
                <%= if @agent.completed_at do %>
                  <span class="flex items-center gap-1">
                    <.icon name="hero-check" class="w-3 h-3" /> {format_time(@agent.completed_at)}
                  </span>
                <% end %>
              </div>
              <div class="flex items-center gap-2">
                <% conversation = @agent.conversation_history || [] %>
                <%= if length(conversation) > 0 do %>
                  <span class="text-base-content/40">{length(conversation)} msgs</span>
                <% end %>
                <%= if @agent.status == :running do %>
                  <span class="badge badge-xs badge-info gap-1">
                    <span class="w-1 h-1 bg-info-content rounded-full animate-pulse"></span> Live
                  </span>
                <% end %>
              </div>
            </div>
            <!-- Row 2: Workspace path -->
            <%= if @agent.workspace_path do %>
              <div class="flex items-center justify-between gap-2">
                <div class="flex items-center gap-1 flex-1 min-w-0">
                  <.icon name="hero-folder" class="w-3 h-3 flex-shrink-0" />
                  <span class="truncate" title={@agent.workspace_path}>{@agent.workspace_path}</span>
                </div>
                <div class="flex items-center gap-1 flex-shrink-0">
                  <%= if @editor do %>
                    <button
                      phx-click="open_in_editor"
                      phx-value-path={@agent.workspace_path}
                      class="btn btn-ghost btn-xs tooltip tooltip-left"
                      data-tip={"Open in #{@editor}"}
                    >
                      <.icon name="hero-code-bracket" class="w-3 h-3" />
                    </button>
                  <% end %>
                  <button
                    phx-click={JS.dispatch("phx:copy", to: "#workspace-path-#{@agent.agent_id}")}
                    class="btn btn-ghost btn-xs tooltip tooltip-left"
                    data-tip="Copy path"
                  >
                    <.icon name="hero-clipboard-document" class="w-3 h-3" />
                  </button>
                </div>
                <input type="hidden" id={"workspace-path-#{@agent.agent_id}"} value={@agent.workspace_path} />
              </div>
            <% end %>
          </div>

    <!-- Conversation content -->
          <div
            class="flex-1 p-4 overflow-y-auto bg-[#0d1117] text-neutral-content/80 font-mono text-sm"
            id="agent-detail-conversation"
            phx-hook="AutoScroll"
          >
            <% conversation = @agent.conversation_history || [] %>
            <div class="space-y-2">
              <!-- Conversation history with interleaved responses -->
              <%= for {msg, idx} <- Enum.with_index(conversation) do %>
                <%= case msg.role do %>
                  <% :tool_call -> %>
                    <.tool_call_entry
                      name={msg.name}
                      args={msg.args}
                      idx={idx}
                      editor={@editor}
                    />
                  <% :tool_result -> %>
                    <.tool_result_entry
                      name={msg.name}
                      result={msg.result}
                      idx={idx}
                      editor={@editor}
                    />
                  <% _ -> %>
                    <.conversation_bubble
                      role={msg.role || :user}
                      content={msg.content}
                      label={get_message_label(msg)}
                      idx={idx}
                      batch_id={Map.get(msg, :batch_id)}
                    />
                <% end %>

    <!-- Show streaming agent response after the last message -->
                <%= if idx == length(conversation) - 1 && @streaming_output != "" do %>
                  <.conversation_bubble
                    role={:assistant}
                    content={@streaming_output}
                    label="Agent"
                    idx={"streaming-#{idx}"}
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
                  idx="streaming-only"
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

  # Open workspace in editor
  def handle_event("open_in_editor", %{"path" => path}, socket) do
    editor = socket.assigns.editor

    if editor do
      Task.start(fn ->
        case System.cmd(editor, [path], stderr_to_stdout: true) do
          {_output, 0} ->
            Logger.info("Opened #{path} in #{editor}")

          {output, exit_code} ->
            Logger.warning("Failed to open editor: exit code #{exit_code}, output: #{output}")
        end
      end)

      {:noreply, put_flash(socket, :info, "Opening in #{editor}...")}
    else
      {:noreply, put_flash(socket, :error, "No editor configured")}
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
      |> Map.put_new(:idx, nil)
      |> Map.put_new(:batch_id, nil)
      |> Map.put_new(:is_streaming, false)

    ~H"""
    <div class={message_container_class(@role)}>
      <%= if is_user_message?(@role) do %>
        <!-- User message - highlighted with border -->
        <div class="pl-2 border-l border-primary/50">
          <div class="flex items-center gap-2 mb-0.5">
            <span class="text-[11px] font-normal text-primary/70">{@label}</span>
            <%= if @batch_id do %>
              <span class="badge badge-xs badge-ghost">batch</span>
            <% end %>
          </div>
          <div class="text-xs font-light whitespace-pre-wrap break-words text-neutral-content/80">{@content}</div>
        </div>
      <% else %>
        <!-- System/Assistant message - render as markdown -->
        <div class={if @role == :system, do: "text-neutral-content/50 text-[11px]", else: ""}>
          <%= if @role == :system do %>
            <div class="flex items-center gap-2 mb-0.5">
              <span class="text-[10px] text-neutral-content/30">{@label}</span>
            </div>
            <div class="text-[11px] font-light whitespace-pre-wrap font-mono text-neutral-content/60">{@content}</div>
          <% else %>
            <div
              id={"markdown-#{@idx || :erlang.phash2(@content)}"}
              class="prose prose-sm prose-invert max-w-none text-neutral-content/70 markdown-content font-light"
              phx-hook="Markdown"
              data-content={@content}
            ><%= if @is_streaming do %><span class="inline-block w-1.5 h-4 bg-info animate-pulse ml-0.5 align-middle"></span><% end %></div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # Tool call entry - collapsible with special handling for Edit tool
  defp tool_call_entry(assigns) do
    assigns = Map.put_new(assigns, :editor, nil)
    tool_glyph = get_tool_glyph(assigns.name)
    is_edit_tool = assigns.name in ["Edit", "MultiEdit"]
    file_path = get_file_path_from_args(assigns.args)

    assigns =
      assigns
      |> Map.put(:tool_glyph, tool_glyph)
      |> Map.put(:is_edit_tool, is_edit_tool)
      |> Map.put(:file_path, file_path)

    ~H"""
    <div class="group" phx-hook="Collapsible" id={"tool-call-#{@idx}"}>
      <div class="flex items-center gap-1.5 cursor-pointer select-none py-0.5 px-1 -mx-1 rounded hover:bg-neutral-600 transition-colors" data-collapse-toggle>
        <span class="text-neutral-content/40 text-xs">{@tool_glyph}</span>
        <span class="text-[11px] font-normal text-neutral-content/50">{@name}</span>
        <%= if @file_path do %>
          <%= if @editor do %>
            <button
              phx-click="open_in_editor"
              phx-value-path={@file_path}
              class="text-[11px] text-neutral-content/40 hover:text-neutral-content/60 hover:underline font-mono"
              title={"Open in #{@editor}"}
            >
              {truncate_path(@file_path)}
            </button>
          <% else %>
            <span class="text-[11px] text-neutral-content/40 font-mono">{truncate_path(@file_path)}</span>
          <% end %>
        <% end %>
        <span class="flex-1"></span>
        <span class="text-neutral-content/30 opacity-0 group-hover:opacity-100 transition-all duration-200 text-xs" data-collapse-icon-wrapper>›</span>
      </div>
      <div class="mt-1 ml-4" data-collapse-content>
        <%= if @is_edit_tool do %>
          <.edit_tool_detail args={@args} />
        <% else %>
          <pre class="text-[10px] bg-black/30 rounded p-2 overflow-x-auto max-h-60 text-neutral-content/60"><code>{format_args(@args)}</code></pre>
        <% end %>
      </div>
    </div>
    """
  end

  # Tool result entry - collapsible
  defp tool_result_entry(assigns) do
    assigns = Map.put_new(assigns, :editor, nil)
    is_success = !is_error_result?(assigns.result)

    assigns =
      assigns
      |> Map.put(:is_success, is_success)

    ~H"""
    <div class="group" phx-hook="Collapsible" id={"tool-result-#{@idx}"}>
      <div class="flex items-center gap-1.5 cursor-pointer select-none py-0.5 px-1 -mx-1 rounded hover:bg-white/5 transition-colors" data-collapse-toggle>
        <%= if @is_success do %>
          <span class="text-success/60 text-xs">✓</span>
        <% else %>
          <span class="text-error/60 text-xs">✗</span>
        <% end %>
        <span class={"text-[11px] font-normal #{if @is_success, do: "text-neutral-content/40", else: "text-error/60"}"}>{@name} result</span>
        <span class="flex-1"></span>
        <span class="text-neutral-content/30 opacity-0 group-hover:opacity-100 transition-all duration-200 text-xs" data-collapse-icon-wrapper>›</span>
      </div>
      <div class="mt-1 ml-4" data-collapse-content>
        <pre class="text-[10px] bg-black/30 rounded p-2 overflow-x-auto max-h-60 whitespace-pre-wrap text-neutral-content/60"><code>{truncate_result(@result)}</code></pre>
      </div>
    </div>
    """
  end

  # Edit tool detail with diff view - renders inline diff without JS hook
  defp edit_tool_detail(assigns) do
    old_string = get_in(assigns.args, ["old_string"]) || assigns.args[:old_string] || ""
    new_string = get_in(assigns.args, ["new_string"]) || assigns.args[:new_string] || ""
    file_path = get_in(assigns.args, ["file_path"]) || assigns.args[:file_path] || "file"

    # Compute unified diff lines
    diff_lines = compute_unified_diff(old_string, new_string)

    assigns =
      assigns
      |> Map.put(:old_string, old_string)
      |> Map.put(:new_string, new_string)
      |> Map.put(:file_path, file_path)
      |> Map.put(:diff_lines, diff_lines)

    ~H"""
    <div class="diff-view">
      <%= if @old_string != "" || @new_string != "" do %>
        <div class="rounded border border-neutral-content/10 overflow-hidden text-xs font-mono bg-[#0d1117]">
          <%= for {type, content} <- @diff_lines do %>
            <div class={diff_line_class(type)}>
              <span class={diff_gutter_class(type)}>{diff_symbol(type)}</span>
              <pre class="flex-1 px-2 py-px overflow-x-auto">{content}</pre>
            </div>
          <% end %>
        </div>
      <% else %>
        <div class="text-xs text-neutral-content/40 italic">No changes</div>
      <% end %>
    </div>
    """
  end

  # Compute a simple unified diff showing removed/added lines in sequence
  defp compute_unified_diff(old_string, new_string) do
    old_lines = String.split(old_string, "\n")
    new_lines = String.split(new_string, "\n")

    # Simple diff: find common prefix/suffix, show changes in middle
    {common_prefix, old_rest, new_rest} = find_common_prefix(old_lines, new_lines)
    {common_suffix, old_changed, new_changed} = find_common_suffix(old_rest, new_rest)

    prefix_lines = Enum.map(common_prefix, &{:context, &1})
    removed_lines = Enum.map(old_changed, &{:removed, &1})
    added_lines = Enum.map(new_changed, &{:added, &1})
    suffix_lines = Enum.map(common_suffix, &{:context, &1})

    # Interleave removed and added for better visual comparison
    changed_lines = interleave_changes(removed_lines, added_lines)

    prefix_lines ++ changed_lines ++ suffix_lines
  end

  defp find_common_prefix([], new_lines), do: {[], [], new_lines}
  defp find_common_prefix(old_lines, []), do: {[], old_lines, []}
  defp find_common_prefix([h | old_rest], [h | new_rest]) do
    {prefix, old_remaining, new_remaining} = find_common_prefix(old_rest, new_rest)
    {[h | prefix], old_remaining, new_remaining}
  end
  defp find_common_prefix(old_lines, new_lines), do: {[], old_lines, new_lines}

  defp find_common_suffix(old_lines, new_lines) do
    old_rev = Enum.reverse(old_lines)
    new_rev = Enum.reverse(new_lines)
    {suffix_rev, old_rest_rev, new_rest_rev} = find_common_prefix(old_rev, new_rev)
    {Enum.reverse(suffix_rev), Enum.reverse(old_rest_rev), Enum.reverse(new_rest_rev)}
  end

  # Interleave removed and added lines for better visual comparison
  defp interleave_changes(removed, added) do
    max_len = max(length(removed), length(added))
    removed_padded = removed ++ List.duplicate(nil, max_len - length(removed))
    added_padded = added ++ List.duplicate(nil, max_len - length(added))

    Enum.zip(removed_padded, added_padded)
    |> Enum.flat_map(fn
      {nil, nil} -> []
      {nil, add} -> [add]
      {rem, nil} -> [rem]
      {rem, add} -> [rem, add]
    end)
  end

  defp diff_line_class(:context), do: "flex text-[#c9d1d9] bg-transparent"
  defp diff_line_class(:removed), do: "flex bg-[#3c1f1f] text-[#f98181]"
  defp diff_line_class(:added), do: "flex bg-[#1f3c2a] text-[#7ee787]"

  defp diff_gutter_class(:context), do: "w-5 text-center text-[#484f58] bg-[#161b22] select-none shrink-0"
  defp diff_gutter_class(:removed), do: "w-5 text-center text-[#f98181] bg-[#4d2020] select-none shrink-0"
  defp diff_gutter_class(:added), do: "w-5 text-center text-[#7ee787] bg-[#1a4d2a] select-none shrink-0"

  defp diff_symbol(:context), do: " "
  defp diff_symbol(:removed), do: "-"
  defp diff_symbol(:added), do: "+"

  defp message_container_class(:user), do: "py-2"
  defp message_container_class(:system), do: "py-1 opacity-70"
  defp message_container_class(_), do: "py-1"

  defp is_user_message?(:user), do: true
  defp is_user_message?("user"), do: true
  defp is_user_message?(_), do: false

  # Tool helpers - returns Unicode glyph for tool type
  defp get_tool_glyph("Read"), do: "📄"
  defp get_tool_glyph("Edit"), do: "✎"
  defp get_tool_glyph("MultiEdit"), do: "✎"
  defp get_tool_glyph("Write"), do: "📝"
  defp get_tool_glyph("Bash"), do: "⌘"
  defp get_tool_glyph("Glob"), do: "📂"
  defp get_tool_glyph("Grep"), do: "🔍"
  defp get_tool_glyph("Task"), do: "📋"
  defp get_tool_glyph("WebFetch"), do: "🌐"
  defp get_tool_glyph("TodoWrite"), do: "☰"
  defp get_tool_glyph(_), do: "⚙"

  defp get_file_path_from_args(args) when is_map(args) do
    get_in(args, ["file_path"]) || args[:file_path] || get_in(args, ["path"]) || args[:path]
  end
  defp get_file_path_from_args(_), do: nil

  defp truncate_path(nil), do: ""
  defp truncate_path(path) when is_binary(path) do
    if String.length(path) > 50 do
      "..." <> String.slice(path, -47, 47)
    else
      path
    end
  end

  defp format_args(args) when is_map(args) do
    inspect(args, pretty: true, limit: 1000, width: 80)
  end
  defp format_args(args), do: inspect(args)

  defp is_error_result?(result) when is_binary(result) do
    String.contains?(String.downcase(result), ["error", "failed", "exception"])
  end
  defp is_error_result?(_), do: false

  defp truncate_result(nil), do: "(no output)"
  defp truncate_result(result) when is_binary(result) do
    if String.length(result) > 2000 do
      String.slice(result, 0, 2000) <> "\n... (truncated)"
    else
      result
    end
  end
  defp truncate_result(result), do: inspect(result, limit: 500, pretty: true)

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
  # Preserve tool_call and tool_result types for specialized rendering
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
          # Preserve tool call structure for specialized rendering
          %{
            role: :tool_call,
            name: entry[:name] || entry["name"],
            args: entry[:args] || entry["args"] || %{},
            timestamp: entry[:timestamp] || entry["timestamp"]
          }

        t when t in [:tool_result, "tool_result"] ->
          # Preserve tool result structure for specialized rendering
          %{
            role: :tool_result,
            name: entry[:name] || entry["name"],
            result: entry[:result] || entry["result"],
            timestamp: entry[:timestamp] || entry["timestamp"]
          }

        _ ->
          # Old format with :role key - pass through
          entry
      end
    end)
  end

  defp convert_to_ui_format(nil), do: []
end
