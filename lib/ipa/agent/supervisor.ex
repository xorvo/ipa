defmodule Ipa.Agent.Supervisor do
  @moduledoc """
  DynamicSupervisor for agent processes within a pod.

  Each pod has one Agent Supervisor that manages all agents for that task.
  Agents are started with `restart: :temporary` - they should not be
  automatically restarted on crash. Instead, the Scheduler should handle
  the failure and decide whether to retry.

  ## Registration

  Agent Supervisors register via the existing `Ipa.PodRegistry` with key
  `{:agent_supervisor, task_id}` for easy lookup.

  ## Agent Lifecycle

  1. Agent is started via `start_agent/3`
  2. Agent registers itself in PodRegistry with key `{:agent, agent_id}`
  3. Agent runs Claude SDK query in a Task
  4. Agent broadcasts completion/failure events
  5. Agent can be stopped via `stop_agent/2` or naturally terminates
  6. On pod shutdown, all agents are terminated
  """

  use DynamicSupervisor
  require Logger

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the Agent Supervisor for a task.

  Called by Pod Supervisor when the pod is started.
  """
  def start_link(opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    DynamicSupervisor.start_link(__MODULE__, opts, name: via_tuple(task_id))
  end

  @doc """
  Returns the child specification for the Agent Supervisor.
  """
  def child_spec(opts) do
    task_id = Keyword.fetch!(opts, :task_id)

    %{
      id: {:agent_supervisor, task_id},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent
    }
  end

  @doc """
  Starts a new agent under this supervisor.

  ## Parameters
    - `task_id` - Task UUID
    - `agent_type` - Module implementing the Ipa.Agent behaviour
    - `context` - Map with agent context (workspace, task info, etc.)

  ## Returns
    - `{:ok, agent_id}` - Agent started successfully
    - `{:error, reason}` - Failed to start agent
  """
  @spec start_agent(String.t(), module(), map()) :: {:ok, String.t()} | {:error, term()}
  def start_agent(task_id, agent_type, context) do
    agent_id = generate_agent_id(agent_type)

    Logger.info("Starting agent",
      task_id: task_id,
      agent_id: agent_id,
      agent_type: agent_type.agent_type()
    )

    child_spec = %{
      id: agent_id,
      start:
        {Ipa.Agent.Instance, :start_link,
         [
           [
             agent_id: agent_id,
             agent_type: agent_type,
             task_id: task_id,
             context: context
           ]
         ]},
      restart: :temporary,
      type: :worker
    }

    case DynamicSupervisor.start_child(via_tuple(task_id), child_spec) do
      {:ok, _pid} ->
        Logger.info("Agent started successfully", agent_id: agent_id)
        {:ok, agent_id}

      {:ok, _pid, _info} ->
        Logger.info("Agent started successfully", agent_id: agent_id)
        {:ok, agent_id}

      {:error, reason} ->
        Logger.error("Failed to start agent",
          agent_id: agent_id,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  @doc """
  Stops an agent under this supervisor.

  ## Parameters
    - `task_id` - Task UUID
    - `agent_id` - Agent ID

  ## Returns
    - `:ok` - Agent stopped
    - `{:error, :not_found}` - Agent not found
  """
  @spec stop_agent(String.t(), String.t()) :: :ok | {:error, :not_found}
  def stop_agent(task_id, agent_id) do
    case find_agent_pid(agent_id) do
      nil ->
        {:error, :not_found}

      pid ->
        Logger.info("Stopping agent", task_id: task_id, agent_id: agent_id)
        DynamicSupervisor.terminate_child(via_tuple(task_id), pid)
        :ok
    end
  end

  @doc """
  Lists all agent PIDs under this supervisor.

  ## Parameters
    - `task_id` - Task UUID

  ## Returns
    - List of PIDs
  """
  @spec list_agents(String.t()) :: [pid()]
  def list_agents(task_id) do
    case GenServer.whereis(via_tuple(task_id)) do
      nil ->
        []

      _pid ->
        DynamicSupervisor.which_children(via_tuple(task_id))
        |> Enum.map(fn {_, pid, _, _} -> pid end)
        |> Enum.filter(&is_pid/1)
    end
  end

  @doc """
  Counts the number of running agents under this supervisor.

  ## Parameters
    - `task_id` - Task UUID

  ## Returns
    - Integer count
  """
  @spec count_agents(String.t()) :: non_neg_integer()
  def count_agents(task_id) do
    list_agents(task_id) |> length()
  end

  @doc """
  Terminates all agents under this supervisor.

  ## Parameters
    - `task_id` - Task UUID

  ## Returns
    - `:ok`
  """
  @spec terminate_all(String.t()) :: :ok
  def terminate_all(task_id) do
    case GenServer.whereis(via_tuple(task_id)) do
      nil ->
        :ok

      _pid ->
        for {_, pid, _, _} <- DynamicSupervisor.which_children(via_tuple(task_id)),
            is_pid(pid) do
          DynamicSupervisor.terminate_child(via_tuple(task_id), pid)
        end

        :ok
    end
  end

  # ============================================================================
  # DynamicSupervisor Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp via_tuple(task_id) do
    {:via, Registry, {Ipa.PodRegistry, {:agent_supervisor, task_id}}}
  end

  defp generate_agent_id(agent_type) do
    type_name =
      agent_type.agent_type()
      |> to_string()
      |> String.replace("_", "-")

    timestamp = System.unique_integer([:positive])
    "#{type_name}-#{timestamp}"
  end

  defp find_agent_pid(agent_id) do
    case Registry.lookup(Ipa.PodRegistry, {:agent, agent_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
