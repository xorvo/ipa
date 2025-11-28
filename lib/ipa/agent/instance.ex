defmodule Ipa.Agent.Instance do
  @moduledoc """
  GenServer that manages a single agent's execution lifecycle.

  Each agent instance:
  - Registers itself in PodRegistry for lookup
  - Spawns a Task to run the Claude SDK query
  - Processes streaming messages and updates internal state
  - Records lifecycle events to Event Store (source of truth)
  - Broadcasts streaming updates to PubSub (for LiveView)
  - Handles interruption and cleanup

  ## State

  The instance maintains rich state including:
  - Agent identity (id, type, task_id, workstream_id)
  - Execution status (:initializing, :running, :completed, :failed, :interrupted)
  - Streaming output (current_response, tool_calls, messages)
  - Timing (started_at, completed_at)

  ## Event Store (Source of Truth)

  Lifecycle events are recorded to the Event Store:
  - `agent_started` - When agent begins execution
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
    :current_response,
    :tool_calls,
    :messages,
    :result,
    :error,
    :context
  ]

  @type t :: %__MODULE__{
          agent_id: String.t(),
          agent_type: module(),
          task_id: String.t(),
          workstream_id: String.t() | nil,
          workspace_path: String.t() | nil,
          prompt: String.t(),
          status: :initializing | :running | :completed | :failed | :interrupted,
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          query_task: Task.t() | nil,
          current_response: String.t(),
          tool_calls: [map()],
          messages: [map()],
          result: term(),
          error: String.t() | nil,
          context: map()
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

    state = %__MODULE__{
      agent_id: agent_id,
      agent_type: agent_type,
      task_id: task_id,
      workstream_id: context[:workstream_id],
      workspace_path: context[:workspace],
      prompt: prompt,
      status: :initializing,
      started_at: DateTime.utc_now(),
      current_response: "",
      tool_calls: [],
      messages: [],
      context: context
    }

    # Schedule notification and query to run after init completes
    # This prevents init from blocking on GenServer calls which can cause timeouts
    # NOTE: The agent_started event is already recorded by Pod.Manager through AgentCommands
    # when it starts this agent. We only need to broadcast the PubSub notification here.
    send(self(), :notify_agent_started)
    send(self(), {:run_query, prompt, options})

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
  def handle_info({:run_query, prompt, options}, state) do
    # Spawn a Task to run the Claude SDK query
    # The Task sends messages back to this GenServer as they arrive
    parent = self()

    task =
      Task.async(fn ->
        run_streaming_query(prompt, options, parent)
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
  def handle_info({ref, result}, state) when state.query_task != nil and ref == state.query_task.ref do
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
    state_map = %{
      agent_id: state.agent_id,
      agent_type: state.agent_type.agent_type(),
      task_id: state.task_id,
      workstream_id: state.workstream_id,
      workspace: state.workspace_path,
      prompt: state.prompt,
      status: state.status,
      started_at: state.started_at,
      completed_at: state.completed_at,
      current_response: state.current_response,
      tool_calls: state.tool_calls,
      error: state.error
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

    new_state = %{
      state
      | status: :interrupted,
        completed_at: DateTime.utc_now(),
        query_task: nil
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
  def terminate(reason, state) do
    Logger.info("Agent instance terminating",
      agent_id: state.agent_id,
      reason: inspect(reason)
    )

    # Cancel any running query task
    if state.query_task do
      Task.shutdown(state.query_task, :brutal_kill)
    end

    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp via_tuple(agent_id) do
    {:via, Registry, {Ipa.PodRegistry, {:agent, agent_id}}}
  end

  defp run_streaming_query(prompt, options, parent) do
    try do
      # Convert options to ClaudeAgentSdkTs format
      claude_opts = convert_options_to_claude_agent_sdk(options)

      # Stream query results back to the parent GenServer
      # ClaudeAgentSdkTs.stream/3 uses a callback for streaming and returns :ok when done
      # Messages are sent via the callback, so we don't need to enumerate anything
      result = ClaudeAgentSdkTs.stream(prompt, claude_opts, fn message ->
        send(parent, {:stream_message, message})
      end)

      case result do
        :ok ->
          {:ok, :completed}

        {:ok, response} ->
          {:ok, response}

        {:error, reason} ->
          {:error, reason}

        other ->
          # Handle unexpected return values gracefully
          Logger.warning("Unexpected return from ClaudeAgentSdkTs.stream: #{inspect(other)}")
          {:ok, other}
      end
    rescue
      error ->
        {:error, {error, __STACKTRACE__}}
    end
  end

  defp convert_options_to_claude_agent_sdk(options) do
    # Convert from Ipa.Agent.Options struct to ClaudeAgentSdkTs options keyword list
    base_opts = [
      cwd: options.cwd,
      max_turns: options.max_turns,
      timeout: options.timeout_ms
    ]

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
        new_response = state.current_response <> text
        # Broadcast streaming data via PubSub (ephemeral, for LiveView)
        broadcast_stream(state, :text_delta, %{text: text})
        %{state | current_response: new_response, messages: [message | state.messages]}

      {:tool_use_start, tool_name, args} ->
        tool_call = %{
          id: generate_tool_call_id(),
          name: tool_name,
          args: args,
          status: :running,
          started_at: DateTime.utc_now(),
          result: nil
        }

        # Call agent type's tool call handler if defined
        if function_exported?(state.agent_type, :handle_tool_call, 3) do
          state.agent_type.handle_tool_call(tool_name, args, state.context)
        end

        # Broadcast streaming data via PubSub (ephemeral)
        broadcast_stream(state, :tool_start, %{tool_name: tool_name, args: args})
        %{state | tool_calls: [tool_call | state.tool_calls], messages: [message | state.messages]}

      {:tool_complete, tool_name, result} ->
        tool_calls = update_tool_call_result(state.tool_calls, tool_name, result)
        # Broadcast streaming data via PubSub (ephemeral)
        broadcast_stream(state, :tool_complete, %{tool_name: tool_name, result: result})
        %{state | tool_calls: tool_calls, messages: [message | state.messages]}

      {:message_stop, _} ->
        %{state | messages: [message | state.messages]}

      _ ->
        %{state | messages: [message | state.messages]}
    end
  end

  defp handle_agent_success(state, _final_messages) do
    Logger.info("Agent completed successfully", agent_id: state.agent_id)

    # Call the agent type's completion handler
    result = %{workspace: state.workspace_path, response: state.current_response}

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
        completed_at: DateTime.utc_now()
    }

    # Calculate duration
    duration_ms =
      if state.started_at do
        DateTime.diff(new_state.completed_at, state.started_at, :millisecond)
      end

    # Convert completion_result to JSON-serializable format
    # completion_result is only :ok or {:error, reason} from handle_completion
    serializable_completion_result =
      case completion_result do
        :ok -> %{status: "ok"}
        {:error, reason} -> %{status: "error", reason: inspect(reason)}
      end

    # Record to Event Store (source of truth)
    # Store the full output for persistent history (not truncated)
    record_lifecycle_event(new_state, "agent_completed", %{
      agent_id: state.agent_id,
      duration_ms: duration_ms,
      result_summary: String.slice(state.current_response, 0, 1000),
      output: state.current_response,
      completion_handler_result: serializable_completion_result
    })

    # Notify Pod.Manager of completion (for scheduler evaluation)
    Ipa.Pod.Manager.notify_agent_completed(state.task_id, state.agent_id, result)

    # Notify via PubSub (just a signal)
    notify_lifecycle(new_state, :agent_completed)

    new_state
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

  defp update_tool_call_result(tool_calls, tool_name, result) do
    Enum.map(tool_calls, fn call ->
      if call.name == tool_name && call.status == :running do
        %{call | status: :completed, result: result, completed_at: DateTime.utc_now()}
      else
        call
      end
    end)
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

  # ============================================================================
  # PubSub - Notifications & Streaming
  # ============================================================================

  # Broadcast streaming data (ephemeral, for LiveView real-time updates)
  defp broadcast_stream(state, event_type, data) do
    Phoenix.PubSub.broadcast(
      Ipa.PubSub,
      "agent:#{state.agent_id}:stream",
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
