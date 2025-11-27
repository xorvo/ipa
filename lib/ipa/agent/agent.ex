defmodule Ipa.Agent do
  @moduledoc """
  Common behaviour and API for all agent types.

  Provides streaming output, lifecycle management, and observability.
  This module defines the behaviour that agent type modules must implement,
  and provides the public API for interacting with agents.

  ## Agent Types

  Agent types implement this behaviour and define:
  - `agent_type/0` - Atom identifying the agent type
  - `generate_prompt/1` - Generate the prompt for the agent
  - `configure_options/1` - Configure Claude SDK options
  - `handle_completion/2` - Handle successful completion
  - `handle_tool_call/3` - Handle tool calls (optional, for logging/hooks)

  ## Public API

  - `start/3` - Start an agent under the pod's agent supervisor
  - `stop/1` - Stop a running agent
  - `interrupt/1` - Interrupt a running agent
  - `get_state/1` - Get the current state of an agent
  - `subscribe/1` - Subscribe to agent streaming events
  - `list_agents/1` - List all agents for a task

  ## PubSub Topics

  Agents broadcast events to two topics:
  - `"agent:{agent_id}:stream"` - Streaming events (text_delta, tool_start, tool_complete)
  - `"task:{task_id}:agents"` - Lifecycle events (agent_started, agent_completed, agent_failed)
  """

  @type agent_id :: String.t()
  @type task_id :: String.t()
  @type message_type :: :text_delta | :tool_use_start | :tool_complete | :message_start | :message_stop

  # ============================================================================
  # Behaviour Callbacks
  # ============================================================================

  @doc """
  Returns the atom identifying this agent type.

  ## Examples

      def agent_type, do: :planning_agent
      def agent_type, do: :workstream
  """
  @callback agent_type() :: atom()

  @doc """
  Generates the prompt for the agent based on the provided context.

  ## Parameters
    - `context` - Map containing task state, workstream info, etc.

  ## Returns
    - String containing the prompt
  """
  @callback generate_prompt(context :: map()) :: String.t()

  @doc """
  Configures the Claude Agent SDK options for this agent type.

  ## Parameters
    - `context` - Map containing workspace path, task info, etc.

  ## Returns
    - Ipa.Agent.Options struct
  """
  @callback configure_options(context :: map()) :: Ipa.Agent.Options.t()

  @doc """
  Handles successful agent completion.

  This callback is invoked when the agent completes successfully.
  Use it to parse output files, emit events, or perform cleanup.

  ## Parameters
    - `result` - Map with :workspace and :response keys
    - `context` - Original context passed to the agent

  ## Returns
    - `:ok` | `{:error, term()}`
  """
  @callback handle_completion(result :: map(), context :: map()) :: :ok | {:error, term()}

  @doc """
  Handles tool calls made by the agent.

  This optional callback can be used for logging, metrics,
  or custom hooks per tool. Default implementation does nothing.

  ## Parameters
    - `tool_name` - Name of the tool being called
    - `args` - Arguments passed to the tool
    - `context` - Original context

  ## Returns
    - `:ok`
  """
  @callback handle_tool_call(tool_name :: String.t(), args :: map(), context :: map()) :: :ok

  @optional_callbacks [handle_tool_call: 3]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts an agent under the pod's agent supervisor.

  ## Parameters
    - `agent_type` - Module implementing the Ipa.Agent behaviour
    - `task_id` - Task UUID
    - `opts` - Keyword list or map with agent context (workspace, workstream info, etc.)

  ## Returns
    - `{:ok, agent_id}` - Agent started successfully
    - `{:error, reason}` - Failed to start agent

  ## Examples

      {:ok, agent_id} = Ipa.Agent.start(Ipa.Agent.Types.Planning, "task-123",
        workspace: "/path/to/workspace",
        task: task_state,
        claude_md: claude_md_content
      )
  """
  @spec start(module(), task_id(), keyword() | map()) :: {:ok, agent_id()} | {:error, term()}
  def start(agent_type, task_id, opts) when is_atom(agent_type) and is_binary(task_id) do
    context = if is_list(opts), do: Map.new(opts), else: opts
    Ipa.Agent.Supervisor.start_agent(task_id, agent_type, context)
  end

  @doc """
  Stops a running agent gracefully.

  ## Parameters
    - `agent_id` - Agent ID

  ## Returns
    - `:ok` - Agent stopped
    - `{:error, :not_found}` - Agent not found
  """
  @spec stop(agent_id()) :: :ok | {:error, :not_found}
  def stop(agent_id) when is_binary(agent_id) do
    case Ipa.Agent.Instance.get_state(agent_id) do
      {:ok, state} ->
        Ipa.Agent.Supervisor.stop_agent(state.task_id, agent_id)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Interrupts a running agent, canceling the SDK query.

  ## Parameters
    - `agent_id` - Agent ID

  ## Returns
    - `:ok` - Agent interrupted
    - `{:error, :not_found}` - Agent not found
  """
  @spec interrupt(agent_id()) :: :ok | {:error, :not_found}
  def interrupt(agent_id) when is_binary(agent_id) do
    Ipa.Agent.Instance.interrupt(agent_id)
  end

  @doc """
  Gets the current state of an agent.

  ## Parameters
    - `agent_id` - Agent ID

  ## Returns
    - `{:ok, state}` - Agent state map
    - `{:error, :not_found}` - Agent not found

  ## State Map Keys

  - `:agent_id` - Unique agent identifier
  - `:agent_type` - Agent type atom
  - `:task_id` - Task UUID
  - `:workstream_id` - Workstream ID (if applicable)
  - `:workspace` - Workspace path
  - `:prompt` - The prompt sent to the agent
  - `:status` - :initializing | :running | :completed | :failed | :interrupted
  - `:started_at` - DateTime when agent started
  - `:completed_at` - DateTime when agent completed (if finished)
  - `:current_response` - Accumulated text response
  - `:tool_calls` - List of tool calls with status
  - `:error` - Error details (if failed)
  """
  @spec get_state(agent_id()) :: {:ok, map()} | {:error, :not_found}
  def get_state(agent_id) when is_binary(agent_id) do
    Ipa.Agent.Instance.get_state(agent_id)
  end

  @doc """
  Subscribes to streaming events for an agent.

  Events are sent to the subscribing process as messages:
  - `{:text_delta, agent_id, %{text: text}}`
  - `{:tool_start, agent_id, %{tool_name: name, args: args}}`
  - `{:tool_complete, agent_id, %{tool_name: name, result: result}}`
  - `{:agent_completed, agent_id, %{response_summary: summary}}`
  - `{:agent_failed, agent_id, %{error: error}}`

  ## Parameters
    - `agent_id` - Agent ID

  ## Returns
    - `:ok`

  ## Examples

      :ok = Ipa.Agent.subscribe(agent_id)

      # Then in handle_info:
      def handle_info({:text_delta, agent_id, %{text: text}}, socket) do
        # Handle streaming text
      end
  """
  @spec subscribe(agent_id()) :: :ok
  def subscribe(agent_id) when is_binary(agent_id) do
    Phoenix.PubSub.subscribe(Ipa.PubSub, "agent:#{agent_id}:stream")
  end

  @doc """
  Unsubscribes from streaming events for an agent.

  ## Parameters
    - `agent_id` - Agent ID

  ## Returns
    - `:ok`
  """
  @spec unsubscribe(agent_id()) :: :ok
  def unsubscribe(agent_id) when is_binary(agent_id) do
    Phoenix.PubSub.unsubscribe(Ipa.PubSub, "agent:#{agent_id}:stream")
  end

  @doc """
  Subscribes to agent lifecycle events for a task.

  Events are sent to the subscribing process as messages:
  - `{:agent_started, agent_id, %{prompt: prompt}}`
  - `{:agent_completed, agent_id, %{response_summary: summary}}`
  - `{:agent_failed, agent_id, %{error: error}}`
  - `{:agent_interrupted, agent_id, %{}}`

  ## Parameters
    - `task_id` - Task UUID

  ## Returns
    - `:ok`
  """
  @spec subscribe_task(task_id()) :: :ok
  def subscribe_task(task_id) when is_binary(task_id) do
    Phoenix.PubSub.subscribe(Ipa.PubSub, "task:#{task_id}:agents")
  end

  @doc """
  Lists all agents for a task.

  Returns a list of agent state maps for all agents (running and completed)
  associated with the given task.

  ## Parameters
    - `task_id` - Task UUID

  ## Returns
    - List of agent state maps
  """
  @spec list_agents(task_id()) :: [map()]
  def list_agents(task_id) when is_binary(task_id) do
    Ipa.Agent.Supervisor.list_agents(task_id)
    |> Enum.map(fn pid ->
      case GenServer.call(pid, :get_state) do
        state when is_map(state) -> state
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
