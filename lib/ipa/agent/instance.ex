defmodule Ipa.Agent.Instance do
  @moduledoc """
  GenServer that manages a single agent's execution lifecycle.

  Each agent instance:
  - Registers itself in PodRegistry for lookup
  - Uses ClaudeAgentSdkTs.Session for multi-turn conversations
  - Processes streaming messages and updates internal state
  - Records lifecycle events to Event Store (source of truth)
  - Broadcasts streaming updates to PubSub (for LiveView)
  - Handles interruption and cleanup

  ## Interactive Mode

  When `interactive: true` (default), the agent:
  - Runs the initial prompt
  - Transitions to :awaiting_input status when complete
  - Waits for user messages via `send_message/2`
  - Can be marked done via `mark_done/1`

  ## State

  The instance maintains rich state including:
  - Agent identity (id, type, task_id, workstream_id)
  - Execution status (:initializing, :running, :awaiting_input, :completed, :failed, :interrupted)
  - Session state (Claude SDK Session PID)
  - Streaming output (conversation_history, current_turn_text)
  - Timing (started_at, completed_at)

  ## Event Store (Source of Truth)

  Lifecycle events are recorded to the Event Store:
  - `agent_started` - When agent begins execution
  - `agent_awaiting_input` - When agent is waiting for user input
  - `agent_completed` - When agent finishes successfully
  - `agent_failed` - When agent encounters an error
  - `agent_interrupted` - When agent is manually stopped

  ## PubSub (Notifications & Streaming)

  PubSub is used for:
  - `"agent:{agent_id}:stream"` - Ephemeral streaming updates (text_delta, tool events)
  - `"task:{task_id}:agents"` - Lifecycle notifications (no data, just signals)

  LiveViews should subscribe to PubSub for notifications, then fetch actual state
  from the Event Store via Pod.Manager.
  """

  use GenServer
  require Logger

  defstruct [
    :agent_id,
    :agent_type,
    :task_id,
    :workstream_id,
    :workspace_path,
    :prompt,
    :status,
    :started_at,
    :completed_at,
    :query_task,
    :session,
    :error,
    :context,
    # Unified linear conversation history - single source of truth
    # Each entry has: %{type: :system|:user|:assistant|:tool_call|:tool_result, ...}
    conversation_history: [],
    # Accumulator for current turn's text response (reset each turn)
    current_turn_text: "",
    # Current turn number (increments on each user message)
    turn_number: 0,
    interactive: true
  ]

  @type history_entry ::
          %{type: :system, content: String.t(), timestamp: integer()}
          | %{type: :user, content: String.t(), sent_by: String.t() | nil, timestamp: integer()}
          | %{type: :assistant, content: String.t(), timestamp: integer()}
          | %{
              type: :tool_call,
              name: String.t(),
              args: map(),
              call_id: String.t(),
              timestamp: integer()
            }
          | %{
              type: :tool_result,
              name: String.t(),
              result: String.t() | nil,
              call_id: String.t(),
              timestamp: integer()
            }

  @type t :: %__MODULE__{
          agent_id: String.t(),
          agent_type: module(),
          task_id: String.t(),
          workstream_id: String.t() | nil,
          workspace_path: String.t() | nil,
          prompt: String.t(),
          status:
            :initializing | :running | :awaiting_input | :completed | :failed | :interrupted,
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          query_task: Task.t() | nil,
          session: pid() | nil,
          error: String.t() | nil,
          context: map(),
          conversation_history: [history_entry()],
          current_turn_text: String.t(),
          turn_number: integer(),
          interactive: boolean()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts an agent instance under the pod's agent supervisor.
  """
  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(agent_id))
  end

  @doc """
  Gets the current state of an agent.
  """
  @spec get_state(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_state(agent_id) do
    case GenServer.whereis(via_tuple(agent_id)) do
      nil -> {:error, :not_found}
      pid -> {:ok, GenServer.call(pid, :get_state)}
    end
  end

  @doc """
  Checks if an agent process is alive.
  """
  @spec alive?(String.t()) :: boolean()
  def alive?(agent_id) do
    GenServer.whereis(via_tuple(agent_id)) != nil
  end

  @doc """
  Interrupts a running agent, canceling the SDK query.
  """
  @spec interrupt(String.t()) :: :ok | {:error, :not_found}
  def interrupt(agent_id) do
    case GenServer.whereis(via_tuple(agent_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :interrupt)
    end
  end

  @doc """
  Sends a message to an interactive agent.

  The agent must be in :awaiting_input status. The message will be sent to the
  Claude session and the agent will transition to :running while processing.
  """
  @spec send_message(String.t(), String.t()) :: :ok | {:error, term()}
  def send_message(agent_id, message) do
    case GenServer.whereis(via_tuple(agent_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:send_message, message}, 300_000)
    end
  end

  @doc """
  Marks an interactive agent as done/completed.

  This can be called when the user is satisfied with the agent's work and doesn't
  need to continue the conversation. The agent will transition to :completed status.
  """
  @spec mark_done(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def mark_done(agent_id, reason \\ nil) do
    case GenServer.whereis(via_tuple(agent_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:mark_done, reason})
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    agent_type = Keyword.fetch!(opts, :agent_type)
    task_id = Keyword.fetch!(opts, :task_id)
    context = Keyword.fetch!(opts, :context)

    Logger.info("Starting agent instance",
      agent_id: agent_id,
      agent_type: agent_type.agent_type(),
      task_id: task_id
    )

    # Generate prompt and options from the agent type module
    prompt = agent_type.generate_prompt(context)
    options = agent_type.configure_options(context)
    interactive = Map.get(options, :interactive, true)

    # Start a Claude Session for multi-turn conversations
    session_opts = convert_options_to_session_opts(options)
    {:ok, session} = ClaudeAgentSdkTs.Session.start_link(session_opts)

    state = %__MODULE__{
      agent_id: agent_id,
      agent_type: agent_type,
      task_id: task_id,
      workstream_id: context[:workstream_id],
      workspace_path: context[:workspace],
      prompt: prompt,
      status: :initializing,
      started_at: DateTime.utc_now(),
      session: session,
      conversation_history: [],
      current_turn_text: "",
      turn_number: 0,
      context: context,
      interactive: interactive
    }

    # Schedule notification and query to run after init completes
    # This prevents init from blocking on GenServer calls which can cause timeouts
    # NOTE: The agent_started event is already recorded by Pod.Manager through AgentCommands
    # when it starts this agent. We only need to broadcast the PubSub notification here.
    send(self(), :notify_agent_started)
    send(self(), {:run_query, prompt})

    {:ok, state}
  end

  @impl true
  def handle_info(:notify_agent_started, state) do
    # Notify via PubSub (just a signal, no data)
    # NOTE: The agent_started event is already recorded by Pod.Manager through AgentCommands
    # We only broadcast the notification here for real-time UI updates
    notify_lifecycle(state, :agent_started)

    {:noreply, state}
  end

  @impl true
  def handle_info({:run_query, prompt}, state) do
    # Add the initial prompt to conversation history
    system_entry = %{
      type: :system,
      content: prompt,
      timestamp: System.system_time(:second)
    }

    state = %{state | conversation_history: [system_entry]}

    # Spawn a Task to run the Claude SDK Session query
    # The Task sends messages back to this GenServer as they arrive
    parent = self()

    task =
      Task.async(fn ->
        run_session_query(state.session, prompt, parent)
      end)

    {:noreply, %{state | status: :running, query_task: task}}
  end

  # Handle streaming messages from the SDK query Task
  @impl true
  def handle_info({:stream_message, message}, state) do
    new_state = process_stream_message(message, state)
    {:noreply, new_state}
  end

  # Handle Task completion
  @impl true
  def handle_info({ref, result}, state)
      when state.query_task != nil and ref == state.query_task.ref do
    # Task completed - flush the monitor
    Process.demonitor(ref, [:flush])

    new_state =
      case result do
        {:ok, final_response} ->
          handle_agent_success(state, final_response)

        {:error, reason} ->
          handle_agent_failure(state, reason)
      end

    {:noreply, new_state}
  end

  # Handle Task crash
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when state.query_task != nil and ref == state.query_task.ref do
    new_state = handle_agent_failure(state, {:task_crashed, reason})
    {:noreply, new_state}
  end

  # Catch-all for unexpected messages
  @impl true
  def handle_info(msg, state) do
    Logger.debug("Agent instance ignoring message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    # Return a map representation of the state (not the struct)
    # This is the single source of truth for agent state
    state_map = %{
      agent_id: state.agent_id,
      agent_type: state.agent_type.agent_type(),
      task_id: state.task_id,
      workstream_id: state.workstream_id,
      workspace_path: state.workspace_path,
      prompt: state.prompt,
      status: state.status,
      started_at: state.started_at,
      completed_at: state.completed_at,
      error: state.error,
      # Unified conversation history - single source of truth
      conversation_history: state.conversation_history,
      # Current turn's accumulated text (for streaming display)
      current_turn_text: state.current_turn_text,
      turn_number: state.turn_number,
      interactive: state.interactive
    }

    {:reply, state_map, state}
  end

  @impl true
  def handle_call(:interrupt, _from, state) do
    Logger.info("Interrupting agent", agent_id: state.agent_id)

    # Cancel the running Task if present
    if state.query_task do
      Task.shutdown(state.query_task, :brutal_kill)
    end

    # Stop the session
    if state.session do
      ClaudeAgentSdkTs.Session.stop(state.session)
    end

    new_state = %{
      state
      | status: :interrupted,
        completed_at: DateTime.utc_now(),
        query_task: nil,
        session: nil
    }

    # Record to Event Store (source of truth)
    record_lifecycle_event(new_state, "agent_interrupted", %{
      agent_id: state.agent_id,
      interrupted_by: "user"
    })

    # Notify via PubSub
    notify_lifecycle(new_state, :agent_interrupted)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:send_message, message}, _from, state) do
    if state.status != :awaiting_input do
      {:reply, {:error, :not_awaiting_input}, state}
    else
      Logger.info("Sending message to agent session",
        agent_id: state.agent_id,
        message_preview: String.slice(message, 0, 50)
      )

      # Add user message to conversation history
      user_entry = %{
        type: :user,
        content: message,
        sent_by: "user",
        timestamp: System.system_time(:second)
      }

      # Reset current_turn_text for the new turn and increment turn number
      state = %{
        state
        | status: :running,
          current_turn_text: "",
          turn_number: state.turn_number + 1,
          conversation_history: state.conversation_history ++ [user_entry]
      }

      # Broadcast state update for UI
      broadcast_state_update(state)

      # Spawn a Task to run the message through the session
      parent = self()

      task =
        Task.async(fn ->
          run_session_query(state.session, message, parent)
        end)

      {:reply, :ok, %{state | query_task: task}}
    end
  end

  @impl true
  def handle_call({:mark_done, reason}, _from, state) do
    if state.status in [:completed, :failed, :interrupted] do
      {:reply, {:error, :already_terminal}, state}
    else
      Logger.info("Marking agent as done",
        agent_id: state.agent_id,
        reason: reason
      )

      # Cancel any running task
      if state.query_task do
        Task.shutdown(state.query_task, :brutal_kill)
      end

      # Stop the session
      if state.session do
        ClaudeAgentSdkTs.Session.stop(state.session)
      end

      new_state = %{
        state
        | status: :completed,
          completed_at: DateTime.utc_now(),
          query_task: nil,
          session: nil
      }

      # Persist final state snapshot
      persist_state_snapshot(new_state)

      # Record lifecycle event
      record_lifecycle_event(new_state, "agent_marked_done", %{
        agent_id: state.agent_id,
        marked_by: "user",
        reason: reason
      })

      # Call the agent type's completion handler (e.g., to process plan files)
      result = %{workspace: state.workspace_path, response: get_latest_response(new_state)}

      case state.agent_type.handle_completion(result, state.context) do
        :ok ->
          Logger.debug("Agent completion handler succeeded", agent_id: state.agent_id)

        {:error, handler_reason} ->
          Logger.warning("Agent completion handler failed",
            agent_id: state.agent_id,
            error: inspect(handler_reason)
          )
      end

      # Notify Pod.Manager of completion
      Ipa.Pod.Manager.notify_agent_completed(state.task_id, state.agent_id, result)

      # Notify via PubSub
      notify_lifecycle(new_state, :agent_completed)
      broadcast_state_update(new_state)

      {:reply, :ok, new_state}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Agent instance terminating",
      agent_id: state.agent_id,
      reason: inspect(reason)
    )

    # Cancel any running query task
    if state.query_task do
      Task.shutdown(state.query_task, :brutal_kill)
    end

    # Stop the session
    if state.session do
      try do
        ClaudeAgentSdkTs.Session.stop(state.session)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp via_tuple(agent_id) do
    {:via, Registry, {Ipa.PodRegistry, {:agent, agent_id}}}
  end

  defp run_session_query(session, prompt, parent) do
    # Use Session's stream/4 for streaming responses with conversation history
    ClaudeAgentSdkTs.Session.stream(session, prompt, [], fn message ->
      send(parent, {:stream_message, message})
    end)
    |> case do
      :ok ->
        {:ok, :completed}

      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp convert_options_to_session_opts(options) do
    # Convert from Ipa.Agent.Options struct to Session start_link options
    base_opts = []

    # Add cwd if present
    base_opts =
      if options.cwd do
        Keyword.put(base_opts, :cwd, options.cwd)
      else
        base_opts
      end

    # Add max_turns if present
    base_opts =
      if options.max_turns do
        Keyword.put(base_opts, :max_turns, options.max_turns)
      else
        base_opts
      end

    # Add timeout if present
    base_opts =
      if options.timeout_ms do
        Keyword.put(base_opts, :timeout, options.timeout_ms)
      else
        base_opts
      end

    # Add allowed_tools if present
    base_opts =
      if options.allowed_tools do
        Keyword.put(base_opts, :allowed_tools, options.allowed_tools)
      else
        base_opts
      end

    # Add permission_mode if present
    base_opts =
      if options.permission_mode do
        Keyword.put(base_opts, :permission_mode, options.permission_mode)
      else
        base_opts
      end

    base_opts
  end

  defp process_stream_message(message, state) do
    case Ipa.Agent.StreamHandler.classify_message(message) do
      {:text_delta, text} ->
        # Accumulate text for current turn
        new_turn_text = state.current_turn_text <> text
        # Broadcast streaming data via PubSub (for real-time LiveView updates)
        broadcast_stream(state, :text_delta, %{text: text})
        # Also broadcast state update signal so LiveView knows to refresh
        broadcast_state_update(state)
        %{state | current_turn_text: new_turn_text}

      {:tool_use_start, tool_name, args} ->
        # IMPORTANT: Flush any accumulated text BEFORE recording the tool call
        # This ensures text appears in the correct position relative to tool calls
        state = flush_accumulated_text(state)

        call_id = generate_tool_call_id()

        # Add tool_call entry to conversation history
        tool_call_entry = %{
          type: :tool_call,
          name: tool_name,
          args: args,
          call_id: call_id,
          timestamp: System.system_time(:second)
        }

        # Call agent type's tool call handler if defined
        if function_exported?(state.agent_type, :handle_tool_call, 3) do
          state.agent_type.handle_tool_call(tool_name, args, state.context)
        end

        # Broadcast streaming data via PubSub
        broadcast_stream(state, :tool_start, %{tool_name: tool_name, args: args, call_id: call_id})
        broadcast_state_update(state)

        %{state | conversation_history: state.conversation_history ++ [tool_call_entry]}

      {:tool_complete, tool_name, result} ->
        # Find the matching tool_call to get its call_id
        call_id =
          state.conversation_history
          |> Enum.reverse()
          |> Enum.find_value(fn
            %{type: :tool_call, name: ^tool_name, call_id: id} -> id
            _ -> nil
          end) || "unknown"

        # Add tool_result entry to conversation history
        tool_result_entry = %{
          type: :tool_result,
          name: tool_name,
          result: truncate_result(result),
          call_id: call_id,
          timestamp: System.system_time(:second)
        }

        # Broadcast streaming data via PubSub
        broadcast_stream(state, :tool_complete, %{tool_name: tool_name, result: result, call_id: call_id})
        broadcast_state_update(state)

        %{state | conversation_history: state.conversation_history ++ [tool_result_entry]}

      {:message_start, _data} ->
        # Message starting - no action needed, just acknowledge
        state

      {:message_stop, _data} ->
        # Message complete - text will be flushed at turn end
        state

      {:thinking, _thinking} ->
        # Extended thinking content - could be logged or displayed separately
        # For now, we ignore it as it's internal reasoning
        state

      {:result, result} ->
        # Final result message - treat as text if non-empty
        if result != "" do
          new_turn_text = state.current_turn_text <> result
          broadcast_stream(state, :text_delta, %{text: result})
          broadcast_state_update(state)
          %{state | current_turn_text: new_turn_text}
        else
          state
        end

      {:error, error} ->
        # Error from the SDK - log and potentially fail the agent
        Logger.error("Stream error for agent #{state.agent_id}: #{inspect(error)}")
        %{state | error: "Stream error: #{error}"}

      :unknown ->
        # Explicitly unknown/empty message - log at debug level and continue
        Logger.debug("Ignoring unknown/empty stream message for agent #{state.agent_id}")
        state

      other ->
        # Unexpected classification - crash to surface the issue
        raise "Unexpected stream message classification for agent #{state.agent_id}: #{inspect(other)}"
    end
  end

  # Flush any accumulated text to conversation history as an assistant entry
  defp flush_accumulated_text(state) do
    if state.current_turn_text != "" do
      assistant_entry = %{
        type: :assistant,
        content: state.current_turn_text,
        timestamp: System.system_time(:second)
      }

      %{
        state
        | conversation_history: state.conversation_history ++ [assistant_entry],
          current_turn_text: ""
      }
    else
      state
    end
  end

  # Truncate large tool results to prevent bloating conversation history
  defp truncate_result(nil), do: nil
  defp truncate_result(result) when is_binary(result) do
    if String.length(result) > 2000 do
      String.slice(result, 0, 2000) <> "... [truncated]"
    else
      result
    end
  end
  defp truncate_result(result), do: inspect(result, limit: 500)

  defp handle_agent_success(state, _final_messages) do
    Logger.info("Agent turn completed", agent_id: state.agent_id, interactive: state.interactive)

    # For interactive agents, transition to awaiting_input
    # For non-interactive agents, complete the agent
    if state.interactive do
      handle_interactive_turn_complete(state)
    else
      handle_final_completion(state)
    end
  end

  # Handle turn completion for interactive agents - transition to awaiting_input
  defp handle_interactive_turn_complete(state) do
    # Finalize the assistant's response by adding it to conversation history
    state =
      if state.current_turn_text != "" do
        assistant_entry = %{
          type: :assistant,
          content: state.current_turn_text,
          timestamp: System.system_time(:second)
        }

        %{
          state
          | conversation_history: state.conversation_history ++ [assistant_entry],
            current_turn_text: ""
        }
      else
        state
      end

    new_state = %{
      state
      | status: :awaiting_input,
        query_task: nil
    }

    # Persist state snapshot to EventStore
    persist_state_snapshot(new_state)

    # Record status change event
    record_lifecycle_event(new_state, "agent_awaiting_input", %{
      agent_id: new_state.agent_id,
      turn_number: new_state.turn_number
    })

    # Notify via PubSub
    notify_lifecycle(new_state, :agent_awaiting_input)
    broadcast_state_update(new_state)

    new_state
  end

  # Handle final completion for non-interactive agents
  defp handle_final_completion(state) do
    # Finalize the assistant's response by adding it to conversation history
    state =
      if state.current_turn_text != "" do
        assistant_entry = %{
          type: :assistant,
          content: state.current_turn_text,
          timestamp: System.system_time(:second)
        }

        %{
          state
          | conversation_history: state.conversation_history ++ [assistant_entry],
            current_turn_text: ""
        }
      else
        state
      end

    # Call the agent type's completion handler
    result = %{workspace: state.workspace_path, response: get_latest_response(state)}

    completion_result =
      case state.agent_type.handle_completion(result, state.context) do
        :ok ->
          Logger.debug("Agent completion handler succeeded", agent_id: state.agent_id)
          :ok

        {:error, reason} ->
          Logger.warning("Agent completion handler failed",
            agent_id: state.agent_id,
            error: inspect(reason)
          )

          {:error, reason}
      end

    new_state = %{
      state
      | status: :completed,
        completed_at: DateTime.utc_now(),
        query_task: nil
    }

    # Stop the session for non-interactive agents
    if state.session do
      ClaudeAgentSdkTs.Session.stop(state.session)
    end

    new_state = %{new_state | session: nil}

    # Persist final state snapshot to EventStore
    persist_state_snapshot(new_state)

    # Calculate duration
    duration_ms =
      if state.started_at do
        DateTime.diff(new_state.completed_at, state.started_at, :millisecond)
      end

    # Convert completion_result to JSON-serializable format
    serializable_completion_result =
      case completion_result do
        :ok -> %{status: "ok"}
        {:error, reason} -> %{status: "error", reason: inspect(reason)}
      end

    # Record completion event (for scheduler/lifecycle tracking)
    record_lifecycle_event(new_state, "agent_completed", %{
      agent_id: state.agent_id,
      duration_ms: duration_ms,
      completion_handler_result: serializable_completion_result
    })

    # Notify Pod.Manager of completion (for scheduler evaluation)
    Ipa.Pod.Manager.notify_agent_completed(state.task_id, state.agent_id, result)

    # Notify via PubSub (just a signal)
    notify_lifecycle(new_state, :agent_completed)
    broadcast_state_update(new_state)

    new_state
  end

  # Get the latest assistant response from conversation history
  defp get_latest_response(state) do
    state.conversation_history
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{type: :assistant, content: content} -> content
      _ -> nil
    end)
  end

  defp handle_agent_failure(state, reason) do
    error_msg = format_error(reason)

    Logger.error("Agent failed",
      agent_id: state.agent_id,
      error: error_msg
    )

    new_state = %{
      state
      | status: :failed,
        completed_at: DateTime.utc_now(),
        error: error_msg
    }

    # Record to Event Store (source of truth)
    record_lifecycle_event(new_state, "agent_failed", %{
      agent_id: state.agent_id,
      error: error_msg
    })

    # Notify Pod.Manager of failure (for scheduler evaluation)
    Ipa.Pod.Manager.notify_agent_failed(state.task_id, state.agent_id, error_msg)

    # Notify via PubSub (just a signal)
    notify_lifecycle(new_state, :agent_failed)

    new_state
  end

  defp format_error({exception, stacktrace}) when is_list(stacktrace) do
    "#{Exception.message(exception)}\n#{Exception.format_stacktrace(stacktrace)}"
  end

  defp format_error({:task_crashed, reason}) do
    "Task crashed: #{inspect(reason)}"
  end

  defp format_error(reason) do
    inspect(reason)
  end

  defp generate_tool_call_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  # ============================================================================
  # Event Store - Source of Truth for Lifecycle Events
  # ============================================================================

  defp record_lifecycle_event(state, event_type, data) do
    case Ipa.EventStore.append(
           state.task_id,
           event_type,
           data,
           actor_id: "agent:#{state.agent_id}"
         ) do
      {:ok, _version} ->
        Logger.debug("Recorded #{event_type} event",
          agent_id: state.agent_id,
          task_id: state.task_id
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to record #{event_type} event",
          agent_id: state.agent_id,
          task_id: state.task_id,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  # Persist conversation state snapshot to EventStore
  # This is called at turn completion or when agent is done
  defp persist_state_snapshot(state) do
    # Build the snapshot data with the unified conversation history
    snapshot_data = %{
      agent_id: state.agent_id,
      conversation_history: state.conversation_history,
      status: state.status,
      turn_number: state.turn_number
    }

    case Ipa.EventStore.append(
           state.task_id,
           "agent_state_snapshot",
           snapshot_data,
           actor_id: "agent:#{state.agent_id}"
         ) do
      {:ok, _version} ->
        Logger.debug("Persisted agent state snapshot",
          agent_id: state.agent_id,
          task_id: state.task_id,
          history_length: length(state.conversation_history)
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to persist agent state snapshot",
          agent_id: state.agent_id,
          task_id: state.task_id,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  # ============================================================================
  # PubSub - Notifications & Streaming
  # ============================================================================

  # Broadcast state update signal (LiveView should fetch fresh state from Instance)
  defp broadcast_state_update(state) do
    # Broadcast to agent-specific topic to signal state has changed
    # LiveViews should fetch fresh state from Agent.Instance.get_state/1
    Phoenix.PubSub.broadcast(
      Ipa.PubSub,
      "agent:#{state.agent_id}:state",
      {:state_updated, state.agent_id}
    )
  end

  # Broadcast streaming data (ephemeral, for LiveView real-time updates)
  defp broadcast_stream(state, event_type, data) do
    topic = "agent:#{state.agent_id}:stream"
    # Only log occasionally to avoid spam
    if event_type != :text_delta or rem(:erlang.unique_integer([:positive]), 20) == 0 do
      Logger.info("Instance broadcasting #{event_type} to #{topic}, agent=#{state.agent_id}")
    end
    Phoenix.PubSub.broadcast(
      Ipa.PubSub,
      topic,
      {event_type, state.agent_id, data}
    )
  end

  # Notify lifecycle change (just a signal, LiveView should fetch fresh state)
  defp notify_lifecycle(state, event_type) do
    # Broadcast to task-level topic - just agent_id, no data payload
    # LiveViews should fetch fresh state from Pod.Manager on receiving this
    Phoenix.PubSub.broadcast(
      Ipa.PubSub,
      "task:#{state.task_id}:agents",
      {event_type, state.agent_id}
    )
  end
end
