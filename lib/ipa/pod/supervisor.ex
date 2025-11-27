defmodule Ipa.PodSupervisor do
  @moduledoc """
  Main interface for managing pod lifecycle.

  This module provides functions to start, stop, restart, and query pods.
  Each pod is a supervised process tree that manages all components for a single task.

  Pods are dynamically started and stopped based on task activation/completion.
  """

  require Logger

  @doc """
  Starts a new pod for the given task_id.

  ## Parameters
    - `task_id` - Unique identifier for the task (must exist in Event Store)

  ## Returns
    - `{:ok, pid}` - Pod started successfully
    - `{:error, :already_started}` - Pod is already running
    - `{:error, :stream_not_found}` - Task doesn't exist in Event Store
    - `{:error, :timeout}` - Pod didn't start within timeout
    - `{:error, term}` - Other error

  ## Examples

      iex> {:ok, pid} = Ipa.PodSupervisor.start_pod("task-uuid-123")
      iex> is_pid(pid)
      true

      iex> Ipa.PodSupervisor.start_pod("task-uuid-123")
      {:error, :already_started}

      iex> Ipa.PodSupervisor.start_pod("nonexistent-task")
      {:error, :stream_not_found}
  """
  def start_pod(task_id) when is_binary(task_id) do
    # Check if pod is already running (includes Process.alive? check)
    if pod_running?(task_id) do
      {:error, :already_started}
    else
      # Clean up any stale registry entry from a dead process
      cleanup_stale_registry_entry(task_id)

      # Verify stream exists in Event Store
      case verify_stream_exists(task_id) do
        :ok ->
          do_start_pod(task_id)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Stops a running pod gracefully.

  ## Parameters
    - `task_id` - Unique identifier for the task

  ## Returns
    - `:ok` - Pod stopped successfully
    - `{:error, :not_running}` - Pod is not running
    - `{:error, term}` - Other error

  ## Examples

      iex> Ipa.PodSupervisor.stop_pod("task-uuid-123")
      :ok

      iex> Ipa.PodSupervisor.stop_pod("nonexistent-task")
      {:error, :not_running}
  """
  def stop_pod(task_id) when is_binary(task_id) do
    stop_pod(task_id, :normal)
  end

  @doc """
  Stops a running pod with a specific reason.

  ## Parameters
    - `task_id` - Unique identifier for the task
    - `reason` - Reason for stopping (for logging/debugging)

  ## Returns
    - `:ok` - Pod stopped successfully
    - `{:error, :not_running}` - Pod is not running
    - `{:error, term}` - Other error

  ## Examples

      iex> Ipa.PodSupervisor.stop_pod("task-uuid-123", :user_requested)
      :ok
  """
  def stop_pod(task_id, reason) when is_binary(task_id) do
    case get_pod_pid(task_id) do
      {:ok, pid} ->
        Logger.info("Stopping pod #{task_id} (reason: #{inspect(reason)})")

        # Use DynamicSupervisor.terminate_child for graceful shutdown
        # Note: Shutdown timeout is controlled by child_spec, not at runtime
        case DynamicSupervisor.terminate_child(__MODULE__, pid) do
          :ok ->
            Logger.info("Pod #{task_id} stopped successfully")
            :ok

          {:error, :not_found} ->
            # Pod already terminated
            :ok
        end

      {:error, :not_found} ->
        {:error, :not_running}
    end
  end

  @doc """
  Restarts a pod (stop + start).

  ## Parameters
    - `task_id` - Unique identifier for the task

  ## Returns
    - `{:ok, pid}` - Pod restarted successfully
    - `{:error, term}` - Error occurred

  ## Examples

      iex> {:ok, new_pid} = Ipa.PodSupervisor.restart_pod("task-uuid-123")
      iex> is_pid(new_pid)
      true
  """
  def restart_pod(task_id) when is_binary(task_id) do
    Logger.info("Restarting pod #{task_id}")

    # Get current pod PID if running, for monitoring
    current_pid =
      case get_pod_pid(task_id) do
        {:ok, pid} -> pid
        {:error, :not_found} -> nil
      end

    # Stop pod if running (ignore error if not running)
    case stop_pod(task_id, :restart_requested) do
      :ok ->
        # Wait for pod to terminate using Process.monitor
        wait_for_pod_termination(current_pid, task_id)

      {:error, :not_running} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end

    # Start pod
    case start_pod(task_id) do
      {:ok, pid} ->
        Logger.info("Pod #{task_id} restarted successfully")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to restart pod #{task_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Wait for pod process to terminate using Process.monitor
  defp wait_for_pod_termination(nil, _task_id), do: :ok

  defp wait_for_pod_termination(pid, task_id) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        # Give Registry time to clean up the entry
        Process.sleep(100)
        :ok
    after
      5_000 ->
        # Timeout waiting for termination
        Process.demonitor(ref, [:flush])
        Logger.warning("Timeout waiting for pod #{task_id} to terminate")
        :ok
    end
  end

  @doc """
  Gets the PID of a running pod.

  ## Parameters
    - `task_id` - Unique identifier for the task

  ## Returns
    - `{:ok, pid}` - Pod found
    - `{:error, :not_found}` - Pod not found

  ## Examples

      iex> {:ok, pid} = Ipa.PodSupervisor.get_pod_pid("task-uuid-123")
      iex> is_pid(pid)
      true
  """
  def get_pod_pid(task_id) when is_binary(task_id) do
    case Ipa.PodRegistry.lookup(task_id) do
      {:ok, pid, _metadata} -> {:ok, pid}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Checks if a pod is currently running.

  This function checks both that the pod is registered AND that the process is alive.
  This handles cases where the registry entry may be stale (e.g., pod crashed but
  registry cleanup hasn't completed yet).

  ## Parameters
    - `task_id` - Unique identifier for the task

  ## Returns
    - `true` - Pod is running
    - `false` - Pod is not running

  ## Examples

      iex> Ipa.PodSupervisor.pod_running?("task-uuid-123")
      true
  """
  def pod_running?(task_id) when is_binary(task_id) do
    case get_pod_pid(task_id) do
      {:ok, pid} ->
        # Verify the process is actually alive
        # This handles stale registry entries after crashes
        Process.alive?(pid)

      {:error, :not_found} ->
        false
    end
  end

  @doc """
  Lists all active pods with their metadata.

  ## Returns
    - List of pod info maps with keys: task_id, pid, status, started_at

  ## Examples

      iex> Ipa.PodSupervisor.list_pods()
      [
        %{task_id: "uuid-1", pid: #PID<0.123.0>, status: :active, started_at: 1699564800},
        %{task_id: "uuid-2", pid: #PID<0.124.0>, status: :active, started_at: 1699564805}
      ]
  """
  def list_pods do
    Ipa.PodRegistry.list_all()
    |> Enum.filter(fn
      {{:pod, _task_id}, _pid, _metadata} -> true
      _ -> false
    end)
    |> Enum.map(fn {{:pod, task_id}, pid, metadata} ->
      %{
        task_id: task_id,
        pid: pid,
        status: Map.get(metadata, :status, :unknown),
        started_at: Map.get(metadata, :started_at)
      }
    end)
  end

  @doc """
  Returns the number of active pods.

  ## Returns
    - Integer count of active pods

  ## Examples

      iex> Ipa.PodSupervisor.count_pods()
      3
  """
  def count_pods do
    Ipa.PodRegistry.count()
  end

  # Private Functions

  defp do_start_pod(task_id) do
    Logger.info("Starting pod #{task_id}")

    # Create child spec for the pod
    child_spec = Ipa.Pod.child_spec(task_id)

    # Start pod via DynamicSupervisor
    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        Logger.info("Pod #{task_id} started successfully")
        {:ok, pid}

      {:ok, pid, _info} ->
        Logger.info("Pod #{task_id} started successfully")
        {:ok, pid}

      {:error, {:already_started, _pid}} ->
        Logger.warning("Pod #{task_id} was already started")
        {:error, :already_started}

      {:error, reason} ->
        Logger.error("Failed to start pod #{task_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp verify_stream_exists(task_id) do
    # Let DB errors crash - they indicate a real problem that needs attention
    case Ipa.EventStore.stream_exists?(task_id) do
      true ->
        :ok

      false ->
        Logger.warning("Cannot start pod #{task_id}: stream not found in Event Store")
        {:error, :stream_not_found}
    end
  end

  # Clean up stale registry entries where the process is dead
  # This can happen if a pod crashes and the registry cleanup hasn't completed
  defp cleanup_stale_registry_entry(task_id) do
    case Ipa.PodRegistry.lookup(task_id) do
      {:ok, pid, _metadata} ->
        unless Process.alive?(pid) do
          Logger.info("Cleaning up stale registry entry for pod #{task_id} (dead process: #{inspect(pid)})")
          # The Registry should clean up automatically when the process dies,
          # but we can help by unregistering explicitly
          Ipa.PodRegistry.unregister(task_id)
          # Give a small delay for registry cleanup
          Process.sleep(50)
        end

      {:error, :not_found} ->
        :ok
    end
  end


  @doc """
  Returns the child specification for the PodSupervisor.

  This is used by the application supervision tree to start the PodSupervisor.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Starts the PodSupervisor.

  This function is called by the application supervision tree.
  """
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc false
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
