defmodule Ipa.Pod do
  @moduledoc """
  Represents a single pod (Supervisor for a task's processes).

  Each pod is an isolated supervision tree that manages all components for a single task:
  - Pod State Manager (event-sourced state management)
  - Pod Communications Manager (threaded messaging and approvals)
  - Pod Scheduler (state machine and agent orchestration)
  - External Sync (GitHub/JIRA integration)

  Note: Workspace management is handled by the stateless `Ipa.Pod.WorkspaceManager` module,
  which is called directly by Pod.Manager when creating workspaces.

  Pods use a one-for-one supervision strategy, meaning if a child crashes,
  only that child is restarted (not the entire pod).

  ## Registry
  Pods register themselves in `Ipa.PodRegistry` with key `{:pod, task_id}` during initialization.
  This ensures atomic registration and prevents duplicate pods.

  ## Lifecycle
  1. Pod is started via `Ipa.PodSupervisor.start_pod(task_id)`
  2. Pod registers itself in `Ipa.PodRegistry`
  3. Pod starts all child processes in order
  4. Pod transitions to `:active` status
  5. Pod can be stopped via `Ipa.PodSupervisor.stop_pod(task_id)`
  6. Children terminate gracefully (reverse order)
  7. Pod is automatically unregistered
  """

  use Supervisor
  require Logger

  @doc """
  Starts a pod supervisor with all child processes.

  This function is called by `Ipa.PodSupervisor` via `DynamicSupervisor.start_child/2`.
  It should not be called directly by users.

  ## Parameters
    - `task_id` - Unique identifier for the task

  ## Returns
    - `{:ok, pid}` - Pod started successfully
    - `{:error, {:already_started, pid}}` - Pod already registered
    - `{:error, term}` - Other error

  ## Examples

      # Called internally by Ipa.PodSupervisor
      {:ok, pid} = Ipa.Pod.start_link("task-uuid-123")
  """
  def start_link(task_id) when is_binary(task_id) do
    # Use :via tuple for atomic registration
    # This prevents race conditions - Registry ensures uniqueness
    Supervisor.start_link(__MODULE__, task_id, name: via_tuple(task_id))
  end

  defp via_tuple(task_id) do
    {:via, Registry, {Ipa.PodRegistry, {:pod, task_id}}}
  end

  @doc """
  Returns the child specification for the pod.

  This is used by `DynamicSupervisor.start_child/2` to start the pod.

  ## Parameters
    - `task_id` - Unique identifier for the task

  ## Returns
    - Child specification map

  ## Examples

      spec = Ipa.Pod.child_spec("task-uuid-123")
      DynamicSupervisor.start_child(Ipa.PodSupervisor, spec)
  """
  def child_spec(task_id) when is_binary(task_id) do
    %{
      id: {:pod, task_id},
      start: {__MODULE__, :start_link, [task_id]},
      restart: :temporary,
      # Prevents auto-restart on crash
      type: :supervisor,
      shutdown: get_config(:shutdown_timeout, 10_000)
    }
  end

  @impl true
  def init(task_id) do
    Logger.info("Initializing pod #{task_id} (pid: #{inspect(self())})")

    # Pod is already registered via :via tuple in start_link
    # Update metadata to set initial status
    Registry.update_value(Ipa.PodRegistry, {:pod, task_id}, fn _ ->
      %{status: :starting, started_at: System.system_time(:second)}
    end)

    # Get pod configuration
    config = Application.get_env(:ipa, __MODULE__, [])
    max_restarts = Keyword.get(config, :max_restarts, 3)
    max_seconds = Keyword.get(config, :max_seconds, 5)

    # Define children
    children = build_children(task_id)

    # Update status to active after init
    update_pod_status(task_id, :active)

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: max_restarts,
      max_seconds: max_seconds
    )
  end

  # Private Functions

  defp build_children(task_id) do
    # Start pod components in order
    # Agent Supervisor must start before Manager (Manager spawns agents via it)
    # Note: WorkspaceManager is now a stateless module, not a GenServer
    base_children = [
      {Ipa.Agent.Supervisor, task_id: task_id},
      {Ipa.Pod.Manager, task_id: task_id}
    ]

    # Add ExternalSync if GitHub is configured
    github_config = Application.get_env(:ipa, :github, [])

    if github_config[:repo] do
      base_children ++
        [{Ipa.Pod.ExternalSync, task_id: task_id, github: Map.new(github_config)}]
    else
      base_children
    end
  end

  defp update_pod_status(task_id, status) do
    case Ipa.PodRegistry.lookup(task_id) do
      {:ok, _pid, metadata} ->
        updated_metadata = Map.put(metadata, :status, status)
        Ipa.PodRegistry.update_meta(task_id, updated_metadata)
        Logger.debug("Pod #{task_id} status updated to #{status}")

      {:error, :not_found} ->
        Logger.warning("Pod #{task_id} not found in registry when updating status")
    end
  end

  defp get_config(key, default) do
    Application.get_env(:ipa, __MODULE__, [])
    |> Keyword.get(key, default)
  end

  @doc """
  Callback invoked when the pod is terminating.

  This ensures children are given time to clean up gracefully.
  """
  def terminate(reason, _state) do
    # Extract task_id from state if available
    # Note: Supervisor state format may vary, this is a safeguard
    Logger.info("Pod terminating (reason: #{inspect(reason)})")
    :ok
  end
end
